`timescale 1ns/1ps
module tb_private_spm_map;
  import cheshire_pkg::*;
  function automatic cheshire_cfg_t config_private();
    cheshire_cfg_t cfg = DefaultCfg;
    cfg.LlcSpmPrivate = 1;
    return cfg;
  endfunction
  localparam cheshire_cfg_t Cfg = config_private();
  localparam axi_out_t Map = gen_axi_out(Cfg);
  localparam axi_out_t Legacy = gen_axi_out(DefaultCfg);
  initial begin
    assert(Map.spm != Map.llc)
      else $fatal(1, "private SPM must use a different crossbar target from DDR");
    assert(Legacy.spm == Legacy.llc && Map.num_out == Legacy.num_out + 1 &&
           Map.num_rules == Legacy.num_rules)
      else $fatal(1, "legacy map changed or private SPM duplicated address rules");
    $display("PASS private SPM crossbar target separation");
    $finish;
  end
endmodule
