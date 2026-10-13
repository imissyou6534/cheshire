// SPDX-License-Identifier: SHL-0.51
package cheshire_dma_pkg;
  localparam int unsigned Conf         = 'h000;
  localparam int unsigned Status       = 'h004;
  localparam int unsigned DstLo        = 'h0d0;
  localparam int unsigned Submit       = 'h100;
  localparam int unsigned QueueStatus  = 'h104;
  localparam int unsigned CompValid    = 'h108;
  localparam int unsigned CompJobId    = 'h10c;
  localparam int unsigned CompStatus   = 'h110;
  localparam int unsigned CompPop      = 'h114;
  localparam int unsigned IrqEnable    = 'h118;
  localparam int unsigned LastJobId    = 'h11c;
  localparam int unsigned SubmitStatus = 'h120;
  localparam logic [7:0] Success = 0, ReadError = 1, WriteError = 2;
  localparam logic [7:0] InvalidJob = 3, NoCapacity = 4;
  typedef struct packed {
    logic [31:0] job_id;
    logic [15:0] engine_id;
    logic [7:0]  error_code;
  } completion_t;
endpackage
