# SPDX-License-Identifier: Apache-2.0
if {$argc != 1} { error "Expected one new result-directory argument" }
set root [file normalize [lindex $argv 0]]
source [file join $root sources.tcl]
foreach debug {0 1} {
  foreach cut {0 1} {
    set name [expr {$debug ? "debug" : "periph"}]-[expr {$cut ? "cut" : "direct"}]
    set out [file join $root vivado-$name]
    file mkdir $out
    create_project -in_memory -part xcvu9p-flga2104-2L-e
    set_property include_dirs $probe_includes [current_fileset]
    set_property verilog_define SYNTHESIS [current_fileset]
    read_verilog -sv $probe_sources
    synth_design -top dw_loop_probe -part xcvu9p-flga2104-2L-e \
      -generic DebugMode=$debug -generic CutBoundary=$cut \
      -flatten_hierarchy none -mode out_of_context
    create_clock -period 20 [get_ports clk_i]
    report_drc -checks [get_drc_checks LUTLP-1] -file [file join $out drc.rpt]
    puts "PROBE_RESULT $name loops=[llength [get_drc_violations -quiet LUTLP-1*]]"
    close_project
  }
}
