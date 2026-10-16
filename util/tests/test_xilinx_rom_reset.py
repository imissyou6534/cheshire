# SPDX-License-Identifier: Apache-2.0
"""Check the UI reset hook's Tcl behavior without running synthesis."""
from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
HOOK = ROOT / "target/xilinx/scripts/apply_multi_tile_rom_reset.tcl"
XDC = ROOT / "target/xilinx/constraints/multi_tile_rom.vcu118.xdc"

HARNESS = r"""
set properties [dict create]
set pblock_exists 0
set pblock_creations 0
proc get_cells {args} {
    global reg_count buffer_count
    set result {}
    if {[string match {*synch_regs_q_reg*} $args]} {
        for {set n 0} {$n < $reg_count} {incr n} {lappend result reset_reg_$n}
    } else {
        for {set n 0} {$n < $buffer_count} {incr n} {lappend result reset_buffer_$n}
    }
    return $result
}
proc get_sites {args} {return BUFGCTRL_X0Y104}
proc get_slrs {args} {global target_slr; return $target_slr}
proc get_pblocks {args} {
    global pblock_exists
    if {$pblock_exists} {return pblock_ddr_ui_reset}
    return {}
}
proc create_pblock {name} {
    global pblock_exists pblock_creations
    set pblock_exists 1
    incr pblock_creations
    return $name
}
proc resize_pblock {args} {global geometry; set geometry [lindex $args end]}
proc add_cells_to_pblock {args} {global members; set members [lindex $args end]}
proc set_property {key value objects} {
    global properties
    foreach object $objects {dict set properties $object $key $value}
}
proc get_property {key object} {
    global properties
    return [dict get $properties $object $key]
}
"""


class ResetHookTest(unittest.TestCase):
    def test_xdc_has_no_control_flow(self):
        self.assertNotRegex(XDC.read_text(), r"(?m)^\s*(?:if|elseif|foreach|for|while|proc)\b")

    def test_hook_registered_before_implementation(self):
        script = (ROOT / "target/xilinx/scripts/impl_sys.tcl").read_text()
        self.assertIn("STEPS.OPT_DESIGN.TCL.PRE", script)
        self.assertIn("apply_multi_tile_rom_reset.tcl", script)
        self.assertLess(script.index("STEPS.OPT_DESIGN.TCL.PRE"),
                        script.index("launch_runs -jobs $num_jobs impl_1"))

    def run_hook(self, registers=4, buffers=1, slr="SLR2", repeats=1):
        if not shutil.which("tclsh"):
            self.skipTest("tclsh is required")
        body = HARNESS + "\nset reg_count {}\nset buffer_count {}\nset target_slr {}\n".format(
            registers, buffers, slr)
        body += "\nif {[catch {\n"
        body += ("source {{{}}}\n".format(HOOK.as_posix())) * repeats
        body += r"""
foreach reg {reset_reg_0 reset_reg_1 reset_reg_2 reset_reg_3} {
    if {![get_property ASYNC_REG $reg]} {error "missing ASYNC_REG"}
}
if {$geometry ne "CLOCKREGION_X2Y13:CLOCKREGION_X3Y13" || [llength $members] != 4} {
    error "wrong reset pblock"
}
if {[get_property IS_SOFT pblock_ddr_ui_reset]} {error "soft pblock"}
if {[get_property LOC reset_buffer_0] ne "BUFGCTRL_X0Y104"} {error "wrong buffer LOC"}
if {$pblock_creations != 1} {error "duplicate pblock"}
} message]} {puts stderr $message; exit 1}
puts "PASS reset hook contract"
exit 0
"""
        return subprocess.run(["tclsh"], input=body, text=True, capture_output=True)

    def test_valid_netlist(self):
        result = self.run_hook()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS reset hook contract", result.stdout)

    def test_idempotent(self):
        result = self.run_hook(repeats=2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_registers_fail(self):
        result = self.run_hook(registers=0)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected four", result.stderr)

    def test_wrong_register_count_fails(self):
        result = self.run_hook(registers=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected four", result.stderr)

    def test_missing_buffer_fails(self):
        result = self.run_hook(buffers=0)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected one", result.stderr)

    def test_wrong_slr_fails(self):
        result = self.run_hook(slr="SLR1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SLR2", result.stderr)


if __name__ == "__main__":
    unittest.main()
