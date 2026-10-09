package fft_accel_pkg;

  localparam logic [6:0] OpcodeCustom0 = 7'h0b;
  localparam logic [6:0] OpcodeCustom1 = 7'h2b;
  localparam logic [31:0] FftWaitInsn  = 32'h0000_002b;
  localparam logic [2:0] FftFunct3     = 3'b101;
  localparam logic [5:0] FftLog2N      = 6'd12;

  typedef enum logic {
    FftCmdStart,
    FftCmdWait
  } fft_cmd_op_e;

  function automatic logic is_fft_namespace(input logic [31:0] insn);
    return (insn[6:0] == OpcodeCustom0 && insn[14:12] == FftFunct3) ||
           insn == FftWaitInsn;
  endfunction

  function automatic logic is_fft_start(input logic [31:0] insn);
    return insn[6:0] == OpcodeCustom0 && insn[14:12] == FftFunct3;
  endfunction

  function automatic logic is_fft_wait(input logic [31:0] insn);
    return insn == FftWaitInsn;
  endfunction

  function automatic logic is_fft_start_legal(input logic [31:0] insn);
    return is_fft_start(insn) &&
           insn[30:25] == FftLog2N &&
           insn[11:7] == 5'd0;
  endfunction

  function automatic logic is_fft_legal(input logic [31:0] insn);
    return is_fft_start_legal(insn) || is_fft_wait(insn);
  endfunction

  function automatic logic is_ifft(input logic [31:0] insn);
    return insn[31];
  endfunction

endpackage
