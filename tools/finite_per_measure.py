"""Collect finite, uniquely numbered PL trials with complete timestamp records."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import uuid
import zipfile

from finite_bench import parse_record, summarize
import per_measure as bench

ROOT = Path(__file__).resolve().parents[1]


def save(path: Path, value: dict) -> None:
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    # Windows scanners/readers can temporarily hold the destination without
    # FILE_SHARE_DELETE. Keep the previous checkpoint until replacement succeeds.
    for attempt in range(12):
        try:
            temporary.replace(path)
            break
        except PermissionError:
            if attempt == 11: raise
            time.sleep(min(0.02 * 2**attempt, 0.25))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while data := stream.read(1024 * 1024): digest.update(data)
    return digest.hexdigest()


def generator_summary(text: str) -> dict:
    lines = [line for line in text.splitlines() if line.startswith('TX_SUMMARY ')]
    if len(lines) != 1:
        raise ValueError('missing/duplicate TX_SUMMARY')
    return {key: int(value) for key, value in (item.split('=') for item in lines[0].split()[1:])}


def stage_templates(c, tpl, prefix, cache_dir=None):
    """Reuse only a content-verified template in one explicitly owned /tmp cache."""
    expected = sha256(tpl)
    cached = None
    reused = False
    if cache_dir:
        if not re.fullmatch(r'/tmp/lora-finite-cache-[0-9a-f]{32}', cache_dir):
            raise ValueError('template cache must be /tmp/lora-finite-cache-<32 hex digits>')
        cached = cache_dir + '/templates.c64'
        bench.run(c, f'mkdir -p {cache_dir}; test ! -L {cache_dir}')
        reply = bench.run(c, f'if [ -f {cached} ]; then sha256sum {cached}; fi').split()
        reused = bool(reply and reply[0] == expected)
        if not reused:
            # Retire only the single file owned by this explicitly named cache.
            bench.run(c, f'rm -f {cached}')
    free_kib = int(bench.run(c, 'df -k /tmp').splitlines()[-1].split()[3])
    required = (0 if reused else tpl.stat().st_size) + 32*1024**2
    if required > free_kib*1024:
        raise RuntimeError('insufficient board /tmp space for finite templates and logs; reduce batch size')
    if reused:
        bench.run(c, f'ln {cached} {prefix}.c64')
    else:
        bench.put(c, tpl, prefix + '.c64')
        if cached:
            remote = bench.run(c, f'sha256sum {prefix}.c64').split()[0]
            if remote != expected:
                raise RuntimeError('uploaded template SHA256 differs from host source')
            bench.run(c, f'ln {prefix}.c64 {cached}')
    return dict(directory=cache_dir, reused=reused, sha256=expected)


def start_tx(c, args, prefix, spp, snr, seed, padded, max_seconds):
    """Launch the finite generator/writer and expose both exit statuses."""
    gap, lead, tail = int(args.gap*args.tx_rate), int(args.tx_rate), int(2*args.tx_rate)
    fifo = prefix + '.fifo'
    gen = (f'{prefix}.noise {prefix}.c64 {args.packets} {spp} {gap} '
           f'{snr} {args.bw*1000} -14 {seed} {args.tx_rate} {args.packets} {lead} {tail}')
    command = (f'mkfifo {fifo} || exit 1; {gen} > {fifo} 2>{prefix}.noise.err & producer=$!; '
               f'echo "$producer" > {prefix}.producer.pid; '
               f'iio_writedev -b 262144 -s {padded} cf-ad9361-dds-core-lpc '
               f'< {fifo} >{prefix}.writer.log 2>&1; writer=$?; '
               'if [ "$writer" -ne 0 ]; then kill "$producer" 2>/dev/null || :; fi; '
               'wait "$producer"; producer_status=$?; '
               f'rm -f {fifo}; echo TX_EXIT producer=$producer_status writer=$writer; '
               '[ "$producer_status" -eq 0 ] && [ "$writer" -eq 0 ]')
    _, tx_out, tx_err = c.exec_command(command, timeout=max_seconds)
    return tx_out, tx_err


def measure(c, args, prefix: str, spp: int, snr: float, seed: int, checkpoint) -> dict:
    gap = int(args.gap * args.tx_rate)
    lead, tail = int(args.tx_rate), int(2 * args.tx_rate)
    samples = lead + args.packets * (spp + gap) + tail
    padded = ((samples + 262143) // 262144) * 262144
    max_seconds = 2 * padded / args.tx_rate + 60
    point = {'snr_db': snr, 'seed': seed, 'records': [], 'status': 'starting',
             'expected_samples': padded, 'lead_samples': lead, 'tail_samples': tail,
             'started_utc': datetime.now(timezone.utc).isoformat()}
    checkpoint(point)
    raw = args.out.with_name(args.out.stem + f'.snr-{snr:g}.trace.txt')
    capture_command = (f'echo $$ > {prefix}.capture.pid; exec {prefix}.trace 0 1000 '
                       f'{math.ceil(max_seconds * 1000)}')
    _, capture_out, capture_err = c.exec_command('sh -c ' + shlex.quote(capture_command), timeout=max_seconds+15)
    capture = capture_out.channel
    tx = None
    stopped = False
    try:
        with raw.open('w', encoding='utf-8') as log:
            # The device announces readiness after the first trace re-arm.
            capture.settimeout(10)
            while True:
                line = capture_out.readline()
                if not line: raise RuntimeError('capture exited before READY')
                log.write(line); log.flush()
                if line.startswith('READY '): break
            tx_out, tx_err = start_tx(c, args, prefix, spp, snr, seed, padded, max_seconds)
            tx = tx_out.channel
            point['status'] = 'collecting'
            checkpoint(point)
            start = time.monotonic()
            tx_done_at = None
            buffer = ''
            capture.settimeout(max_seconds+15)
            while True:
                while capture.recv_ready():
                    buffer += capture.recv(65536).decode('utf-8', errors='replace')
                    while '\n' in buffer:
                        line, buffer = buffer.split('\n', 1)
                        log.write(line + '\n'); log.flush()
                        if line.startswith(('PKT ', 'TIMEOUT ')):
                            point['records'].append(parse_record(line))
                            checkpoint(point)
                        elif line == 'STOP': stopped = True
                if tx.exit_status_ready() and tx_done_at is None:
                    point['tx_exit_code'] = tx.recv_exit_status()
                    point['tx_output'] = tx_out.read().decode() + tx_err.read().decode()
                    point['tx_elapsed_s'] = time.monotonic() - start
                    point['generator_log'] = bench.run(c, f'cat {prefix}.noise.err')
                    point['writer_log'] = bench.run(c, f'cat {prefix}.writer.log')
                    point['generator_summary'] = generator_summary(point['generator_log'])
                    tx_done_at = time.monotonic()
                    checkpoint(point)
                if tx_done_at is not None and time.monotonic() - tx_done_at >= 2 and not point.get('stop_requested'):
                    bench.run(c, f'kill -TERM $(cat {prefix}.capture.pid)')
                    point['stop_requested'] = True
                if capture.exit_status_ready() and not capture.recv_ready(): break
                if time.monotonic() - start > max_seconds: raise TimeoutError('finite series exceeded deadline')
                time.sleep(0.05)
            if buffer: log.write(buffer); point['records'].append(parse_record(buffer))
        point['capture_exit_code'] = capture.recv_exit_status()
        point['capture_stderr'] = capture_err.read().decode()
        summary = point.get('generator_summary', {})
        complete = (point.get('tx_exit_code') == 0 and summary.get('complete') == 1
                    and summary.get('packets_completed') == args.packets
                    and summary.get('samples_written') == padded
                    and summary.get('clipped_components') == 0
                    and point.get('tx_elapsed_s', 0) >= (lead + args.packets * (spp + gap) - gap) / args.tx_rate - 1)
        point.update(summarize(point['records'], args.first_sequence, args.packets,
                               tx_complete=complete, collection_complete=bool(
                                   stopped and point.get('stop_requested') and point['capture_exit_code'] == 0)))
        point['status'] = 'complete' if point['measurement_valid'] else 'invalid'
        point['raw_trace'] = raw.name
        point['raw_trace_sha256'] = sha256(raw)
        checkpoint(point)
        return point
    except BaseException as exc:
        point.update(status='interrupted', error=f'{type(exc).__name__}: {exc}')
        checkpoint(point)
        raise
    finally:
        # Limit cleanup to this run's reader; transmitter cleanup is also in main.
        bench.run(c, f'for p in {prefix}.capture.pid {prefix}.producer.pid; do '
                     'if [ -f "$p" ]; then kill -TERM $(cat "$p") 2>/dev/null || :; fi; done')
        capture.close()
        if tx is not None: tx.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='192.168.40.1')
    parser.add_argument('--receiver', default='pl', help='pl or serial port of Heltec V4 receiver firmware >=0.2.0')
    parser.add_argument('--known-hosts', type=Path, required=True)
    parser.add_argument('--password', default='analog')
    parser.add_argument('--bin-dir', type=Path, default=ROOT / 'board/per')
    parser.add_argument('--packets', type=int, default=100)
    parser.add_argument('--first-sequence', type=int, default=0)
    parser.add_argument('--sf', type=int, default=7)
    parser.add_argument('--bw', type=float, default=125)
    parser.add_argument('--cr', type=int, default=1)
    parser.add_argument('--snr', type=float, nargs='+', required=True)
    parser.add_argument('--gap', type=float, default=0.3)
    parser.add_argument('--tx-rate', type=float, default=1e6)
    parser.add_argument('--rx-gain', type=float, default=37)
    parser.add_argument('--tx-atten', type=float, default=10)
    parser.add_argument('--seed', type=int, default=1000)
    parser.add_argument('--restore-profile', action='store_true')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--templates', type=Path, help='prebuilt uniquely numbered complex64 templates and .json sidecar')
    parser.add_argument('--allow-unrecognized-rx', action='store_true',
                        help='controlled conducted serial delivery test: retain unknown outputs as errors; require exact planned payloads')
    parser.add_argument('--template-cache-dir', help='owned /tmp/lora-finite-cache-<32 hex digits>; caller retires it after the campaign')
    args = parser.parse_args()
    if args.template_cache_dir and not re.fullmatch(r'/tmp/lora-finite-cache-[0-9a-f]{32}', args.template_cache_dir):
        parser.error('template cache must be /tmp/lora-finite-cache-<32 hex digits>')
    if ((args.receiver == 'pl' and (args.sf != 7 or args.bw != 125))
            or not 7 <= args.sf <= 12 or args.bw not in (125,250,500)
            or not 1 <= args.cr <= 4 or args.tx_rate != 1e6
            or not 1 <= args.packets <= 500 or args.first_sequence < 0
            or args.first_sequence + args.packets > 2**32 or args.gap < 0.15
            or not 0 <= args.rx_gain <= 73 or not 0 <= args.tx_atten <= 89.75
            or not all(math.isfinite(x) for x in [*args.snr, args.gap, args.rx_gain, args.tx_atten])
            or len(set(args.snr)) != len(args.snr)):
        parser.error('PL requires SF7/BW125; serial supports SF7..12/BW125/250/500; use 1MS/s, CR1..4, valid RF values, 1..500 distinct packets and gap >=0.15s')
    if args.out.exists(): parser.error('output exists; select a new series path')
    build_info = json.loads((args.bin_dir / 'per-tools-manifest.json').read_text(encoding='utf-8'))
    if not build_info['target'].startswith('arm'): parser.error('board binaries require an ARM compiler')
    for name in ('lora_trace_stream', 'lora_tx_noise'):
        if (sha256(args.bin_dir / name) != build_info['files'][name]['binary_sha256'] or
                sha256(ROOT / 'board/per' / (name + '.c')) != build_info['files'][name]['source_sha256']):
            parser.error('board tools/source differ from build manifest; rebuild before measuring')
    args.out.parent.mkdir(parents=True, exist_ok=True)
    if args.receiver != 'pl' and not args.templates:
        from lora_tx_waveform import packet_waveform
        from lora_per_ideal import test_payload
        estimate = packet_waveform(test_payload(args.first_sequence),args.sf,args.bw*1000,args.cr,args.tx_rate).size*8
        if estimate*args.packets > 384*1024**2:
            parser.error(f'template batch too large for the board RAM filesystem; use --packets <= {384*1024**2//estimate} and aggregate distinct finite batches')
    tpl = args.out.with_suffix('.c64')
    if args.templates:
        tpl = args.templates
    else:
        subprocess.run([sys.executable, str(ROOT / 'tools/lora_tx_waveform.py'), '--templates',
                        '--sf', str(args.sf), '--bw', str(args.bw), '--cr', str(args.cr),
                        '--packets', str(args.packets), '--first-sequence', str(args.first_sequence),
                        '--fs', str(args.tx_rate), '--out', str(tpl)], check=True)
    sidecar = json.loads(tpl.with_suffix(tpl.suffix + '.json').read_text(encoding='utf-8'))
    expected = dict(sf=args.sf, bw_khz=args.bw, cr=args.cr, packets=args.packets,
                    first_sequence=args.first_sequence, sample_rate=args.tx_rate)
    if any(sidecar.get(k) != v for k, v in expected.items()):
        parser.error('template sidecar does not match requested profile/sequence range')
    spp = sidecar['samples_per_packet']
    if not isinstance(spp, int) or spp <= 0 or tpl.stat().st_size != args.packets*spp*8:
        parser.error('invalid template dimensions/file size')
    if 'trials' in sidecar:
        trials = sidecar['trials']
        if (len(trials) != args.packets or {t['sequence'] for t in trials} !=
                set(range(args.first_sequence, args.first_sequence+args.packets))
                or any(not math.isfinite(t['start_offset_samples']) or
                       not math.isfinite(t['cfo_hz']) for t in trials)):
            parser.error('invalid trial geometry/sequence range')
    report = {'schema': 'finite-per-v1', 'configuration': {
        k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items() if k != 'password'},
        'points': [], 'status': 'starting', 'source_files': {str(p.relative_to(ROOT)): sha256(p)
            for p in [Path(__file__), ROOT / 'tools/finite_bench.py', ROOT / 'tools/finite_serial_bench.py', ROOT / 'tools/lora_per_ideal.py', ROOT / 'tools/per_measure.py',
                      ROOT / 'tools/lora_tx_waveform.py', ROOT / 'board/per/lora_trace_stream.c',
                      ROOT / 'board/per/lora_tx_noise.c', ROOT / 'tools/build_per_tools.py']},
        'binaries': {name: sha256(args.bin_dir / name) for name in ['lora_trace_stream', 'lora_tx_noise']},
        'templates_sha256': sha256(tpl), 'template_sidecar': sidecar, 'samples_per_packet': spp}
    report['build_provenance'] = build_info
    archive = args.out.with_suffix('.sources.zip')
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as z:
        for name in report['source_files']: z.write(ROOT / name, name)
    report['source_archive'] = archive.name
    report['source_archive_sha256'] = sha256(archive)
    save(args.out, report)
    prefix = '/tmp/lora-finite-' + uuid.uuid4().hex
    report['remote_prefix'] = prefix
    c = bench.ssh(args.password, args.host, args.known_hosts)
    try:
        bench.tx_off(c)
        report['board_identity'] = bench.run(c, 'uname -a; sha256sum /mnt/mmcblk0p1/system_top.bit; iio_writedev -V')
        if args.receiver == 'pl':
            signature = bench.run(c, 'devmem 0x790405c8 32').strip().lower()
            if signature != '0x4c4f5241': raise RuntimeError('unexpected PL signature: ' + signature)
        if args.restore_profile:
            profile = args.out.with_suffix('.restore.sh')
            profile.write_bytes((ROOT / 'fpga/board/clg400/restore_rx_profile.sh').read_bytes().replace(b'\r\n', b'\n'))
            bench.put(c, profile, prefix + '.restore.sh')
            report['restore_log'] = bench.run(c, f'GAIN={args.rx_gain} LO=868100000 RATE=1000000 RX_FIR=generic sh {prefix}.restore.sh')
        report['rx_profile'] = bench.run(c, f'cat {bench.PHY}/in_voltage_sampling_frequency '
                                        f'{bench.PHY}/in_voltage0_gain_control_mode {bench.PHY}/in_voltage_filter_fir_en')
        if report['rx_profile'].split() != ['1000000', 'manual', '1']:
            raise RuntimeError('restore the 1MS/s manual-gain FIR profile first')
        bench.run(c, 'if pidof iio_readdev >/dev/null; then echo RX_DMA_ACTIVE; exit 1; fi')
        report['tx_profile'] = bench.run(c, f'cat {bench.PHY}/out_voltage_sampling_frequency {bench.PHY}/out_voltage_filter_fir_en {bench.PHY}/out_voltage_rf_bandwidth')
        if report['tx_profile'].split()[:2] != ['1000000','1']:
            raise RuntimeError('TX rate/FIR differs from the qualified 1MS/s profile')
        report['template_cache'] = stage_templates(c, tpl, prefix, args.template_cache_dir)
        for name, target in [('lora_trace_stream', '.trace'), ('lora_tx_noise', '.noise')]:
            bench.put(c, args.bin_dir / name, prefix + target)
        bench.run(c, f'chmod +x {prefix}.trace {prefix}.noise')
        if args.receiver == 'pl':
            bench.run(c, 'devmem 0x79040404 32 0x1203; sleep 0.1; devmem 0x79040404 32 0x1201')
        report['temps_start'] = bench.board_temps(c)
        report['tx_state'] = bench.tx_configure(c, args.tx_atten)
        report['gain_readback'] = bench.run(c, f'set -e; echo {args.rx_gain} > {bench.PHY}/in_voltage0_hardwaregain; '
                                          f'echo {args.rx_gain} > {bench.PHY}/in_voltage1_hardwaregain; '
                                          f'cat {bench.PHY}/in_voltage0_hardwaregain')
        for i, snr in enumerate(args.snr):
            report['points'].append({})
            def checkpoint(point):
                report['points'][-1] = point
                save(args.out, report)
            if args.receiver == 'pl':
                point = measure(c, args, prefix, spp, snr, args.seed+i, checkpoint)
            else:
                from finite_serial_bench import measure_serial
                point = measure_serial(c, args, prefix, spp, snr, args.seed+i, checkpoint,
                                       start_tx, generator_summary)
            print(f"SNR {snr:+g}: {point['received_unique']}/{args.packets}, PER={point['per']}, ToA={point['usable_toa']}, valid={point['measurement_valid']}", flush=True)
            if not point['measurement_valid']: raise RuntimeError('invalid measurement; inspect preserved records/logs')
        report['status'] = 'complete'
    except BaseException as exc:
        report.update(status='interrupted', error=f'{type(exc).__name__}: {exc}')
        raise
    finally:
        try:
            bench.tx_off(c)
            report['temps_end'] = bench.board_temps(c)
            report['final_tx_state'] = bench.run(c, f'cat {bench.PHY}/out_altvoltage1_TX_LO_powerdown {bench.PHY}/out_voltage0_hardwaregain')
            # Logs and templates are preserved on the host; retire only this UUID.
            if report['status'] == 'complete':
                files = ['.c64', '.trace', '.noise', '.restore.sh', '.capture.pid',
                         '.producer.pid', '.noise.err', '.writer.log']
                bench.run(c, 'rm -f ' + ' '.join(prefix + name for name in files))
        finally:
            c.close()
            save(args.out, report)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
