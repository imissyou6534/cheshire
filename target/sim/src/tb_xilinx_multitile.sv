// SPDX-License-Identifier: SHL-0.51
`timescale 1ns/1ps
`include "cheshire/typedef.svh"
module tb_xilinx_multitile #(
  parameter int unsigned NumTiles = 1,
  parameter int unsigned NumDmas = 1
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
  logic uart_tx, uart_rx;
  wire sys_reset = !vip_rst_n;
  multi_tile_top_xilinx #(.NumTiles(NumTiles), .NumDmas(NumDmas)) dut (
    .sys_clk_p(sys_clk), .sys_clk_n(!sys_clk), .sys_reset,
    .jtag_tck_i(jtag_tck), .jtag_tms_i(jtag_tms), .jtag_tdi_i(jtag_tdi), .jtag_tdo_o(jtag_tdo),
    .uart_rx_i(uart_rx), .uart_tx_o(uart_tx),
    .c0_ddr4_reset_n(), .c0_ddr4_ck_t(), .c0_ddr4_ck_c(), .c0_ddr4_act_n(),
    .c0_ddr4_adr(), .c0_ddr4_ba(), .c0_ddr4_bg(), .c0_ddr4_cke(), .c0_ddr4_odt(),
    .c0_ddr4_cs_n(), .c0_ddr4_dm_dbi_n(), .c0_ddr4_dq(), .c0_ddr4_dqs_c(), .c0_ddr4_dqs_t()
  );
  // Use the original JTAG/UART VIP; its unused DDR interface is tied off.
  vip_cheshire_soc #(
    .DutCfg(Cfg), .UseDramSys(0), .ClkPeriodSys(4ns), .ClkPeriodJtag(100ns),
    .ClkPeriodRtc(1000ns), .axi_ext_llc_req_t(tile_axi_llc_req_t),
    .axi_ext_llc_rsp_t(tile_axi_llc_rsp_t), .axi_ext_mst_req_t(tile_axi_mst_req_t),
    .axi_ext_mst_rsp_t(tile_axi_mst_rsp_t)
  ) vip (
    .clk(sys_clk), .rst_n(vip_rst_n), .test_mode(), .boot_mode(), .rtc(),
    .axi_llc_mst_req('0), .axi_llc_mst_rsp(), .axi_slink_mst_req('0), .axi_slink_mst_rsp(),
    .jtag_tck, .jtag_trst_n, .jtag_tms, .jtag_tdi, .jtag_tdo, .uart_tx, .uart_rx,
    .i2c_sda(), .i2c_scl(), .spih_sck(), .spih_csb(), .spih_sd(),
    .slink_rcv_clk_i(), .slink_rcv_clk_o('0), .slink_i(), .slink_o('0)
  );

  string received = "";
  string expected = {"ni hao a, 1017!",8'h0d,8'h0a,"Hello Vector World!",8'h0d,8'h0a};
  string expected_buffer = {"Hello Vector World!",8'h0d,8'h0a};
  bit uart_done = 0;
  int unsigned ara_requests = 0, ara_reads = 0, ara_writes = 0, spm_retired = 0;
  int unsigned dma_submits = 0, dma_pops = 0, ddr_reads = 0, ddr_writes = 0;
  int unsigned sba_reads = 0, sba_writes = 0;
  bit app_started = 0;
  initial begin : uart_monitor
    byte unsigned data;
    wait(app_started && dut.rst_n);
    forever begin
      @(negedge uart_tx);
      #4340ns;
      assert(uart_tx === 0) else $fatal(1,"FPGA UART start");
      for (int b=0;b<8;b++) begin
        #8680ns;
        assert(!$isunknown(uart_tx)) else $fatal(1,"FPGA UART unknown bit");
        data[b] = uart_tx;
      end
      #8680ns;
      assert(uart_tx === 1 && !uart_done) else $fatal(1,"FPGA UART frame/extra byte");
      received = {received,data};
      if (received.len() == expected.len()) begin
        $write("FPGA UART actual: %s",received);
        assert(received == expected) else $fatal(1,"FPGA UART string mismatch");
        uart_done = 1;
      end
    end
  end

  always @(posedge dut.soc_clk) if (dut.rst_n) begin
    assert(dut.clocks_locked) else $fatal(1,"FPGA core released before clock lock");
    if (dut.i_multi_tile.gen_tiles[0].i_soc.axi_dbg_req.ar_valid &&
        dut.i_multi_tile.gen_tiles[0].i_soc.axi_dbg_rsp.ar_ready) sba_reads++;
    if (dut.i_multi_tile.gen_tiles[0].i_soc.axi_dbg_req.aw_valid &&
        dut.i_multi_tile.gen_tiles[0].i_soc.axi_dbg_rsp.aw_ready) sba_writes++;
    if (app_started) begin
      if (dut.i_multi_tile.gen_tiles[0].i_soc.acc_req_ara.acc_req.req_valid &&
          dut.i_multi_tile.gen_tiles[0].i_soc.acc_resp_ara.acc_resp.req_ready) ara_requests++;
      if (dut.i_multi_tile.gen_tiles[0].i_soc.axi_ara_wide_req.ar_valid &&
          dut.i_multi_tile.gen_tiles[0].i_soc.axi_ara_wide_resp.ar_ready) ara_reads++;
      if (dut.i_multi_tile.gen_tiles[0].i_soc.axi_ara_wide_req.aw_valid &&
          dut.i_multi_tile.gen_tiles[0].i_soc.axi_ara_wide_resp.aw_ready) ara_writes++;
      for (int c=0;c<$bits(dut.i_multi_tile.gen_tiles[0].i_soc.gen_cva6_cores[0].i_core_cva6.commit_ack);c++)
        if (dut.i_multi_tile.gen_tiles[0].i_soc.gen_cva6_cores[0].i_core_cva6.commit_ack[c] &&
            !dut.i_multi_tile.gen_tiles[0].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].ex.valid &&
            dut.i_multi_tile.gen_tiles[0].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].pc >= 'h10000000 &&
            dut.i_multi_tile.gen_tiles[0].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].pc < 'h10020000)
          spm_retired++;
    end
    if (dut.i_multi_tile.i_dma_subsystem.i_pool.submit_valid[0] &&
        dut.i_multi_tile.i_dma_subsystem.i_pool.submit_ready[0]) dma_submits++;
    if (dut.i_multi_tile.i_dma_subsystem.i_pool.gen_tiles[0].i_frontend.pop_fire) dma_pops++;
    if (dut.ddr_req.ar_valid && dut.ddr_rsp.ar_ready) ddr_reads++;
    if (dut.ddr_req.aw_valid && dut.ddr_rsp.aw_ready) ddr_writes++;
  end

  task automatic write32(input logic [63:0] address, input logic [31:0] value);
    vip.jtag_write_reg32(address,value,0);
    vip.jtag_dbg.wait_idle(20);
  endtask
  always @(posedge dut.i_dram_wrapper.dram_axi_clk)
    if (dut.i_dram_wrapper.dram_axi_resetn === 1'b1)
      assert(dut.rst_n && !dut.i_dram_wrapper.dram_rst_o)
        else $fatal(1,"MIG AXI reset released before UI reset");
  task automatic read32(input logic [63:0] address, output logic [31:0] value);
    vip.jtag_read_reg32(address,value);
    assert(!$isunknown(value)) else $fatal(1,"FPGA JTAG read unknown address=%h",address);
  endtask

  initial begin : run
    string elf;
    logic [31:0] code, value;
    longint unsigned buffer;
    assert((NumTiles == 1 || $test$plusargs("LINKS_ONLY")) && NumDmas > 0 && dut.FPGACfg == Cfg)
      else $fatal(1,"FPGA smoke expects one tile and matching configuration");
    assert($bits(dut.ddr_req.aw.id) == $bits(tile_axi_llc_id_t)+$clog2(NumTiles+NumDmas))
      else $fatal(1,"FPGA DDR source IDs truncated");
    assert($bits(dut.i_dram_wrapper.cdc_dram_req.w.data) == 512 &&
      $bits(dut.i_dram_wrapper.cdc_dram_req.aw.id) == 8)
      else $fatal(1,"MIG width/ID conversion missing");
    assert(Cfg.AraNrLanes == 4 && Cfg.AxiDataWidth == 128 &&
      $bits(dut.i_multi_tile.gen_tiles[0].i_soc.axi_dbg_req.w.data) == 64 &&
      $bits(dut.i_multi_tile.gen_tiles[0].i_soc.axi_dbg_wide_req.w.data) == 128 &&
      $bits(dut.i_multi_tile.i_dma_subsystem.dma_req[0].w.data) == 128 &&
      $bits(dut.i_multi_tile.i_dma_subsystem.masters_req[0].w.data) == 256 &&
      $bits(dut.ddr_req.w.data) == 256)
      else $fatal(1,"FPGA wide bus profile mismatch");
    if ($test$plusargs("LINKS_ONLY")) begin
      logic read_data [32*NumTiles], write_data [32*NumTiles];
      write_data = '{default:1'b0};
      vip.wait_for_reset();
      wait(dut.rst_n);
      repeat (100) @(posedge jtag_tck);
      vip.jtag_dbg.reset_master();
      vip.jtag_dbg.jtag.shift_dr();
      vip.jtag_dbg.jtag.readwrite_bits(read_data,write_data,1'b0);
      vip.jtag_dbg.jtag.update_dr(1'b1);
      for (int t=0;t<NumTiles;t++) begin
        for (int b=0;b<32;b++) value[b] = read_data[t*32+b];
        assert(value === Cfg.DbgIdCode) else $fatal(1,"FPGA JTAG chain ID tile=%0d got=%h",t,value);
        if (t > 0) assert(dut.tile_uart_rx[t] === 1'b1)
          else $fatal(1,"FPGA UART RX broadcast into tile=%0d",t);
      end
      $display("PASS Xilinx multi-tile JTAG/UART links %0d tiles x %0d DMA",NumTiles,NumDmas);
      $finish;
    end
    if (!$value$plusargs("BINARY=%s",elf) || !$value$plusargs("BUF=%h",buffer))
      $fatal(1,"FPGA smoke requires BINARY and BUF");
    vip.set_boot_mode(0);
    vip.wait_for_reset();
    wait(dut.rst_n);
    vip.jtag_init();
    read32(64'h02000000,value);
    assert(value != 0) else $fatal(1,"FPGA JTAG ROM read failed");
    vip.jtag_poll_bit0(64'h03001000,value,20);
    vip.jtag_dbg.wait_idle(10000);
    vip.uart_write_byte(8'h06);
    vip.uart_boot_scoop_expect("ACK",8'h06);
    $display("PASS FPGA UART passive ACK");
    // The original JTAG driver expects calls aligned to its clock phase.
    @(posedge jtag_tck);
    vip.jtag_init();
    app_started = 1;
    vip.jtag_elf_run(elf);
    vip.jtag_wait_for_eoc(code);
    assert(code == 0) else $fatal(1,"FPGA firmware exit=%h",code);
    for (int c=0;c<5000 && !uart_done;c++) @(negedge dut.soc_clk);
    assert(uart_done && ara_requests > 0 && ara_reads > 0 && ara_writes > 0 && spm_retired > 80)
      else $fatal(1,"FPGA Ara/CPU/UART execution evidence missing");
    for (int b=0;b<64;b+=4) begin
      read32(buffer+b,value);
      for (int lane=0;lane<4;lane++)
        assert(value[lane*8+:8] === (b+lane < expected_buffer.len() ? 8'(expected_buffer[b+lane]) : 8'h00))
          else $fatal(1,"FPGA hello buffer mismatch byte=%0d",b+lane);
    end
    for (int w=0;w<16;w++) begin
      write32(64'h84000000+4*w,32'hcafe0000+32'(w));
      write32(64'h84000100+4*w,0);
    end
    write32(64'h01000000,0);
    write32(64'h010000d0,32'h84000100);
    write32(64'h010000d4,0);
    write32(64'h010000d8,32'h84000000);
    write32(64'h010000dc,0);
    write32(64'h010000e0,64);
    write32(64'h010000e4,0);
    write32(64'h01000118,1);
    write32(64'h01000100,1);
    vip.jtag_poll_bit0(64'h01000108,value,20);
    read32(64'h01000110,value);
    assert(value[7:0] == 0) else $fatal(1,"FPGA DMA completion failed %h",value);
    assert(dut.dma_irq[0]) else $fatal(1,"FPGA DMA IRQ missing");
    read32(64'h04001004,value);
    assert(value[26]) else $fatal(1,"FPGA PLIC source 58 missing");
    for (int w=0;w<16;w++) begin
      read32(64'h84000100+4*w,value);
      assert(value == 32'hcafe0000+32'(w)) else $fatal(1,"FPGA DMA data mismatch word=%0d",w);
    end
    write32(64'h01000114,1);
    assert(!dut.dma_irq[0] && dma_submits == 1 && dma_pops == 1 && ddr_reads > 0 && ddr_writes > 0 &&
      sba_reads > 0 && sba_writes > 0)
      else $fatal(1,"FPGA DMA accounting or IRQ clear failed");
    $display("FPGA evidence Ara req/read/write=%0d/%0d/%0d SPM retirements=%0d DDR R/W=%0d/%0d DMA=%0d/%0d",
      ara_requests,ara_reads,ara_writes,spm_retired,ddr_reads,ddr_writes,dma_submits,dma_pops);
    $display("FPGA evidence JTAG SBA R/W=%0d/%0d widths Debug64 Tile128 DMA128 Shared256 MIG512 Ara4",sba_reads,sba_writes);
    $display("PASS Xilinx multi-tile board smoke %0d tile x %0d DMA",NumTiles,NumDmas);
    $finish;
  end
  initial begin
    #100ms;
    $fatal(1,"FPGA board smoke watchdog");
  end
endmodule
