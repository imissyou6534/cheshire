module fft_accelerator_ip
  import fft_accel_pkg::*;
#(
  parameter int unsigned AddrWidth          = 48,
  parameter int unsigned DataWidth          = 64,
  parameter int unsigned TransIdWidth       = 3,
  parameter int unsigned FftCmdQueueDepth   = 4,
  parameter type exception_t = logic,
  parameter type accelerator_req_t = logic,
  parameter type accelerator_resp_t = logic,
  parameter type acc_mmu_req_t = logic,
  parameter type cva6_to_acc_t = logic,
  parameter type acc_to_cva6_t = logic,
  parameter type axi_req_t = logic,
  parameter type axi_rsp_t = logic
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  cva6_to_acc_t acc_req_i,
  output acc_to_cva6_t acc_resp_o,

  output axi_req_t      axi_req_o,
  input  axi_rsp_t      axi_rsp_i
);

  typedef struct packed {
    fft_cmd_op_e              op;
    logic [AddrWidth-1:0]     src_addr;
    logic [AddrWidth-1:0]     dst_addr;
    logic                     inverse;
    logic [TransIdWidth-1:0]  wait_trans_id;
  } fft_cmd_entry_t;

  localparam int unsigned QueueIdxWidth = (FftCmdQueueDepth <= 1) ? 1 : $clog2(FftCmdQueueDepth);
  localparam int unsigned QueueCntWidth = $clog2(FftCmdQueueDepth + 1);

  logic                    mem_req;
  logic [AddrWidth-1:0]    mem_addr;
  logic                    mem_we;
  logic [DataWidth-1:0]    mem_wdata;
  logic [DataWidth/8-1:0]  mem_be;
  logic                    mem_gnt;
  logic                    mem_rsp_valid;
  logic [DataWidth-1:0]    mem_rsp_rdata;
  logic                    mem_rsp_error;

  logic                    ctrl_cmd_valid;
  logic                    ctrl_cmd_ready;
  logic                    ctrl_resp_valid;
  logic [TransIdWidth-1:0] ctrl_resp_trans_id;
  exception_t              ctrl_resp_exception;

  logic                    core_reset;
  logic                    core_ce;
  logic                    core_inverse;
  logic [31:0]             core_sample;
  logic [45:0]             core_result;
  logic                    core_sync;

  fft_cmd_entry_t          queue_q [FftCmdQueueDepth];
  logic [QueueIdxWidth-1:0] rd_ptr_q, wr_ptr_q;
  logic [QueueCntWidth-1:0] count_q;

  logic                    fifo_empty;
  logic                    fifo_full;
  fft_cmd_entry_t          fifo_head;
  fft_cmd_entry_t          enqueue_entry;
  logic                    enqueue_fire;
  logic                    accepted_fire;
  logic                    illegal_fire;
  logic                    start_fire;
  logic                    issue_start;
  logic                    wait_fire;
  logic                    active_task_q;
  logic                    active_task_d;

  exception_t              illegal_exception;

  logic                    wait_resp_q, wait_resp_d;
  logic [TransIdWidth-1:0] wait_resp_trans_id_q, wait_resp_trans_id_d;
  exception_t              wait_resp_exception_q, wait_resp_exception_d;
  logic                    wait_resp_fire;
  logic                    imm_resp_q, imm_resp_d;
  logic [TransIdWidth-1:0] imm_resp_trans_id_q, imm_resp_trans_id_d;
  exception_t              imm_resp_exception_q, imm_resp_exception_d;
  logic                    imm_resp_fire;
  logic                    epoch_error_q, epoch_error_d;

  logic                    insn_is_legal;
  logic                    insn_is_start;
  logic                    insn_is_wait;
  logic                    resp_busy;
  logic                    req_ready;

  assign insn_is_start = is_fft_start_legal(acc_req_i.acc_req.insn);
  assign insn_is_wait  = is_fft_wait(acc_req_i.acc_req.insn);
  assign insn_is_legal = insn_is_start || insn_is_wait;
  assign fifo_empty    = count_q == '0;
  assign fifo_full     = count_q == FftCmdQueueDepth;
  assign fifo_head     = queue_q[rd_ptr_q];
  assign resp_busy     = imm_resp_q || wait_resp_q || wait_fire;
  assign imm_resp_fire = imm_resp_q && acc_req_i.acc_req.resp_ready;
  assign wait_resp_fire = wait_resp_q && acc_req_i.acc_req.resp_ready;
  assign req_ready     = !resp_busy && (!insn_is_legal || !fifo_full);

  always_comb begin
    illegal_exception = '0;
    illegal_exception.valid = 1'b1;
    illegal_exception.cause = {{($bits(illegal_exception.cause)-2){1'b0}}, 2'd2};
    illegal_exception.tval  = {{($bits(illegal_exception.tval)-32){1'b0}}, acc_req_i.acc_req.insn};
  end

  always_comb begin
    enqueue_entry = '0;
    enqueue_entry.op = insn_is_wait ? FftCmdWait : FftCmdStart;
    enqueue_entry.src_addr = acc_req_i.acc_req.rs1[AddrWidth-1:0];
    enqueue_entry.dst_addr = acc_req_i.acc_req.rs2[AddrWidth-1:0];
    enqueue_entry.inverse = is_ifft(acc_req_i.acc_req.insn);
    enqueue_entry.wait_trans_id = acc_req_i.acc_req.trans_id;
  end

  assign accepted_fire = acc_req_i.acc_req.req_valid &&
                         req_ready &&
                         insn_is_legal;
  assign illegal_fire = acc_req_i.acc_req.req_valid &&
                        req_ready &&
                        !insn_is_legal;
  assign start_fire   = accepted_fire && insn_is_start;
  assign enqueue_fire = accepted_fire;
  assign issue_start  = !fifo_empty && fifo_head.op == FftCmdStart && ctrl_cmd_ready;
  assign wait_fire    = !fifo_empty && fifo_head.op == FftCmdWait &&
                        !active_task_q && !ctrl_resp_valid && !wait_resp_q;

  always_comb begin
    wait_resp_d = wait_resp_q;
    wait_resp_trans_id_d = wait_resp_trans_id_q;
    wait_resp_exception_d = wait_resp_exception_q;
    imm_resp_d = imm_resp_q;
    imm_resp_trans_id_d = imm_resp_trans_id_q;
    imm_resp_exception_d = imm_resp_exception_q;
    active_task_d = active_task_q;
    epoch_error_d = epoch_error_q;

    if (imm_resp_fire) begin
      imm_resp_d = 1'b0;
    end

    if (wait_resp_fire) begin
      wait_resp_d = 1'b0;
    end

    if (illegal_fire) begin
      imm_resp_d = 1'b1;
      imm_resp_trans_id_d = acc_req_i.acc_req.trans_id;
      imm_resp_exception_d = illegal_exception;
    end else if (start_fire) begin
      imm_resp_d = 1'b1;
      imm_resp_trans_id_d = acc_req_i.acc_req.trans_id;
      imm_resp_exception_d = '0;
    end

    if (issue_start) begin
      active_task_d = 1'b1;
    end

    if (ctrl_resp_valid) begin
      active_task_d = 1'b0;
      epoch_error_d = epoch_error_q | ctrl_resp_exception.valid;
    end

    if (wait_fire) begin
      wait_resp_d = 1'b1;
      wait_resp_trans_id_d = fifo_head.wait_trans_id;
      wait_resp_exception_d = '0;
      wait_resp_exception_d.valid = epoch_error_q;
      wait_resp_exception_d.cause = {{($bits(wait_resp_exception_d.cause)-1){1'b0}}, 1'b1};
      epoch_error_d = 1'b0;
    end
  end

  always_comb begin
    acc_resp_o = '0;
    acc_resp_o.acc_resp.req_ready = req_ready;
    acc_resp_o.acc_resp.result = '0;

    if (imm_resp_q) begin
      acc_resp_o.acc_resp.resp_valid = 1'b1;
      acc_resp_o.acc_resp.trans_id = imm_resp_trans_id_q;
      acc_resp_o.acc_resp.exception = imm_resp_exception_q;
    end else if (wait_resp_q) begin
      acc_resp_o.acc_resp.resp_valid = 1'b1;
      acc_resp_o.acc_resp.trans_id = wait_resp_trans_id_q;
      acc_resp_o.acc_resp.exception = wait_resp_exception_q;
    end
  end

  assign ctrl_cmd_valid = issue_start;

  fft_task_ctrl #(
    .AddrWidth    ( AddrWidth    ),
    .DataWidth    ( DataWidth    ),
    .TransIdWidth ( TransIdWidth ),
    .exception_t  ( exception_t  )
  ) i_fft_task_ctrl (
    .clk_i,
    .rst_ni,
    .cmd_valid_i      ( ctrl_cmd_valid ),
    .cmd_ready_o      ( ctrl_cmd_ready ),
    .cmd_insn_i       ( {fifo_head.inverse, FftLog2N, 10'b0, FftFunct3, 5'b0, OpcodeCustom0} ),
    .cmd_src_addr_i   ( fifo_head.src_addr ),
    .cmd_dst_addr_i   ( fifo_head.dst_addr ),
    .cmd_trans_id_i   ( '0 ),
    .resp_valid_o     ( ctrl_resp_valid ),
    .resp_trans_id_o  ( ctrl_resp_trans_id ),
    .resp_exception_o ( ctrl_resp_exception ),
    .mem_req_o        ( mem_req ),
    .mem_addr_o       ( mem_addr ),
    .mem_we_o         ( mem_we ),
    .mem_wdata_o      ( mem_wdata ),
    .mem_be_o         ( mem_be ),
    .mem_gnt_i        ( mem_gnt ),
    .mem_rsp_valid_i  ( mem_rsp_valid ),
    .mem_rsp_rdata_i  ( mem_rsp_rdata ),
    .mem_rsp_error_i  ( mem_rsp_error ),
    .core_reset_o     ( core_reset ),
    .core_ce_o        ( core_ce ),
    .core_inverse_o   ( core_inverse ),
    .core_sample_o    ( core_sample ),
    .core_result_i    ( core_result ),
    .core_sync_i      ( core_sync )
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_ptr_q <= '0;
      wr_ptr_q <= '0;
      count_q  <= '0;
      wait_resp_q <= 1'b0;
      wait_resp_trans_id_q <= '0;
      wait_resp_exception_q <= '0;
      imm_resp_q <= 1'b0;
      imm_resp_trans_id_q <= '0;
      imm_resp_exception_q <= '0;
      active_task_q <= 1'b0;
      epoch_error_q <= 1'b0;
    end else begin
      wait_resp_q <= wait_resp_d;
      wait_resp_trans_id_q <= wait_resp_trans_id_d;
      wait_resp_exception_q <= wait_resp_exception_d;
      imm_resp_q <= imm_resp_d;
      imm_resp_trans_id_q <= imm_resp_trans_id_d;
      imm_resp_exception_q <= imm_resp_exception_d;
      active_task_q <= active_task_d;
      epoch_error_q <= epoch_error_d;

      if (enqueue_fire) begin
        queue_q[wr_ptr_q] <= enqueue_entry;
        wr_ptr_q <= (wr_ptr_q == FftCmdQueueDepth - 1) ? '0 : wr_ptr_q + 1'b1;
      end

      if (issue_start || wait_fire) begin
        rd_ptr_q <= (rd_ptr_q == FftCmdQueueDepth - 1) ? '0 : rd_ptr_q + 1'b1;
      end

      unique case ({enqueue_fire, issue_start || wait_fire})
        2'b10: count_q <= count_q + 1'b1;
        2'b01: count_q <= count_q - 1'b1;
        default: count_q <= count_q;
      endcase

`ifndef SYNTHESIS
      if (enqueue_fire && insn_is_start) begin
        $display("[fft_accelerator_ip] enqueue START trans=%0d inverse=%0d src=%h dst=%h depth=%0d",
                 acc_req_i.acc_req.trans_id, is_ifft(acc_req_i.acc_req.insn),
                 acc_req_i.acc_req.rs1, acc_req_i.acc_req.rs2, count_q + 1'b1);
      end
      if (enqueue_fire && insn_is_wait) begin
        $display("[fft_accelerator_ip] enqueue WAIT trans=%0d depth=%0d",
                 acc_req_i.acc_req.trans_id, count_q + 1'b1);
      end
      if (issue_start) begin
        $display("[fft_accelerator_ip] issue START inverse=%0d src=%h dst=%h",
                 fifo_head.inverse, fifo_head.src_addr, fifo_head.dst_addr);
      end
      if (wait_fire) begin
        $display("[fft_accelerator_ip] WAIT complete trans=%0d error=%0d",
                 fifo_head.wait_trans_id, epoch_error_q);
      end
`endif
    end
  end

  axi_from_mem #(
    .MemAddrWidth ( AddrWidth  ),
    .AxiAddrWidth ( AddrWidth  ),
    .DataWidth    ( DataWidth  ),
    .MaxRequests  ( 1          ),
    .AxiProt      ( '0         ),
    .axi_req_t    ( axi_req_t  ),
    .axi_rsp_t    ( axi_rsp_t  )
  ) i_fft_axi_from_mem (
    .clk_i,
    .rst_ni,
    .mem_req_i       ( mem_req ),
    .mem_addr_i      ( mem_addr ),
    .mem_we_i        ( mem_we ),
    .mem_wdata_i     ( mem_wdata ),
    .mem_be_i        ( mem_be ),
    .mem_gnt_o       ( mem_gnt ),
    .mem_rsp_valid_o ( mem_rsp_valid ),
    .mem_rsp_rdata_o ( mem_rsp_rdata ),
    .mem_rsp_error_o ( mem_rsp_error ),
    .slv_aw_cache_i  ( axi_pkg::CACHE_MODIFIABLE ),
    .slv_ar_cache_i  ( axi_pkg::CACHE_MODIFIABLE ),
    .axi_req_o       ( axi_req_o ),
    .axi_rsp_i       ( axi_rsp_i )
  );

  fftifftmain i_fftifftmain (
    .i_clk     ( clk_i ),
    .i_reset   ( core_reset ),
    .i_ce      ( core_ce ),
    .i_inverse ( core_inverse ),
    .i_sample  ( core_sample ),
    .o_result  ( core_result ),
    .o_sync    ( core_sync )
  );

  initial begin
    assert (FftCmdQueueDepth > 1);
  end

endmodule
