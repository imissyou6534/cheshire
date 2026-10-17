// SPDX-License-Identifier: SHL-0.51
`timescale 1ns/1ps
module vip_multitile #(
  parameter int unsigned NumTiles = 1,
  parameter cheshire_pkg::cheshire_cfg_t Cfg = cheshire_pkg::DefaultCfg,
  parameter time ClkPeriod = 20ns,
  parameter time UartBitPeriod = 8680ns,
  parameter type loader_req_t = logic,
  parameter type loader_rsp_t = logic,
  parameter type ddr_req_t = logic,
  parameter type ddr_rsp_t = logic
) (
  output wire clk_o,
  output logic rst_no = 0,
  output logic rtc_o = 0,
  output loader_req_t [NumTiles-1:0] loader_req_o,
  input loader_rsp_t [NumTiles-1:0] loader_rsp_i,
  input ddr_req_t ddr_req_i,
  output ddr_rsp_t ddr_rsp_o,
  input logic [NumTiles-1:0] uart_tx_i
);
  localparam int BeatBytes = Cfg.AxiDataWidth / 8;
  localparam int BeatSize = $clog2(BeatBytes);
  localparam logic [63:0] SpmBase = 64'h10000000;
  localparam logic [63:0] AliasBase = 64'h14000000;
  localparam logic [31:0] AllWays = (32'd1 << Cfg.LlcSetAssoc)-1;
  logic memory_clk = 0;
  string uart_received [NumTiles];
  bit [NumTiles-1:0] uart_busy = '0;
  int unsigned loader_writes [NumTiles], loader_reads [NumTiles];

  always #(ClkPeriod/2) memory_clk = ~memory_clk;
  assign #(3*ClkPeriod/20) clk_o = memory_clk;
  always #500ns rtc_o = ~rtc_o;
  initial begin
    loader_req_o = '0;
    foreach (loader_writes[t]) begin
      loader_writes[t] = 0;
      loader_reads[t] = 0;
      uart_received[t] = "";
    end
    repeat (8) @(negedge clk_o);
    rst_no = 1;
  end

  axi_sim_mem #(
    .AddrWidth(Cfg.AddrWidth), .DataWidth(Cfg.AxiDataWidth),
    .IdWidth($bits(ddr_req_i.aw.id)), .UserWidth(Cfg.AxiUserWidth),
    .axi_req_t(ddr_req_t), .axi_rsp_t(ddr_rsp_t),
    .UninitializedData("zeros"), .ApplDelay(ClkPeriod/20), .AcqDelay(ClkPeriod/10)
  ) memory (
    .clk_i(memory_clk), .rst_ni(rst_no), .axi_req_i(ddr_req_i), .axi_rsp_o(ddr_rsp_o),
    .mon_w_valid_o(), .mon_w_addr_o(), .mon_w_data_o(), .mon_w_id_o(), .mon_w_user_o(),
    .mon_w_beat_count_o(), .mon_w_last_o(), .mon_r_valid_o(), .mon_r_addr_o(),
    .mon_r_data_o(), .mon_r_id_o(), .mon_r_user_o(), .mon_r_beat_count_o(), .mon_r_last_o()
  );

  for (genvar t=0; t<NumTiles; t++) begin : gen_uart
    initial begin
      byte unsigned data;
      wait(rst_no && uart_tx_i[t] === 1'b1);
      forever begin
        @(negedge uart_tx_i[t]);
        uart_busy[t] = 1;
        #(UartBitPeriod/2);
        assert(uart_tx_i[t] === 0) else $fatal(1,"UART start tile=%0d",t);
        for (int b=0; b<8; b++) begin
          #(UartBitPeriod);
          assert(!$isunknown(uart_tx_i[t])) else $fatal(1,"UART unknown tile=%0d",t);
          data[b] = uart_tx_i[t];
        end
        #(UartBitPeriod);
        assert(uart_tx_i[t] === 1) else $fatal(1,"UART stop tile=%0d",t);
        uart_received[t] = {uart_received[t],data};
        if (data == 8'h0a) $write("FW UART tile=%0d: %s",t,uart_received[t]);
        uart_busy[t] = 0;
      end
    end
  end

  task automatic wait_for_reset;
    wait(rst_no);
    @(posedge clk_o);
  endtask

  // AW and W may be accepted on different cycles; hold each until its handshake.
  task automatic axi_write(input int tile, input logic [63:0] address,
      input logic [Cfg.AxiDataWidth-1:0] data,
      input logic [BeatBytes-1:0] strb, input int size);
    bit aw_pending, w_pending;
    assert(tile >= 0 && tile < NumTiles && size >= 0 && size <= BeatSize &&
           (address & ((64'h1 << size)-1)) == 0 && strb != 0)
      else $fatal(1,"invalid loader write");
    @(negedge clk_o);
    loader_req_o[tile] = '0;
    loader_req_o[tile].aw.addr = address;
    loader_req_o[tile].aw.size = 3'(size);
    loader_req_o[tile].aw.burst = axi_pkg::BURST_INCR;
    loader_req_o[tile].aw.user = Cfg.AxiUserDefault;
    loader_req_o[tile].aw_valid = 1;
    loader_req_o[tile].w.data = data;
    loader_req_o[tile].w.strb = strb;
    loader_req_o[tile].w.last = 1;
    loader_req_o[tile].w_valid = 1;
    aw_pending = 1;
    w_pending = 1;
    while (aw_pending || w_pending) begin
      @(posedge clk_o);
      if (aw_pending && loader_rsp_i[tile].aw_ready) aw_pending = 0;
      if (w_pending && loader_rsp_i[tile].w_ready) w_pending = 0;
      @(negedge clk_o);
      loader_req_o[tile].aw_valid = aw_pending;
      loader_req_o[tile].w_valid = w_pending;
    end
    loader_req_o[tile].b_ready = 1;
    do @(posedge clk_o); while (!loader_rsp_i[tile].b_valid);
    assert(loader_rsp_i[tile].b.id === '0 && loader_rsp_i[tile].b.resp === axi_pkg::RESP_OKAY)
      else $fatal(1,"loader write response tile=%0d addr=%h",tile,address);
    @(negedge clk_o);
    loader_req_o[tile] = '0;
    loader_writes[tile]++;
  endtask

  task automatic axi_read(input int tile, input logic [63:0] address,
      input int size, output logic [Cfg.AxiDataWidth-1:0] data);
    assert(tile >= 0 && tile < NumTiles && size >= 0 && size <= BeatSize &&
           (address & ((64'h1 << size)-1)) == 0)
      else $fatal(1,"invalid loader read");
    @(negedge clk_o);
    loader_req_o[tile] = '0;
    loader_req_o[tile].ar.addr = address;
    loader_req_o[tile].ar.size = 3'(size);
    loader_req_o[tile].ar.burst = axi_pkg::BURST_INCR;
    loader_req_o[tile].ar.user = Cfg.AxiUserDefault;
    loader_req_o[tile].ar_valid = 1;
    do @(posedge clk_o); while (!loader_rsp_i[tile].ar_ready);
    @(negedge clk_o);
    loader_req_o[tile].ar_valid = 0;
    loader_req_o[tile].r_ready = 1;
    do @(posedge clk_o); while (!loader_rsp_i[tile].r_valid);
    assert(loader_rsp_i[tile].r.id === '0 && loader_rsp_i[tile].r.last === 1 &&
           loader_rsp_i[tile].r.resp === axi_pkg::RESP_OKAY)
      else $fatal(1,"loader read response tile=%0d addr=%h",tile,address);
    data = loader_rsp_i[tile].r.data;
    @(negedge clk_o);
    loader_req_o[tile] = '0;
    loader_reads[tile]++;
  endtask

  task automatic write32(input int tile, input logic [63:0] address, input logic [31:0] value);
    axi_write(tile,address,Cfg.AxiDataWidth'(value) << (8*(address%BeatBytes)),
              BeatBytes'('hf) << (address%BeatBytes),2);
  endtask

  task automatic read32(input int tile, input logic [63:0] address, output logic [31:0] value);
    logic [Cfg.AxiDataWidth-1:0] data;
    axi_read(tile,address,2,data);
    value = 32'(data >> (8*(address%BeatBytes)));
    assert(!$isunknown(value)) else $fatal(1,"unknown loader read tile=%0d addr=%h",tile,address);
  endtask

  task automatic wait_for_spm(input int tile);
    logic [31:0] bist, flushed, ways;
    do begin
      read32(tile,64'h03001048,bist);
      read32(tile,64'h03001018,flushed);
    end while (!bist[0] || (flushed & AllWays) != AllWays);
    read32(tile,64'h03001000,ways);
    assert((ways & AllWays) == AllWays) else $fatal(1,"SPM initialization tile=%0d",tile);
  endtask

  task automatic read_binary(input string filename, output byte unsigned bytes[]);
    int fd, length, count;
    fd = $fopen(filename,"rb");
    if (!fd) $fatal(1,"cannot open binary %s",filename);
    count = $fseek(fd,0,2);
    length = $ftell(fd);
    assert(count == 0 && length > 0 && length <= 65536) else $fatal(1,"invalid binary size %s",filename);
    count = $fseek(fd,0,0);
    bytes = new[length];
    count = $fread(bytes,fd);
    $fclose(fd);
    assert(count == length) else $fatal(1,"short binary read %s",filename);
  endtask

  task automatic load_spm(input int tile, input byte unsigned bytes[],
      input longint unsigned address, input longint unsigned mem_size);
    logic [Cfg.AxiDataWidth-1:0] data, actual;
    logic [BeatBytes-1:0] strb;
    assert(address == SpmBase && bytes.size() > 0 && bytes.size() <= mem_size &&
           mem_size <= 65536) else $fatal(1,"invalid application layout");
    for (longint unsigned offset=0; offset<mem_size; offset+=BeatBytes) begin
      data = '0;
      strb = '0;
      for (int b=0; b<BeatBytes; b++) if (offset+b < mem_size) begin
        strb[b] = 1;
        if (offset+b < bytes.size()) data[8*b+:8] = bytes[offset+b];
      end
      axi_write(tile,AliasBase+address-SpmBase+offset,data,strb,BeatSize);
    end
    for (int alias_id=0; alias_id<2; alias_id++)
      for (longint unsigned offset=0; offset<mem_size; offset+=BeatBytes) begin
        axi_read(tile,address+offset+(alias_id ? AliasBase-SpmBase : 0),BeatSize,actual);
        for (int b=0; b<BeatBytes; b++) if (offset+b < mem_size)
          assert(actual[8*b+:8] === (offset+b < bytes.size() ? bytes[offset+b] : 8'h00))
            else $fatal(1,"SPM load readback tile=%0d offset=%h",tile,offset+b);
      end
    $display("TB loaded tile=%0d file=%0d memory=%0d",tile,bytes.size(),mem_size);
  endtask
endmodule
