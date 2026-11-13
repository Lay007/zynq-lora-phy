"""Run complete SF7/BW125 packets through the joint ToA/CFO RTL path."""

from __future__ import annotations

import argparse
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import numpy as np

TREE = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(TREE), str(TREE / "tools"), str(TREE / "src")]
from tools.joint_packet_checks import cases_for_suite, evaluate, stimulus, summarize
from tools.lora_per_ideal import test_payload


def source_files() -> list[str]:
    sources = [str(p.relative_to(TREE)) for p in sorted(
        (TREE / 'fpga/generated/fft-correlator-fixed/lora_fft_correlator_gen').glob('*.v'))]
    sources += [
        'fpga/generated/blind-detector/lora_blind_detector_gen/lora_blind_BlindDetector.v',
        'fpga/generated/toa-interpolator/lora_toa_interpolator_gen/lora_toa_ToaInterpolator.v']
    sources += ['fpga/wrappers/' + name + '.v' for name in (
        'fft_correlator_route_top', 'lora_detector_timestamp_align', 'lora_detector_timestamp_path',
        'lora_cfo_derotator', 'lora_fft_detector_timestamp_path', 'lora_iq_history_buffer',
        'lora_reference_chirp_rom', 'lora_matched_filter_mac', 'lora_peak_triplet_capture',
        'lora_matched_filter_search', 'lora_joint_chirp_grid_controller', 'lora_symbol_grid_resync',
        'lora_timestamp_metadata_join', 'lora_axi_lite_status', 'lora_packet_toa_receiver_top')]
    return sources + ['fpga/tb/tb_replay_detect.sv']


def save(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True, help='New, empty output directory')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--suite', choices=('baseline', 'timing'), default='baseline')
    parser.add_argument('--timeout', type=float, default=300, help='Seconds per simulation case')
    parser.add_argument('--extra-source', action='append', default=[],
                        help='Additional RTL source relative to the source tree')
    args = parser.parse_args()
    if args.jobs < 1 or not np.isfinite(args.timeout) or args.timeout <= 0:
        parser.error('jobs and timeout must be positive')
    out = args.out.resolve()
    if out.exists() and (not out.is_dir() or any(out.iterdir())):
        parser.error('output directory must be empty; previous evidence is never overwritten')
    sources = source_files()
    for name in args.extra_source:
        path = (TREE / name).resolve()
        if not path.is_relative_to(TREE) or not path.is_file():
            parser.error('extra source must be an existing file in the source tree')
        sources.append(str(path.relative_to(TREE)))
    out.mkdir(parents=True, exist_ok=True)
    os.chdir(TREE)
    cases = cases_for_suite(args.suite)
    rows = []
    save(out / 'results.json', rows)
    save(out / 'summary.json', summarize(rows, len(cases)))
    python_sources = [str(p.relative_to(TREE)) for p in sorted((TREE / 'src/zynq_lora_phy').glob('*.py'))]
    python_sources += ['tools/joint_packet_regression.py', 'tools/joint_packet_checks.py',
                       'tools/lora_tx_waveform.py', 'tools/lora_per_ideal.py']
    provenance_sources = sources + python_sources + ['fpga/rom/lora_sf7_l8_reference_q10.mem']
    save(out / 'provenance.json', {
        'suite': args.suite, 'cases': [asdict(case) for case in cases],
        'pl_clock_hz': 62500000, 'sample_rate_hz': 1000000,
        'search_radius': 48, 'guard_samples': 48, 'coarse_stride': 2,
        'prefetch_up': True, 'request_on_response': True,
        'numpy_version': np.__version__, 'python_version': sys.version,
        'verilator_version': subprocess.check_output(['verilator', '--version'], text=True).strip(),
        'source_sha256': {name: hashlib.sha256((TREE / name).read_bytes()).hexdigest()
                          for name in provenance_sources}})
    directory = out / 'simulator'
    cmd = ['verilator', '--binary', '--timing', '-j', str(args.jobs), '-Wno-fatal',
           '--unroll-count', '4096', '--unroll-stmts', '1000000',
           '--top-module', 'tb_replay_detect', '-DLORA_NAMESPACED_GENERATED',
           '-GSEARCH_RADIUS=48', '-GFINE_GUARD=48', '-GFAST_MAC=1', '-GPREFETCH_UP=1',
           '-GCOARSE_STRIDE=2', '--Mdir', str(directory), *sources]
    with (out / 'build.log').open('w', encoding='utf-8') as log:
        subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, check=True)
    print('Full packet simulator compiled', flush=True)
    payload = test_payload(1234)
    for case in cases:
        words, truth = stimulus(case, payload)
        hexfile = out / (case.name + '.hex')
        hexfile.write_text('\n'.join(f'{v:08x}' for v in words) + '\n', encoding='ascii')
        started = time.monotonic()
        timed_out = False
        try:
            result = subprocess.run(
                [str(directory / 'Vtb_replay_detect'), f'+iq={hexfile}', f'+n={len(words)}',
                 '+gap=62', '+gap_half=1'], text=True, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, timeout=args.timeout)
            output, returncode = result.stdout, result.returncode
        except subprocess.TimeoutExpired as error:
            output = error.stdout or b''
            if isinstance(output, bytes):
                output = output.decode('utf-8', errors='replace')
            returncode, timed_out = -1, True
        logfile = out / (case.name + '.log')
        logfile.write_text(output, encoding='utf-8')
        row = evaluate(case, output, payload, truth, returncode)
        if timed_out:
            row['failures'].append('simulator_timeout')
            row['passed'] = False
        row.update(simulation_seconds=time.monotonic() - started, raw_log=logfile.name,
                   stimulus_sha256=hashlib.sha256(hexfile.read_bytes()).hexdigest(),
                   raw_log_sha256=hashlib.sha256(logfile.read_bytes()).hexdigest())
        rows.append(row)
        save(out / 'results.json', rows)
        save(out / 'summary.json', summarize(rows, len(cases)))
        print(f"{'PASS' if row['passed'] else 'FAIL'} {case.name}: "
              f"ToA={row['toa_error_samples']} samples; failures={row['failures']}", flush=True)
    summary = summarize(rows, len(cases))
    print(json.dumps(summary, indent=2), flush=True)
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
