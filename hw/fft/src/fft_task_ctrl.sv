// One reserved read burst and one reserved write burst may be outstanding.
// Entire write payloads are retained until WLAST, including during error drain.
module fft_task_ctrl #(
  parameter int unsigned AddrWidth = 48,
  parameter int unsigned DataWidth = 64,
  parameter int unsigned TransIdWidth = 3,
  parameter type exception_t = logic,
  parameter type axi_req_t = logic,
  parameter type axi_rsp_t = logic
) (
  input logic clk_i, rst_ni,
  input logic cmd_valid_i,
  output logic cmd_ready_o,
  input logic [31:0] cmd_insn_i,
  input logic [AddrWidth-1:0] cmd_src_addr_i,cmd_dst_addr_i,
  input logic [TransIdWidth-1:0] cmd_trans_id_i,
  output logic resp_valid_o,
  output logic [TransIdWidth-1:0] resp_trans_id_o,
  output exception_t resp_exception_o,
  output axi_req_t axi_req_o,
  input axi_rsp_t axi_rsp_i,
  output logic core_reset_o,core_ce_o,core_inverse_o,
  output logic [31:0] core_left_o,core_right_o,
  input logic [45:0] core_left_i,core_right_i,
  input logic core_sync_i
);
  localparam int Bytes = DataWidth/8;
  localparam int FullSize = $clog2(Bytes);
  localparam int PairDepth = 64;
  typedef enum logic [1:0] {Idle,ResetCore,Run,Done} task_state_t;
  typedef enum logic [1:0] {ReadIdle,ReadAddr,ReadData,ReadFeed} read_state_t;
  typedef enum logic [2:0] {WriteIdle,WriteFill,WriteAddr,WriteData,WriteResp} write_state_t;
  task_state_t task_q;
  read_state_t read_q;
  write_state_t write_q;
  logic [AddrWidth-1:0] read_addr_q,write_addr_q;
  logic [13:0] read_bytes_q;
  logic [12:0] write_words_q;
  logic [TransIdWidth-1:0] trans_q;
  logic inverse_q,error_q,output_active_q;
  logic [11:0] input_pairs_q,output_pairs_q;
  logic [4:0] read_beats_q,read_index_q,write_beats_q,write_index_q;
  logic [2:0] read_size_q,write_size_q;
  logic [6:0] feed_pairs_q,feed_index_q;
  logic [DataWidth-1:0] read_buffer [16];
  logic [DataWidth-1:0] write_buffer [16];
  logic [127:0] output_fifo [PairDepth];
  logic [5:0] pair_wr_q;
  logic [6:0] word_rd_q,second_index;
  logic [7:0] fifo_words_q;
  logic [1:0] pop_words;
  logic push_pair,bus_error,feed_pair;
  logic [63:0] first_word,second_word;
  logic [DataWidth-1:0] packed_beat;
  int unsigned read_plan_size,read_plan_beats,write_plan_size,write_plan_beats;
  int unsigned feed_row,feed_lane;

  function automatic logic [63:0] result_word(input logic [45:0] value);
    return {{9{value[22]}},value[22:0],{9{value[45]}},value[45:23]};
  endfunction

  // Prefix/suffix accesses preserve the legacy eight-byte alignment contract.
  // Full-width bursts never cross a page or consume bytes outside the input.
  always_comb begin
    read_plan_size = FullSize;
    if ((read_addr_q % Bytes) != 0 || read_bytes_q < Bytes) read_plan_size=3;
    read_plan_beats = int'(read_bytes_q) >> read_plan_size;
    if (read_plan_size != FullSize) read_plan_beats=1;
    if (read_plan_beats>16) read_plan_beats=16;
    if (read_plan_beats>((4096-int'(read_addr_q[11:0])) >> read_plan_size))
      read_plan_beats=(4096-int'(read_addr_q[11:0])) >> read_plan_size;
    write_plan_size=FullSize;
    if ((write_addr_q % Bytes) != 0 || write_words_q < Bytes/8) write_plan_size=3;
    write_plan_beats=(int'(write_words_q)*8) >> write_plan_size;
    if (write_plan_size != FullSize) write_plan_beats=1;
    if (write_plan_beats>16) write_plan_beats=16;
    if (write_plan_beats>((4096-int'(write_addr_q[11:0])) >> write_plan_size))
      write_plan_beats=(4096-int'(write_addr_q[11:0])) >> write_plan_size;
  end

  assign cmd_ready_o = task_q==Idle;
  assign resp_valid_o = task_q==Done;
  assign resp_trans_id_o = trans_q;
  assign core_reset_o = task_q==ResetCore;
  assign core_inverse_o = inverse_q;
  assign bus_error = (axi_rsp_i.r_valid && axi_req_o.r_ready && axi_rsp_i.r.resp[1]) ||
                     (axi_rsp_i.b_valid && axi_req_o.b_ready && axi_rsp_i.b.resp[1]);
  assign core_ce_o = task_q==Run && !error_q && !bus_error &&
                     output_pairs_q<2048 && fifo_words_q<=126 &&
                     (input_pairs_q==2048 || read_q==ReadFeed);
  assign feed_pair=core_ce_o && input_pairs_q<2048;
  assign push_pair=core_ce_o && (core_sync_i || output_active_q);
  assign first_word=output_fifo[word_rd_q[6:1]][word_rd_q[0]*64+:64];
  // A 128-bit beat can straddle two core pairs when dst % 16 == 8.
  assign second_index=word_rd_q+7'd1;
  assign second_word=output_fifo[second_index[6:1]][second_index[0]*64+:64];

  always_comb begin
    resp_exception_o='0;
    resp_exception_o.valid=error_q;
    resp_exception_o.cause=1;
    feed_row=int'(feed_index_q)/((1<<read_size_q)/4);
    feed_lane=(int'(feed_index_q)%((1<<read_size_q)/4))*32;
    core_left_o='0;
    core_right_o='0;
    if (feed_pair) begin
      core_left_o={read_buffer[feed_row][feed_lane+:16],16'b0};
      core_right_o={read_buffer[feed_row][feed_lane+16+:16],16'b0};
    end
    pop_words=0;
    packed_beat='0;
    if(write_q==WriteFill && !error_q && !bus_error) begin
      if(write_size_q==4 && fifo_words_q>=2) begin
        packed_beat=DataWidth'({second_word,first_word});
        pop_words=2;
      end else if(write_size_q==3 && fifo_words_q>=1) begin
        packed_beat=DataWidth'(first_word) << ((write_addr_q%Bytes)*8);
        pop_words=1;
      end
    end
    axi_req_o='0;
    axi_req_o.ar.addr=read_addr_q;
    axi_req_o.ar.len=8'(read_beats_q-1'b1);
    axi_req_o.ar.size=read_size_q;
    axi_req_o.ar.burst=2'b01;
    axi_req_o.ar.cache=4'b0011;
    axi_req_o.ar_valid=read_q==ReadAddr;
    axi_req_o.r_ready=read_q==ReadData;
    axi_req_o.aw.addr=write_addr_q;
    axi_req_o.aw.len=8'(write_beats_q-1'b1);
    axi_req_o.aw.size=write_size_q;
    axi_req_o.aw.burst=2'b01;
    axi_req_o.aw.cache=4'b0011;
    axi_req_o.aw_valid=write_q==WriteAddr;
    axi_req_o.w.data=write_buffer[write_index_q[3:0]];
    axi_req_o.w.strb='1;
    if(write_size_q==3) axi_req_o.w.strb=(DataWidth/8)'(8'hff) << (write_addr_q%Bytes);
    axi_req_o.w.last=write_index_q==write_beats_q-1'b1;
    axi_req_o.w_valid=write_q==WriteData;
    axi_req_o.b_ready=write_q==WriteResp;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if(!rst_ni) begin
      task_q<=Idle;read_q<=ReadIdle;write_q<=WriteIdle;
      read_addr_q<='0;write_addr_q<='0;read_bytes_q<='0;write_words_q<='0;
      trans_q<='0;inverse_q<=0;error_q<=0;output_active_q<=0;
      input_pairs_q<=0;output_pairs_q<=0;read_beats_q<=1;read_index_q<=0;
      read_size_q<=3;write_size_q<=3;write_beats_q<=1;write_index_q<=0;
      feed_pairs_q<=0;feed_index_q<=0;pair_wr_q<=0;word_rd_q<=0;fifo_words_q<=0;
    end else begin
      if(bus_error) error_q<=1;
      if(push_pair) begin
        output_fifo[pair_wr_q]<={result_word(core_right_i),result_word(core_left_i)};
        pair_wr_q<=pair_wr_q+1'b1;
        output_active_q<=1;
        output_pairs_q<=output_pairs_q+1'b1;
      end
      if(push_pair || pop_words!=0) fifo_words_q<=fifo_words_q+8'(push_pair ? 2:0)-8'(pop_words);
      if(pop_words!=0) word_rd_q<=word_rd_q+7'(pop_words);
      if(feed_pair) begin
        input_pairs_q<=input_pairs_q+1'b1;
        feed_index_q<=feed_index_q+1'b1;
        if(feed_index_q==feed_pairs_q-1'b1) read_q<=ReadIdle;
      end
      case(task_q)
        Idle: if(cmd_valid_i) begin
          task_q<=ResetCore;read_q<=ReadIdle;write_q<=WriteIdle;
          read_addr_q<=cmd_src_addr_i;write_addr_q<=cmd_dst_addr_i;
          read_bytes_q<=8192;write_words_q<=4096;trans_q<=cmd_trans_id_i;
          inverse_q<=cmd_insn_i[31];
          error_q<=cmd_src_addr_i[2:0]!=0 || cmd_dst_addr_i[2:0]!=0;
          input_pairs_q<=0;output_pairs_q<=0;output_active_q<=0;
          pair_wr_q<=0;word_rd_q<=0;fifo_words_q<=0;
        end
        ResetCore: task_q<=Run;
        Run: if(read_q==ReadIdle && write_q==WriteIdle &&
          (error_q || (write_words_q==0 && output_pairs_q==2048 && read_bytes_q==0)))
            task_q<=Done;
        Done: task_q<=Idle;
        default: task_q<=Idle;
      endcase

      if(task_q==Run) begin
        case(read_q)
          ReadIdle: if(!error_q && !bus_error && read_bytes_q!=0) begin
            read_beats_q<=5'(read_plan_beats);read_size_q<=3'(read_plan_size);
            read_q<=ReadAddr;
          end
          ReadAddr: if(axi_rsp_i.ar_ready) begin
            read_q<=ReadData;read_index_q<=0;
            read_bytes_q<=read_bytes_q-14'(int'(read_beats_q)<<read_size_q);
          end
          ReadData: if(axi_rsp_i.r_valid) begin
            // All R beats have reserved storage. During drain RREADY is unconditional.
            if(!error_q && !bus_error) read_buffer[read_index_q[3:0]]<=
              axi_rsp_i.r.data >> ((read_addr_q%Bytes)*8);
            read_index_q<=read_index_q+1'b1;
            if(axi_rsp_i.r.last) begin
              read_addr_q<=read_addr_q+AddrWidth'(int'(read_beats_q)<<read_size_q);
              feed_pairs_q<=7'(int'(read_beats_q) << (read_size_q-2));
              feed_index_q<=0;
              read_q<=(error_q || bus_error) ? ReadIdle:ReadFeed;
            end
          end
          ReadFeed: if(error_q || bus_error) read_q<=ReadIdle;
          default: read_q<=ReadIdle;
        endcase
        case(write_q)
          WriteIdle: if(!error_q && !bus_error && write_words_q!=0) begin
            write_beats_q<=5'(write_plan_beats);write_size_q<=3'(write_plan_size);
            write_index_q<=0;write_q<=WriteFill;
          end
          WriteFill: begin
            if(error_q || bus_error) write_q<=WriteIdle;
            else if(pop_words!=0) begin
              write_buffer[write_index_q[3:0]]<=packed_beat;
              write_index_q<=write_index_q+1'b1;
              if(write_index_q==write_beats_q-1'b1) begin
                write_index_q<=0;write_q<=WriteAddr;
              end
            end
          end
          WriteAddr: if(axi_rsp_i.aw_ready) write_q<=WriteData;
          WriteData: if(axi_rsp_i.w_ready) begin
            write_index_q<=write_index_q+1'b1;
            if(write_index_q==write_beats_q-1'b1) write_q<=WriteResp;
          end
          WriteResp: if(axi_rsp_i.b_valid) begin
            write_q<=WriteIdle;
            write_addr_q<=write_addr_q+AddrWidth'(int'(write_beats_q)<<write_size_q);
            write_words_q<=write_words_q-13'(int'(write_beats_q) << (write_size_q-3));
          end
          default: write_q<=WriteIdle;
        endcase
      end
`ifndef SYNTHESIS
      assert(fifo_words_q<=128) else $fatal(1,"FFT output FIFO overflow");
`endif
    end
  end
  initial begin
    assert(DataWidth==64 || DataWidth==128);
    assert(AddrWidth>=12);
  end
endmodule
