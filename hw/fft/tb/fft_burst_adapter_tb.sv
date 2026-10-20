`timescale 1ns/1ps
package fft_burst_test_pkg;
  parameter int DW = `FFT_TEST_DW;
  typedef struct packed {logic valid; logic [63:0] cause,tval;} exception_t;
  typedef struct packed {logic [3:0] id; logic [47:0] addr; logic [7:0] len;
    logic [2:0] size; logic [1:0] burst; logic lock; logic [3:0] cache;
    logic [2:0] prot; logic [3:0] qos,region; logic [5:0] atop; logic user;} ax_t;
  typedef struct packed {logic [DW-1:0] data; logic [DW/8-1:0] strb; logic last,user;} w_t;
  typedef struct packed {logic [3:0] id; logic [DW-1:0] data; logic [1:0] resp;
    logic last,user;} r_t;
  typedef struct packed {logic [3:0] id; logic [1:0] resp; logic user;} b_t;
  typedef struct packed {ax_t aw; logic aw_valid; w_t w; logic w_valid,b_ready;
    ax_t ar; logic ar_valid,r_ready;} req_t;
  typedef struct packed {logic aw_ready,w_ready; b_t b; logic b_valid;
    logic ar_ready; r_t r; logic r_valid;} rsp_t;
  typedef struct packed {logic [31:0] insn; logic [63:0] rs1,rs2;
    logic [2:0] trans_id; logic req_valid,resp_ready;} acc_req_t;
  typedef struct packed {logic req_ready,resp_valid; logic [2:0] trans_id;
    logic [63:0] result; exception_t exception;} acc_rsp_t;
  typedef struct packed {acc_req_t acc_req;} cpu_req_t;
  typedef struct packed {acc_rsp_t acc_resp;} cpu_rsp_t;
endpackage

`ifndef FFT_REAL_CORE
// A deterministic CE-gated pair delay isolates transport/packing from FFT arithmetic.
module fftifftmain(input logic i_clk,i_reset,i_ce,i_inverse,
  input logic [31:0] i_left,i_right,i_sample,
  output logic [45:0] o_left,o_right,o_result,output logic o_sync);
  logic [31:0] samples [4096];
  integer count;
`ifdef FFT_TEST_EARLY
  localparam int OutputStart=64;
`else
  localparam int OutputStart=2048;
`endif
  function automatic logic [45:0] result(input logic [31:0] s,input logic inverse);
    logic signed [22:0] realpart,imagpart;
    realpart = 23'($signed(s[31:16]));
    imagpart = inverse ? realpart : -realpart;
    return {realpart,imagpart};
  endfunction
  always_comb begin
    o_sync = count == OutputStart;
    o_left = '0; o_right = '0; o_result = '0;
    if (count >= OutputStart && count < OutputStart+2048) begin
      o_left = result(samples[2*(count-OutputStart)],i_inverse);
      o_right = result(samples[2*(count-OutputStart)+1],i_inverse);
    end
  end
  always @(posedge i_clk) begin
    if (i_reset) count <= 0;
    else if (i_ce) begin
      if (count < 2048) begin
        samples[2*count] <= i_left;
        samples[2*count+1] <= i_right;
      end
      count <= count+1;
    end
  end
endmodule
`endif

module fft_burst_adapter_tb;
  import fft_burst_test_pkg::*;
  logic clk=0,rst_n=0;
  always #5 clk=~clk;
  req_t req;
  rsp_t rsp;
  cpu_req_t cpu;
  cpu_rsp_t response;
  byte unsigned memory [131072];
  integer cycles=0,ar_count,aw_count,w_count,b_count,r_count;
  integer src,dst,rd_addr,rd_size,rd_left,wr_addr,wr_size,wr_left,b_delay;
  integer error_mode,error_injected,large_read,large_write,inverse;
  logic [15:0] input_samples[4096];
  logic [63:0] expected_words[4096];
  string input_file,expected_file;
  integer tolerance;
  req_t previous_req;
  logic ar_stalled,aw_stalled,w_stalled;
  logic rd_active,wr_active,b_pending;
  logic [31:0] random_q=32'h47b6c912;
  fft_accelerator_ip #(.DataWidth(DW),.exception_t(exception_t),
    .cva6_to_acc_t(cpu_req_t),.acc_to_cva6_t(cpu_rsp_t),
    .axi_req_t(req_t),.axi_rsp_t(rsp_t)) dut
    (.clk_i(clk),.rst_ni(rst_n),.acc_req_i(cpu),.acc_resp_o(response),
     .axi_req_o(req),.axi_rsp_i(rsp));
  always @(negedge clk) begin
    random_q = {random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};
    rsp.aw_ready = !wr_active && !b_pending && random_q[0];
    rsp.w_ready = wr_active && random_q[2];
    rsp.ar_ready = !rd_active && random_q[4];
    if(error_mode==3 && aw_count==1 && !error_injected) rsp.aw_ready=0;
    if(error_mode==4 && aw_count>=2 && !error_injected) rsp.w_ready=0;
    if(error_mode==5 && aw_count>=2 && !error_injected) rsp.ar_ready=0;
    if (!rsp.r_valid && rd_active && random_q[6]) begin
      rsp.r='0;
      for(integer j=0;j<DW/8;j++) rsp.r.data[j*8+:8]=memory[(rd_addr/(DW/8))*(DW/8)+j];
      rsp.r.last=rd_left==1;
      if(!error_injected && ((error_mode==1 && r_count==7) ||
        (error_mode==3 && aw_count==1 && req.aw_valid && !rsp.aw_ready) ||
        (error_mode==4 && aw_count>=2 && wr_active && !rsp.w_ready))) begin
        rsp.r.resp=2; error_injected=1;
      end
      rsp.r_valid=1;
    end
    if(b_pending && b_delay>0) b_delay--;
    if(b_pending && b_delay==0) begin
      rsp.b_valid=1; rsp.b='0;
      if(!error_injected && (error_mode==2 || (error_mode==5 && req.ar_valid && !rsp.ar_ready))) begin
        rsp.b.resp=2; error_injected=1;
      end
    end
  end
  always @(posedge clk) begin
    cycles++;
    if(cycles>300000) $fatal(1,"watchdog ar=%0d aw=%0d w=%0d b=%0d",ar_count,aw_count,w_count,b_count);
    if(rst_n) begin
      if(ar_stalled && (!req.ar_valid || req.ar!==previous_req.ar)) $fatal(1,"AR changed while stalled");
      if(aw_stalled && (!req.aw_valid || req.aw!==previous_req.aw)) $fatal(1,"AW changed while stalled");
      if(w_stalled && (!req.w_valid || req.w!==previous_req.w)) $fatal(1,"W changed while stalled");
      ar_stalled=req.ar_valid && !rsp.ar_ready;
      aw_stalled=req.aw_valid && !rsp.aw_ready;
      w_stalled=req.w_valid && !rsp.w_ready;
      previous_req=req;
      if(req.ar_valid && rsp.ar_ready) begin
        if(req.ar.burst!=1 || req.ar.len>15 ||
          (int'(req.ar.addr[11:0])+((int'(req.ar.len)+1)<<req.ar.size))>4096)
          $fatal(1,"illegal AR burst");
        rd_active=1; rd_addr=int'(req.ar.addr); rd_size=1<<req.ar.size;
        rd_left=int'(req.ar.len)+1; ar_count++; if(req.ar.len>0) large_read++;
      end
      if(rsp.r_valid && req.r_ready) begin
        rsp.r_valid<=0; r_count++; rd_addr+=rd_size; rd_left--;
        if(rd_left==0) rd_active=0;
      end
      if(req.aw_valid && rsp.aw_ready) begin
        if(req.aw.burst!=1 || req.aw.len>15 ||
          (int'(req.aw.addr[11:0])+((int'(req.aw.len)+1)<<req.aw.size))>4096)
          $fatal(1,"illegal AW burst");
        wr_active=1; wr_addr=int'(req.aw.addr); wr_size=1<<req.aw.size;
        wr_left=int'(req.aw.len)+1; aw_count++; if(req.aw.len>0) large_write++;
      end
      if(req.w_valid && rsp.w_ready) begin
        if(req.w.last!=(wr_left==1)) $fatal(1,"WLAST mismatch");
        for(integer j=0;j<DW/8;j++) if(req.w.strb[j]) memory[(wr_addr/(DW/8))*(DW/8)+j]=req.w.data[j*8+:8];
        wr_addr+=wr_size; wr_left--; w_count++;
        if(wr_left==0) begin wr_active=0; b_pending=1; b_delay=37; end
      end
      if(rsp.b_valid && req.b_ready) begin rsp.b_valid<=0; b_pending=0; b_count++; end
    end
  end
  task automatic command(input logic [31:0] insn,input logic [2:0] id);
    @(negedge clk); cpu.acc_req.insn=insn; cpu.acc_req.rs1=64'(src);
    cpu.acc_req.rs2=64'(dst); cpu.acc_req.trans_id=id; cpu.acc_req.req_valid=1;
    do @(posedge clk); while(!response.acc_resp.req_ready);
    @(negedge clk); cpu.acc_req.req_valid=0;
    while(!response.acc_resp.resp_valid) @(negedge clk);
    if(id==2) begin
      if(response.acc_resp.exception.valid != (error_mode!=0)) $fatal(1,"WAIT error mismatch");
      if(rd_active || wr_active || b_pending || rsp.r_valid || rsp.b_valid || aw_count!=b_count)
        $fatal(1,"WAIT before protocol drain");
    end
    @(negedge clk);
  endtask
  initial begin
    integer so,doff,original_error;
    logic signed [31:0] expected;
    logic [63:0] actual,wanted;
    logic signed [31:0] real_delta,imag_delta;
    cpu='0; rsp='0; rd_active=0; wr_active=0; b_pending=0;
    ar_stalled=0;aw_stalled=0;w_stalled=0;previous_req='0;
    if(!$value$plusargs("SRC_OFFSET=%d",so)) so=0;
    if(!$value$plusargs("DST_OFFSET=%d",doff)) doff=0;
    if(!$value$plusargs("ERROR=%d",error_mode)) error_mode=0;
    original_error=error_mode;
    if(!$value$plusargs("INVERSE=%d",inverse)) inverse=0;
    if(!$value$plusargs("TOLERANCE=%d",tolerance)) tolerance=0;
    src=4080+so; dst=32752+doff;
    ar_count=0;aw_count=0;w_count=0;b_count=0;r_count=0;
    error_injected=0;large_read=0;large_write=0;
    for(integer i=0;i<131072;i++) memory[i]=8'ha5;
    if($value$plusargs("INPUT_HEX=%s",input_file)) $readmemh(input_file,input_samples);
    if($value$plusargs("EXPECTED_HEX=%s",expected_file)) $readmemh(expected_file,expected_words);
    for(integer i=0;i<4096;i++) begin
      if(input_file=="") input_samples[i]=16'(i*17-30000);
      memory[src+i*2]=input_samples[i][7:0]; memory[src+i*2+1]=input_samples[i][15:8];
    end
    repeat(5) @(negedge clk); rst_n=1; cpu.acc_req.resp_ready=1;
    command(inverse ? 32'h9800500b:32'h1800500b,1); command(32'h0000002b,2);
    if(error_mode!=0 && $test$plusargs("RECOVER")) begin
      if(!error_injected) $fatal(1,"recovery without injected error");
      error_mode=0;inverse=1-inverse;
      for(integer i=0;i<32768;i++) memory[dst+i]=8'ha5;
      command(inverse ? 32'h9800500b:32'h1800500b,1); command(32'h0000002b,2);
      $display("PASS recovery after error %0d",original_error);
    end
    if(error_mode==0) begin
      if(large_read==0 || large_write==0) $fatal(1,"missing INCR bursts");
      for(integer i=0;i<4096;i++) begin
        expected=32'($signed(input_samples[i])); wanted={-expected,expected};
        if(inverse) wanted={expected,expected};
        if(expected_file!="") wanted=expected_words[i];
        actual='0; for(integer j=0;j<8;j++) actual[j*8+:8]=memory[dst+i*8+j];
        real_delta=$signed(actual[31:0])-$signed(wanted[31:0]);
        imag_delta=$signed(actual[63:32])-$signed(wanted[63:32]);
        if(real_delta>tolerance || real_delta< -tolerance || imag_delta>tolerance || imag_delta< -tolerance)
          $fatal(1,"word %0d got %h wanted %h",i,actual,wanted);
      end
      for(integer j=1;j<=16;j++) if(memory[dst-j]!=8'ha5 || memory[dst+32768+j-1]!=8'ha5)
        $fatal(1,"guard overwritten");
    end else if(!error_injected) $fatal(1,"error not injected");
    $display("PASS fft burst DW=%0d src=%0d dst=%0d inverse=%0d error=%0d cycles=%0d AR=%0d R=%0d AW=%0d W=%0d B=%0d",
      DW,so,doff,inverse,original_error,cycles,ar_count,r_count,aw_count,w_count,b_count);
    $finish;
  end
endmodule
