module fft_task_ctrl #(
  parameter int unsigned AddrWidth    = 48,
  parameter int unsigned DataWidth    = 64,
  parameter int unsigned TransIdWidth = 3,
  parameter type exception_t = logic
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  input  logic                    cmd_valid_i,
  output logic                    cmd_ready_o,
  input  logic [31:0]             cmd_insn_i,
  input  logic [AddrWidth-1:0]    cmd_src_addr_i,
  input  logic [AddrWidth-1:0]    cmd_dst_addr_i,
  input  logic [TransIdWidth-1:0] cmd_trans_id_i,

  output logic                    resp_valid_o,
  output logic [TransIdWidth-1:0] resp_trans_id_o,
  output exception_t              resp_exception_o,

  output logic                    mem_req_o,
  output logic [AddrWidth-1:0]    mem_addr_o,
  output logic                    mem_we_o,
  output logic [DataWidth-1:0]    mem_wdata_o,
  output logic [DataWidth/8-1:0]  mem_be_o,
  input  logic                    mem_gnt_i,
  input  logic                    mem_rsp_valid_i,
  input  logic [DataWidth-1:0]    mem_rsp_rdata_i,
  input  logic                    mem_rsp_error_i,

  output logic                    core_reset_o,
  output logic                    core_ce_o,
  output logic                    core_inverse_o,
  output logic [31:0]             core_sample_o,
  input  logic [45:0]             core_result_i,
  input  logic                    core_sync_i
);

  localparam int unsigned Points     = 4096;
  localparam int unsigned SamplesPer = DataWidth / 16;
  localparam int unsigned ReadBeats  = Points / SamplesPer;

  typedef enum logic [3:0] {
    StIdle,
    StResetCore,
    StReadReq,
    StReadWait,
    StFeed,
    StDrain,
    StAdvanceOut,
    StCaptureOut,
    StWriteReq,
    StWriteWait,
    StDone
  } state_e;

  state_e state_d, state_q;

  logic [AddrWidth-1:0]    src_addr_q, dst_addr_q;
  logic [TransIdWidth-1:0] trans_id_q;
  logic                    inverse_q;
  logic                    error_q, error_d;
  logic [DataWidth-1:0]    read_word_q, read_word_d;
  logic [DataWidth-1:0]    write_word_q, write_word_d;
  logic [12:0]             input_count_q, input_count_d;
  logic [12:0]             output_count_q, output_count_d;
  logic [$clog2(ReadBeats):0] read_beat_q, read_beat_d;
  logic [$clog2(SamplesPer)-1:0] sample_sel_q, sample_sel_d;
  logic                    out_active_q, out_active_d;
  logic                    latch_cmd;
  logic                    capture_output;
  logic signed [22:0]      fft_real;
  logic signed [22:0]      fft_imag;

  assign latch_cmd = cmd_valid_i && cmd_ready_o;
  assign fft_real  = core_result_i[45:23];
  assign fft_imag  = core_result_i[22:0];

  always_comb begin
    state_d        = state_q;
    error_d        = error_q;
    read_word_d    = read_word_q;
    write_word_d   = write_word_q;
    input_count_d  = input_count_q;
    output_count_d = output_count_q;
    read_beat_d    = read_beat_q;
    sample_sel_d   = sample_sel_q;
    out_active_d   = out_active_q;

    cmd_ready_o     = state_q == StIdle;
    resp_valid_o    = state_q == StDone;
    resp_trans_id_o = trans_id_q;
    resp_exception_o = '0;
    resp_exception_o.valid = error_q;
    resp_exception_o.cause = {{($bits(resp_exception_o.cause)-1){1'b0}}, 1'b1};

    mem_req_o   = 1'b0;
    mem_addr_o  = '0;
    mem_we_o    = 1'b0;
    mem_wdata_o = write_word_q;
    mem_be_o    = '1;

    core_reset_o   = state_q == StResetCore;
    core_ce_o      = 1'b0;
    core_inverse_o = inverse_q;
    core_sample_o  = '0;
    capture_output = 1'b0;

    unique case (state_q)
      StIdle: begin
        if (latch_cmd) begin
          state_d        = StResetCore;
          input_count_d  = '0;
          output_count_d = '0;
          read_beat_d    = '0;
          sample_sel_d   = '0;
          out_active_d   = 1'b0;
          error_d        = 1'b0;
        end
      end

      StResetCore: begin
        state_d = StReadReq;
      end

      StReadReq: begin
        mem_req_o  = 1'b1;
        mem_addr_o = src_addr_q + AddrWidth'(read_beat_q * (DataWidth / 8));
        mem_we_o   = 1'b0;
        mem_be_o   = '1;
        if (mem_gnt_i) state_d = StReadWait;
      end

      StReadWait: begin
        if (mem_rsp_valid_i) begin
          read_word_d = mem_rsp_rdata_i;
          error_d     = error_q | mem_rsp_error_i;
          sample_sel_d = '0;
          state_d     = StFeed;
        end
      end

      StFeed: begin
        core_ce_o     = 1'b1;
        core_sample_o = {read_word_q[sample_sel_q*16 +: 16], 16'h0000};
        input_count_d = input_count_q + 13'd1;
        sample_sel_d  = sample_sel_q + 1'b1;
        if (sample_sel_q == SamplesPer[$bits(sample_sel_q)-1:0] - 1'b1) begin
          read_beat_d = read_beat_q + 1'b1;
          state_d = (input_count_q == Points-1) ? StDrain : StReadReq;
        end
      end

      StDrain: begin
        core_ce_o = 1'b1;
        if (core_sync_i || out_active_q) begin
          core_ce_o = 1'b0;
          out_active_d = 1'b1;
          write_word_d = {{9{fft_imag[22]}}, fft_imag, {9{fft_real[22]}}, fft_real};
          output_count_d = output_count_q + 13'd1;
          state_d = StWriteReq;
        end
      end

      StAdvanceOut: begin
        core_ce_o = 1'b1;
        state_d = StCaptureOut;
      end

      StCaptureOut: begin
        write_word_d = {{9{fft_imag[22]}}, fft_imag, {9{fft_real[22]}}, fft_real};
        output_count_d = output_count_q + 13'd1;
        state_d = StWriteReq;
      end

      StWriteReq: begin
        mem_req_o   = 1'b1;
        mem_addr_o  = dst_addr_q + AddrWidth'((output_count_q - 13'd1) * (DataWidth / 8));
        mem_we_o    = 1'b1;
        mem_wdata_o = write_word_q;
        mem_be_o    = '1;
        if (mem_gnt_i) state_d = StWriteWait;
      end

      StWriteWait: begin
        if (mem_rsp_valid_i) begin
          error_d = error_q | mem_rsp_error_i;
          if (output_count_q == Points) begin
            state_d = StDone;
          end else begin
            state_d = StAdvanceOut;
          end
        end
      end

      StDone: begin
        if (!cmd_valid_i) state_d = StIdle;
      end

      default: state_d = StIdle;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q        <= StIdle;
      src_addr_q     <= '0;
      dst_addr_q     <= '0;
      trans_id_q     <= '0;
      inverse_q      <= 1'b0;
      error_q        <= 1'b0;
      read_word_q    <= '0;
      write_word_q   <= '0;
      input_count_q  <= '0;
      output_count_q <= '0;
      read_beat_q    <= '0;
      sample_sel_q   <= '0;
      out_active_q   <= 1'b0;
    end else begin
      state_q        <= state_d;
      error_q        <= error_d;
      read_word_q    <= read_word_d;
      write_word_q   <= write_word_d;
      input_count_q  <= input_count_d;
      output_count_q <= output_count_d;
      read_beat_q    <= read_beat_d;
      sample_sel_q   <= sample_sel_d;
      out_active_q   <= out_active_d;
      if (latch_cmd) begin
        src_addr_q <= cmd_src_addr_i;
        dst_addr_q <= cmd_dst_addr_i;
        trans_id_q <= cmd_trans_id_i;
        inverse_q  <= cmd_insn_i[31];
      end
`ifndef SYNTHESIS
      if (latch_cmd) begin
        $display("[fft_task_ctrl] cmd insn=%08x src=%h dst=%h inverse=%0d",
                 cmd_insn_i, cmd_src_addr_i, cmd_dst_addr_i, cmd_insn_i[31]);
      end
      if (state_q == StReadWait && mem_rsp_valid_i && read_beat_q < 2) begin
        $display("[fft_task_ctrl] read beat=%0d data=%016x err=%0d",
                 read_beat_q, mem_rsp_rdata_i, mem_rsp_error_i);
      end
      if (state_q == StWriteReq && mem_gnt_i &&
          (output_count_q <= 8 || output_count_q > Points - 4)) begin
        $display("[fft_task_ctrl] write idx=%0d data=%016x",
                 output_count_q - 13'd1, write_word_q);
      end
      if ($test$plusargs("FFT_DUT_WRITES") && state_q == StWriteReq && mem_gnt_i) begin
        $display("[fft_task_ctrl] dut-write trans=%0d inverse=%0d idx=%0d data=%016x",
                 trans_id_q, inverse_q, output_count_q - 13'd1, write_word_q);
      end
      if (state_q == StCaptureOut && output_count_q > Points - 4) begin
        $display("[fft_task_ctrl] capture idx=%0d sync=%0d result=%012x real=%0d imag=%0d",
                 output_count_q, core_sync_i, core_result_i, fft_real, fft_imag);
      end
      if (state_q == StDrain && (core_sync_i || out_active_q) &&
          output_count_q > Points - 4) begin
        $display("[fft_task_ctrl] drain-capture idx=%0d sync=%0d result=%012x real=%0d imag=%0d",
                 output_count_q, core_sync_i, core_result_i, fft_real, fft_imag);
      end
      if (state_q == StWriteWait && mem_rsp_valid_i && output_count_q == Points) begin
        $display("[fft_task_ctrl] done trans=%0d outputs=%0d err=%0d",
                 trans_id_q, output_count_q, error_q | mem_rsp_error_i);
      end
`endif
    end
  end

  initial begin
    assert (DataWidth == 64);
    assert (SamplesPer == 4);
  end

endmodule
