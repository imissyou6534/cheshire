`timescale 1ns/1ps
`include "cheshire/typedef.svh"
module tb_shared_dma_system #(
  parameter int unsigned NumTiles=4,
  parameter int unsigned NumDmas=2,
  parameter bit BootSmoke=0,
  parameter int unsigned NegativeCase=0
);
  import cheshire_pkg::*;
  function automatic cheshire_cfg_t system_cfg();
    cheshire_cfg_t cfg;
    cfg=cheshire_shared_dma_cfg_pkg::tile_cfg(DefaultCfg);
    cfg.Bootrom=0;
    cfg.PlatformRom='h80000000;
    cfg.Uart=0;
    cfg.Ara=0;
    cfg.Fft=0;
    return cfg;
  endfunction
  localparam cheshire_cfg_t Cfg=system_cfg();
  `CHESHIRE_TYPEDEF_ALL(tile_, Cfg)
  typedef logic [$bits(tile_axi_llc_id_t)+$clog2(NumTiles+NumDmas)-1:0] ddr_id_t;
  `CHESHIRE_TYPEDEF_AXI_CT(ddr, tile_addr_t, ddr_id_t,
    tile_axi_data_t, tile_axi_strb_t, tile_axi_user_t)
  logic model_clk=0, clk, rst_n=0;
  always #5 model_clk=~model_clk;
  assign #3ns clk=model_clk;
  ddr_req_t req;
  ddr_rsp_t rsp;
  logic [NumTiles-1:0] irq, done, failed;
  logic [NumTiles-1:0][31:0] exit_code, phase, trap_cause, trap_value;
  logic [NumTiles-1:0][31:0] observed_tile;
  logic [NumTiles-1:0][31:0] sw_irqs, sw_jobs, sw_cache, sw_sync;
  longint unsigned retired [NumTiles];
  longint unsigned accepted [NumTiles], popped [NumTiles], claims [NumTiles], completes [NumTiles];
  longint unsigned irq_cycles [NumTiles], meip_cycles [NumTiles], flush_acks [NumTiles];
  longint unsigned cache_cycles [NumTiles], cache_writes [NumTiles];
  longint unsigned killed_unknown [NumTiles];
  longint unsigned partial_unknown [NumTiles], known_loads [NumTiles];
  int cache_outstanding [NumTiles];
  int peak_engines=0, dma_completed=0;
  logic [NumTiles-1:0][63:0] last_pc;
  string elf_dir;
  import "DPI-C" function byte read_elf(input string filename);
  import "DPI-C" function byte get_entry(output longint entry);
  import "DPI-C" function byte get_section(output longint address, output longint len);
  import "DPI-C" context function byte read_section(input longint address,
    inout byte buffer[], input longint len);
  multi_tile_top #(
    .NumTiles(NumTiles), .NumDmas(NumDmas), .Cfg(Cfg), .TileBootStride(64'h100000),
    .ddr_req_t(ddr_req_t), .ddr_rsp_t(ddr_rsp_t)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .rtc_i(1'b0), .boot_mode_i('0),
    .uart_rx_i('1), .uart_tx_o(), .jtag_tck_i('0), .jtag_trst_ni({NumTiles{rst_n}}),
    .jtag_tms_i('1), .jtag_tdi_i('0), .jtag_tdo_o(), .dma_irq_o(irq),
    .ddr_req_o(req), .ddr_rsp_i(rsp)
  );
  axi_sim_mem #(
    .AddrWidth(Cfg.AddrWidth), .DataWidth(Cfg.AxiDataWidth), .IdWidth($bits(ddr_id_t)),
    .UserWidth(Cfg.AxiUserWidth), .axi_req_t(ddr_req_t), .axi_rsp_t(ddr_rsp_t),
    .UninitializedData("zeros"), .ApplDelay(1ns), .AcqDelay(2ns)
  ) memory (
    .clk_i(model_clk), .rst_ni(rst_n), .axi_req_i(req), .axi_rsp_o(rsp),
    .mon_w_valid_o(), .mon_w_addr_o(), .mon_w_data_o(), .mon_w_id_o(), .mon_w_user_o(),
    .mon_w_beat_count_o(), .mon_w_last_o(), .mon_r_valid_o(), .mon_r_addr_o(),
    .mon_r_data_o(), .mon_r_id_o(), .mon_r_user_o(), .mon_r_beat_count_o(), .mon_r_last_o()
  );
  for(genvar t=0;t<NumTiles;t++) begin : gen_watch
    initial killed_unknown[t]=0;
    initial partial_unknown[t]=0;
    initial known_loads[t]=0;
    for(genvar p=0;p<2;p++) begin : gen_live_read_check
      assert property (@(posedge clk) disable iff(!rst_n)
        dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.gen_cache_wb.i_cache_subsystem.dcache_req_ports_o[p].data_rvalid |->
        !$isunknown(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.gen_cache_wb.i_cache_subsystem.dcache_req_ports_o[p].data_rdata))
      else begin
        logic [63:0] selected_bytes;
        int first_byte,byte_count;
        first_byte=int'($sampled(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.gen_cache_wb.i_cache_subsystem.i_nbdcache.master_ports[p].i_cache_ctrl.mem_req_q.index[2:0]));
        byte_count=1 << $sampled(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.gen_cache_wb.i_cache_subsystem.i_nbdcache.master_ports[p].i_cache_ctrl.mem_req_q.size);
        selected_bytes='0;
        for(int b=0;b<8;b++) if(b>=first_byte && b<first_byte+byte_count) selected_bytes[b*8+:8]='1;
        if($sampled(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.gen_cache_wb.i_cache_subsystem.dcache_req_ports_i[p].kill_req) ||
           $sampled(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.gen_cache_wb.i_cache_subsystem.i_nbdcache.master_ports[p].i_cache_ctrl.mem_req_q.killed))
          killed_unknown[t]++;
        else if(selected_bytes!='0 && !$isunknown(selected_bytes) &&
          !$isunknown($sampled(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.gen_cache_wb.i_cache_subsystem.dcache_req_ports_o[p].data_rdata) & selected_bytes))
          partial_unknown[t]++;
        else begin
          $display("READX tile=%0d port=%0d phase=%0d pc=%h req=%h rsp=%h cacheen=%b flush=%b ack=%b",
            t,p,$sampled(phase[t]),$sampled(last_pc[t]),
            $sampled(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.gen_cache_wb.i_cache_subsystem.dcache_req_ports_i[p]),
            $sampled(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.gen_cache_wb.i_cache_subsystem.dcache_req_ports_o[p]),
            $sampled(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.dcache_en_csr_nbdcache),
            $sampled(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.dcache_flush_ctrl_cache),
            $sampled(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.dcache_flush_ack_cache_ctrl));
          $fatal(1,"live D-cache read returned X tile=%0d port=%0d",t,p);
        end
      end
    end
    assign observed_tile[t]=dut.gen_tiles[t].i_soc.i_regs.scratch_0_qs;
    assign exit_code[t]=dut.gen_tiles[t].i_soc.i_regs.scratch_2_qs;
    assign phase[t]=dut.gen_tiles[t].i_soc.i_regs.scratch_1_qs;
    assign trap_cause[t]=dut.gen_tiles[t].i_soc.i_regs.scratch_3_qs;
    assign trap_value[t]=dut.gen_tiles[t].i_soc.i_regs.scratch_4_qs;
    assign done[t]=exit_code[t][0];
    assign failed[t]=done[t] && exit_code[t]!=1;
    assign sw_irqs[t]=dut.gen_tiles[t].i_soc.i_regs.scratch_5_qs;
    assign sw_jobs[t]=dut.gen_tiles[t].i_soc.i_regs.scratch_6_qs;
    assign sw_cache[t]=dut.gen_tiles[t].i_soc.i_regs.scratch_7_qs;
    assign sw_sync[t]=dut.gen_tiles[t].i_soc.i_regs.scratch_8_qs;
    always @(posedge clk) begin
      if(!rst_n) begin retired[t]=0; last_pc[t]=0; end
      else for(int c=0;c<$bits(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_ack);c++) begin
        if(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_ack[c] &&
           !dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].ex.valid) begin
          retired[t]++;
          last_pc[t]=dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].pc;
          if(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].fu==ariane_pkg::LOAD &&
             dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].rd!=0) begin
            assert(!$isunknown(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.commit_instr_id_commit[c].result))
              else $fatal(1,"retired load result contains X tile=%0d pc=%h",t,last_pc[t]);
            known_loads[t]++;
          end
        end
      end
    end
    always @(posedge clk) begin : monitor
      logic aw_fire,b_fire;
      if(!rst_n) begin
        accepted[t]=0; popped[t]=0; claims[t]=0; completes[t]=0;
        irq_cycles[t]=0; meip_cycles[t]=0; flush_acks[t]=0;
        cache_cycles[t]=0; cache_writes[t]=0; cache_outstanding[t]=0;
      end else begin
        if(dut.i_dma_subsystem.i_pool.submit_valid[t] && dut.i_dma_subsystem.i_pool.submit_ready[t])
          accepted[t]++;
        if(dut.i_dma_subsystem.i_pool.gen_tiles[t].i_frontend.pop_fire) popped[t]++;
        if(irq[t]) irq_cycles[t]++;
        if(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.irq_i!='0) meip_cycles[t]++;
        if(dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.dcache_flush_ack_cache_ctrl)
          flush_acks[t]++;
        if(phase[t]==4 && dut.gen_tiles[t].i_soc.gen_cva6_cores[0].i_core_cva6.dcache_en_csr_nbdcache)
          cache_cycles[t]++;
        aw_fire=dut.gen_tiles[t].i_soc.gen_cva6_cores[0].core_out_req.aw_valid &&
          dut.gen_tiles[t].i_soc.gen_cva6_cores[0].core_out_rsp.aw_ready &&
          dut.gen_tiles[t].i_soc.gen_cva6_cores[0].core_out_req.aw.id==Cva6IdDCache;
        b_fire=dut.gen_tiles[t].i_soc.gen_cva6_cores[0].core_out_rsp.b_valid &&
          dut.gen_tiles[t].i_soc.gen_cva6_cores[0].core_out_req.b_ready &&
          dut.gen_tiles[t].i_soc.gen_cva6_cores[0].core_out_rsp.b.id==Cva6IdDCache;
        if(aw_fire) begin
          cache_outstanding[t]++;
          if(phase[t]==4) cache_writes[t]++;
        end
        if(b_fire) cache_outstanding[t]--;
        assert(cache_outstanding[t]>=0) else $fatal(1,"cache B without AW");
        if(dut.gen_tiles[t].i_soc.i_plic.reg_req_i.valid && dut.gen_tiles[t].i_soc.i_plic.reg_rsp_o.ready &&
           dut.gen_tiles[t].i_soc.i_plic.reg_req_i.addr[25:0]==26'h200004) begin
          if(!dut.gen_tiles[t].i_soc.i_plic.reg_req_i.write &&
             dut.gen_tiles[t].i_soc.i_plic.reg_rsp_o.rdata==58) claims[t]++;
          if(dut.gen_tiles[t].i_soc.i_plic.reg_req_i.write &&
             dut.gen_tiles[t].i_soc.i_plic.reg_req_i.wdata==58) completes[t]++;
        end
      end
    end
  end
  always @(posedge clk) if(rst_n) begin
    if($countones(dut.i_dma_subsystem.i_pool.engine_active)>peak_engines)
      peak_engines=$countones(dut.i_dma_subsystem.i_pool.engine_active);
    dma_completed += $countones(dut.i_dma_subsystem.i_pool.comp_fire);
    for(int d=0;d<NumDmas;d++)
      if(dut.i_dma_subsystem.dma_req[d].ar_valid && dut.i_dma_subsystem.dma_rsp[d].ar_ready)
        for(int t=0;t<NumTiles;t++)
          if(dut.i_dma_subsystem.dma_req[d].ar.addr >= 64'h84002800+t*64'h10000 &&
             dut.i_dma_subsystem.dma_req[d].ar.addr < 64'h84002a00+t*64'h10000 && phase[t]==4)
            assert(cache_outstanding[t]==0) else $fatal(1,"DMA reads before cache writeback B drain");
  end
  function automatic logic [31:0] mem32(input logic [63:0] address);
    logic [31:0] value;
    for(int b=0;b<4;b++) value[b*8+:8]=memory.mem[tile_addr_t'(address+b)];
    return value;
  endfunction
  function automatic byte unsigned pattern(input int tile, input int offset);
    return 8'('h31+37*tile+13*offset+(offset>>4));
  endfunction
  function automatic byte unsigned cache_pattern(input int tile, input int offset);
    return 8'('hc3+29*tile+7*offset+(offset>>3));
  endfunction
  task automatic check_cache_ddr(input int tile);
    for(int i=0;i<512;i++) begin
      assert(memory.mem[tile_addr_t'(64'h84002800+tile*64'h10000+i)]==cache_pattern(tile,i)) else $fatal(1,"cache DDR source");
      assert(memory.mem[tile_addr_t'(64'h84006800+tile*64'h10000+i)]==cache_pattern(tile,i)) else $fatal(1,"cache DDR destination");
    end
  endtask
  task automatic check_all_ddr(input int tile);
    logic [63:0] base;
    byte unsigned expected_src,expected_dst;
    base=64'h84000000+tile*64'h10000;
    for(int i=0;i<'h4000;i++) begin
      expected_src=pattern(tile,i);
      if(i>='h2800 && i<'h2a00) expected_src=cache_pattern(tile,i-'h2800);
      expected_dst='ha5;
      if(i<4096) expected_dst=pattern(tile,i);
      if(i>='h2005 && i<'h2348 && (i-'h2005)%256<67)
        expected_dst=pattern(tile,'h2003+((i-'h2005)/256)*128+(i-'h2005)%256);
      if(i>='h2800 && i<'h2a00) expected_dst=cache_pattern(tile,i-'h2800);
      if(i>='h3000 && i<'h3400) expected_dst=pattern(tile,i);
      assert(memory.mem[tile_addr_t'(base+i)]==expected_src) else $fatal(1,"DDR source mismatch tile=%0d byte=%h",tile,i);
      assert(memory.mem[tile_addr_t'(base+'h4000+i)]==expected_dst) else $fatal(1,"DDR destination/guard mismatch tile=%0d byte=%h",tile,i);
    end
    base+='h8000;
    assert(mem32(base)=='h53444d41 && mem32(base+4)==tile) else $fatal(1,"metadata identity");
    assert(mem32(base+8)==5 && mem32(base+'hc)==1 && mem32(base+'h10)==2 && mem32(base+'h14)==2) else $fatal(1,"metadata counts");
    assert(mem32(base+'h18)==7 && mem32(base+'h1c)==NumTiles) else $fatal(1,"metadata synchronization");
    for(int j=0;j<5;j++) begin
      assert(mem32(base+'h20+j*4)==j+1 && mem32(base+'h34+j*4)==j+1) else $fatal(1,"metadata job IDs");
      assert((mem32(base+'h48+j*4)&32'hff)==0 && (mem32(base+'h48+j*4)>>16)<NumDmas) else $fatal(1,"metadata engine/status");
    end
  endtask
  initial begin : run
    longint entry,address,len;
    byte bytes[];
    if(!$value$plusargs("ELF_DIR=%s",elf_dir)) $fatal(1,"ELF_DIR required");
    for(int t=0;t<NumTiles;t++) begin
      string filename;
      filename=$sformatf("%s/tile%0d.elf",elf_dir,t);
      if(read_elf(filename)) $fatal(1,"ELF load failed %s",filename);
      void'(get_entry(entry));
      assert(entry == 64'h80000000+t*64'h100000) else $fatal(1,"ELF reset entry mismatch");
      while(get_section(address,len)) begin
        assert(address>=entry && address+len<=entry+64'h40000) else $fatal(1,"ELF outside private tile image");
        bytes=new[len];
        foreach(bytes[b]) bytes[b]=0;
        if(read_section(address,bytes,len)) $fatal(1,"ELF section load");
        for(longint b=0;b<len;b++) memory.mem[tile_addr_t'(address+b)]=bytes[b];
      end
      $display("SYSTEM preloaded tile=%0d entry=%h",t,entry);
    end
    repeat(10) @(negedge clk);
    rst_n=1;
    wait(&done || |failed);
    if(NegativeCase==1 && failed[0]) begin
      assert(exit_code[0]=='he9 && phase[0]==4 && sw_cache[0]=='h7400a5a5 && accepted[0]==3 && popped[0]==2) else $fatal(1,"cache negative did not reproduce stale line");
      assert(cache_cycles[0]>0 && cache_writes[0]>0) else $fatal(1,"cache negative lacks real cache activity");
      check_cache_ddr(0);
      $display("PASS real CVA6 negative cache: DDR correct, CPU stale=%h retired=%0d",sw_cache[0],retired[0]);
      $finish;
    end
    if(NegativeCase==2 && failed[0]) begin
      assert(exit_code[0]=='heb && phase[0]==5 && sw_irqs[0]==0 && claims[0]==0 && accepted[0]==4 && popped[0]==3) else $fatal(1,"IRQ negative did not reproduce masked handler");
      assert(irq[0] && dut.gen_tiles[0].i_soc.gen_cva6_cores[0].i_core_cva6.irq_i[0]) else $fatal(1,"IRQ negative lacks machine PLIC pending");
      assert(dut.gen_tiles[0].i_soc.i_regs.scratch_9_qs[3] && !dut.gen_tiles[0].i_soc.i_regs.scratch_10_qs[11])
        else $fatal(1,"IRQ negative must enable global MIE and mask only MEIE");
      for(int i=0;i<512;i++)
        assert(memory.mem[tile_addr_t'(64'h84007000+i)]==pattern(0,'h3000+i)) else $fatal(1,"IRQ negative DMA data");
      $display("PASS real CVA6 negative IRQ: DMA/PLIC pending, handler suppressed retired=%0d",retired[0]);
      $finish;
    end
    for(int t=0;t<NumTiles;t++) begin
      $display("SYSTEM tile=%0d exit=%h phase=%0d retired=%0d pc=%h trap=%h mtval=%h",
        t,exit_code[t],phase[t],retired[t],last_pc[t],trap_cause[t],trap_value[t]);
      $display("SYSTEM evidence tile=%0d accepted=%0d popped=%0d claims=%0d complete=%0d irqcycles=%0d meipcycles=%0d flushack=%0d cachecycles=%0d cachewrites=%0d",
        t,accepted[t],popped[t],claims[t],completes[t],irq_cycles[t],meip_cycles[t],flush_acks[t],cache_cycles[t],cache_writes[t]);
      $display("SYSTEM readcheck tile=%0d killed_unknown=%0d unused_lane_unknown=%0d known_retired_loads=%0d live_unknown=0",
        t,killed_unknown[t],partial_unknown[t],known_loads[t]);
      assert(exit_code[t]==1 && phase[t]==(BootSmoke?2:7) && retired[t]>=80 && observed_tile[t]==t &&
        last_pc[t]>=64'h80000000+t*64'h100000 && last_pc[t]<64'h80040000+t*64'h100000)
        else $fatal(1,"real CPU smoke failed");
      if(!BootSmoke) begin
        assert(accepted[t]==5 && popped[t]==5 && sw_jobs[t]==5 && sw_irqs[t]==2) else $fatal(1,"CPU/DMA event counts");
        assert(claims[t]==2 && completes[t]==2 && irq_cycles[t]>0 && meip_cycles[t]>0 && !irq[t]) else $fatal(1,"PLIC claim/complete/level checks");
        assert(cache_cycles[t]>0 && cache_writes[t]>0 && flush_acks[t]>0 && sw_cache[t]==1 && sw_sync[t]==NumTiles) else $fatal(1,"cache or synchronization evidence");
        check_all_ddr(t);
      end
    end
    if(!BootSmoke) begin
      assert(dma_completed==5*NumTiles) else $fatal(1,"DMA completion total");
      assert(peak_engines==((NumTiles<NumDmas)?NumTiles:NumDmas)) else $fatal(1,"DMA concurrency not observed");
      assert(mem32('h88000000)=='h52445931) else $fatal(1,"software ready publication");
      for(int p=2;p<=6;p++) assert(mem32('h88000100+p*4)==NumTiles) else $fatal(1,"software barrier count");
    end
    $display("PASS real CVA6 %s %0d tiles x %0d engines peak=%0d jobs=%0d",
      BootSmoke?"boot":"system",NumTiles,NumDmas,peak_engines,dma_completed);
    $finish;
  end
  initial begin
    #20000000;
    for(int t=0;t<NumTiles;t++) $display("TIMEOUT tile=%0d phase=%0d retired=%0d pc=%h exit=%h trap=%h mtval=%h",
      t,phase[t],retired[t],last_pc[t],exit_code[t],trap_cause[t],trap_value[t]);
    $fatal(1,"real CPU system watchdog");
  end
endmodule
