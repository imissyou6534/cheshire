`timescale 1ns/1ps
`include "axi/typedef.svh"
module tb_shared_dma #(
  parameter int unsigned NumTiles = 4,
  parameter int unsigned NumDmas = 2,
  parameter int unsigned AddrWidth = 32,
  parameter bit RandomStalls = 0
);
  localparam int IW = 3;
  localparam int DW = IW + $clog2(NumTiles + NumDmas);
  typedef logic [AddrWidth-1:0] addr_t;
  typedef logic [63:0] data_t;
  typedef logic [7:0] strb_t;
  typedef logic [IW-1:0] id_t;
  typedef logic [DW-1:0] ddr_id_t;
  typedef logic user_t;
  `AXI_TYPEDEF_ALL(axi, addr_t, id_t, data_t, strb_t, user_t)
  `AXI_TYPEDEF_ALL(ddr, addr_t, ddr_id_t, data_t, strb_t, user_t)
  logic model_clk = 0, clk, rst_n = 0;
  always #5 model_clk = ~model_clk;
  // The model drives at +1ns and samples at +2ns; DUT samples the same bus at +3ns.
  assign #3ns clk = model_clk;
  axi_req_t [NumTiles-1:0] ctrl_req, tile_req;
  axi_resp_t [NumTiles-1:0] ctrl_rsp, tile_rsp;
  ddr_req_t ddr_req;
  ddr_resp_t ddr_rsp;
  ddr_req_t delayed_req;
  ddr_resp_t delayed_rsp;
  ddr_req_t [0:0] mem_req;
  ddr_resp_t [0:0] mem_rsp;
  logic [NumTiles-1:0] irq;
  logic block_memory = 0, block_b = 0;
  int completions = 0;

  cheshire_shared_dma_subsystem #(
    .NumTiles(NumTiles), .NumDmas(NumDmas), .AxiAddrWidth(AddrWidth), .AxiDataWidth(64),
    .AxiIdWidth(IW), .AxiSlvIdWidth(IW), .AxiUserWidth(1), .JobFifoDepth(2),
    .CompletionDepth(4), .MemStart(64'h80000000), .MemEnd(64'h80010000),
    .tile_ctrl_req_t(axi_req_t), .tile_ctrl_rsp_t(axi_resp_t),
    .axi_req_t(axi_req_t), .axi_rsp_t(axi_resp_t),
    .ddr_req_t(ddr_req_t), .ddr_rsp_t(ddr_resp_t)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .tile_ctrl_req_i(ctrl_req),
    .tile_ctrl_rsp_o(ctrl_rsp), .tile_mem_req_i(tile_req), .tile_mem_rsp_o(tile_rsp),
    .ddr_req_o(ddr_req), .ddr_rsp_i(ddr_rsp), .dma_irq_o(irq)
  );

  axi_delayer #(
    .aw_chan_t(ddr_aw_chan_t), .w_chan_t(ddr_w_chan_t), .b_chan_t(ddr_b_chan_t),
    .ar_chan_t(ddr_ar_chan_t), .r_chan_t(ddr_r_chan_t),
    .axi_req_t(ddr_req_t), .axi_resp_t(ddr_resp_t),
    .StallRandomInput(RandomStalls), .StallRandomOutput(RandomStalls),
    .FixedDelayInput(0), .FixedDelayOutput(0)
  ) i_delayer (
    .clk_i(clk), .rst_ni(rst_n), .slv_req_i(ddr_req), .slv_resp_o(ddr_rsp),
    .mst_req_o(delayed_req), .mst_resp_i(delayed_rsp)
  );

  // Gate both halves of a handshake, allowing deterministic final-B backpressure.
  always_comb begin
    mem_req[0] = delayed_req;
    delayed_rsp = mem_rsp[0];
    if (block_memory) begin
      mem_req[0] = '0;
      delayed_rsp = '0;
    end else if (block_b) begin
      mem_req[0].b_ready = 0;
      delayed_rsp.b_valid = 0;
    end
  end
  axi_sim_mem #(
    .AddrWidth(AddrWidth), .DataWidth(64), .IdWidth(DW), .UserWidth(1),
    .axi_req_t(ddr_req_t), .axi_rsp_t(ddr_resp_t),
    .UninitializedData("zeros"), .ApplDelay(1ns), .AcqDelay(2ns)
  ) memory (
    .clk_i(model_clk), .rst_ni(rst_n), .axi_req_i(mem_req), .axi_rsp_o(mem_rsp),
    .mon_w_valid_o(), .mon_w_addr_o(), .mon_w_data_o(), .mon_w_id_o(), .mon_w_user_o(),
    .mon_w_beat_count_o(), .mon_w_last_o(), .mon_r_valid_o(), .mon_r_addr_o(),
    .mon_r_data_o(), .mon_r_id_o(), .mon_r_user_o(), .mon_r_beat_count_o(), .mon_r_last_o()
  );

  task automatic tick(input int n = 1);
    repeat (n) @(negedge clk);
  endtask
  task automatic wr(input int tile, input int off, input logic [31:0] val,
                    input bit expect_error = 0, input logic [3:0] mask = 4'hf);
    int lane;
    bit aw_done, w_done;
    lane = (off % 8) / 4;
    if ($test$plusargs("VERBOSE")) $display("WR start t=%0d off=%h @%t",tile,off,$time);
    aw_done = 0; w_done = 0;
    @(negedge clk);
    ctrl_req[tile].aw = '0;
    ctrl_req[tile].aw.addr = addr_t'(32'h01000000 + off);
    ctrl_req[tile].aw.size = 2;
    ctrl_req[tile].aw.burst = axi_pkg::BURST_INCR;
    ctrl_req[tile].aw.id = id_t'(tile);
    ctrl_req[tile].aw_valid = 1;
    ctrl_req[tile].w = '0;
    ctrl_req[tile].w.data[lane*32+:32] = val;
    ctrl_req[tile].w.strb[lane*4+:4] = mask;
    ctrl_req[tile].w.last = 1;
    ctrl_req[tile].w_valid = 1;
    ctrl_req[tile].b_ready = 1;
    while (!aw_done || !w_done) begin
      @(posedge clk);
      aw_done |= ctrl_rsp[tile].aw_ready && ctrl_req[tile].aw_valid;
      w_done |= ctrl_rsp[tile].w_ready && ctrl_req[tile].w_valid;
      @(negedge clk);
      if (aw_done) ctrl_req[tile].aw_valid = 0;
      if (w_done) ctrl_req[tile].w_valid = 0;
    end
    do @(posedge clk); while (!ctrl_rsp[tile].b_valid);
    assert (ctrl_rsp[tile].b.id == id_t'(tile)) else $fatal(1, "MMIO B ID");
    assert ((ctrl_rsp[tile].b.resp == axi_pkg::RESP_SLVERR) == expect_error)
      else $fatal(1, "MMIO write error tile=%0d off=%h resp=%h",tile,off,ctrl_rsp[tile].b.resp);
    @(negedge clk);
    ctrl_req[tile].b_ready = 0;
    if ($test$plusargs("VERBOSE")) $display("WR done t=%0d off=%h @%t",tile,off,$time);
  endtask
  task automatic rd(input int tile, input int off, output logic [31:0] val);
    if ($test$plusargs("VERBOSE")) $display("RD start t=%0d off=%h @%t",tile,off,$time);
    @(negedge clk);
    ctrl_req[tile].ar = '0;
    ctrl_req[tile].ar.addr = addr_t'(32'h01000000 + off);
    ctrl_req[tile].ar.size = 2;
    ctrl_req[tile].ar.burst = axi_pkg::BURST_INCR;
    ctrl_req[tile].ar.id = id_t'(tile);
    ctrl_req[tile].ar_valid = 1;
    ctrl_req[tile].r_ready = 1;
    do @(posedge clk); while (!ctrl_rsp[tile].ar_ready);
    @(negedge clk); ctrl_req[tile].ar_valid = 0;
    do @(posedge clk); while (!ctrl_rsp[tile].r_valid);
    assert (ctrl_rsp[tile].r.id == id_t'(tile) && ctrl_rsp[tile].r.resp == 0)
      else $fatal(1,"MMIO R ID/response");
    val = ctrl_rsp[tile].r.data[((off%8)/4)*32+:32];
    @(negedge clk); ctrl_req[tile].r_ready = 0;
  endtask
  task automatic config_job(input int tile, input int unsigned src, input int unsigned dst,
                             input int len, input int reps=1,
                             input int ss=128, input int ds=256, input bit nd=1);
    wr(tile,'h0,nd ? 32'h400 : 0);
    wr(tile,'hd0,dst); wr(tile,'hd4,0);
    wr(tile,'hd8,src); wr(tile,'hdc,0);
    wr(tile,'he0,len); wr(tile,'he4,0);
    wr(tile,'he8,ds); wr(tile,'hec,0);
    wr(tile,'hf0,ss); wr(tile,'hf4,0);
    wr(tile,'hf8,reps); wr(tile,'hfc,0);
  endtask
  task automatic completion(input int tile, input int id, input int error_code=0);
    logic [31:0] valid_word, id_word, status_word;
    do rd(tile,'h108,valid_word); while (!valid_word[0]);
    rd(tile,'h10c,id_word); rd(tile,'h110,status_word);
    assert(id_word == id && status_word[7:0] == error_code)
      else $fatal(1,"completion tile=%0d expected=%0d got=%0d status=%h",tile,id,id_word,status_word);
    assert(status_word[31:16] < NumDmas) else $fatal(1,"engine index");
    wr(tile,'h114,1);
    completions++;
  endtask
  task automatic check_copy(input int unsigned src, input int unsigned dst, input int len,
                             input int reps=1, input int ss=128, input int ds=256);
    for(int row=0; row<reps; row++)
      for(int b=0; b<len; b++)
        assert(memory.mem[addr_t'(src+row*ss+b)] == memory.mem[addr_t'(dst+row*ds+b)])
          else $fatal(1,"data mismatch dst=%h row=%0d byte=%0d expected=%h actual=%h",dst,row,b,
            memory.mem[addr_t'(src+row*ss+b)],memory.mem[addr_t'(dst+row*ds+b)]);
  endtask
  task automatic poison_copy(input int unsigned src, input int unsigned dst, input int len,
                              input int reps=1, input int ss=128, input int ds=256);
    for(int row=0;row<reps;row++) for(int b=0;b<len;b++)
      memory.mem[addr_t'(dst+row*ds+b)] = ~memory.mem[addr_t'(src+row*ss+b)];
  endtask
  task automatic cpu_read(input int tile, input int unsigned address, input logic [63:0] expected,
                           input bit exclusive=0);
    @(negedge clk);
    tile_req[tile].ar = '0;
    tile_req[tile].ar.addr = addr_t'(address);
    tile_req[tile].ar.id = id_t'(5);
    tile_req[tile].ar.size = 3;
    tile_req[tile].ar.burst = axi_pkg::BURST_INCR;
    tile_req[tile].ar.lock=exclusive;
    tile_req[tile].ar_valid = 1;
    tile_req[tile].r_ready = 1;
    do @(posedge clk); while (!tile_rsp[tile].ar_ready);
    @(negedge clk); tile_req[tile].ar_valid=0;
    do @(posedge clk); while (!tile_rsp[tile].r_valid);
    assert(tile_rsp[tile].r.data == expected && tile_rsp[tile].r.id == 5 &&
      tile_rsp[tile].r.resp == (exclusive ? axi_pkg::RESP_EXOKAY : axi_pkg::RESP_OKAY))
      else $fatal(1,"CPU DDR data/ID routing addr=%h expected=%h got=%h id=%0d resp=%h",
        tile_req[tile].ar.addr,expected,tile_rsp[tile].r.data,tile_rsp[tile].r.id,tile_rsp[tile].r.resp);
    @(negedge clk); tile_req[tile].r_ready=0;
  endtask
  task automatic cpu_write(input int tile, input int unsigned address, input logic [63:0] data,
      input bit exclusive=0, input bit exclusive_success=0, input bit amo=0);
    bit aw_done,w_done,b_done,r_done;
    aw_done=0; w_done=0; b_done=0; r_done=!amo;
    @(negedge clk);
    tile_req[tile].aw='0;
    tile_req[tile].aw.addr=addr_t'(address);
    tile_req[tile].aw.size=3;
    tile_req[tile].aw.id=id_t'(6);
    tile_req[tile].aw.burst=axi_pkg::BURST_INCR;
    tile_req[tile].aw.lock=exclusive;
    if(amo) tile_req[tile].aw.atop={axi_pkg::ATOP_ATOMICLOAD,1'b0,axi_pkg::ATOP_ADD};
    tile_req[tile].aw_valid=1;
    tile_req[tile].w='0;
    tile_req[tile].w.data=data; tile_req[tile].w.strb='1; tile_req[tile].w.last=1;
    tile_req[tile].w_valid=1; tile_req[tile].b_ready=1; tile_req[tile].r_ready=amo;
    while(!aw_done || !w_done || !b_done || !r_done) begin
      @(posedge clk);
      aw_done |= tile_req[tile].aw_valid && tile_rsp[tile].aw_ready;
      w_done |= tile_req[tile].w_valid && tile_rsp[tile].w_ready;
      if(tile_rsp[tile].b_valid && tile_req[tile].b_ready) begin
        b_done=1;
        assert(tile_rsp[tile].b.id==6 && tile_rsp[tile].b.resp==
          ((exclusive && exclusive_success) ? axi_pkg::RESP_EXOKAY : axi_pkg::RESP_OKAY))
          else $fatal(1,"CPU write/SC response tile=%0d resp=%h",tile,tile_rsp[tile].b.resp);
      end
      if(tile_rsp[tile].r_valid && tile_req[tile].r_ready) begin
        r_done=1; assert(tile_rsp[tile].r.id==6) else $fatal(1,"AMO return ID");
      end
      @(negedge clk);
      if(aw_done) tile_req[tile].aw_valid=0;
      if(w_done) tile_req[tile].w_valid=0;
      if(b_done) tile_req[tile].b_ready=0;
      if(r_done) tile_req[tile].r_ready=0;
    end
  endtask

  initial begin : test
    logic [31:0] v, old_id;
    int atomic_dma_id;
    atomic_dma_id=14;
    ctrl_req = '0; tile_req='0;
    for(int b=0;b<65536;b++) memory.mem[32'h80000000+b] = 8'((b*19)^ (b>>7));
    tick(5); rst_n=1; tick(5);
    // Concurrent private CSR programming, then held DDR to check real parallelism.
    block_memory=1;
    for(int t=0;t<NumTiles;t++) begin
      fork
        automatic int tile=t;
        begin
          config_job(tile,32'h80000003+tile*'h800,32'h80008005+tile*'h800,67,4);
          wr(tile,'h118,1); wr(tile,'h100,1);
        end
      join_none
    end
    wait fork;
    tick(20);
    assert($countones(dut.i_pool.engine_active) == ((NumTiles<NumDmas)?NumTiles:NumDmas))
      else $fatal(1,"engines did not execute concurrently");
    // A later shadow edit must not change the accepted snapshot.
    wr(0,'hd8,32'h80004000);
    block_memory=0;
    cpu_read(0,32'h80000000,64'h85725f4c39261300);
    for(int t=0;t<NumTiles;t++) begin
      completion(t,1);
      check_copy(32'h80000003+t*'h800,32'h80008005+t*'h800,67,4);
      for(int row=0;row<4;row++) begin
        int unsigned before_addr, after_addr;
        before_addr=32'h80008004+t*'h800+row*256;
        after_addr=32'h80008048+t*'h800+row*256;
        assert(memory.mem[addr_t'(before_addr)] == 8'(((before_addr-'h80000000)*19)^((before_addr-'h80000000)>>7)))
          else $fatal(1,"write before destination");
        assert(memory.mem[addr_t'(after_addr)] == 8'(((after_addr-'h80000000)*19)^((after_addr-'h80000000)>>7)))
          else $fatal(1,"write after destination");
      end
      rd(t,'h108,v); assert(v==0 && !irq[t]) else $fatal(1,"completion pop/IRQ");
    end
    // Partial writes and high 32-bit lane readback.
    wr(0,'hd4,32'h12345678); wr(0,'hd4,32'h00ab0000,0,4'b0100);
    rd(0,'hd4,v); assert(v==32'h12ab5678) else $fatal(1,"byte strobes");
    // Reject zero, truncation, out-of-range and overlapping jobs without allocating IDs.
    config_job(0,32'h80001000,32'h80009000,0); wr(0,'h100,1,1);
    wr(0,'he0,16); wr(0,'hf8,0); wr(0,'h100,1,1);
    wr(0,'hf8,1); wr(0,'he4,1); wr(0,'h100,1,1); wr(0,'he4,0);
    wr(0,'hdc,32'hffffffff); wr(0,'h100,1,1); wr(0,'hdc,0);
    wr(0,'hec,1); wr(0,'h100,1,1); wr(0,'hec,0);
    wr(0,'hfc,1); wr(0,'h100,1,1); wr(0,'hfc,0);
    wr(0,'hf8,32'hffffffff); wr(0,'hf0,32'hffffffff); wr(0,'h100,1,1);
    wr(0,'hf8,1); wr(0,'hf0,128);
    wr(0,'hd8,32'h8000fffe); wr(0,'h100,1,1);
    wr(0,'hd8,32'h80009000); wr(0,'h100,1,1);
    rd(0,'h11c,v); assert(v==1) else $fatal(1,"invalid submit allocated ID");
    // Native 1D mode (CONF.enable_nd=0) uses one repetition even with reps=0.
    config_job(0,32'h80001000,32'h80009000,19,0,128,256,0);
    poison_copy(32'h80001000,32'h80009000,19);
    wr(0,'h100,1); completion(0,2); check_copy(32'h80001000,32'h80009000,19);
    // Do not retire at final ND input handshake: wait for final AXI B.
    block_b=1;
    config_job(0,32'h80001000,32'h80009000,16,3);
    wr(0,'h100,1); tick(100);
    rd(0,'h108,v); assert(v==0) else $fatal(1,"retired before final B");
    block_b=0; completion(0,3); check_copy(32'h80001000,32'h80009000,16,3);
    // Fill completion reservations, verify rejection returns, then resume after POP.
    for(int j=4;j<=7;j++) begin
      wr(0,'h100,1); tick(100);
      wait(!dut.i_pool.tile_active[0] && !dut.i_pool.tile_valid[0]); tick(2);
    end
    wr(0,'h100,1,1);
    rd(0,'h11c,v); assert(v==7 && irq[0]) else $fatal(1,"credit/IRQ");
    for(int j=4;j<=7;j++) completion(0,j);
    wr(0,'h114,1); // empty POP is harmless
    // Errors on an intermediate row must survive until final ND completion.
    config_job(0,32'h80001000,32'h80009000,16,3);
    poison_copy(32'h80001000,32'h80009000,16,3);
    memory.rerr[32'h80001000]=axi_pkg::RESP_SLVERR;
    wr(0,'h100,1); completion(0,8,1); check_copy(32'h80001000,32'h80009000,16,3);
    memory.rerr.delete();
    memory.werr[32'h80009000]=axi_pkg::RESP_DECERR;
    poison_copy(32'h80001000,32'h80009000,16,3);
    wr(0,'h100,1); completion(0,9,2); check_copy(32'h80001000,32'h80009000,16,3);
    memory.werr.delete();
    // An active job plus two queued jobs fills the job FIFO before completion credit.
    block_memory=1;
    config_job(0,32'h80001000,32'h80009000,16);
    wr(0,'h100,1); tick(10); wr(0,'h100,1); wr(0,'h100,1);
    wr(0,'h100,1,1);
    rd(0,'h11c,v); assert(v==12) else $fatal(1,"job FIFO overflow allocated ID");
    block_memory=0;
    completion(0,10); completion(0,11); completion(0,12);
    // Legalizer splits large transfers at AXI burst and 4-KiB boundaries.
    config_job(0,32'h80001ff3,32'h8000aff5,6000);
    poison_copy(32'h80001ff3,32'h8000aff5,6000);
    wr(0,'h100,1);
    completion(0,13); check_copy(32'h80001ff3,32'h8000aff5,6000);
    // Many separately arbitrated rows keep the long engine active while a short
    // job from a second tile completes. A single long AXI burst can serialize DDR.
    if(NumTiles>1 && NumDmas>1) begin
      config_job(0,32'h80001000,32'h8000a000,16,64,16,16);
      poison_copy(32'h80001000,32'h8000a000,16,64,16,16);
      wr(0,'h100,1);
      config_job(1,32'h80004000,32'h80009000,16);
      wr(1,'h100,1); completion(1,2);
      rd(0,'h108,v); assert(v==0) else $fatal(1,"short job did not complete ahead of long job");
      completion(0,14); check_copy(32'h80001000,32'h8000a000,16,64,16,16);
      atomic_dma_id=15;
    end
    // Shared atomic monitor must see other CPU and DMA writers. LR and SC use
    // different transaction IDs but the same source/hart reservation key.
    cpu_write(0,32'h80007000,64'd10);
    cpu_read(0,32'h80007000,64'd10,1);
    cpu_write(0,32'h80007000,64'd11,1,1);
    cpu_read(0,32'h80007000,64'd11);
    if(NumTiles>1) begin
      cpu_read(0,32'h80007000,64'd11,1);
      cpu_write(1,32'h80007000,64'd12);
      cpu_write(0,32'h80007000,64'd99,1,0);
      cpu_read(0,32'h80007000,64'd12);
      // Same local user and address, distinct physical source: both LRs coexist.
      cpu_read(0,32'h80007000,64'd12,1);
      cpu_read(1,32'h80007000,64'd12,1);
      cpu_write(0,32'h80007000,64'd13,1,1);
      cpu_write(1,32'h80007000,64'd99,1,0);
      cpu_read(0,32'h80007000,64'd13);
    end
    cpu_read(0,32'h80007000,NumTiles>1 ? 64'd13 : 64'd11,1);
    cpu_write(0,32'h80006000,64'd17);
    config_job(0,32'h80006000,32'h80007000,8);
    wr(0,'h100,1); completion(0,atomic_dma_id);
    cpu_write(0,32'h80007000,64'd99,1,0);
    cpu_read(0,32'h80007000,64'd17);
    if(NumTiles>1) begin
      fork
        cpu_write(0,32'h80007000,64'd1,0,0,1);
        cpu_write(1,32'h80007000,64'd1,0,0,1);
      join
      cpu_read(0,32'h80007000,64'd19);
    end
    // Full 256-beat DMA burst must invalidate reservations beyond the first beat.
    cpu_write(0,32'h80005008,64'd23);
    cpu_read(0,32'h80005008,64'd23,1);
    config_job(0,32'h80006000,32'h80005000,2048);
    wr(0,'h100,1); completion(0,atomic_dma_id+1);
    check_copy(32'h80006000,32'h80005000,2048);
    cpu_write(0,32'h80005008,64'd99,1,0);
    // Reset with jobs active/queued and DDR held before accepting requests. The
    // upstream memory model cannot clear accepted traffic on reset, so keep it idle.
    block_memory=1;
    wr(0,'h100,1); tick(10); wr(0,'h100,1);
    assert(dut.i_pool.engine_active!='0 && dut.i_pool.tile_valid[0]);
    rst_n=0; tick(5); rst_n=1; tick(5); block_memory=0;
    rd(0,'h11c,v); assert(v==0 && irq=='0) else $fatal(1,"reset");
    config_job(0,32'h80006000,32'h80007000,8);
    wr(0,'h100,1); completion(0,1); cpu_read(0,32'h80007000,64'd17);
    $display("PASS shared DMA %0d tiles x %0d engines addr=%0d random=%0d; %0d completions",
      NumTiles,NumDmas,AddrWidth,RandomStalls,completions);
    $finish;
  end
  initial begin
    #2000000;
    $display("timeout ctrl_req=%h ctrl_rsp=%h active=%b tile_valid=%b",ctrl_req,ctrl_rsp,
      dut.i_pool.engine_active,dut.i_pool.tile_valid);
    $display("engine0 state=%0d burst v/r=%b/%b rsp v/r=%b/%b nd ready=%b req=%h rsp=%h DDR req=%h rsp=%h",
      dut.i_pool.gen_engines[0].i_engine.state_q,
      dut.i_pool.gen_engines[0].i_engine.burst_valid,
      dut.i_pool.gen_engines[0].i_engine.burst_ready,
      dut.i_pool.gen_engines[0].i_engine.burst_rsp_valid,
      dut.i_pool.gen_engines[0].i_engine.burst_rsp_ready,
      dut.i_pool.gen_engines[0].i_engine.nd_ready,
      dut.i_pool.gen_engines[0].i_engine.axi_req_o,
      dut.i_pool.gen_engines[0].i_engine.axi_rsp_i,ddr_req,ddr_rsp);
    $fatal(1,"shared DMA watchdog timeout");
  end
  always @(posedge clk) if ($test$plusargs("VERBOSE")) begin
    if(ddr_req.ar_valid && ddr_rsp.ar_ready) $display("DDR AR addr=%h len=%0d @%t",ddr_req.ar.addr,ddr_req.ar.len,$time);
    if(ddr_rsp.r_valid && ddr_req.r_ready) $display("DDR R id=%0d last=%b @%t",ddr_rsp.r.id,ddr_rsp.r.last,$time);
    if(ddr_req.aw_valid && ddr_rsp.aw_ready) $display("DDR AW addr=%h len=%0d @%t",ddr_req.aw.addr,ddr_req.aw.len,$time);
    if(ddr_rsp.b_valid && ddr_req.b_ready) $display("DDR B id=%0d @%t",ddr_rsp.b.id,$time);
    if(ddr_req.w_valid && ddr_rsp.w_ready && $time > 73000)
      $display("DDR W strb=%h data=%h last=%b @%t",ddr_req.w.strb,ddr_req.w.data,ddr_req.w.last,$time);
  end
  always @(posedge clk) if(rst_n) begin
    if(ddr_req.ar_valid && ddr_rsp.ar_ready)
      assert((int'(ddr_req.ar.addr[11:0]) + ((int'(ddr_req.ar.len)+1) << ddr_req.ar.size)) <= 4096)
        else $fatal(1,"AR crosses 4-KiB boundary");
    if(ddr_req.aw_valid && ddr_rsp.aw_ready)
      assert((int'(ddr_req.aw.addr[11:0]) + ((int'(ddr_req.aw.len)+1) << ddr_req.aw.size)) <= 4096)
        else $fatal(1,"AW crosses 4-KiB boundary");
  end
endmodule
