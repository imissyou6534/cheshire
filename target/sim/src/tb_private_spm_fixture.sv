`timescale 1ns/1ps
module tb_private_spm_fixture #(parameter int unsigned SelectedCfg = 5);
  fixture_cheshire_soc #(.SelectedCfg(SelectedCfg), .UseDramSys(0)) fixture();
  initial begin
    #10000ns;
    if (SelectedCfg == 5)
      assert(fixture.DutCfg.LlcSpmPrivate && fixture.DutCfg.Ara && fixture.DutCfg.Fft)
        else $fatal(1, "configuration 5 lost private SPM or Ara/FFT");
    $display("PASS Cheshire fixture config=%0d elaboration and reset", SelectedCfg);
    $finish;
  end
endmodule
