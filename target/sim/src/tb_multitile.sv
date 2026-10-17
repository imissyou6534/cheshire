// SPDX-License-Identifier: SHL-0.51
`timescale 1ns/1ps
`include "cheshire/typedef.svh"
module tb_multitile #(
  parameter int unsigned NumTiles = 1,
  parameter int unsigned NumDmas = 1,
  parameter bit RomEmbedded = 1
);
  import cheshire_pkg::*;
  function automatic cheshire_cfg_t configuration();
    cheshire_cfg_t cfg = DefaultCfg;
    cfg.Ara = 1;
    cfg.Fft = 1;
    cfg.AraNrLanes = 2;
    cfg.AraVLEN = 2048;
    cfg.RtcFreq = 1000000;
    return cheshire_shared_dma_cfg_pkg::private_spm_tile_cfg(cfg);
  endfunction
  localparam cheshire_cfg_t Cfg = configuration();
  localparam int BeatBytes = Cfg.AxiDataWidth/8;
  localparam int BeatSize = $clog2(BeatBytes);
  `CHESHIRE_TYPEDEF_ALL(tile_, Cfg)
  typedef logic [$bits(tile_axi_llc_id_t)+$clog2(NumTiles+NumDmas)-1:0] ddr_id_t;
  `CHESHIRE_TYPEDEF_AXI_CT(ddr, tile_addr_t, ddr_id_t, tile_axi_data_t, tile_axi_strb_t, tile_axi_user_t)
  wire clk, rst_n, rtc;
  logic [NumTiles-1:0] uart_tx, irq;
  tile_axi_mst_req_t [NumTiles-1:0] loader_req;
  tile_axi_mst_rsp_t [NumTiles-1:0] loader_rsp;
  tile_axi_mst_req_t [NumTiles-1:0][0:0] ext_req;
  tile_axi_mst_rsp_t [NumTiles-1:0][0:0] ext_rsp;
  ddr_req_t ddr_req;
  ddr_rsp_t ddr_rsp;
  logic [NumTiles-1:0][31:0] raw, status, boot_error;
  logic [NumTiles-1:0] done;
  bit [NumTiles-1:0] loading_seen = '0, ready_seen = '0;
  longint unsigned rom_retired [NumTiles], spm_retired [NumTiles];
  longint unsigned ara_requests [NumTiles], fft_requests [NumTiles];
  logic [NumTiles-1:0][63:0] last_pc, trap_cause;
  bit finished = 0;
  int unsigned expected_return = 0;
  int require_ara = 0, require_fft = 0, allow_traps = 0;
  int uart_all = 0;
  longint unsigned timeout_ns = 100000000, uart_drain_ns = 10000000;
  longint unsigned app_address, app_entry, app_mem_size, check_address;
  string app_binary, uart_expected_file, check_file;
  string result_file = "result.csv";

  multi_tile_top #(
    .NumTiles(NumTiles), .NumDmas(NumDmas), .Cfg(Cfg),
    .ddr_req_t(ddr_req_t), .ddr_rsp_t(ddr_rsp_t),
    .ext_mst_req_t(tile_axi_mst_req_t), .ext_mst_rsp_t(tile_axi_mst_rsp_t)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .rtc_i(rtc), .boot_mode_i('0),
    .uart_rx_i('1), .uart_tx_o(uart_tx), .jtag_tck_i('0), .jtag_trst_ni({NumTiles{rst_n}}),
    .jtag_tms_i('1), .jtag_tdi_i('0), .jtag_tdo_o(), .dma_irq_o(irq),
    .tile_ext_mst_req_i(ext_req), .tile_ext_mst_rsp_o(ext_rsp),
    .ddr_req_o(ddr_req), .ddr_rsp_i(ddr_rsp)
  );
  vip_multitile #(
    .NumTiles(NumTiles), .Cfg(Cfg), .loader_req_t(tile_axi_mst_req_t),
    .loader_rsp_t(tile_axi_mst_rsp_t), .ddr_req_t(ddr_req_t), .ddr_rsp_t(ddr_rsp_t)
  ) vip (
    .clk_o(clk), .rst_no(rst_n), .rtc_o(rtc), .loader_req_o(loader_req),
    .loader_rsp_i(loader_rsp), .ddr_req_i(ddr_req), .ddr_rsp_o(ddr_rsp), .uart_tx_i(uart_tx)
  );

  task automatic write_results;
    int fd;
    fd = $fopen(result_file,"w");
    if (!fd) $fatal(1,"cannot write result file %s",result_file);
    $fdisplay(fd,"tile,raw,rom_retired,spm_retired,ara_requests,fft_requests,uart_bytes,trap_cause,last_pc");
    for (int t=0; t<NumTiles; t++)
      $fdisplay(fd,"%0d,0x%08h,%0d,%0d,%0d,%0d,%0d,0x%016h,0x%016h",t,raw[t],
        rom_retired[t],spm_retired[t],ara_requests[t],fft_requests[t],
        vip.uart_received[t].len(),trap_cause[t],last_pc[t]);
    $fclose(fd);
  endtask

  task automatic fail(input string reason);
    if (!finished) begin
      finished = 1;
      write_results();
      $fatal(1,"FAIL MULTITILE: %s",reason);
    end
  endtask

  for (genvar t=0; t<NumTiles; t++) begin : gen_watch
    assign ext_req[t][0] = loader_req[t];
    assign loader_rsp[t] = ext_rsp[t][0];
    assign raw[t] = dut.gen_tiles[t].i_soc.i_regs.scratch_2_qs;
    assign status[t] = dut.gen_tiles[t].i_soc.i_regs.scratch_15_qs;
    assign boot_error[t] = dut.gen_tiles[t].i_soc.i_regs.scratch_14_qs;
    assign done[t] = raw[t][0] && (!RomEmbedded || status[t] == 32'h524f4d44);
    always @(posedge clk) begin
      if (!rst_n) begin
        rom_retired[t] = 0; spm_retired[t] = 0;
        ara_requests[t] = 0; fft_requests[t] = 0;
        last_pc[t] = 0; trap_cause[t] = 0;
      end else begin
        if ($isunknown(raw[t])) fail($sformatf("unknown completion tile=%0d",t));
        if (RomEmbedded) begin
          if (status[t] == 32'h524f4d4c) loading_seen[t] = 1;
          if (status[t] == 32'h524f4d52) ready_seen[t] = 1;
          if (status[t] == 32'h524f4d46) fail($sformatf("ROM error tile=%0d code=%0d",t,boot_error[t]));
          if (loader_req[t].aw_valid) fail("external write during embedded ROM execution");
        end
        if (raw[t][0] && (raw[t] >> 1) != expected_return)
          fail($sformatf("return tile=%0d got=%0d expected=%0d",t,raw[t] >> 1,expected_return));
        if (dut.gen_tiles[t].i_soc.acc_req_ara.acc_req.req_valid &&
            dut.gen_tiles[t].i_soc.acc_resp_ara.acc_resp.req_ready) ara_requests[t]++;
        if (dut.gen_tiles[t].i_soc.acc_req_fft.acc_req.req_valid &&
            dut.gen_tiles[t].i_soc.acc_resp_fft.acc_resp.req_ready) fft_requests[t]++;
        for (int c=0; c<$bits(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_ack); c++)
          if (dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_ack[c] &&
              !dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].ex.valid) begin
            last_pc[t] = dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].pc;
            if (last_pc[t] >= 'h02000000 && last_pc[t] < 'h02004000) rom_retired[t]++;
            if (last_pc[t] >= 'h10000000 && last_pc[t] < 'h10010000) spm_retired[t]++;
          end
        if (dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.ex_commit.valid &&
            !dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.ex_commit.cause[63] && !raw[t][0]) begin
          trap_cause[t] = dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.ex_commit.cause;
          if (!allow_traps) fail($sformatf("synchronous trap tile=%0d cause=%h pc=%h",t,trap_cause[t],last_pc[t]));
        end
      end
    end
  end

  initial begin : run
    byte unsigned application[], expected_uart[], expected_memory[];
    bit uart_complete;
    time drain_deadline;
    tile_axi_data_t data;
    assert(NumTiles > 0 && NumTiles <= 64 && NumDmas > 0 && NumDmas <= 65536)
      else $fatal(1,"invalid tile/DMA counts");
    void'($value$plusargs("RESULT=%s",result_file));
    void'($value$plusargs("EXPECTED_RETURN=%d",expected_return));
    void'($value$plusargs("REQUIRE_ARA=%d",require_ara));
    void'($value$plusargs("REQUIRE_FFT=%d",require_fft));
    void'($value$plusargs("ALLOW_TRAPS=%d",allow_traps));
    void'($value$plusargs("UART_ALL=%d",uart_all));
    void'($value$plusargs("UART_DRAIN_NS=%d",uart_drain_ns));
    if ($value$plusargs("UART_EXPECTED=%s",uart_expected_file)) vip.read_binary(uart_expected_file,expected_uart);
    if ($value$plusargs("CHECK_FILE=%s",check_file)) begin
      if (!$value$plusargs("CHECK_ADDR=%h",check_address)) $fatal(1,"CHECK_ADDR required");
      vip.read_binary(check_file,expected_memory);
      assert(check_address >= 'h10000000 && check_address < 'h10010000 &&
             expected_memory.size() <= 'h10010000-check_address)
        else $fatal(1,"memory checker outside application SPM");
    end
    vip.wait_for_reset();
    if (!RomEmbedded) begin
      if (!$value$plusargs("APP_BIN=%s",app_binary) ||
          !$value$plusargs("APP_ADDR=%h",app_address) ||
          !$value$plusargs("APP_ENTRY=%h",app_entry) ||
          !$value$plusargs("APP_MEM_SIZE=%d",app_mem_size)) $fatal(1,"external application metadata required");
      vip.read_binary(app_binary,application);
      assert(app_entry >= app_address && app_entry-app_address < application.size() && !(app_entry & 1))
        else $fatal(1,"external application entry outside image");
      for (int t=0; t<NumTiles; t++) begin
        vip.wait_for_spm(t);
        vip.load_spm(t,application,app_address,app_mem_size);
      end
      // Release no CPU until all private images and both aliases have been checked.
      for (int t=0; t<NumTiles; t++) begin
        vip.write32(t,'h03000000,32'(app_entry));
        vip.write32(t,'h03000004,32'(app_entry >> 32));
        vip.write32(t,'h03000008,2);
      end
    end
    wait(&done);
    drain_deadline = $time + uart_drain_ns*1ns;
    do begin
      uart_complete = 1;
      for (int t=0; t<NumTiles; t++) if (uart_all || t == 0)
        if (vip.uart_busy[t] || vip.uart_received[t].len() < expected_uart.size()) uart_complete = 0;
      if (!uart_complete) @(negedge clk);
    end while (!uart_complete && $time < drain_deadline);
    if (!uart_complete) fail("UART drain timeout or truncated output");
    // Leave one frame for a delayed final byte or an unexpected trailing byte.
    #100us;
    for (int t=0; t<NumTiles; t++) begin
      if (RomEmbedded && (!loading_seen[t] || !ready_seen[t])) fail("missing ROM startup phases");
      if (spm_retired[t] == 0) fail($sformatf("no SPM execution tile=%0d",t));
      if (require_ara && ara_requests[t] == 0) fail($sformatf("no Ara request tile=%0d",t));
      if (require_fft && fft_requests[t] == 0) fail($sformatf("no FFT request tile=%0d",t));
      foreach (expected_memory[b]) begin
        vip.axi_read(t,'h14000000+check_address-'h10000000+b,0,data);
        if (data[(check_address+b)%BeatBytes*8+:8] !== expected_memory[b])
          fail($sformatf("memory mismatch tile=%0d byte=%0d",t,b));
      end
    end
    for (int t=0; t<NumTiles; t++) if (uart_all || t == 0) begin
      if (vip.uart_busy[t]) fail($sformatf("UART still active tile=%0d",t));
      if (expected_uart.size()) begin
        if (vip.uart_received[t].len() != expected_uart.size()) fail($sformatf("UART length tile=%0d",t));
        foreach (expected_uart[b])
          if (8'(vip.uart_received[t][b]) !== expected_uart[b]) fail($sformatf("UART mismatch tile=%0d byte=%0d",t,b));
      end
    end
    finished = 1;
    write_results();
    $display("PASS MULTITILE boot=%s tiles=%0d dmas=%0d",RomEmbedded ? "rom" : "spm",NumTiles,NumDmas);
    $finish;
  end

  initial begin
    void'($value$plusargs("TIMEOUT_NS=%d",timeout_ns));
    #(timeout_ns*1ns);
    fail("simulation watchdog timeout");
  end
endmodule
