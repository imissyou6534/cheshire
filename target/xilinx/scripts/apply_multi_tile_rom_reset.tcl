# SPDX-License-Identifier: SHL-0.51
# Run as ordinary Tcl on the linked netlist, not through the XDC parser.
set ui_reset_regs [get_cells -quiet -hier -filter \
    {NAME =~ i_platform/i_dram_wrapper/gen_ui_reset.i_ui_rstgen/i_rstgen_bypass/synch_regs_q_reg*}]
if {[llength $ui_reset_regs] != 4} {
    error "Expected four DDR UI reset synchronization registers, found [llength $ui_reset_regs]"
}
set ui_reset_buffer [get_cells -quiet \
    i_platform/i_dram_wrapper/gen_ui_reset.i_ui_rstgen/i_rstgen_bypass/i_tc_clk_mux2_rst_no/i_BUFGMUX]
if {[llength $ui_reset_buffer] != 1} {
    error "Expected one DDR UI reset output buffer, found [llength $ui_reset_buffer]"
}
set ui_reset_site [get_sites -quiet BUFGCTRL_X0Y104]
if {[llength $ui_reset_site] != 1 || [get_slrs -of_objects $ui_reset_site] ne "SLR2"} {
    error "DDR UI reset buffer site must exist in SLR2"
}

# Keep the high-fanout reset source close to its SLR2 consumers.
set_property ASYNC_REG TRUE $ui_reset_regs
if {![llength [get_pblocks -quiet pblock_ddr_ui_reset]]} {
    create_pblock pblock_ddr_ui_reset
}
resize_pblock [get_pblocks pblock_ddr_ui_reset] \
    -add {CLOCKREGION_X2Y13:CLOCKREGION_X3Y13}
add_cells_to_pblock [get_pblocks pblock_ddr_ui_reset] $ui_reset_regs
set_property IS_SOFT FALSE [get_pblocks pblock_ddr_ui_reset]
set_property LOC BUFGCTRL_X0Y104 $ui_reset_buffer
puts "Applied DDR UI reset Scheme A: 4 ASYNC_REG stages, hard SLR2 pblock, BUFGCTRL_X0Y104"
