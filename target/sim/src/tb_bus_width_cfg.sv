// SPDX-License-Identifier: SHL-0.51
module tb_bus_width_cfg;
  import cheshire_pkg::*;
  localparam cheshire_cfg_t Wide =
    cheshire_shared_dma_cfg_pkg::wide_private_spm_tile_cfg(DefaultCfg);
  localparam config_pkg::cva6_user_cfg_t Cpu = gen_cva6_cfg(Wide);
  initial begin
    assert(Wide.AxiDataWidth == 128 && Wide.CoreAxiDataWidth == 64)
      else $fatal(1, "CPU/Tile widths are coupled");
    assert(Wide.AraAxiDataWidth == 128 && Wide.AraNrLanes == 4 && Wide.AraVLEN == 2048)
      else $fatal(1, "Ara profile mismatch");
    assert(Wide.FftAxiDataWidth == 128 && Wide.DbgAxiDataWidth == 64)
      else $fatal(1, "accelerator/debug profile mismatch");
    assert(get_llc_size(Wide) == 131072 && Wide.LlcNumBlocks == 4)
      else $fatal(1, "SPM capacity changed");
    assert(Cpu.AxiDataWidth == 64)
      else $fatal(1, "CPU native interface changed");
    $display("PASS mixed-width configuration CPU64 Ara4/128 FFT128 Tile128 SPM128KiB Debug64");
    $finish;
  end
endmodule
