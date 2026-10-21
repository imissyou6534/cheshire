import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
sys.dont_write_bytecode = True
from run_multitile_sim import ROOT as repo, hardware_state, run_timed, validate_result
parser = argparse.ArgumentParser(description='Check VID routing/accounting in a compiled CVA6/Ara model.')
parser.add_argument('--profile', choices=['legacy', 'wide'], required=True)
parser.add_argument('--model', type=Path, required=True)
parser.add_argument('--firmware', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
before = hardware_state()
profile = args.profile
model = args.model.resolve()
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
assert not (out / 'report.json').exists(), 'use a new directory for each successful monitor run'
config = json.loads((model / 'compile.json').read_text())['config']
assert config['hardware'] == before and config['bus_profile'] == profile
assert config['tiles'] == 1 and config['dmas'] == 1 and config['boot'] == 'spm'
monitor = repo / 'target/sim/src/tb_ara_vid_monitor.sv'
with (out / 'compile.log').open('w') as stream:
    run_timed(['vlogan', '-full64', '-sverilog', '-timescale=1ns/1ps', str(monitor)],
              cwd=model, stdout=stream, stderr=subprocess.STDOUT, timeout=120, check=True)
with (out / 'elab.log').open('w') as stream:
    run_timed(['vcs', '-full64', '-timescale=1ns/1ps', '-assert', 'svaext',
                    '-top', 'tb_multitile', '-top', 'tb_ara_vid_monitor',
                    '-pvalue+tb_multitile.NumTiles=1', '-pvalue+tb_multitile.NumDmas=1',
                    '-pvalue+tb_multitile.RomEmbedded=0',
                    '-pvalue+tb_multitile.WideBus=' + str(int(profile == 'wide')),
                    '-pvalue+tb_ara_vid_monitor.NrLanes=' + str(4 if profile == 'wide' else 2),
                    '-o', str(out / 'simv')], cwd=model,
              stdout=stream, stderr=subprocess.STDOUT, timeout=600, check=True)
firmware = args.firmware.resolve()
manifest = json.loads((firmware / 'payload.json').read_text())
args = [str(out / 'simv'), '+RESULT=' + str(out / 'result.csv'), '+EXPECTED_RETURN=0',
        '+TIMEOUT_NS=5000000', '+REQUIRE_ARA=1', '+APP_BIN=' + str(firmware / 'application.bin'),
        '+APP_ADDR=10000000', '+APP_ENTRY=10000000',
        '+APP_MEM_SIZE=' + str(manifest['segments'][0]['mem_size'])]
with (out / 'run.log').open('w') as stream:
    result = run_timed(args, cwd=model, stdout=stream, stderr=subprocess.STDOUT, timeout=300)
log = (out / 'run.log').read_text()
with (out / 'result.csv').open() as stream:
    rows = [{k:int(v, 0) for k,v in row.items()} for row in csv.DictReader(stream)]
reason = validate_result(result.returncode, log, rows, 1, 0)
match = re.search(r'VID_MONITOR requests=(\d+) lanes=(\d+) alu_queue=(\d+)', log)
assert not reason, reason
assert match and tuple(map(int, match.groups())) == (5, 4 if profile == 'wide' else 2, 0)
assert hardware_state() == before
report = dict(status='passed', hardware_unchanged=True, hardware=before, rows=rows,
              vid_requests=5, lanes=int(match[2]), final_alu_queue=0,
              monitor_sha256=hashlib.sha256(monitor.read_bytes()).hexdigest())
(out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print('PASS', profile, match.group(0), flush=True)
