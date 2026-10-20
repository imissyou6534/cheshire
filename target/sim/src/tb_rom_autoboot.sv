// SPDX-License-Identifier: SHL-0.51
`timescale 1ns/1ps
`include "cheshire/typedef.svh"
module tb_rom_autoboot #(
  parameter int unsigned NumTiles = 1,
  parameter int unsigned NumDmas = 1,
  parameter bit ExpectFailure = 0
);
  import cheshire_pkg::*;
  function automatic cheshire_cfg_t test_cfg();
    cheshire_cfg_t cfg = DefaultCfg;
    cfg.Ara=1; cfg.Fft=1; cfg.AraNrLanes=2; cfg.AraVLEN=2048; cfg.RtcFreq=1000000;
    return cheshire_shared_dma_cfg_pkg::wide_private_spm_tile_cfg(cfg);
  endfunction
  localparam cheshire_cfg_t Cfg = test_cfg();
  `CHESHIRE_TYPEDEF_ALL(tile_, Cfg)
  logic sys_clk, vip_rst_n;
  logic jtag_tck, jtag_tms, jtag_tdi, jtag_tdo, jtag_trst_n;
  logic uart_tx;
  bit allow_debug = 0;
  multi_tile_rom_top_xilinx #(.NumTiles(NumTiles), .NumDmas(NumDmas)) dut (
    .sys_clk_p(sys_clk), .sys_clk_n(!sys_clk), .sys_reset(!vip_rst_n),
    .jtag_tck_i(allow_debug ? jtag_tck : 1'b0), .jtag_tms_i(allow_debug ? jtag_tms : 1'b1),
    .jtag_tdi_i(allow_debug ? jtag_tdi : 1'b0), .jtag_tdo_o(jtag_tdo),
    .uart_rx_i(1'b1), .uart_tx_o(uart_tx),
    .c0_ddr4_reset_n(), .c0_ddr4_ck_t(), .c0_ddr4_ck_c(), .c0_ddr4_act_n(),
    .c0_ddr4_adr(), .c0_ddr4_ba(), .c0_ddr4_bg(), .c0_ddr4_cke(), .c0_ddr4_odt(),
    .c0_ddr4_cs_n(), .c0_ddr4_dm_dbi_n(), .c0_ddr4_dq(), .c0_ddr4_dqs_c(), .c0_ddr4_dqs_t()
  );
  // The VIP is attached only after autonomous completion, for readback.
  vip_cheshire_soc #(
    .DutCfg(Cfg), .UseDramSys(0), .ClkPeriodSys(4ns), .ClkPeriodJtag(100ns),
    .ClkPeriodRtc(1000ns), .axi_ext_llc_req_t(tile_axi_llc_req_t),
    .axi_ext_llc_rsp_t(tile_axi_llc_rsp_t), .axi_ext_mst_req_t(tile_axi_mst_req_t),
    .axi_ext_mst_rsp_t(tile_axi_mst_rsp_t)
  ) vip (
    .clk(sys_clk), .rst_n(vip_rst_n), .test_mode(), .boot_mode(), .rtc(),
    .axi_llc_mst_req('0), .axi_llc_mst_rsp(), .axi_slink_mst_req('0), .axi_slink_mst_rsp(),
    .jtag_tck, .jtag_trst_n, .jtag_tms, .jtag_tdi, .jtag_tdo, .uart_tx, .uart_rx(),
    .i2c_sda(), .i2c_scl(), .spih_sck(), .spih_csb(), .spih_sd(),
    .slink_rcv_clk_i(), .slink_rcv_clk_o('0), .slink_i(), .slink_o('0)
  );
  logic [NumTiles-1:0] done, failed;
  logic [NumTiles-1:0][31:0] code, status, error;
  bit [NumTiles-1:0] loading_seen = '0, ready_seen = '0;
  int unsigned rom_retired [NumTiles], spm_retired [NumTiles], copy_writes [NumTiles];
  int unsigned ara_requests [NumTiles], ara_reads [NumTiles], ara_writes [NumTiles];
  int unsigned ddr_reads = 0, ddr_writes = 0;
  string received = "";
  string expected = {"ni hao a, 1017!",8'h0d,8'h0a,"Hello Vector World!",8'h0d,8'h0a};
  string expected_buffer = {"Hello Vector World!",8'h0d,8'h0a};
  bit uart_done = 0;

  initial begin : uart_monitor
    byte unsigned data;
    wait(dut.i_platform.rst_n && uart_tx === 1'b1);
    forever begin
      @(negedge uart_tx);
      #4340ns;
      assert(uart_tx === 0) else $fatal(1,"ROM UART start");
      for (int b=0;b<8;b++) begin
        #8680ns;
        assert(!$isunknown(uart_tx)) else $fatal(1,"ROM UART unknown bit");
        data[b] = uart_tx;
      end
      #8680ns;
      assert(uart_tx === 1 && !uart_done) else $fatal(1,"ROM UART frame/extra byte");
      received = {received,data};
      if (received.len() == expected.len()) begin
        $write("ROM UART actual: %s",received);
        assert(received == expected) else $fatal(1,"ROM UART mismatch");
        uart_done = 1;
      end
    end
  end

  for (genvar t=0;t<NumTiles;t++) begin : gen_watch
    assign code[t] = dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.i_regs.scratch_2_qs;
    assign error[t] = dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.i_regs.scratch_14_qs;
    assign status[t] = dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.i_regs.scratch_15_qs;
    assign done[t] = status[t] == 32'h524f4d44 && code[t] == 1;
    assign failed[t] = status[t] == 32'h524f4d46 || (code[t][0] && code[t] != 1);
    always @(posedge dut.i_platform.soc_clk) begin
      if (!dut.i_platform.rst_n) begin
        rom_retired[t]=0; spm_retired[t]=0; copy_writes[t]=0;
        ara_requests[t]=0; ara_reads[t]=0; ara_writes[t]=0;
        loading_seen[t]=0; ready_seen[t]=0;
      end else begin
        if (status[t] == 32'h524f4d4c) loading_seen[t] = 1;
        if (status[t] == 32'h524f4d52) ready_seen[t] = 1;
        assert(dut.i_platform.ext_req[t][0] === '0)
          else $fatal(1,"external loader used during ROM boot tile=%0d",t);
        if (!allow_debug)
          assert(dut.jtag_tck_i === 0 && dut.uart_rx_i === 1)
            else $fatal(1,"external boot stimulus present");
        if (dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.acc_req_ara.acc_req.req_valid &&
            dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.acc_resp_ara.acc_resp.req_ready) ara_requests[t]++;
        if (dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.axi_ara_wide_req.ar_valid &&
            dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.axi_ara_wide_resp.ar_ready) ara_reads[t]++;
        if (dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.axi_ara_wide_req.aw_valid &&
            dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.axi_ara_wide_resp.aw_ready) ara_writes[t]++;
        if (spm_retired[t] == 0 &&
            dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.gen_private_spm.spm_mem_req.aw_valid &&
            dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.gen_private_spm.spm_mem_rsp.aw_ready) copy_writes[t]++;
        for (int c=0;c<$bits(dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_ack);c++) begin
          if (dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_ack[c] &&
              !dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].ex.valid) begin
            if (dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].pc >= 'h02000000 &&
                dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].pc < 'h02004000)
              rom_retired[t]++;
            if (dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].pc >= 'h10000000 &&
                dut.i_platform.i_multi_tile.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].pc < 'h10010000)
              spm_retired[t]++;
          end
        end
      end
    end
  end
  always @(posedge dut.i_platform.soc_clk) if (dut.i_platform.rst_n) begin
    if (dut.i_platform.ddr_req.ar_valid && dut.i_platform.ddr_rsp.ar_ready) ddr_reads++;
    if (dut.i_platform.ddr_req.aw_valid && dut.i_platform.ddr_rsp.aw_ready) ddr_writes++;
  end

  task automatic diagnostics();
    for (int t=0;t<NumTiles;t++)
      $display("ROM evidence tile=%0d code=%h status=%h error=%h ROM/SPM retire=%0d/%0d copy_writes=%0d Ara req/R/W=%0d/%0d/%0d",
        t,code[t],status[t],error[t],rom_retired[t],spm_retired[t],copy_writes[t],ara_requests[t],ara_reads[t],ara_writes[t]);
  endtask
  initial begin : run
    logic [31:0] value;
    longint unsigned buffer;
    if (ExpectFailure) begin
      wait(&failed);
      for (int t=0;t<NumTiles;t++) wait(code[t][0]);
      diagnostics();
      for (int t=0;t<NumTiles;t++)
        assert(code[t] == 5 && error[t] == 2 && loading_seen[t] && !ready_seen[t] &&
          spm_retired[t] == 0 && ara_requests[t] == 0 && received.len() == 0)
          else $fatal(1,"bad ROM checksum not rejected before application");
      $display("PASS ROM autoboot checksum negative rejected before application");
      $finish;
    end
    wait(&done || |failed);
    diagnostics();
    assert(!(|failed)) else $fatal(1,"ROM autonomous firmware failed");
    for (int c=0;c<10000 && !uart_done;c++) @(negedge dut.i_platform.soc_clk);
    assert(uart_done && ddr_reads == 0 && ddr_writes == 0)
      else $fatal(1,"ROM boot UART incomplete or unexpected DDR dependence");
    for (int t=0;t<NumTiles;t++)
      assert(loading_seen[t] && ready_seen[t] && error[t] == 0 && rom_retired[t] > 80 &&
        spm_retired[t] > 80 && copy_writes[t] > 64 && ara_requests[t] > 0 &&
        ara_reads[t] > 0 && ara_writes[t] > 0)
        else $fatal(1,"ROM/SPM handoff execution evidence missing tile=%0d",t);
    if (NumTiles == 1) begin
      if (!$value$plusargs("BUF=%h",buffer)) $fatal(1,"BUF required for post-boot readback");
      @(negedge jtag_tck);
      allow_debug = 1;
      @(posedge jtag_tck);
      vip.jtag_init();
      for (int b=0;b<64;b+=4) begin
        vip.jtag_read_reg32(buffer+b,value);
        for (int lane=0;lane<4;lane++)
          assert(value[lane*8+:8] === (b+lane < expected_buffer.len() ? 8'(expected_buffer[b+lane]) : 8'h00))
            else $fatal(1,"autoboot buffer mismatch byte=%0d",b+lane);
      end
    end
    $display("PASS ROM autoboot real CVA6 %0d tiles x %0d DMA no external program load",NumTiles,NumDmas);
    $finish;
  end
  initial begin
    #100ms;
    diagnostics();
    $fatal(1,"ROM autoboot watchdog");
  end
endmodule
