// SPDX-License-Identifier: SHL-0.51
`timescale 1ns/1ps
`include "cheshire/typedef.svh"
module tb_private_spm_system #(
  parameter int unsigned NumTiles = 2,
  parameter int unsigned NumDmas = 1,
  parameter int unsigned ExpectedPhase = 9,
  parameter bit ExternalWrite = 1,
  parameter bit DdrOwner = 1,
  parameter bit DmaSmoke = 1,
  parameter bit AraHello = 0
);
  import cheshire_pkg::*;
  function automatic cheshire_cfg_t system_cfg();
    cheshire_cfg_t cfg = tb_cheshire_pkg::gen_cheshire_ara_fft_spm_cfg();
    cfg.RtcFreq = 1000000;
    return cfg;
  endfunction
  localparam cheshire_cfg_t Cfg = system_cfg();
  localparam longint unsigned SpmBase = 64'h10000000;
  localparam longint unsigned AliasBase = 64'h14000000;
  localparam longint unsigned SpmBytes = get_llc_size(Cfg);
  localparam int BeatBytes = Cfg.AxiDataWidth/8;
  localparam int BeatSize = $clog2(BeatBytes);
  localparam time UartBitPeriod = 8680ns;
  localparam logic [63:0] AllWays = (64'h1 << Cfg.LlcSetAssoc)-1;
  `CHESHIRE_TYPEDEF_ALL(tile_, Cfg)
  typedef logic [$bits(tile_axi_llc_id_t)+$clog2(NumTiles+NumDmas)-1:0] ddr_id_t;
  `CHESHIRE_TYPEDEF_AXI_CT(ddr, tile_addr_t, ddr_id_t,
    tile_axi_data_t, tile_axi_strb_t, tile_axi_user_t)
  tile_axi_mst_req_t [NumTiles-1:0][iomsb(Cfg.AxiExtNumMst):0] loader_req;
  tile_axi_mst_rsp_t [NumTiles-1:0][iomsb(Cfg.AxiExtNumMst):0] loader_rsp;
  ddr_req_t ddr_req;
  ddr_rsp_t ddr_rsp;
  logic model_clk = 0, clk, rst_n = 0, rtc = 0;
  always #5ns model_clk = ~model_clk;
  assign #3ns clk = model_clk;
  always #500ns rtc = ~rtc;
  logic [NumTiles-1:0] irq, spm_ready = '0, started = '0, done, failed;
  logic [NumTiles-1:0] uart_tx;
  string hello_message = {"Hello Vector World!",8'h0d,8'h0a};
  longint unsigned hello_buffer;
  int hello_negative = 0;
  int hello_uart_negative = 0;
  int uart_bytes [NumTiles];
  string uart_received [NumTiles];
  bit [NumTiles-1:0] uart_checked = '0;
  longint unsigned ara_requests [NumTiles], ara_responses [NumTiles];
  longint unsigned ara_reads [NumTiles], ara_writes [NumTiles], fft_requests [NumTiles];
  logic [NumTiles-1:0] injected = '0;
  logic [NumTiles-1:0] ddr_owner_checked = '0;
  logic [NumTiles-1:0][31:0] exit_code, phase, trap_cause, trap_value, trap_pc;
  logic [NumTiles-1:0][31:0] observed_tile, failure_code, success_signature, injection_sc;
  logic [NumTiles-1:0][63:0] last_pc;
  longint unsigned retired [NumTiles], spm_retired [NumTiles], known_loads [NumTiles];
  longint unsigned local_aw [NumTiles], local_ar [NumTiles];
  longint unsigned local_amo [NumTiles], local_lr [NumTiles], local_sc [NumTiles];
  longint unsigned global_aw [NumTiles], global_ar [NumTiles];
  longint unsigned global_amo [NumTiles], global_lr [NumTiles], global_sc [NumTiles];
  longint unsigned loader_writes [NumTiles], loader_reads [NumTiles];
  longint unsigned ddr_aw = 0, ddr_ar = 0;
  longint unsigned shared_amo = 0, shared_lr = 0, shared_sc = 0;
  longint unsigned dma_accepted [NumTiles], dma_popped [NumTiles];
  longint unsigned cached_spm_cycles [NumTiles], cached_spm_writebacks [NumTiles];
  longint entries [NumTiles];
  string elf_dir;
  longint unsigned timeout_ns = 50000000;
  import "DPI-C" function byte spm_read_elf(input string filename);
  import "DPI-C" function byte get_entry(output longint entry);
  import "DPI-C" function byte get_section(output longint address, output longint len);
  import "DPI-C" context function byte read_section(input longint address,
    inout byte buffer[], input longint len);

  multi_tile_top #(
    .NumTiles(NumTiles), .NumDmas(NumDmas), .Cfg(Cfg),
    .ext_mst_req_t(tile_axi_mst_req_t), .ext_mst_rsp_t(tile_axi_mst_rsp_t),
    .ddr_req_t(ddr_req_t), .ddr_rsp_t(ddr_rsp_t)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .rtc_i(rtc), .boot_mode_i('0),
    .uart_rx_i('1), .uart_tx_o(uart_tx), .jtag_tck_i('0),
    .jtag_trst_ni({NumTiles{rst_n}}), .jtag_tms_i('1), .jtag_tdi_i('0), .jtag_tdo_o(),
    .dma_irq_o(irq), .tile_ext_mst_req_i(loader_req), .tile_ext_mst_rsp_o(loader_rsp),
    .ddr_req_o(ddr_req), .ddr_rsp_i(ddr_rsp)
  );
  axi_sim_mem #(
    .AddrWidth(Cfg.AddrWidth), .DataWidth(Cfg.AxiDataWidth), .IdWidth($bits(ddr_id_t)),
    .UserWidth(Cfg.AxiUserWidth), .axi_req_t(ddr_req_t), .axi_rsp_t(ddr_rsp_t),
    .UninitializedData("zeros"), .ApplDelay(1ns), .AcqDelay(2ns)
  ) memory (
    .clk_i(model_clk), .rst_ni(rst_n), .axi_req_i(ddr_req), .axi_rsp_o(ddr_rsp),
    .mon_w_valid_o(), .mon_w_addr_o(), .mon_w_data_o(), .mon_w_id_o(), .mon_w_user_o(),
    .mon_w_beat_count_o(), .mon_w_last_o(), .mon_r_valid_o(), .mon_r_addr_o(),
    .mon_r_data_o(), .mon_r_id_o(), .mon_r_user_o(), .mon_r_beat_count_o(), .mon_r_last_o()
  );

  function automatic bit in_spm(input logic [63:0] address);
    return address >= SpmBase && address < SpmBase+SpmBytes;
  endfunction
  function automatic bit in_ddr(input logic [63:0] address);
    return address >= Cfg.LlcOutRegionStart && address < Cfg.LlcOutRegionEnd;
  endfunction
  function automatic logic [63:0] signature(input int tile);
    return 64'h53504d5f00000000 | (64'(tile+1) << 16) | 64'(NumTiles);
  endfunction

  // AW and W advance independently; B is accepted only after both handshakes.
  task automatic axi_write(input int tile, input logic [63:0] address,
    input tile_axi_data_t data, input tile_axi_strb_t strb, input int size,
    input logic [1:0] expected_response = axi_pkg::RESP_OKAY,
    input bit exclusive = 0);
    bit aw_pending, w_pending;
    assert(tile >= 0 && tile < NumTiles && size <= BeatSize && size >= 0 &&
      (address & ((64'h1 << size)-1)) == 0 && strb != '0)
      else $fatal(1, "invalid loader write tile=%0d addr=%h size=%0d",tile,address,size);
    @(negedge clk);
    loader_req[tile][0] = '0;
    loader_req[tile][0].aw.addr = tile_addr_t'(address);
    loader_req[tile][0].aw.size = 3'(size);
    loader_req[tile][0].aw.burst = axi_pkg::BURST_INCR;
    loader_req[tile][0].aw.lock = exclusive;
    loader_req[tile][0].aw.user = tile_axi_user_t'(Cfg.AxiUserDefault);
    loader_req[tile][0].aw_valid = 1;
    loader_req[tile][0].w.data = data;
    loader_req[tile][0].w.strb = strb;
    loader_req[tile][0].w.last = 1;
    loader_req[tile][0].w.user = tile_axi_user_t'(Cfg.AxiUserDefault);
    loader_req[tile][0].w_valid = 1;
    aw_pending = 1;
    w_pending = 1;
    while (aw_pending || w_pending) begin
      @(posedge clk);
      if (aw_pending && loader_rsp[tile][0].aw_ready) aw_pending = 0;
      if (w_pending && loader_rsp[tile][0].w_ready) w_pending = 0;
      @(negedge clk);
      loader_req[tile][0].aw_valid = aw_pending;
      loader_req[tile][0].w_valid = w_pending;
    end
    loader_req[tile][0].b_ready = 1;
    do @(posedge clk); while (!loader_rsp[tile][0].b_valid);
    assert(loader_rsp[tile][0].b.id === '0 &&
      loader_rsp[tile][0].b.resp === expected_response)
      else $fatal(1,"loader B tile=%0d addr=%h id=%h resp=%h",tile,address,
        loader_rsp[tile][0].b.id,loader_rsp[tile][0].b.resp);
    @(negedge clk);
    loader_req[tile][0] = '0;
    loader_writes[tile]++;
  endtask
  task automatic axi_read(input int tile, input logic [63:0] address,
    input int size, output tile_axi_data_t data);
    assert(tile >= 0 && tile < NumTiles && size <= BeatSize && size >= 0 &&
      (address & ((64'h1 << size)-1)) == 0)
      else $fatal(1,"invalid loader read tile=%0d addr=%h size=%0d",tile,address,size);
    @(negedge clk);
    loader_req[tile][0] = '0;
    loader_req[tile][0].ar.addr = tile_addr_t'(address);
    loader_req[tile][0].ar.size = 3'(size);
    loader_req[tile][0].ar.burst = axi_pkg::BURST_INCR;
    loader_req[tile][0].ar.user = tile_axi_user_t'(Cfg.AxiUserDefault);
    loader_req[tile][0].ar_valid = 1;
    do @(posedge clk); while (!loader_rsp[tile][0].ar_ready);
    @(negedge clk);
    loader_req[tile][0].ar_valid = 0;
    loader_req[tile][0].r_ready = 1;
    do @(posedge clk); while (!loader_rsp[tile][0].r_valid);
    assert(loader_rsp[tile][0].r.id === '0 && loader_rsp[tile][0].r.last === 1'b1 &&
      loader_rsp[tile][0].r.resp === axi_pkg::RESP_OKAY)
      else $fatal(1,"loader R tile=%0d addr=%h id=%h resp=%h last=%b",tile,address,
        loader_rsp[tile][0].r.id,loader_rsp[tile][0].r.resp,loader_rsp[tile][0].r.last);
    data = loader_rsp[tile][0].r.data;
    @(negedge clk);
    loader_req[tile][0] = '0;
    loader_reads[tile]++;
  endtask
  task automatic write32(input int tile, input logic [63:0] address,
    input logic [31:0] value, input logic [1:0] expected_response = axi_pkg::RESP_OKAY);
    axi_write(tile,address,tile_axi_data_t'(value) << (8*(address%BeatBytes)),
      tile_axi_strb_t'('hf) << (address%BeatBytes),2,expected_response);
  endtask
  task automatic read32(input int tile, input logic [63:0] address,
    output logic [31:0] value);
    tile_axi_data_t data;
    axi_read(tile,address,2,data);
    value = 32'(data >> (8*(address%BeatBytes)));
    assert(!$isunknown(value)) else $fatal(1,"unknown CSR tile=%0d addr=%h",tile,address);
  endtask
  task automatic load_elf(input int tile);
    longint address, len, aligned_address, index;
    byte bytes[];
    tile_axi_data_t data, actual;
    tile_axi_strb_t strb;
    string filename;
    filename = $sformatf("%s/tile%0d.elf",elf_dir,tile);
    if (spm_read_elf(filename)) $fatal(1,"ELF load failed %s",filename);
    if (get_entry(entries[tile])) $fatal(1,"ELF entry failed %s",filename);
    assert(in_spm(entries[tile])) else $fatal(1,"ELF entry outside SPM %h",entries[tile]);
    while (get_section(address,len)) begin
      assert(len > 0 && len <= SpmBytes && in_spm(address) &&
        len <= SpmBase+SpmBytes-address)
        else $fatal(1,"ELF PT_LOAD outside SPM addr=%h len=%h",address,len);
      bytes = new[len];
      foreach (bytes[b]) bytes[b] = 0;
      if (read_section(address,bytes,len)) $fatal(1,"ELF PT_LOAD read %s",filename);
      aligned_address = address & ~(64'(BeatBytes)-1);
      for (longint a=aligned_address; a<address+len; a+=BeatBytes) begin
        data = '0;
        strb = '0;
        for (int b=0;b<BeatBytes;b++) begin
          index = a+b-address;
          if (index >= 0 && index < len) begin
            data[b*8+:8] = bytes[index];
            strb[b] = 1;
          end
        end
        axi_write(tile,AliasBase+a-SpmBase,data,strb,BeatSize);
      end
      for (longint a=aligned_address; a<address+len; a+=BeatBytes) begin
        for (int alias_id=0;alias_id<2;alias_id++) begin
          axi_read(tile,a+(alias_id ? AliasBase-SpmBase : 0),BeatSize,actual);
          for (int b=0;b<BeatBytes;b++) begin
            index = a+b-address;
            if (index >= 0 && index < len)
              assert(actual[b*8+:8] === bytes[index])
                else $fatal(1,"ELF alias readback tile=%0d alias=%0d addr=%h byte=%0d got=%h expected=%h",
                  tile,alias_id,a,b,actual[b*8+:8],bytes[index]);
          end
        end
      end
      $display("SPM PT_LOAD tile=%0d address=%h bytes=%0d aliases verified",tile,address,len);
    end
  endtask

  function automatic logic [63:0] expected_probe(input int tile, input int word_index);
    logic [31:0] seed32, swap32;
    logic [63:0] seed64;
    seed32 = 32'h81230000 + 32'(tile)*32'h101;
    swap32 = 32'hfedc0000 | 32'(tile);
    seed64 = 64'h8123456700001000 + 64'(tile)*64'h101;
    case (word_index)
      0: return {32'hcafebabe,swap32};
      1: return 64'hfedcba9800000000 | 64'(tile);
      2: return {32'hcafebabe,32'(seed32+9)};
      3: return seed64+9;
      4: return seed64+'h20;
      5: return {swap32,32'hdecafbad};
      6: return {32'(seed32+9),32'hdecafbad};
      16: return seed64+'h89;
      32: return ExternalWrite ? 64'hee11223344550000+64'(tile)+1 : seed64+'h100;
      33: return 64'h53504d4900000000 | 64'(tile);
      default: return '0;
    endcase
  endfunction
  task automatic check_results(input int tile);
    tile_axi_data_t actual;
    logic [31:0] count;
    for (int p=0;p<34;p++) begin
      for (int alias_id=0;alias_id<2;alias_id++) begin
        axi_read(tile,64'h1000f000+8*p+(alias_id ? AliasBase-SpmBase : 0),BeatSize,actual);
        assert(actual === expected_probe(tile,p))
          else $fatal(1,"final private SPM probe tile=%0d word=%0d alias=%0d got=%h expected=%h",
            tile,p,alias_id,actual,expected_probe(tile,p));
      end
    end
    if (DmaSmoke) begin
      for (int b=0;b<64;b++) begin
        assert(memory.mem[tile_addr_t'(64'h84000000+tile*64'h10000+b)] === 8'('h31+37*tile+13*b) &&
          memory.mem[tile_addr_t'(64'h84000100+tile*64'h10000+b)] === 8'('h31+37*tile+13*b))
          else $fatal(1,"private SPM DMA DDR data tile=%0d byte=%0d",tile,b);
      end
    end
    if (tile == 0) begin
      read32(tile,64'h88010000,count);
      assert(count == 32'h53504d52) else $fatal(1,"DDR ready publication missing");
      for (int i=0;i<2;i++) begin
        read32(tile,64'h88010010+4*i,count);
        assert(count == NumTiles) else $fatal(1,"DDR barrier count index=%0d got=%0d",i,count);
      end
      for (int t=0;t<NumTiles;t++) begin
        read32(tile,64'h88010100+4*t,count);
        assert(count == 0) else $fatal(1,"DDR error slot tile=%0d code=%h",t,count);
      end
    end
  endtask

  for (genvar t=0;t<NumTiles;t++) begin : gen_watch
    if (AraHello) begin : gen_hello_uart
      initial begin
        byte unsigned data;
        string expected_message;
        uart_bytes[t] = 0;
        uart_received[t] = "";
        wait(started[t]);
        expected_message = hello_message;
        if (hello_uart_negative && t == 0)
          expected_message.putc(1,expected_message[1] ^ 8'h01);
        forever begin
          @(negedge uart_tx[t]);
          #(UartBitPeriod/2);
          assert(uart_tx[t] === 0) else $fatal(1,"ARA hello UART start");
          for (int bitno=0;bitno<8;bitno++) begin
            #UartBitPeriod;
            assert(!$isunknown(uart_tx[t])) else $fatal(1,"ARA hello UART X");
            data[bitno] = uart_tx[t];
          end
          #UartBitPeriod;
          assert(uart_tx[t] === 1) else $fatal(1,"FAIL ARA UART tile=%0d: stop bit",t);
          assert(!uart_checked[t]) else $fatal(1,"FAIL ARA UART tile=%0d: extra byte=%h",t,data);
          uart_received[t] = {uart_received[t],data};
          uart_bytes[t]++;
          if (data == 8'h0a) begin
            $write("ARA UART tile=%0d: %s",t,uart_received[t]);
            assert(uart_received[t] == expected_message)
              else $fatal(1,"FAIL ARA UART tile=%0d: string mismatch received=%s expected=%s",
                t,uart_received[t],expected_message);
            $display("PASS ARA UART tile=%0d bytes=%0d",t,uart_bytes[t]);
            uart_checked[t] = 1;
          end
        end
      end
    end
    assign observed_tile[t] = dut.gen_tiles[t].i_soc.i_regs.scratch_0_qs;
    assign phase[t] = dut.gen_tiles[t].i_soc.i_regs.scratch_1_qs;
    assign exit_code[t] = dut.gen_tiles[t].i_soc.i_regs.scratch_2_qs;
    assign failure_code[t] = dut.gen_tiles[t].i_soc.i_regs.scratch_3_qs;
    assign trap_value[t] = dut.gen_tiles[t].i_soc.i_regs.scratch_4_qs;
    assign success_signature[t] = dut.gen_tiles[t].i_soc.i_regs.scratch_6_qs;
    assign injection_sc[t] = dut.gen_tiles[t].i_soc.i_regs.scratch_9_qs;
    assign trap_cause[t] = dut.gen_tiles[t].i_soc.i_regs.scratch_10_qs;
    assign trap_pc[t] = dut.gen_tiles[t].i_soc.i_regs.scratch_11_qs;
    assign done[t] = started[t] && exit_code[t][0];
    assign failed[t] = done[t] && exit_code[t] != 1;
    wire tile_axi_slv_req_t spm_req = dut.gen_tiles[t].i_soc.gen_private_spm.spm_req;
    wire tile_axi_slv_rsp_t spm_rsp = dut.gen_tiles[t].i_soc.gen_private_spm.spm_rsp;
    wire tile_axi_slv_req_t mem_req = dut.gen_tiles[t].i_soc.gen_private_spm.spm_mem_req;
    wire tile_axi_slv_rsp_t mem_rsp = dut.gen_tiles[t].i_soc.gen_private_spm.spm_mem_rsp;
    if (ExternalWrite) begin : gen_injection
      initial begin
        logic [31:0] address, low_word, high_word;
        wait (started[t] && phase[t] == 5);
        read32(t,64'h03000010,address);
        read32(t,64'h03000014,low_word);
        read32(t,64'h03000020,high_word);
        assert(address == 32'h1400f100 && {high_word,low_word} == 64'hee11223344550000+64'(t))
          else $fatal(1,"external-write firmware protocol tile=%0d addr=%h data=%h",t,address,{high_word,low_word});
        axi_write(t,64'(address),{high_word,low_word},'1,BeatSize);
        injected[t] = 1;
        write32(t,64'h0300001c,32'h49574f4b);
        $display("SPM external write tile=%0d address=%h data=%h B accepted before ACK",t,address,{high_word,low_word});
      end
    end
    if (DdrOwner) begin : gen_ddr_owner
      initial begin
        logic [31:0] address, low_word, high_word;
        tile_axi_data_t actual;
        wait (started[t] && phase[t] == 10);
        read32(t,64'h03000010,address);
        read32(t,64'h03000014,low_word);
        read32(t,64'h03000020,high_word);
        assert(address == 32'h84000800+t*32'h10000 &&
          {high_word,low_word} == 64'hddeeff0011220000+64'(t))
          else $fatal(1,"DDR owner firmware protocol tile=%0d",t);
        axi_write(t,64'(address),{high_word,low_word},'1,BeatSize,axi_pkg::RESP_OKAY,1);
        axi_read(t,64'(address),BeatSize,actual);
        assert(actual == 64'h8123456700001800+64'(t)*64'h101)
          else $fatal(1,"loader stole CPU DDR reservation tile=%0d data=%h",t,actual);
        ddr_owner_checked[t] = 1;
        write32(t,64'h0300001c,32'h49574f4b);
        $display("DDR loader SC rejected tile=%0d; CPU reservation preserved",t);
      end
    end
    always @(posedge clk) begin : monitor
      if (!rst_n) begin
        retired[t]=0; spm_retired[t]=0; known_loads[t]=0; last_pc[t]='0;
        local_aw[t]=0; local_ar[t]=0; local_amo[t]=0; local_lr[t]=0; local_sc[t]=0;
        global_aw[t]=0; global_ar[t]=0; global_amo[t]=0; global_lr[t]=0; global_sc[t]=0;
        dma_accepted[t]=0; dma_popped[t]=0;
        cached_spm_cycles[t]=0; cached_spm_writebacks[t]=0;
        ara_requests[t]=0; ara_responses[t]=0; ara_reads[t]=0; ara_writes[t]=0; fft_requests[t]=0;
      end else begin
        if (started[t]) begin
          if (dut.gen_tiles[t].i_soc.acc_req_ara.acc_req.req_valid &&
              dut.gen_tiles[t].i_soc.acc_resp_ara.acc_resp.req_ready)
            ara_requests[t]++;
          if (dut.gen_tiles[t].i_soc.acc_resp_ara.acc_resp.resp_valid &&
              dut.gen_tiles[t].i_soc.acc_req_ara.acc_req.resp_ready)
            ara_responses[t]++;
          if (dut.gen_tiles[t].i_soc.axi_ara_wide_req.ar_valid &&
              dut.gen_tiles[t].i_soc.axi_ara_wide_resp.ar_ready) ara_reads[t]++;
          if (dut.gen_tiles[t].i_soc.axi_ara_wide_req.aw_valid &&
              dut.gen_tiles[t].i_soc.axi_ara_wide_resp.aw_ready) ara_writes[t]++;
          if (dut.gen_tiles[t].i_soc.acc_req_fft.acc_req.req_valid &&
              dut.gen_tiles[t].i_soc.acc_resp_fft.acc_resp.req_ready) fft_requests[t]++;
        end
        if (phase[t] == 14 && dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.dcache_en_csr_nbdcache)
          cached_spm_cycles[t]++;
        if (phase[t] == 14 &&
            dut.gen_tiles[t].i_soc.gen_cva6_cores[0].core_out_req.aw_valid &&
            dut.gen_tiles[t].i_soc.gen_cva6_cores[0].core_out_rsp.aw_ready &&
            dut.gen_tiles[t].i_soc.gen_cva6_cores[0].core_out_req.aw.id == Cva6IdDCache &&
            in_spm(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].core_out_req.aw.addr))
          cached_spm_writebacks[t]++;
        if ($test$plusargs("TRACE_AXI")) begin
          if (dut.gen_tiles[t].i_soc.axi_rt_in_req[0].ar_valid && dut.gen_tiles[t].i_soc.axi_rt_in_rsp[0].ar_ready)
            $display("CPU AR time=%0t tile=%0d id=%h addr=%h len=%0d", $time,t,
              dut.gen_tiles[t].i_soc.axi_rt_in_req[0].ar.id,
              dut.gen_tiles[t].i_soc.axi_rt_in_req[0].ar.addr,
              dut.gen_tiles[t].i_soc.axi_rt_in_req[0].ar.len);
          if (dut.gen_tiles[t].i_soc.axi_rt_in_rsp[0].r_valid && dut.gen_tiles[t].i_soc.axi_rt_in_req[0].r_ready)
            $display("CPU R time=%0t tile=%0d id=%h last=%b resp=%h", $time,t,
              dut.gen_tiles[t].i_soc.axi_rt_in_rsp[0].r.id,
              dut.gen_tiles[t].i_soc.axi_rt_in_rsp[0].r.last,
              dut.gen_tiles[t].i_soc.axi_rt_in_rsp[0].r.resp);
          if (spm_req.ar_valid && spm_rsp.ar_ready)
            $display("SPM AR time=%0t tile=%0d id=%h addr=%h len=%0d", $time,t,spm_req.ar.id,spm_req.ar.addr,spm_req.ar.len);
          if (spm_rsp.r_valid && spm_req.r_ready)
            $display("SPM R time=%0t tile=%0d id=%h last=%b resp=%h", $time,t,spm_rsp.r.id,spm_rsp.r.last,spm_rsp.r.resp);
        end
        if ($test$plusargs("TRACE_CSR") && dut.gen_tiles[t].i_soc.gen_private_spm.spm_conf_req.valid)
          $display("SPM CSR tile=%0d request=%h response=%h decoded=%h hit=%h", t,
            dut.gen_tiles[t].i_soc.gen_private_spm.spm_conf_req,
            dut.gen_tiles[t].i_soc.gen_private_spm.spm_conf_rsp,
            dut.gen_tiles[t].i_soc.gen_private_spm.i_spm.i_llc_config_regfile.reg_addr,
            dut.gen_tiles[t].i_soc.gen_private_spm.i_spm.i_llc_config_regfile.addr_hit);
        if (spm_ready[t]) begin
          assert((dut.gen_tiles[t].i_soc.gen_private_spm.i_spm.config_regs_q.cfg_spm & AllWays) === AllWays)
            else $fatal(1,"actual LLC CFG_SPM cleared tile=%0d",t);
          assert(dut.gen_tiles[t].i_soc.gen_private_spm.i_spm.i_axi_llc_top_raw.spm_lock === Cfg.LlcSetAssoc'(AllWays))
            else $fatal(1,"actual LLC SPM lock cleared tile=%0d",t);
        end
        if (dut.i_dma_subsystem.i_pool.submit_valid[t] && dut.i_dma_subsystem.i_pool.submit_ready[t])
          dma_accepted[t]++;
        if (dut.i_dma_subsystem.i_pool.gen_tiles[t].i_frontend.pop_fire) dma_popped[t]++;
        if (loader_req[t][0].aw_valid)
          assert(loader_req[t][0].aw.id == 0 && loader_req[t][0].aw.atop == 0)
            else $fatal(1,"loader must issue normal AW ID zero tile=%0d",t);
        if (loader_req[t][0].ar_valid)
          assert(loader_req[t][0].ar.id == 0 && !loader_req[t][0].ar.lock)
            else $fatal(1,"loader must issue normal AR ID zero tile=%0d",t);
        if (spm_req.aw_valid && spm_rsp.aw_ready) begin
          local_aw[t]++;
          assert(in_spm(spm_req.aw.addr)) else $fatal(1,"local AW outside normalized SPM tile=%0d addr=%h",t,spm_req.aw.addr);
          if (spm_req.aw.atop != 0) local_amo[t]++;
          if (spm_req.aw.lock) local_sc[t]++;
        end
        if (spm_req.ar_valid && spm_rsp.ar_ready) begin
          local_ar[t]++;
          assert(in_spm(spm_req.ar.addr)) else $fatal(1,"local AR outside normalized SPM tile=%0d addr=%h",t,spm_req.ar.addr);
          if (spm_req.ar.lock) local_lr[t]++;
        end
        if (mem_req.aw_valid && mem_rsp.aw_ready)
          assert(in_spm(mem_req.aw.addr) && mem_req.aw.atop == 0 && !mem_req.aw.lock)
            else $fatal(1,"SPM memory AW was not localized/deatomized tile=%0d",t);
        if (mem_req.ar_valid && mem_rsp.ar_ready)
          assert(in_spm(mem_req.ar.addr) && !mem_req.ar.lock)
            else $fatal(1,"SPM memory AR was not localized/deatomized tile=%0d",t);
        if (dut.mem_req[t].aw_valid && dut.mem_rsp[t].aw_ready) begin
          global_aw[t]++;
          assert(in_ddr(dut.mem_req[t].aw.addr)) else $fatal(1,"tile AW leaked into DDR tile=%0d addr=%h",t,dut.mem_req[t].aw.addr);
          if (dut.mem_req[t].aw.atop != 0) global_amo[t]++;
          if (dut.mem_req[t].aw.lock) global_sc[t]++;
        end
        if (dut.mem_req[t].ar_valid && dut.mem_rsp[t].ar_ready) begin
          global_ar[t]++;
          assert(in_ddr(dut.mem_req[t].ar.addr)) else $fatal(1,"tile AR leaked into DDR tile=%0d addr=%h",t,dut.mem_req[t].ar.addr);
          if (dut.mem_req[t].ar.lock) global_lr[t]++;
        end
        for (int c=0;c<$bits(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_ack);c++) begin
          if (dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_ack[c] &&
              !dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].ex.valid) begin
            retired[t]++;
            last_pc[t] = dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].pc;
            if (in_spm(last_pc[t])) spm_retired[t]++;
            if (dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].fu == ariane_pkg::LOAD &&
                dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].rd != 0) begin
              assert(!$isunknown(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].result))
                else $fatal(1,"retired load register contains X tile=%0d pc=%h",t,last_pc[t]);
              known_loads[t]++;
            end
          end
        end
      end
    end
  end
  always @(posedge clk) if (rst_n) begin
    if (dut.i_dma_subsystem.i_fabric.atom_slv_req.aw_valid &&
        dut.i_dma_subsystem.i_fabric.atom_slv_rsp.aw_ready) begin
      assert(in_ddr(dut.i_dma_subsystem.i_fabric.atom_slv_req.aw.addr))
        else $fatal(1,"raw shared atomic AW outside DDR");
      if (dut.i_dma_subsystem.i_fabric.atom_slv_req.aw.atop != 0) shared_amo++;
      if (dut.i_dma_subsystem.i_fabric.atom_slv_req.aw.lock) shared_sc++;
    end
    if (dut.i_dma_subsystem.i_fabric.atom_slv_req.ar_valid &&
        dut.i_dma_subsystem.i_fabric.atom_slv_rsp.ar_ready) begin
      assert(in_ddr(dut.i_dma_subsystem.i_fabric.atom_slv_req.ar.addr))
        else $fatal(1,"raw shared atomic AR outside DDR");
      if (dut.i_dma_subsystem.i_fabric.atom_slv_req.ar.lock) shared_lr++;
    end
    if (ddr_req.aw_valid && ddr_rsp.aw_ready) begin
      ddr_aw++;
      assert(in_ddr(ddr_req.aw.addr) && ddr_req.aw.atop == 0 && !ddr_req.aw.lock)
        else $fatal(1,"global DDR AW address/atomic leak addr=%h",ddr_req.aw.addr);
    end
    if (ddr_req.ar_valid && ddr_rsp.ar_ready) begin
      ddr_ar++;
      assert(in_ddr(ddr_req.ar.addr) && !ddr_req.ar.lock)
        else $fatal(1,"global DDR AR address/atomic leak addr=%h",ddr_req.ar.addr);
    end
  end
  task automatic diagnostics();
    for (int t=0;t<NumTiles;t++) begin
      $display("SPM CPU tile=%0d ready=%b started=%b exit=%h phase=%0d id=%h retired=%0d spm_retired=%0d pc=%h failure=%h mcause=%h mtval=%h mepc=%h signature=%h",
        t,spm_ready[t],started[t],exit_code[t],phase[t],observed_tile[t],retired[t],spm_retired[t],last_pc[t],failure_code[t],trap_cause[t],trap_value[t],trap_pc[t],success_signature[t]);
      $display("SPM evidence tile=%0d local_aw/ar=%0d/%0d local_amo/lr/sc=%0d/%0d/%0d global_aw/ar=%0d/%0d global_amo/lr/sc=%0d/%0d/%0d loader_w/r=%0d/%0d known_loads=%0d",
        t,local_aw[t],local_ar[t],local_amo[t],local_lr[t],local_sc[t],global_aw[t],global_ar[t],global_amo[t],global_lr[t],global_sc[t],loader_writes[t],loader_reads[t],known_loads[t]);
    end
    $display("SPM DDR accepted AW=%0d AR=%0d raw_shared_amo/lr/sc=%0d/%0d/%0d",ddr_aw,ddr_ar,shared_amo,shared_lr,shared_sc);
  endtask
  initial begin : run
    logic [31:0] bist, flushed, cfg_spm;
    tile_axi_data_t actual;
    loader_req = '0;
    for (int t=0;t<NumTiles;t++) begin loader_writes[t]=0; loader_reads[t]=0; end
    assert(NumTiles > 0 && NumDmas > 0 && Cfg.Ara && Cfg.Fft && Cfg.LlcSpmPrivate &&
      Cfg.LlcNotBypass && SpmBytes == 128*1024 && Cfg.LlcSetAssoc == 8 &&
      !Cfg.Dma && Cfg.AxiExtNumMst == 1 && Cfg.AxiExtNumSlv == 1 &&
      Cfg.Uart && Cfg.Bootrom && Cfg.PlatformRom == 0 && BeatBytes == 8)
      else $fatal(1,"config 5 private SPM system contract violated");
    if (!$value$plusargs("ELF_DIR=%s",elf_dir)) $fatal(1,"ELF_DIR required");
    if (AraHello) begin
      assert(!ExternalWrite && !DdrOwner && !DmaSmoke)
        else $fatal(1,"ARA hello requires its own workload checks");
      if (!$value$plusargs("ARA_HELLO_BUF=%h",hello_buffer)) $fatal(1,"ARA_HELLO_BUF required");
      void'($value$plusargs("ARA_HELLO_NEGATIVE=%d",hello_negative));
      void'($value$plusargs("ARA_HELLO_UART_NEGATIVE=%d",hello_uart_negative));
      assert(in_spm(hello_buffer) && hello_buffer+64 <= SpmBase+SpmBytes)
        else $fatal(1,"ARA hello buffer outside private SPM");
    end
    repeat (10) @(negedge clk);
    rst_n = 1;
    write32(0,64'h88010000,0);
    for (int t=0;t<NumTiles;t++) begin
      do begin
        read32(t,64'h03001048,bist);
        read32(t,64'h03001018,flushed);
        if ($test$plusargs("TRACE_CSR")) $display("SPM poll tile=%0d bist=%h flushed=%h",t,bist,flushed);
      end while (!bist[0] || (flushed & 32'(AllWays)) != 32'(AllWays));
      read32(t,64'h03001000,cfg_spm);
      assert((cfg_spm & 32'(AllWays)) == 32'(AllWays)) else $fatal(1,"boot ROM did not configure all-SPM tile=%0d",t);
      spm_ready[t] = 1;
      write32(t,64'h03001000,0,axi_pkg::RESP_SLVERR);
      for (int alias_id=1; alias_id<32; alias_id++)
        write32(t,64'h03001000+128*alias_id,0,axi_pkg::RESP_SLVERR);
      read32(t,64'h03001000,cfg_spm);
      assert((cfg_spm & 32'(AllWays)) == 32'(AllWays))
        else $fatal(1,"rejected CFG_SPM clear changed all-SPM tile=%0d",t);
      $display("SPM CFG_SPM clear rejected with SLVERR tile=%0d ways=%h",t,cfg_spm);
      axi_write(t,AliasBase,tile_axi_data_t'(signature(t)),'1,BeatSize);
    end
    // Hold every CPU in passive ROM until all tile-local signatures have been checked.
    for (int t=0;t<NumTiles;t++) begin
      axi_read(t,SpmBase,BeatSize,actual);
      assert(actual === signature(t)) else $fatal(1,"cached alias/isolation signature tile=%0d got=%h",t,actual);
      axi_read(t,AliasBase,BeatSize,actual);
      assert(actual === signature(t)) else $fatal(1,"uncached alias/isolation signature tile=%0d got=%h",t,actual);
      load_elf(t);
    end
    for (int t=0;t<NumTiles;t++) begin
      write32(t,64'h03000000,32'(entries[t]));
      write32(t,64'h03000004,32'(entries[t] >> 32));
      started[t] = 1;
      write32(t,64'h03000008,32'h2);
      $display("SPM boot ROM handoff tile=%0d entry=%h",t,entries[t]);
    end
    wait (&done || |failed);
    for (int t=0;t<NumTiles;t++) if (failed[t]) begin
      diagnostics();
      $fatal(1,"private SPM firmware failed tile=%0d code=%h",t,exit_code[t]);
    end
    diagnostics();
    if (AraHello) begin
      for (int tile=0;tile<NumTiles;tile++) begin
      // UART TEMT can precede the monitor's final stop-bit sample.
      for (int cycle=0;cycle<8680 && !uart_checked[tile];cycle++)
        @(negedge clk);
      assert(uart_checked[tile]) else begin
        $display("ARA UART tile=%0d (partial): %s",tile,uart_received[tile]);
        $fatal(1,"FAIL ARA UART tile=%0d: incomplete line bytes=%0d",tile,uart_bytes[tile]);
      end
      assert(exit_code[tile] == 1 && spm_retired[tile] >= 80 && known_loads[tile] > 0 &&
        ara_requests[tile] > 0 && ara_responses[tile] > 0 && ara_reads[tile] > 0 && ara_writes[tile] > 0 &&
        fft_requests[tile] == 0 && uart_bytes[tile] == hello_message.len() &&
        dma_accepted[tile] == 0 && dma_popped[tile] == 0)
        else $fatal(1,"ARA hello execution evidence incomplete req=%0d rsp=%0d reads=%0d writes=%0d uart=%0d",
          ara_requests[tile],ara_responses[tile],ara_reads[tile],ara_writes[tile],uart_bytes[tile]);
      for (int b=0;b<64;b++) begin
        byte unsigned expected_byte;
        expected_byte = b < hello_message.len() ? hello_message[b] : 0;
        if (hello_negative && b == 1) expected_byte ^= 1;
        axi_read(tile,(hello_buffer+b) & ~64'h7,BeatSize,actual);
        assert(8'(actual >> (8*((hello_buffer+b)%8))) === expected_byte)
          else $fatal(1,"ARA hello buffer mismatch tile=%0d byte=%0d got=%h expected=%h",tile,b,
            8'(actual >> (8*((hello_buffer+b)%8))),expected_byte);
      end
      $display("ARA evidence tile=%0d retired=%0d spm_retired=%0d requests=%0d responses=%0d reads=%0d writes=%0d fft=%0d uart_bytes=%0d dma_jobs=0",
        tile,retired[tile],spm_retired[tile],ara_requests[tile],ara_responses[tile],ara_reads[tile],ara_writes[tile],
        fft_requests[tile],uart_bytes[tile]);
      end
      $display("PASS Ara hello real CVA6 %0d tiles x %0d DMA engines",NumTiles,NumDmas);
      $finish;
    end
    for (int t=0;t<NumTiles;t++) begin
      assert(exit_code[t] == 1 && phase[t] == ExpectedPhase && observed_tile[t] == t &&
        spm_retired[t] >= 80 && known_loads[t] > 0 && local_amo[t] > 0 &&
        local_lr[t] > 0 && local_sc[t] > 0 && global_amo[t] > 0 && failure_code[t] == 0 &&
        success_signature[t] == (32'h53504d00 | 32'(t)))
        else $fatal(1,"private SPM CPU/routing evidence failed tile=%0d",t);
      if (ExternalWrite)
        assert(injected[t] && injection_sc[t] != 0) else $fatal(1,"external write/failed SC missing tile=%0d",t);
      if (DdrOwner) begin
        logic [31:0] cpu_sc_status;
        read32(t,64'h03000030,cpu_sc_status);
        assert(ddr_owner_checked[t] && cpu_sc_status == 0 && global_lr[t] > 0 && global_sc[t] > 1)
          else $fatal(1,"DDR CPU/loader reservation ownership check missing tile=%0d",t);
      end
      begin
        logic [31:0] cache_pass, cross_memory_pass;
        read32(t,64'h03000034,cache_pass);
        read32(t,64'h03000038,cross_memory_pass);
        assert(cache_pass == 1 && cross_memory_pass == 1 &&
          cached_spm_cycles[t] > 0 && cached_spm_writebacks[t] > 0)
          else $fatal(1,"cached or cross-memory SPM atomic test missing tile=%0d",t);
        $display("SPM extended evidence tile=%0d cache=%0d cross_memory_lrsc=%0d cache_cycles=%0d cache_writebacks=%0d",
          t,cache_pass,cross_memory_pass,cached_spm_cycles[t],cached_spm_writebacks[t]);
      end
      if (DmaSmoke)
        assert(dma_accepted[t] == 1 && dma_popped[t] == 1) else $fatal(1,"DMA smoke counts tile=%0d",t);
      check_results(t);
    end
    assert(ddr_aw > 0 && ddr_ar > 0 && shared_amo > 0) else $fatal(1,"global DDR/atomic traffic missing");
    $display("PASS private SPM real CVA6 %0d tiles x %0d engines",NumTiles,NumDmas);
    $finish;
  end
  initial begin : watchdog
    void'($value$plusargs("TIMEOUT_NS=%d",timeout_ns));
    #(timeout_ns * 1ns);
    diagnostics();
    $fatal(1,"private SPM system watchdog after %0d ns",timeout_ns);
  end
endmodule
