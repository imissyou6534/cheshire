# Copyright 2024 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Nicole Narr <narrn@student.ethz.ch>
# Christopher Reinwardt <creinwar@student.ethz.ch>
# Cyril Koenig <cykoenig@iis.ee.ethz.ch>
# Paul Scheffler <paulsc@iis.ee.ethz.ch>
# Yvan Tortorella <yvan.tortorella@gmail.com>
# Mojtaba Rostami <m.rostami1989@gmail.com>

VIVADO ?= vitis-2022.1 vivado

CHS_XILINX_DIR ?= $(CHS_ROOT)/target/xilinx

# Required to split stems
.SECONDEXPANSION:

##############
# Xilinx IPs #
##############

.PRECIOUS: $(CHS_XILINX_DIR)/build/%/ $(CHS_XILINX_DIR)/build/%/out.xci

$(CHS_XILINX_DIR)/build/%/:
	mkdir -p $@

# We split the stem into a board and an IP and resolve dependencies accordingly
$(CHS_XILINX_DIR)/build/%/out.xci: \
		$(CHS_XILINX_DIR)/scripts/impl_ip.tcl \
		$$(wildcard $(CHS_XILINX_DIR)/src/ips/$$*.prj) \
		| $(CHS_XILINX_DIR)/build/%/
	@rm -f $(CHS_XILINX_DIR)/build/$(*)*.log $(CHS_XILINX_DIR)/build/$(*)*.jou
	cd $| && $(VIVADO) -mode batch -log ../$*.log -jou ../$*.jou -source $< -tclargs $(subst ., ,$*)

##############
# Bitstreams #
##############

CHS_XILINX_BOARDS := genesys2 vcu128 vcu118

CHS_XILINX_IPS_genesys2 := clkwiz vio mig7s
CHS_XILINX_IPS_vcu128   := clkwiz vio ddr4
CHS_XILINX_IPS_vcu118   := clkwiz vio ddr4

$(CHS_XILINX_DIR)/scripts/add_sources.%.tcl: $(CHS_ROOT)/Bender.yml
	$(BENDER) script vivado -t fpga -t $* $(CHS_BENDER_RTL_FLAGS) > $@

define chs_xilinx_bit_rule
$$(CHS_XILINX_DIR)/out/%.$(1).bit: \
		$$(CHS_XILINX_DIR)/scripts/impl_sys.tcl \
		$$(CHS_XILINX_DIR)/scripts/add_sources.$(1).tcl \
		$$(CHS_XILINX_IPS_$(1):%=$(CHS_XILINX_DIR)/build/$(1).%/out.xci) \
		$$(CHS_HW_ALL) \
		| $$(CHS_XILINX_DIR)/build/$(1).%/
	@rm -f $$(CHS_XILINX_DIR)/build/$$*.$(1)*.log $$(CHS_XILINX_DIR)/build/$$*.$(1)*.jou
	cd $$| && $$(VIVADO) -mode batch -log ../$$*.$(1).log -jou ../$$*.$(1).jou -source $$< \
		-tclargs $(1) $$* $$(CHS_XILINX_IPS_$(1):%=$$(CHS_XILINX_DIR)/build/$(1).%/out.xci)

CHS_PHONY += chs-xilinx-$(1)
chs-xilinx-$(1): $$(CHS_XILINX_DIR)/out/cheshire.$(1).bit
endef

$(foreach board,$(CHS_XILINX_BOARDS),$(eval $(call chs_xilinx_bit_rule,$(board))))

# Separate source list and output paths preserve the original single-SoC target.
CHS_NUM_TILES ?= 1
CHS_NUM_DMAS ?= 1
CHS_XILINX_SYNTH_ONLY ?= 0
CHS_MULTITILE_RTL_FLAGS ?= -t rtl -t cva6 -t cv64a6_imafdcv_sv39 -t exclude_first_pass_decoder \
    --define ARA --define NR_LANES=2 --define VLEN=2048 --define FFT_ACCEL
CHS_MULTITILE_IPS := $(CHS_XILINX_IPS_vcu118:%=$(CHS_XILINX_DIR)/build/vcu118.%/out.xci)
CHS_PHONY += chs-xilinx-multi-tile-vcu118
chs-xilinx-multi-tile-vcu118: $(CHS_HW_ALL) $(CHS_MULTITILE_IPS) \
        | $(CHS_XILINX_DIR)/build/vcu118.multi_tile/
	@test "$(CHS_NUM_TILES)" -ge 1 && test "$(CHS_NUM_TILES)" -le 64
	@test "$(CHS_NUM_DMAS)" -ge 1 && test "$(CHS_NUM_DMAS)" -le 65536
	@test "$(CHS_XILINX_SYNTH_ONLY)" = 0 -o "$(CHS_XILINX_SYNTH_ONLY)" = 1
	$(BENDER) script vivado -t fpga -t vcu118 $(CHS_MULTITILE_RTL_FLAGS) \
	    --define CHS_NUM_TILES=$(CHS_NUM_TILES) --define CHS_NUM_DMAS=$(CHS_NUM_DMAS) \
	    > $(CHS_XILINX_DIR)/scripts/add_sources.multi_tile.vcu118.tcl
	bash $(CHS_ROOT)/util/prepare_shared_dma_plic.sh --check
	cd $(CHS_XILINX_DIR)/build/vcu118.multi_tile/ && \
	    CHS_XILINX_SYNTH_ONLY=$(CHS_XILINX_SYNTH_ONLY) $(VIVADO) -mode batch \
	    -log ../multi_tile.vcu118.log -jou ../multi_tile.vcu118.jou \
	    -source $(CHS_XILINX_DIR)/scripts/impl_sys.tcl \
	    -tclargs vcu118 multi_tile $(CHS_MULTITILE_IPS)

# Compile application sources and the loader, then link one ROM/SPM firmware.
CHS_ROM_APP ?= sw/tests/vector_helloworld.c
CHS_ROM_EXTRA_SRCS ?=
CHS_ROM_APP_MARCH ?= rv64gcv_zifencei
CHS_ROM_CC ?= $(CHS_SW_CC)
CHS_ROM_BUILD_ARGS = --out "$(CHS_ROOT)/target/rom_autoboot" --app "$(CHS_ROM_APP)" \
    --cc "$(CHS_ROM_CC)" \
    --app-march "$(CHS_ROM_APP_MARCH)" \
    $(foreach source,$(CHS_ROM_EXTRA_SRCS),--extra-source "$(source)")
CHS_PHONY += chs-rom-autoboot chs-xilinx-multi-tile-rom-vcu118
chs-rom-autoboot:
	bash $(CHS_ROOT)/util/build_rom_autoboot.sh $(CHS_ROM_BUILD_ARGS)

chs-xilinx-multi-tile-rom-vcu118: $(CHS_HW_ALL) $(CHS_MULTITILE_IPS) \
        | $(CHS_XILINX_DIR)/build/vcu118.multi_tile_rom/
	@test "$(CHS_NUM_TILES)" -ge 1 && test "$(CHS_NUM_TILES)" -le 64
	@test "$(CHS_NUM_DMAS)" -ge 1 && test "$(CHS_NUM_DMAS)" -le 65536
	@test "$(CHS_XILINX_SYNTH_ONLY)" = 0 -o "$(CHS_XILINX_SYNTH_ONLY)" = 1
	@set -e; \
	    snapshot="$$(bash $(CHS_ROOT)/util/build_rom_autoboot.sh $(CHS_ROM_BUILD_ARGS) --print-snapshot)"; \
	    $(BENDER) script vivado -t fpga -t vcu118 -t rom_autoboot $(CHS_MULTITILE_RTL_FLAGS) \
	    --define CHS_NUM_TILES=$(CHS_NUM_TILES) --define CHS_NUM_DMAS=$(CHS_NUM_DMAS) \
	    > $(CHS_XILINX_DIR)/scripts/add_sources.multi_tile_rom.vcu118.tcl; \
	    bash $(CHS_ROOT)/util/prepare_shared_dma_plic.sh --check; \
	    cd $(CHS_XILINX_DIR)/build/vcu118.multi_tile_rom/; \
	    CHS_ROM_SNAPSHOT="$$snapshot" CHS_XILINX_SYNTH_ONLY=$(CHS_XILINX_SYNTH_ONLY) $(VIVADO) -mode batch \
	    -log ../multi_tile_rom.vcu118.log -jou ../multi_tile_rom.vcu118.jou \
	    -source $(CHS_XILINX_DIR)/scripts/impl_sys.tcl \
	    -tclargs vcu118 multi_tile_rom $(CHS_MULTITILE_IPS)

# Builds bitstreams for all available boards
CHS_XILINX_ALL = $(foreach board,$(CHS_XILINX_BOARDS),$$(CHS_XILINX_DIR)/out/cheshire.$(board).bit)

#############
# Utilities #
#############

# Parameters for HW server (defaults are for a unique board @ localhost).
# `CHS_XILINX_HWS_PATH_$(board)` overrides the device path for each board (default *).
CHS_XILINX_HWS_URL ?= localhost:3121

# We build the dependency file $(2) only if it does not exist; it must not be up to date.
# We add PHONYs for each board as despite the implicit rule, these should be explicit.
define chs_xilinx_util_rule
CHS_PHONY += $(foreach board,$(CHS_XILINX_BOARDS),chs-xilinx-$(1)-$(board))
$(foreach board,$(CHS_XILINX_BOARDS),chs-xilinx-$(1)-$(board)): chs-xilinx-$(1)-%: \
		$$(CHS_XILINX_DIR)/scripts/util/$(1).tcl | $$(CHS_XILINX_DIR)/build/%.$(1)/
	[ -e $(subst %,$$*,$(2)) ] || $$(MAKE) $(subst %,$$*,$(2))
	@rm -f $$(CHS_XILINX_DIR)/build/$$(*)*.$(1).log $$(CHS_XILINX_DIR)/build/$$(*)*.$(1).jou
	cd $$| && $$(VIVADO) -mode batch -log ../$$(*).$(1).log -jou ../$$(*).$(1).jou -source $$< \
		-tclargs $$(CHS_XILINX_HWS_URL) $$(or $$(CHS_XILINX_HWS_PATH_$$*),{*}) $$* $(subst %,$$*,$(2)) 0
endef

# Program bitstream onto board
$(eval $(call chs_xilinx_util_rule,program,$(CHS_XILINX_DIR)/out/cheshire.%.bit))

# Flash onboard memory with the file `CHS_XILINX_FLASH_IMG` (only selected boards).
# `%` is substituted with the board name. The default is the Linux disk image for that board.
CHS_XILINX_FLASH_IMG ?= $(CHS_SW_DIR)/boot/linux.%.gpt.bin
$(eval $(call chs_xilinx_util_rule,flash,$(CHS_XILINX_FLASH_IMG)))
