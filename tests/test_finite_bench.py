from pathlib import Path
import shutil
import subprocess
import sys
import signal
import time
from types import SimpleNamespace

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import finite_bench as bench
from finite_per_measure import generator_summary, save
import per_measure
from analyze_finite_toa import analyze


def line(**overrides):
    values = dict(cap='2', pbin='0', realigned='1', n='64', p0seq='3',
                  p0coarse='0x123456789abcdef0', p0frac='-123', p0status='0x11207',
                  p0log='42', p0debug='0x0', joint='0x4a540011', clock_status='0x434b0000',
                  drop_before='2', drop_after='2', p0fresh='1', changed='0', sym='00'*128)
    values.update(overrides)
    return 'PKT 456 ' + ' '.join(f'{k}={v}' for k, v in values.items())


@pytest.fixture
def decode(monkeypatch):
    monkeypatch.setattr(bench, 'decode_lora_symbol_trace', lambda *a: SimpleNamespace(
        result=SimpleNamespace(crc_valid=True, header=SimpleNamespace(payload_crc=True),
                               payload=b'ZLP1'+(12).to_bytes(4, 'little'))))


def test_crc_disabled_header_cannot_bypass_finite_bench_crc_policy():
    from zynq_lora_phy import encode_lora_packet
    data = b'ZLP1' + (12).to_bytes(4, 'little')
    symbols = encode_lora_packet(data, payload_crc_present=False).symbols
    decoded = bench.decode_lora_symbol_trace(symbols, 0).result
    assert decoded.crc_valid and decoded.payload == data and not decoded.header.payload_crc
    r = bench.parse_record(line(n=str(len(symbols)), sym=bytes(symbols).hex().ljust(256, '0')))
    assert r['kind'] == 'packet' and r['capture_valid']
    assert not r['crc'] and r['seq'] is None and not r['payload_crc_enabled']
    summary = bench.summarize([r], 12, 1, tx_complete=True, collection_complete=True)
    assert summary['measurement_valid'] and summary['received_unique'] == 0
    assert summary['per'] == 1 and summary['crc_fail'] == 1


def test_full_timestamp_retains_64_bit_precision_and_raw_record(decode):
    raw = line()
    r = bench.parse_record(raw)
    assert r['toa_samples_q12'] == 0x123456789abcdef0 * 4096 - 123
    assert r['raw'] == raw and r['cap'] == 2 and r['p0seq'] == 3
    assert r['toa_valid'] and r['seq'] == 12


@pytest.mark.parametrize('fields,reason', [({'changed': '1'}, 'snapshot_changed'),
    ({'p0fresh': '0'}, 'stale_metadata'), ({'drop_after': '3'}, 'sample_drop'),
    ({'joint': '0x4a540003'}, 'joint_not_applied'),
    ({'p0status': '0x1120f'}, 'metadata_overflow')])
def test_untrusted_toa_is_preserved_with_reason(decode, fields, reason):
    r = bench.parse_record(line(**fields))
    assert not r['toa_valid'] and reason in r['toa_rejection_reasons']
    assert 'p0coarse' in r and r['kind'] == 'packet'


@pytest.mark.parametrize('raw', [line(sym='ff'), line(n='129'), line(changed='2'),
                                line()+' cap=99', 'PKT invalid cap=1', 'PKT 4 cap=1'])
def test_malformed_attempt_is_not_dropped(raw):
    r = bench.parse_record(raw)
    assert r['kind'] == 'invalid' and r['raw'] == raw and r['error']


def test_timeout_status_is_preserved():
    assert bench.parse_record('TIMEOUT 10 status=0x53590000')['status'] == 0x53590000


def packet(seq):
    return dict(kind='packet', capture_valid=True, crc=True, seq=seq, cap=seq, toa_valid=True)


def test_exact_denominator_includes_leading_trailing_and_long_losses():
    r = bench.summarize([packet(103), packet(170)], 100, 100,
                        tx_complete=True, collection_complete=True)
    assert (r['received_unique'], r['lost'], r['per']) == (2, 98, 0.98)
    assert not r['outcomes'][0]['crc_valid'] and not r['outcomes'][-1]['crc_valid']


def test_no_success_is_still_a_finite_per():
    r = bench.summarize([], 0, 20, tx_complete=True, collection_complete=True)
    assert r['per'] == 1 and r['lost'] == 20


def test_duplicates_and_unexpected_id_are_not_extra_successes():
    r = bench.summarize([packet(3), packet(3), packet(1000)], 0, 10,
                        tx_complete=True, collection_complete=True)
    assert r['duplicates'] == 1 and r['received_unique'] == 1
    assert r['unexpected_sequences'] == [1000] and r['per'] is None


@pytest.mark.parametrize('tx,collection,records', [(False, True, []), (True, False, []),
                         (True, True, [{'kind': 'invalid'}])])
def test_failed_collection_cannot_claim_qualified_per(tx, collection, records):
    r = bench.summarize(records, 0, 10, tx_complete=tx, collection_complete=collection)
    assert r['per'] is None and not r['measurement_valid']


def test_checkpoint_replaces_complete_json(tmp_path):
    import json
    p = tmp_path / 'point.json'
    save(p, {'records': [1]}); save(p, {'records': [1, 2], 'error': 'stopped'})
    assert json.loads(p.read_text()) == {'records': [1, 2], 'error': 'stopped'}


def test_nonzero_remote_exit_is_not_hidden():
    class Output:
        channel = SimpleNamespace(recv_exit_status=lambda: 1)
        def read(self): return b'failed'
    c = SimpleNamespace(exec_command=lambda *a, **k: (None, Output(), Output()))
    with pytest.raises(RuntimeError, match='exited 1'): per_measure.run(c, 'false')


def test_checkpoint_survives_transient_windows_reader_lock(tmp_path, monkeypatch):
    import json
    p = tmp_path / 'point.json'
    save(p, {'records': [1]})
    replace = Path.replace
    calls = []
    def temporarily_locked(source, target):
        calls.append(1)
        if len(calls) < 3:
            assert json.loads(p.read_text()) == {'records': [1]}
            raise PermissionError('reader holds destination')
        return replace(source, target)
    monkeypatch.setattr(Path, 'replace', temporarily_locked)
    save(p, {'records': [1, 2]})
    assert json.loads(p.read_text()) == {'records': [1, 2]} and len(calls) == 3


@pytest.fixture
def generator(tmp_path):
    gcc = shutil.which('gcc')
    if not gcc: pytest.skip('native gcc required; runs in Linux CI/WSL')
    binary = tmp_path / 'noise'
    source = Path(__file__).resolve().parents[1] / 'board/per/lora_tx_noise.c'
    subprocess.run([gcc, '-O2', '-Wall', '-Wextra', '-Werror', str(source), '-lm', '-o', str(binary)], check=True)
    templates = tmp_path / 'templates.c64'
    np.ones(3 * 32, dtype=np.complex64).tofile(templates)
    return binary, templates


def test_finite_generator_completes_aligned_stream_and_clipping_count(generator):
    binary, templates = generator
    r = subprocess.run([str(binary), str(templates), '3', '32', '8', '20', '125000', '-14',
                        '42', '1000000', '3', '10', '20'], capture_output=True, check=True)
    summary = generator_summary(r.stderr.decode())
    assert summary['packets_completed'] == 3 and summary['complete'] == 1
    assert summary['samples_written'] == 262144 and len(r.stdout) == 262144*4
    assert summary['clipped_components'] == 0


def test_short_template_series_is_an_error(generator):
    binary, templates = generator
    templates.write_bytes(templates.read_bytes()[:32*8])
    r = subprocess.run([str(binary), str(templates), '3', '32', '8', '20', '125000', '-14',
                        '42', '1000000', '3'], capture_output=True)
    assert r.returncode != 0 and generator_summary(r.stderr.decode())['complete'] == 0


def test_relative_timing_keeps_subsample_precision_at_large_counter():
    records = [dict(kind='packet', capture_valid=True, crc=True, toa_valid=True,
                    seq=i, toa_samples_q12=(2**60 + i*100)*4096 + (100 if i == 2 else 0))
               for i in range(5)]
    series = {'schema': 'finite-per-v1', 'configuration': dict(tx_rate=1e6, gap=0,
              first_sequence=0, packets=5), 'samples_per_packet': 100,
              'points': [dict(snr_db=20, per=0, measurement_valid=True, records=records)]}
    result = analyze(series)['points'][0]
    assert 0 < result['affine_residual_std_ns'] < 20
    assert result['usable_unique_toa'] == 5 and abs(result['clock_scale_ppm']) < 1e-6
    assert not result['sample_counter_continuity_valid']
    assert not result['sample_counter_continuity_observed']


def test_generator_reports_clipping_instead_of_claiming_zero(generator):
    binary, templates = generator
    r = subprocess.run([str(binary), str(templates), '3', '32', '8', '20', '125000', '10',
                        '42', '1000000', '3'], capture_output=True, check=True)
    assert generator_summary(r.stderr.decode())['clipped_components'] > 0


def test_interrupted_generator_reports_incomplete_counters(generator):
    binary, templates = generator
    p = subprocess.Popen([str(binary), str(templates), '3', '32', '8', '20', '125000', '-14'],
                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    time.sleep(0.1)
    p.send_signal(signal.SIGTERM)
    _, err = p.communicate(timeout=5)
    assert p.returncode != 0
    summary = generator_summary(err.decode())
    assert summary['complete'] == 0 and summary['signal'] == signal.SIGTERM


def test_invalid_generator_number_is_rejected(generator):
    binary, templates = generator
    r = subprocess.run([str(binary), str(templates), '3', '32', '8', 'nan', '125000', '-14'],
                       capture_output=True)
    assert r.returncode == 2 and not r.stdout


def test_joint_diagnostics_preserve_sign_and_mark_stale_values(decode):
    r = bench.parse_record(line(joint_correction='-2', joint_up_offset='-4',
                                joint_up_coarse='100', joint_packet_start='90', joint_phase_bin='0x10002'))
    assert r['joint_correction'] == -2 and r['joint_diagnostics_valid']
    stale = bench.parse_record(line(joint_correction='-2', p0fresh='0'))
    assert stale['joint_correction'] == -2 and not stale['joint_diagnostics_valid']


def test_cfo_groups_use_zero_cfo_control_instead_of_fitting_away_bias():
    rows = [dict(kind='packet',capture_valid=True,crc=True,toa_valid=True,seq=i,
                 toa_samples_q12=i*100*4096+(100 if i%2 else 0)) for i in range(8)]
    trials = [dict(sequence=i,start_offset_samples=0,cfo_hz=1000.0 if i%2 else 0.0) for i in range(8)]
    r = analyze({'schema':'finite-per-v1', 'configuration':dict(tx_rate=1e6,gap=0,first_sequence=0,packets=8),
                 'samples_per_packet':100,'template_sidecar':{'trials':trials},
                 'points':[dict(snr_db=20,records=rows)]})
    groups=r['points'][0]['zero_cfo_reference']['groups']
    assert groups['1000.0']['median_error_ns'] == pytest.approx(100/4096*1000,abs=1e-6)
    assert abs(groups['0.0']['median_error_ns']) < 1e-6


def test_control_outlier_does_not_move_reference_or_disappear():
    rows = [dict(kind='packet',capture_valid=True,crc=True,toa_valid=True,seq=i,
                 toa_samples_q12=(i*100+(1024 if i == 0 else 0))*4096+
                                   (100 if i%2 else 0)) for i in range(20)]
    trials = [dict(sequence=i,start_offset_samples=0,cfo_hz=1000.0 if i%2 else 0.0) for i in range(20)]
    result = analyze({'schema':'finite-per-v1',
                      'configuration':dict(tx_rate=1e6,gap=0,first_sequence=0,packets=20),
                      'samples_per_packet':100,'template_sidecar':{'trials':trials},
                      'points':[dict(snr_db=20,records=rows)]})['points'][0]['zero_cfo_reference']
    assert result['groups']['1000.0']['median_error_ns'] == pytest.approx(100/4096*1000,abs=1e-6)
    assert result['groups']['0.0']['over_one_sample'] == 1
    assert result['groups']['0.0']['count'] == 10
    assert max(s['error_ns'] for s in result['samples']) == pytest.approx(1024000)


def test_timeout_retains_acquisition_and_clock_outcomes_without_packet():
    r = bench.parse_record('TIMEOUT 1000 status=0x53590000 joint=0x4a540200 clock_status=0x434b0001 drop_before=4 drop_after=5')
    assert r['kind'] == 'timeout' and r['joint'] & 512
    assert r['drop_before'] == 4 and r['drop_after'] == 5
    assert not r.get('toa_valid', False)
