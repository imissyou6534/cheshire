# SPDX-License-Identifier: SHL-0.51
# VCU118 pin assignments and MIG CDC constraints are in vcu118.xdc.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_ports jtag_tck_i]]
set_property CLOCK_BUFFER_TYPE NONE [get_nets -of_objects [get_ports jtag_tck_i]]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_ports sys_reset]]
set_property CLOCK_BUFFER_TYPE NONE [get_nets -of_objects [get_ports sys_reset]]

set mux_inputs [get_nets -of_objects [get_pins -filter {DIRECTION == IN} -of_objects \
    [get_cells -hier -filter {ORIG_REF_NAME == tc_clk_mux2 || REF_NAME == tc_clk_mux2}]]]
set_property CLOCK_DEDICATED_ROUTE FALSE $mux_inputs
set_property CLOCK_BUFFER_TYPE NONE $mux_inputs

set JTAG_TCK 100.0
create_clock -period $JTAG_TCK -name clk_jtag [get_ports jtag_tck_i]
set_input_jitter clk_jtag 1.000
set_clock_groups -name jtag_async -asynchronous -group {clk_jtag}
set_input_delay -min -clock clk_jtag [expr {0.10 * $JTAG_TCK}] [get_ports {jtag_tdi_i jtag_tms_i}]
set_input_delay -max -clock clk_jtag [expr {0.20 * $JTAG_TCK}] [get_ports {jtag_tdi_i jtag_tms_i}]
set_output_delay -min -clock clk_jtag [expr {0.10 * $JTAG_TCK}] [get_ports jtag_tdo_o]
set_output_delay -max -clock clk_jtag [expr {0.20 * $JTAG_TCK}] [get_ports jtag_tdo_o]

set UART_IO_SPEED 200.0
set_max_delay [expr {$UART_IO_SPEED * 0.35}] -from [get_ports uart_rx_i]
set_false_path -hold -from [get_ports uart_rx_i]
set_max_delay [expr {$UART_IO_SPEED * 0.35}] -to [get_ports uart_tx_o]
set_false_path -hold -to [get_ports uart_tx_o]

set sync_cells [get_cells -hier -filter {ORIG_REF_NAME == sync || REF_NAME == sync}]
set_property KEEP_HIERARCHY SOFT $sync_cells
set_false_path -hold -through [get_pins -of_objects $sync_cells -filter {NAME =~ *serial_i}]
set_false_path -hold -through [get_pins -of_objects \
    [get_cells -hier -filter {ORIG_REF_NAME == axi_cdc_src || REF_NAME == axi_cdc_src}] \
    -filter {NAME =~ *async*}]
set_false_path -hold -through [get_pins -of_objects \
    [get_cells -hier -filter {ORIG_REF_NAME == axi_cdc_dst || REF_NAME == axi_cdc_dst}] \
    -filter {NAME =~ *async*}]
set reset_synchronizers [get_cells -hier -filter {NAME =~ *i_ui_rstgen || NAME =~ *i_jtag_rstgen}]
set_property KEEP_HIERARCHY TRUE $reset_synchronizers
set_false_path -through [get_pins -of_objects $reset_synchronizers -filter {NAME =~ */rst_ni}]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
