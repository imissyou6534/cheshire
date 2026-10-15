// SPDX-License-Identifier: SHL-0.51
`timescale 1ns/1ps
`include "cheshire/typedef.svh"
module tb_scratch_multitile #(
  parameter int unsigned NumTiles = 4,
  parameter int unsigned NumDmas = 2
);
  import cheshire_pkg::*;
  function automatic cheshire_cfg_t system_cfg();
    cheshire_cfg_t cfg = tb_cheshire_pkg::gen_cheshire_ara_fft_spm_cfg();
    cfg.RtcFreq = 1000000;
    return cfg;
  endfunction
  localparam cheshire_cfg_t Cfg = system_cfg();
  localparam int FullWrites = 70*16;
  localparam int PartialWrites = 6*16;
  `CHESHIRE_TYPEDEF_ALL(tile_, Cfg)
  typedef logic [$bits(tile_axi_llc_id_t)+$clog2(NumTiles+NumDmas)-1:0] ddr_id_t;
  `CHESHIRE_TYPEDEF_AXI_CT(ddr, tile_addr_t, ddr_id_t,
    tile_axi_data_t, tile_axi_strb_t, tile_axi_user_t)
  logic model_clk = 0, clk, rst_n = 0, rtc = 0;
  always #5ns model_clk = ~model_clk;
  assign #3ns clk = model_clk;
  always #500ns rtc = ~rtc;
  tile_axi_mst_req_t [NumTiles-1:0][iomsb(Cfg.AxiExtNumMst):0] loader_req;
  tile_axi_mst_rsp_t [NumTiles-1:0][iomsb(Cfg.AxiExtNumMst):0] loader_rsp;
  ddr_req_t ddr_req;
  ddr_rsp_t ddr_rsp;
  logic [NumTiles-1:0] active = '0;
  logic [15:0][31:0] golden [NumTiles];
  int writes [NumTiles], rejected [NumTiles], reads [NumTiles], bus_errors [NumTiles];
  longint unsigned retired [NumTiles];
  string elf_dir;
  int negative = 0;
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
    .uart_rx_i('1), .uart_tx_o(), .jtag_tck_i('0),
    .jtag_trst_ni({NumTiles{rst_n}}), .jtag_tms_i('1), .jtag_tdi_i('0), .jtag_tdo_o(),
    .dma_irq_o(), .tile_ext_mst_req_i(loader_req), .tile_ext_mst_rsp_o(loader_rsp),
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

  function automatic logic [31:0] pattern(input int tile, round, regno);
    logic [31:0] stamp;
    case (round)
      0: return 32'h0;
      1: return 32'hffffffff;
      2: return 32'haaaaaaaa;
      3: return 32'h55555555;
      default: begin
        if (round < 36) return 32'h1 << (round-4);
        if (round < 68) return ~(32'h1 << (round-36));
        stamp = 32'h5a000000 | (32'(tile) << 16) | (32'(regno) << 8) | 32'(128+regno);
        return round == 68 ? stamp : ~stamp;
      end
    endcase
  endfunction

  function automatic logic [31:0] mem32(input longint unsigned address);
    logic [31:0] value;
    value = 0;
    for (int b=0; b<4; b++)
      if (memory.mem.exists(tile_addr_t'(address+b)))
        value[b*8+:8] = memory.mem[tile_addr_t'(address+b)];
    return value;
  endfunction

  task automatic axi_write(input int tile, input longint unsigned address,
    input tile_axi_data_t data, input tile_axi_strb_t strb);
    bit aw_pending, w_pending;
    @(negedge clk);
    loader_req[tile][0] = '0;
    loader_req[tile][0].aw.addr = tile_addr_t'(address);
    loader_req[tile][0].aw.size = 3'd3;
    loader_req[tile][0].aw.burst = axi_pkg::BURST_INCR;
    loader_req[tile][0].aw.user = tile_axi_user_t'(Cfg.AxiUserDefault);
    loader_req[tile][0].aw_valid = 1;
    loader_req[tile][0].w.data = data;
    loader_req[tile][0].w.strb = strb;
    loader_req[tile][0].w.last = 1;
    loader_req[tile][0].w_valid = 1;
    aw_pending = 1; w_pending = 1;
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
    assert(loader_rsp[tile][0].b.resp === axi_pkg::RESP_OKAY)
      else $fatal(1,"SCRATCH loader write failed tile=%0d address=%h",tile,address);
    @(negedge clk);
    loader_req[tile][0] = '0;
  endtask

  task automatic write32(input int tile, input longint unsigned address, input logic [31:0] value);
    axi_write(tile,address & ~64'h7,64'(value) << (8*(address%8)),8'hf << (address%8));
  endtask

  task automatic read32(input int tile, input longint unsigned address, output logic [31:0] value);
    @(negedge clk);
    loader_req[tile][0] = '0;
    loader_req[tile][0].ar.addr = tile_addr_t'(address);
    loader_req[tile][0].ar.size = 3'd2;
    loader_req[tile][0].ar.burst = axi_pkg::BURST_INCR;
    loader_req[tile][0].ar.user = tile_axi_user_t'(Cfg.AxiUserDefault);
    loader_req[tile][0].ar_valid = 1;
    do @(posedge clk); while (!loader_rsp[tile][0].ar_ready);
    @(negedge clk);
    loader_req[tile][0].ar_valid = 0;
    loader_req[tile][0].r_ready = 1;
    do @(posedge clk); while (!loader_rsp[tile][0].r_valid);
    assert(loader_rsp[tile][0].r.resp === axi_pkg::RESP_OKAY)
      else $fatal(1,"SCRATCH loader read failed tile=%0d address=%h",tile,address);
    value = 32'(loader_rsp[tile][0].r.data >> (8*(address%8)));
    @(negedge clk);
    loader_req[tile][0] = '0;
  endtask

  task automatic load_elf(input int tile);
    longint entry, address, len, index;
    byte bytes[];
    tile_axi_data_t data;
    tile_axi_strb_t strb;
    if (spm_read_elf($sformatf("%s/tile%0d.elf",elf_dir,tile))) $fatal(1,"SCRATCH ELF parse");
    if (get_entry(entry) || entry != 64'h10000000) $fatal(1,"SCRATCH ELF entry");
    while (get_section(address,len)) begin
      assert(address >= 64'h10000000 && address+len <= 64'h10010000 && len > 0)
        else $fatal(1,"SCRATCH ELF segment bounds");
      bytes = new[len];
      foreach(bytes[b]) bytes[b] = 0;
      if (read_section(address,bytes,len)) $fatal(1,"SCRATCH ELF read");
      for (longint a=address & ~64'h7; a<address+len; a+=8) begin
        data = '0; strb = '0;
        for (int b=0; b<8; b++) begin
          index = a+b-address;
          if (index >= 0 && index < len) begin data[b*8+:8] = bytes[index]; strb[b] = 1; end
        end
        axi_write(tile,a+64'h04000000,data,strb);
      end
    end
  endtask

  for (genvar t=0; t<NumTiles; t++) begin : gen_check
    logic [15:0][31:0] actual;
    tile_reg_req_t req;
    tile_reg_rsp_t rsp;
    assign req = dut.gen_tiles[t].i_soc.i_regs.reg_req_i;
    assign rsp = dut.gen_tiles[t].i_soc.i_regs.reg_rsp_o;
    assign actual = {
      dut.gen_tiles[t].i_soc.i_regs.scratch_15_qs, dut.gen_tiles[t].i_soc.i_regs.scratch_14_qs,
      dut.gen_tiles[t].i_soc.i_regs.scratch_13_qs, dut.gen_tiles[t].i_soc.i_regs.scratch_12_qs,
      dut.gen_tiles[t].i_soc.i_regs.scratch_11_qs, dut.gen_tiles[t].i_soc.i_regs.scratch_10_qs,
      dut.gen_tiles[t].i_soc.i_regs.scratch_9_qs, dut.gen_tiles[t].i_soc.i_regs.scratch_8_qs,
      dut.gen_tiles[t].i_soc.i_regs.scratch_7_qs, dut.gen_tiles[t].i_soc.i_regs.scratch_6_qs,
      dut.gen_tiles[t].i_soc.i_regs.scratch_5_qs, dut.gen_tiles[t].i_soc.i_regs.scratch_4_qs,
      dut.gen_tiles[t].i_soc.i_regs.scratch_3_qs, dut.gen_tiles[t].i_soc.i_regs.scratch_2_qs,
      dut.gen_tiles[t].i_soc.i_regs.scratch_1_qs, dut.gen_tiles[t].i_soc.i_regs.scratch_0_qs
    };
    always @(posedge clk) begin : monitor
      int regno, groupno, lane;
      logic [3:0] strobe;
      logic [31:0] data, mask;
      if (!rst_n) begin
        active[t] = 0; golden[t] = '0;
        writes[t] = 0; rejected[t] = 0; reads[t] = 0; retired[t] = 0; bus_errors[t] = 0;
      end else begin
        if (!active[t]) begin
          for (int c=0; c<$bits(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_ack); c++)
            if (dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_ack[c] &&
                !dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].ex.valid &&
                dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].pc == 64'h10000000) begin
              golden[t] = actual;
              active[t] = 1;
            end
        end
        if (active[t]) begin
          if (dut.gen_tiles[t].i_soc.gen_cva6_cores[0].core_out_rsp.b_valid &&
              dut.gen_tiles[t].i_soc.gen_cva6_cores[0].core_out_req.b_ready) begin
            if (dut.gen_tiles[t].i_soc.gen_cva6_cores[0].core_out_rsp.b.resp == axi_pkg::RESP_SLVERR)
              bus_errors[t]++;
            else assert(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].core_out_rsp.b.resp === axi_pkg::RESP_OKAY)
              else $fatal(1,"SCRATCH unexpected CPU B response tile=%0d",t);
          end
          for (int c=0; c<$bits(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_ack); c++)
            if (dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_ack[c]) retired[t]++;
          if (req.valid && rsp.ready) begin
            assert(!$isunknown({req,rsp})) else $fatal(1,"SCRATCH unknown register transaction tile=%0d",t);
            if (req.write) begin
              if (writes[t] < FullWrites) begin
                regno = writes[t]%16;
                data = pattern(t,writes[t]/16,regno);
                assert(req.addr === 32'h03000000+32'(4*regno))
                  else $fatal(1,"SCRATCH address mismatch tile=%0d write=%0d got=%h",t,writes[t],req.addr);
                assert(req.wstrb === 4'hf && req.wdata === data && rsp.error === 1'b0)
                  else $fatal(1,"SCRATCH data mismatch tile=%0d write=%0d got=%h expected=%h strb=%h error=%b",t,writes[t],req.wdata,data,req.wstrb,rsp.error);
                golden[t][regno] = data;
                writes[t]++;
              end else begin
                assert(rejected[t] < PartialWrites) else $fatal(1,"SCRATCH extra write tile=%0d",t);
                regno = rejected[t]%16; groupno = rejected[t]/16;
                lane = groupno < 4 ? groupno : 2*(groupno-4);
                strobe = groupno < 4 ? (4'h1 << lane) : (4'h3 << lane);
                data = groupno < 4 ? (32'ha6 << (8*lane)) : (32'h3c5a << (8*lane));
                mask = 0;
                for (int b=0; b<4; b++) if (strobe[b]) mask[b*8+:8] = 8'hff;
                assert((req.addr & ~32'h3) === 32'h03000000+32'(4*regno) &&
                  req.wstrb === strobe && (req.wdata & mask) === data && rsp.error === 1'b1)
                  else $fatal(1,"SCRATCH partial-write contract tile=%0d reject=%0d addr=%h strb=%h data=%h error=%b",t,rejected[t],req.addr,req.wstrb,req.wdata,rsp.error);
                rejected[t]++;
              end
            end else begin
              assert(req.addr >= 32'h03000000 && req.addr < 32'h03000040 && rsp.error === 1'b0)
                else $fatal(1,"SCRATCH unexpected register read tile=%0d addr=%h",t,req.addr);
              regno = int'((req.addr-32'h03000000)/4);
              assert(rsp.rdata === golden[t][regno]) else $fatal(1,"SCRATCH read mismatch tile=%0d reg=%0d",t,regno);
              reads[t]++;
            end
          end
        end
      end
    end
    // Compare all words, including idle tiles, after sequential updates settle.
    always @(negedge clk) if (rst_n && active[t])
      assert(actual === golden[t]) else $fatal(1,"SCRATCH storage/isolation mismatch tile=%0d",t);
  end

  initial begin : run
    logic [31:0] bist, flushed;
    bit complete;
    loader_req = '0;
    if (!$value$plusargs("ELF_DIR=%s",elf_dir)) $fatal(1,"ELF_DIR required");
    void'($value$plusargs("NEGATIVE=%d",negative));
    assert(NumTiles >= 2 && negative inside {0,1,2}) else $fatal(1,"SCRATCH test parameters");
    repeat (10) @(negedge clk);
    rst_n = 1;
    for (int t=0; t<NumTiles; t++) begin
      do begin
        read32(t,64'h03001048,bist);
        read32(t,64'h03001018,flushed);
      end while (!bist[0] || (flushed & 32'hff) != 32'hff);
      load_elf(t);
      for (int i=0; i<10; i++) write32(t,64'h84000000+64'(t)*64'h10000+64'(4*i),i==7 ? 32'(negative) : 0);
    end
    for (int t=0; t<NumTiles; t++) begin
      write32(t,64'h03000000,32'h10000000);
      write32(t,64'h03000004,0);
      write32(t,64'h03000008,2);
    end
    do begin
      repeat (100) @(negedge clk);
      complete = 1;
      for (int t=0; t<NumTiles; t++) begin
        if (mem32(64'h84000000+64'(t)*64'h10000) == 0) complete = 0;
        else assert(mem32(64'h84000000+64'(t)*64'h10000) === 32'h53435250)
          else $fatal(1,"SCRATCH firmware failure tile=%0d error=%h cause=%h",t,
            mem32(64'h84000014+64'(t)*64'h10000),mem32(64'h84000018+64'(t)*64'h10000));
      end
    end while (!complete);
    assert(negative == 0) else $fatal(1,"SCRATCH negative escaped checker");
    for (int t=0; t<NumTiles; t++) begin
      assert(active[t] && writes[t] == FullWrites && rejected[t] == PartialWrites && bus_errors[t] == PartialWrites &&
        reads[t] >= FullWrites*2+PartialWrites && retired[t] > 100)
        else $fatal(1,"SCRATCH missing CPU/bus evidence tile=%0d writes=%0d rejected=%0d reads=%0d bus_errors=%0d",t,writes[t],rejected[t],reads[t],bus_errors[t]);
      assert(mem32(64'h84000004+64'(t)*64'h10000) == t &&
        mem32(64'h84000008+64'(t)*64'h10000) == FullWrites &&
        mem32(64'h8400000c+64'(t)*64'h10000) == PartialWrites &&
        mem32(64'h84000010+64'(t)*64'h10000) == FullWrites*2+PartialWrites)
        else $fatal(1,"SCRATCH mailbox counts mismatch tile=%0d",t);
      $display("SCRATCH evidence tile=%0d writes32=%0d rejected8=%0d rejected16=%0d cpu_slverr=%0d reg_reads=%0d retired=%0d",t,writes[t],64,32,bus_errors[t],reads[t],retired[t]);
    end
    $display("PASS SCRATCH real CVA6 %0d tiles x %0d engines",NumTiles,NumDmas);
    $finish;
  end
  initial begin
    #50000000ns;
    for (int t=0; t<NumTiles; t++) $display("SCRATCH timeout tile=%0d active=%b writes=%0d rejected=%0d mailbox=%h",t,active[t],writes[t],rejected[t],mem32(64'h84000000+64'(t)*64'h10000));
    $fatal(1,"SCRATCH watchdog");
  end
endmodule
