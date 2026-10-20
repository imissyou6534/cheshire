`timescale 1ns/1ps
`include "axi/typedef.svh"
module tb_shared_dma_widths #(
  parameter int TileWidth = 128,
  parameter int DmaWidth = 128,
  parameter int SharedWidth = 256,
  parameter bit LegacyDefaults = 0
);
  localparam int Tiles = 2, Dmas = 2, IW = 3, OIW = IW+$clog2(Tiles+Dmas);
  typedef logic [31:0] addr_t;
  typedef logic [TileWidth-1:0] tile_data_t;
  typedef logic [TileWidth/8-1:0] tile_strb_t;
  typedef logic [SharedWidth-1:0] shared_data_t;
  typedef logic [SharedWidth/8-1:0] shared_strb_t;
  typedef logic [IW-1:0] id_t;
  typedef logic [OIW-1:0] out_id_t;
  typedef logic [1:0] user_t;
  `AXI_TYPEDEF_ALL(tile, addr_t, id_t, tile_data_t, tile_strb_t, user_t)
  `AXI_TYPEDEF_ALL(ddr, addr_t, out_id_t, shared_data_t, shared_strb_t, user_t)
  logic model_clk = 0, clk, rst_n = 0;
  always #5 model_clk = ~model_clk;
  assign #3ns clk = model_clk;
  tile_req_t [Tiles-1:0] ctrl_req, tile_req;
  tile_resp_t [Tiles-1:0] ctrl_rsp, tile_rsp;
  ddr_req_t ddr_req;
  ddr_resp_t ddr_rsp;
  ddr_req_t delayed_req;
  ddr_resp_t delayed_rsp;
  ddr_req_t [0:0] mem_req;
  ddr_resp_t [0:0] mem_rsp;
  logic [Tiles-1:0] irq;
  logic block_b = 0;
  int dma_reads = 0, tile_reads = 0;
  cheshire_shared_dma_subsystem #(
    .NumTiles(Tiles), .NumDmas(Dmas), .AxiDataWidth(TileWidth),
    .DmaAxiDataWidth(LegacyDefaults ? 0 : DmaWidth),
    .SharedAxiDataWidth(LegacyDefaults ? 0 : SharedWidth),
    .AxiIdWidth(IW), .AxiSlvIdWidth(IW), .AxiUserWidth(2),
    .NumAxInFlight(8), .MemStart(64'h80000000), .MemEnd(64'h80010000),
    .tile_ctrl_req_t(tile_req_t), .tile_ctrl_rsp_t(tile_resp_t),
    .axi_req_t(tile_req_t), .axi_rsp_t(tile_resp_t),
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
    .StallRandomInput(1), .StallRandomOutput(1),
    .FixedDelayInput(0), .FixedDelayOutput(0)
  ) i_delayer (
    .clk_i(clk), .rst_ni(rst_n), .slv_req_i(ddr_req), .slv_resp_o(ddr_rsp),
    .mst_req_o(delayed_req), .mst_resp_i(delayed_rsp)
  );
  always_comb begin
    mem_req[0] = delayed_req;
    delayed_rsp = mem_rsp[0];
    if (block_b) begin
      mem_req[0].b_ready = 0;
      delayed_rsp.b_valid = 0;
    end
  end
  axi_sim_mem #(
    .AddrWidth(32), .DataWidth(SharedWidth), .IdWidth(OIW), .UserWidth(2),
    .axi_req_t(ddr_req_t), .axi_rsp_t(ddr_resp_t),
    .UninitializedData("zeros"), .ApplDelay(1ns), .AcqDelay(2ns)
  ) memory (
    .clk_i(model_clk), .rst_ni(rst_n), .axi_req_i(mem_req), .axi_rsp_o(mem_rsp),
    .mon_w_valid_o(), .mon_w_addr_o(), .mon_w_data_o(), .mon_w_id_o(), .mon_w_user_o(),
    .mon_w_beat_count_o(), .mon_w_last_o(), .mon_r_valid_o(), .mon_r_addr_o(),
    .mon_r_data_o(), .mon_r_id_o(), .mon_r_user_o(), .mon_r_beat_count_o(), .mon_r_last_o()
  );
  task automatic tick(input int n=1);
    repeat(n) @(negedge clk);
  endtask
  task automatic atomic_read(input int address, input int size, input logic [63:0] expected,
                              input bit exclusive=0);
    @(negedge clk);
    tile_req[0]='0;
    tile_req[0].ar.addr=32'(address); tile_req[0].ar.size=3'(size);
    tile_req[0].ar.burst=axi_pkg::BURST_INCR; tile_req[0].ar.id=5;
    tile_req[0].ar.user=2; tile_req[0].ar.lock=exclusive;
    tile_req[0].ar_valid=1; tile_req[0].r_ready=1;
    do @(posedge clk); while(!tile_rsp[0].ar_ready);
    @(negedge clk); tile_req[0].ar_valid=0;
    do @(posedge clk); while(!tile_rsp[0].r_valid);
    assert(tile_rsp[0].r.id==5 && tile_rsp[0].r.resp==
      (exclusive ? axi_pkg::RESP_EXOKAY : axi_pkg::RESP_OKAY)) else $fatal(1,"LR/read response");
    for(int b=0;b<(1<<size);b++)
      assert(tile_rsp[0].r.data[((address%(TileWidth/8))+b)*8+:8]==expected[b*8+:8])
        else $fatal(1,"atomic read address=%h byte=%0d",address,b);
    @(negedge clk); tile_req[0]='0;
  endtask
  task automatic atomic_write(input int address, input int size, input logic [63:0] value,
                               input bit exclusive=0, input bit success=0,
                               input bit amo=0, input logic [63:0] old_value=0);
    bit aw_done, w_done, b_done, r_done;
    aw_done=0; w_done=0; b_done=0; r_done=!amo;
    @(negedge clk);
    tile_req[0]='0;
    tile_req[0].aw.addr=32'(address); tile_req[0].aw.size=3'(size);
    tile_req[0].aw.burst=axi_pkg::BURST_INCR; tile_req[0].aw.id=6;
    tile_req[0].aw.user=2; tile_req[0].aw.lock=exclusive;
    if(amo) tile_req[0].aw.atop={axi_pkg::ATOP_ATOMICLOAD,1'b0,axi_pkg::ATOP_ADD};
    tile_req[0].aw_valid=1;
    for(int b=0;b<(1<<size);b++) begin
      tile_req[0].w.data[((address%(TileWidth/8))+b)*8+:8]=value[b*8+:8];
      tile_req[0].w.strb[(address%(TileWidth/8))+b]=1;
    end
    tile_req[0].w.last=1; tile_req[0].w_valid=1;
    tile_req[0].b_ready=1; tile_req[0].r_ready=amo;
    while(!aw_done || !w_done || !b_done || !r_done) begin
      @(posedge clk);
      aw_done |= tile_req[0].aw_valid && tile_rsp[0].aw_ready;
      w_done |= tile_req[0].w_valid && tile_rsp[0].w_ready;
      if(tile_req[0].b_ready && tile_rsp[0].b_valid) begin
        b_done=1;
        assert(tile_rsp[0].b.id==6 && tile_rsp[0].b.resp==
          ((exclusive && success) ? axi_pkg::RESP_EXOKAY : axi_pkg::RESP_OKAY))
          else $fatal(1,"SC/write response address=%h",address);
      end
      if(tile_req[0].r_ready && tile_rsp[0].r_valid) begin
        r_done=1;
        // The prepared AMO adapter retains EXOKAY from its internal LR response.
        assert(tile_rsp[0].r.id==6 && !tile_rsp[0].r.resp[1])
          else $fatal(1,"AMO response address=%h size=%0d id=%0d resp=%h",address,size,
            tile_rsp[0].r.id,tile_rsp[0].r.resp);
        for(int b=0;b<(1<<size);b++)
          assert(tile_rsp[0].r.data[((address%(TileWidth/8))+b)*8+:8]==old_value[b*8+:8])
            else $fatal(1,"AMO old value address=%h byte=%0d",address,b);
      end
      @(negedge clk);
      if(aw_done) tile_req[0].aw_valid=0;
      if(w_done) tile_req[0].w_valid=0;
      if(b_done) tile_req[0].b_ready=0;
      if(r_done) tile_req[0].r_ready=0;
    end
    tile_req[0]='0;
  endtask
  task automatic csr_write(input int off, input logic [31:0] val, input logic [3:0] mask=15);
    bit aw_done, w_done;
    int lane;
    aw_done=0; w_done=0; lane=(off%(TileWidth/8))/4;
    @(negedge clk);
    ctrl_req[0]='0;
    ctrl_req[0].aw.addr=32'h01000000+off;
    ctrl_req[0].aw.size=2; ctrl_req[0].aw.burst=axi_pkg::BURST_INCR;
    ctrl_req[0].aw.id=3; ctrl_req[0].aw_valid=1;
    ctrl_req[0].w.data[lane*32+:32]=val;
    ctrl_req[0].w.strb[lane*4+:4]=mask;
    ctrl_req[0].w.last=1; ctrl_req[0].w_valid=1; ctrl_req[0].b_ready=1;
    while (!aw_done || !w_done) begin
      @(posedge clk);
      aw_done |= ctrl_req[0].aw_valid && ctrl_rsp[0].aw_ready;
      w_done |= ctrl_req[0].w_valid && ctrl_rsp[0].w_ready;
      @(negedge clk);
      if(aw_done) ctrl_req[0].aw_valid=0;
      if(w_done) ctrl_req[0].w_valid=0;
    end
    do @(posedge clk); while(!ctrl_rsp[0].b_valid);
    assert(ctrl_rsp[0].b.id==3 && ctrl_rsp[0].b.resp==0) else $fatal(1,"CSR B");
    @(negedge clk); ctrl_req[0]='0;
  endtask
  task automatic csr_read(input int off, output logic [31:0] val);
    @(negedge clk);
    ctrl_req[0]='0;
    ctrl_req[0].ar.addr=32'h01000000+off;
    ctrl_req[0].ar.size=2; ctrl_req[0].ar.burst=axi_pkg::BURST_INCR;
    ctrl_req[0].ar.id=4; ctrl_req[0].ar_valid=1; ctrl_req[0].r_ready=1;
    do @(posedge clk); while(!ctrl_rsp[0].ar_ready);
    @(negedge clk); ctrl_req[0].ar_valid=0;
    do @(posedge clk); while(!ctrl_rsp[0].r_valid);
    assert(ctrl_rsp[0].r.id==4 && ctrl_rsp[0].r.resp==0) else $fatal(1,"CSR R");
    val=ctrl_rsp[0].r.data[(off%(TileWidth/8))*8+:32];
    @(negedge clk); ctrl_req[0]='0;
  endtask
  // A byte-masked narrow INCR burst visits every byte lane, including upper lanes.
  task automatic tile_burst(input int source, input int size);
    int bytes_per_beat, beats, lane;
    logic [31:0] address;
    bytes_per_beat=1<<size; beats=4*(TileWidth/8)/bytes_per_beat;
    address=32'h80006000+source*256;
    @(negedge clk);
    tile_req[source]='0;
    tile_req[source].aw.addr=address; tile_req[source].aw.size=3'(size);
    tile_req[source].aw.len=8'(beats-1); tile_req[source].aw.burst=axi_pkg::BURST_INCR;
    tile_req[source].aw.cache=axi_pkg::CACHE_MODIFIABLE;
    tile_req[source].aw.id=5; tile_req[source].aw.user=2; tile_req[source].aw_valid=1;
    do @(posedge clk); while(!tile_rsp[source].aw_ready);
    @(negedge clk); tile_req[source].aw_valid=0;
    for(int beat=0;beat<beats;beat++) begin
      lane=(beat*bytes_per_beat)%(TileWidth/8);
      tile_req[source].w='0;
      for(int b=0;b<bytes_per_beat;b++) begin
        tile_req[source].w.data[(lane+b)*8+:8]=8'(beat*bytes_per_beat+b+17);
        tile_req[source].w.strb[lane+b]=((beat*bytes_per_beat+b)%3)!=0;
      end
      tile_req[source].w.last=(beat==beats-1); tile_req[source].w_valid=1;
      do @(posedge clk); while(!tile_rsp[source].w_ready);
      @(negedge clk);
    end
    tile_req[source].w_valid=0; tile_req[source].b_ready=1;
    do @(posedge clk); while(!tile_rsp[source].b_valid);
    assert(tile_rsp[source].b.id==5 && tile_rsp[source].b.resp==0) else $fatal(1,"Tile B ID");
    @(negedge clk); tile_req[source]='0;
    for(int b=0;b<beats*bytes_per_beat;b++)
      assert(memory.mem[address+b]==((b%3)!=0 ? 8'(b+17) : 8'ha5))
        else $fatal(1,"Tile byte mask address=%h byte=%0d",address,b);
    tile_req[source].ar.addr=address; tile_req[source].ar.size=3'(size);
    tile_req[source].ar.len=8'(beats-1); tile_req[source].ar.burst=axi_pkg::BURST_INCR;
    tile_req[source].ar.cache=axi_pkg::CACHE_MODIFIABLE;
    tile_req[source].ar.id=6; tile_req[source].ar.user=2; tile_req[source].ar_valid=1;
    do @(posedge clk); while(!tile_rsp[source].ar_ready);
    @(negedge clk); tile_req[source].ar_valid=0; tile_req[source].r_ready=1;
    for(int beat=0;beat<beats;beat++) begin
      do @(posedge clk); while(!tile_rsp[source].r_valid);
      lane=(beat*bytes_per_beat)%(TileWidth/8);
      assert(tile_rsp[source].r.id==6 && tile_rsp[source].r.resp==0 &&
        tile_rsp[source].r.last==(beat==beats-1)) else $fatal(1,"Tile R ID/last");
      for(int b=0;b<bytes_per_beat;b++)
        assert(tile_rsp[source].r.data[(lane+b)*8+:8]==memory.mem[address+beat*bytes_per_beat+b])
          else $fatal(1,"Tile read byte lane");
      @(negedge clk);
    end
    tile_req[source]='0;
  endtask
  task automatic dma_copy(input int job, input int len, input int src_off, input int dst_off,
                          input int reps=1, input int expected_error=0);
    logic [31:0] value;
    int unsigned src, dst;
    src=32'h80000f80+src_off; dst=32'h80002f80+dst_off;
    for(int b=-1;b<reps*256+len+1;b++) memory.mem[dst+b]=8'hc7;
    csr_write('h0,reps>1 ? 'h400 : 0);
    csr_write('hd0,dst); csr_write('hd4,0); csr_write('hd8,src); csr_write('hdc,0);
    csr_write('he0,len); csr_write('he4,0); csr_write('he8,256); csr_write('hec,0);
    csr_write('hf0,128); csr_write('hf4,0); csr_write('hf8,reps); csr_write('hfc,0);
    csr_write('h100,1);
    if(job==1) begin
      tick(150); csr_read('h108,value);
      assert(value==0) else $fatal(1,"DMA completed before final B");
      block_b=0;
    end
    do csr_read('h108,value); while(!value[0]);
    csr_read('h10c,value); assert(value==job) else $fatal(1,"DMA completion ID");
    csr_read('h110,value);
    assert(value[7:0]==8'(expected_error)) else $fatal(1,"DMA completion error");
    for(int row=0;row<reps;row++) begin
      for(int b=0;b<len;b++)
        assert(memory.mem[src+row*128+b]==memory.mem[dst+row*256+b])
          else $fatal(1,"DMA copy len=%0d row=%0d byte=%0d",len,row,b);
      assert(memory.mem[dst+row*256-1]==8'hc7 && memory.mem[dst+row*256+len]==8'hc7)
        else $fatal(1,"DMA guard byte");
    end
    csr_write('h114,1);
    csr_read('h108,value); assert(value==0) else $fatal(1,"duplicate completion");
  endtask
  initial begin
    logic [31:0] value;
    int lengths[7]='{1,7,8,15,16,17,33};
    ctrl_req='0; tile_req='0;
    for(int b=0;b<65536;b++) memory.mem[32'h80000000+b]=8'(b*19+(b>>7));
    for(int b=0;b<1024;b++) memory.mem[32'h80006000+b]=8'ha5;
    tick(5); rst_n=1; tick(5);
    // All four CSR lanes on Tile128, with partial bytes in the highest lane.
    for(int i=0;i<4;i++) begin
      csr_write('hd0+4*i,32'h12345678+i);
      csr_read('hd0+4*i,value); assert(value==32'h12345678+i) else $fatal(1,"CSR lane");
    end
    csr_write('hdc,32'h00ab0000,4'b0100); csr_read('hdc,value);
    assert(value==32'h12ab567b) else $fatal(1,"CSR byte mask");
    for(int s=0;s<2;s++) begin
      tile_burst(s,0);
      for(int b=0;b<256;b++) memory.mem[32'h80006000+s*256+b]=8'ha5;
      tile_burst(s,$clog2(TileWidth/8));
    end
    block_b=1;
    for(int j=0;j<7;j++) dma_copy(j+1,lengths[j],j%16,(j*3+1)%16);
    dma_copy(8,200,117,119);
    dma_copy(9,33,5,7,3);
    dma_copy(10,6000,117,119);
    for(int size=2;size<=3;size++) for(int off=0;off<SharedWidth/8;off+=(1<<size)) begin
      int address;
      address=32'h80007000+off;
      atomic_write(address,size,10);
      atomic_read(address,size,10,1);
      atomic_write(address,size,11,1,1);
      atomic_read(address,size,11);
      atomic_write(address,size,2,0,0,1,11);
      atomic_read(address,size,13);
      atomic_read(address,size,13,1);
      atomic_write(address,size,14);
      atomic_write(address,size,99,1,0);
      atomic_read(address,size,14);
    end
    atomic_write(32'h80002f88,3,23);
    atomic_read(32'h80002f88,3,23,1);
    dma_copy(11,33,5,7);
    atomic_write(32'h80002f88,3,99,1,0);
    for(int b=0;b<8;b++)
      assert(memory.mem[32'h80002f88+b]==memory.mem[32'h80000f86+b])
        else $fatal(1,"DMA write did not invalidate reservation");
    memory.rerr[32'h80000f85]=axi_pkg::RESP_SLVERR;
    dma_copy(12,33,5,7,1,1);
    memory.rerr.delete();
    memory.werr[32'h80002f87]=axi_pkg::RESP_DECERR;
    dma_copy(13,33,5,7,1,2);
    memory.werr.delete();
    assert(dma_reads>0 && tile_reads>0) else $fatal(1,"source prefix coverage");
    $display("PASS shared widths Tile=%0d DMA=%0d Shared=%0d real DMA/narrow/burst/masks/atomics/errors",TileWidth,DmaWidth,SharedWidth);
    $finish;
  end
  always @(posedge clk) if(rst_n && ddr_req.ar_valid && ddr_rsp.ar_ready) begin
    if((int'(ddr_req.ar.id)>>IW)<Tiles) begin
      tile_reads++;
      assert(ddr_req.ar.user==2) else $fatal(1,"Tile USER lost");
    end else dma_reads++;
    assert((int'(ddr_req.ar.addr[11:0]) & ~((1<<ddr_req.ar.size)-1))+
      ((int'(ddr_req.ar.len)+1)<<ddr_req.ar.size)<=4096)
      else $fatal(1,"DDR read crosses 4KiB addr=%h len=%0d size=%0d",
        ddr_req.ar.addr,ddr_req.ar.len,ddr_req.ar.size);
  end
  initial begin #2000000; $fatal(1,"shared widths timeout"); end
endmodule
