// SPDX-License-Identifier: SHL-0.51
module dma_job_scheduler #(
  parameter int unsigned NumTiles = 4,
  parameter int unsigned NumDmas = 2,
  parameter type job_t = logic,
  parameter int unsigned TileWidth = (NumTiles > 1) ? $clog2(NumTiles) : 1
) (
  input logic clk_i, rst_ni,
  input job_t [NumTiles-1:0] tile_job_i,
  input logic [NumTiles-1:0] tile_valid_i,
  output logic [NumTiles-1:0] tile_ready_o,
  output job_t [NumDmas-1:0] engine_job_o,
  output logic [NumDmas-1:0][TileWidth-1:0] engine_tile_o,
  output logic [NumDmas-1:0] engine_valid_o,
  input logic [NumDmas-1:0] engine_ready_i,
  input logic [NumDmas-1:0] completion_fire_i,
  input logic [NumDmas-1:0][TileWidth-1:0] completion_tile_i,
  output logic [NumTiles-1:0] tile_active_o
);
  localparam int EngineWidth = (NumDmas > 1) ? $clog2(NumDmas) : 1;
  logic [TileWidth-1:0] tile_rr_q;
  logic [EngineWidth-1:0] engine_rr_q;
  logic [NumTiles-1:0] tile_active_q;
  int chosen_tile, chosen_engine;
  logic dispatch;
  // Ready is an IDLE-state indication from our registered engines. A ready-qualified
  // grant is consumed immediately; this interface is internal, not a general stream arbiter.
  always_comb begin
    chosen_tile=-1; chosen_engine=-1;
    for (int k=0;k<NumTiles;k++) begin
      if (chosen_tile == -1 && tile_valid_i[(int'(tile_rr_q)+k)%NumTiles] &&
          !tile_active_q[(int'(tile_rr_q)+k)%NumTiles])
        chosen_tile=(int'(tile_rr_q)+k)%NumTiles;
    end
    for (int k=0;k<NumDmas;k++) begin
      if (chosen_engine == -1 && engine_ready_i[(int'(engine_rr_q)+k)%NumDmas])
        chosen_engine=(int'(engine_rr_q)+k)%NumDmas;
    end
    tile_ready_o='0; engine_valid_o='0; engine_job_o='0; engine_tile_o='0;
    dispatch=(chosen_tile >= 0 && chosen_engine >= 0);
    if (dispatch) begin
      engine_job_o[chosen_engine]=tile_job_i[chosen_tile];
      engine_tile_o[chosen_engine]=TileWidth'(chosen_tile);
      engine_valid_o[chosen_engine]=1;
      tile_ready_o[chosen_tile]=1;
    end
  end
  assign tile_active_o=tile_active_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tile_rr_q<='0; engine_rr_q<='0; tile_active_q<='0;
    end else begin
      for (int d=0;d<NumDmas;d++)
        if (completion_fire_i[d]) tile_active_q[completion_tile_i[d]]<=0;
      if (dispatch) begin
        tile_active_q[chosen_tile]<=1;
        tile_rr_q<=TileWidth'((chosen_tile+1)%NumTiles);
        engine_rr_q<=EngineWidth'((chosen_engine+1)%NumDmas);
      end
    end
  end
  initial assert(NumTiles > 0 && NumDmas > 0);
  assert property (@(posedge clk_i) disable iff (!rst_ni) $onehot0(tile_ready_o));
endmodule
