// SPDX-License-Identifier: SHL-0.51
package cheshire_shared_dma_cfg_pkg;
  // A standalone multi-tile configuration; existing board configurations remain separate.
  function automatic cheshire_pkg::cheshire_cfg_t tile_cfg(
      input cheshire_pkg::cheshire_cfg_t base);
    cheshire_pkg::cheshire_cfg_t cfg;
    cfg=base;
    cfg.NumCores=1;
    cfg.Dma=0;
    cfg.LlcOutConnect=1;
    cfg.LlcNotBypass=0;
    cfg.AxiExtNumMst=0;
    cfg.AxiExtNumSlv=1;
    cfg.AxiExtNumRules=1;
    cfg.AxiExtRegionIdx='0;
    cfg.AxiExtRegionStart='0;
    cfg.AxiExtRegionEnd='0;
    cfg.AxiExtRegionStart[0]='h01000000;
    cfg.AxiExtRegionEnd[0]='h01001000;
    cfg.RegExtNumSlv=0;
    cfg.RegExtNumRules=0;
    cfg.NumExtInIntrs=1;
    cfg.NumExtOutIntrTgts=0;
    cfg.NumExtIrqHarts=0;
    cfg.NumExtDbgHarts=0;
    cfg.I2c=0; cfg.SpiHost=0; cfg.Gpio=0; cfg.SerialLink=0; cfg.Vga=0; cfg.Usb=0;
    return cfg;
  endfunction
endpackage
