# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Design-specific optimization directives for Synopsys Design Compiler,
# independent of the technology. Sourced after elaboration, before compile.
# They follow the cva6-eval flow, so CVA6 is optimized as in core-only runs.
# Expects CHS_ASIC_HIERARCHY (flat, blocks or rtl; see asic.mk).

# Retime the registers of the pipelined FPU and multiplier
foreach pattern {fpnew_* multiplier_*} {
    set designs [get_designs -quiet ${pattern}]
    if { [sizeof_collection ${designs}] == 0 } {
        error "synopsys_optimize.tcl: no designs ${pattern} to retime"
    }
    set_optimize_registers true -justification_effort medium -designs ${designs}
}

# Flatten the contents of the ALU wrapper, where it exists (newer CVA6 versions)
foreach_in_collection wrapper [get_cells -quiet -hierarchical alu_wrapper_i] {
    set children [get_cells -quiet [get_object_name ${wrapper}]/* \
        -filter "is_hierarchical == true"]
    if { [sizeof_collection ${children}] > 0 } {
        ungroup -flatten ${children}
    }
}


# CHS_ASIC_HIERARCHY=blocks: keep the main blocks of the SoC and of CVA6 as
# hierarchies, with their parents, so their area and power can be reported
# after place and route. Blocks absent from a configuration are skipped; the
# logic inside each block is optimized as usual.
set chs_asic_soc_blocks {
    i_core_cva6 i_llc i_llc_atomics i_axi_xbar i_axi_to_reg_v2 i_reg_demux
    i_dbg_dm_top i_dbg_dmi_jtag i_clint i_plic i_clic i_irq_router i_idma
    i_bootrom i_uart i_i2c i_spi_host i_gpio i_axi_vga i_spinal_usb_ohci
    i_serial_link i_axi_rt_unit_top
}
set chs_asic_core_blocks {
    i_frontend id_stage_i issue_stage_i ex_stage_i commit_stage_i csr_regfile_i
    controller_i perf_counters_i i_cache_subsystem
}
set chs_asic_unit_blocks {
    lsu_i fpu_i i_mult i_cva6_icache i_dcache
}
# Hierarchical cells below `parents` whose names end in one of `names`
proc chs_asic_blocks_below { parents names } {
    set cells {}
    foreach_in_collection parent ${parents} {
        foreach name ${names} {
            set cells [add_to_collection ${cells} [get_cells -quiet \
                -filter "is_hierarchical == true" [get_object_name ${parent}]/*${name}]]
        }
    }
    return ${cells}
}
if { ${CHS_ASIC_HIERARCHY} eq "blocks" } {
    set soc [get_cells i_cheshire_soc]
    set blocks [chs_asic_blocks_below ${soc} ${chs_asic_soc_blocks}]
    set cores [filter_collection ${blocks} "full_name =~ *i_core_cva6"]
    set units [chs_asic_blocks_below ${cores} ${chs_asic_core_blocks}]
    set blocks [add_to_collection ${blocks} ${units}]
    set blocks [add_to_collection ${blocks} [chs_asic_blocks_below ${units} ${chs_asic_unit_blocks}]]
    set_ungroup [add_to_collection ${soc} ${blocks}] false
    foreach_in_collection block ${blocks} { puts "Kept hierarchy: [get_object_name ${block}]" }
}

