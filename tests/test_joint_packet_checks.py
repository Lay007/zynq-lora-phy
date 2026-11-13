from dataclasses import replace
import json
import subprocess
import sys
from types import SimpleNamespace

import numpy as np
import pytest

from tools.joint_packet_checks import Case, cases_for_suite, evaluate, resample_clock, stimulus, summarize
from tools.lora_per_ideal import test_payload as payload_for
from tools.lora_tx_waveform import packet_waveform
from zynq_lora_phy import encode_lora_packet


PAYLOAD = payload_for(1234)
CASE = Case(0, 0, 8, 0)
TRUTH = dict(expected_origin_samples=2048, header_start_sample=14592, input_samples=20000)


def trace(*, coarse=2048, fraction=0, payload=PAYLOAD, fine=14000):
    symbols = encode_lora_packet(payload).symbols
    lines = ['DET 0 0 n=12000 straddle=0 split=0 early=0']
    lines += [f'SYM {symbol} {13000 + i * 1024}' for i, symbol in enumerate(symbols)]
    lines += [f'META {coarse} {fraction}',
              f'LATENCY joint_total_clocks=250000 down_to_fine_clocks=55613 n={fine} '
              'cfo_q12=0 detection_to_fine_clocks=120000',
              'DONE detected=1 samples=20000']
    return '\n'.join(lines) + '\n'


def test_packet_trace_requires_crc_payload_timestamp_and_deadline():
    row = evaluate(CASE, trace(), PAYLOAD, TRUTH)
    assert row['passed'] and row['failures'] == []
    assert row['metadata_count'] == 1 and row['toa_error_samples'] == 0
    assert row['header_margin_samples'] == 592


@pytest.mark.parametrize('change,reason', [
    ({'coarse': 3072}, 'toa_error'),
    ({'fraction': 2048}, 'toa_error'),
    ({'fraction': -2048}, 'toa_error'),
    ({'fraction': 2049}, 'fractional_range'),
    ({'fine': 14496}, 'header_margin'),
    ({'payload': payload_for(1235)}, 'payload_match'),
])
def test_crc_success_cannot_hide_wrong_epoch_fraction_deadline_or_payload(change, reason):
    row = evaluate(CASE, trace(**change), PAYLOAD, TRUTH)
    assert row['crc_valid'] and not row['passed'] and reason in row['failures']


def test_no_packet_and_duplicate_metadata_stay_in_denominator():
    good = evaluate(CASE, trace(), PAYLOAD, TRUTH)
    missed = evaluate(CASE, 'DONE detected=0 samples=20000\n', PAYLOAD, TRUTH)
    duplicate = evaluate(CASE, trace() + 'META 2048 0\n', PAYLOAD, TRUTH)
    report = summarize([good, missed, duplicate], 4)
    assert report['counts'] == dict(planned=4, completed=3, passed=1, failed=2,
                                    missing=1, detection_misses=1, missing_metadata=1,
                                    ambiguous_metadata=1, crc_valid=2, toa_observations=1)
    assert duplicate['toa_error_samples'] is None and not report['passed']


def test_statistics_keep_outliers_and_timestamps_from_failed_decodes():
    good = evaluate(CASE, trace(), PAYLOAD, TRUTH)
    bad = evaluate(CASE, 'META 2050 0\nDONE detected=0 samples=20000\n', PAYLOAD, TRUTH)
    report = summarize([good, bad], 2)
    assert report['counts']['toa_observations'] == 2
    assert report['toa']['bias_samples'] == 1
    assert report['toa']['rmse_samples'] == pytest.approx(np.sqrt(2))
    assert report['toa']['abs_p95_samples'] == pytest.approx(1.9)
    assert report['toa']['abs_p99_samples'] == pytest.approx(1.98)
    assert report['toa']['outliers'] == 1


@pytest.mark.parametrize('output,code,reason', [
    (trace().replace('DONE detected=1 samples=20000\n', ''), 0, 'incomplete_trace'),
    (trace().replace('samples=20000', 'samples=19999'), 0, 'incomplete_trace'),
    (trace(), 1, 'simulator_exit'),
    (trace() + 'DET 0 0 n=19999\n', 0, 'detection_count'),
])
def test_partial_and_failed_simulations_cannot_pass(output, code, reason):
    row = evaluate(CASE, output, PAYLOAD, TRUTH, code)
    assert not row['passed'] and reason in row['failures']


def test_empty_report_is_json_serializable_and_incomplete():
    report = summarize([], 17)
    assert not report['passed'] and report['toa'] is None
    json.dumps(report, allow_nan=False)


@pytest.mark.parametrize('case', cases_for_suite('baseline'), ids=lambda c: c.name)
def test_baseline_stimuli_remain_bit_exact(case):
    # Independent reproduction of the original 17-case driver's stimulus.
    clean = packet_waveform(PAYLOAD, 7, 125000, 1)
    if case.preamble_symbols == 8:
        clean = clean[4 * 1024:]
    samples = np.pad(clean, (2048 + case.phase, 2048))
    if case.fractional_delay:
        samples = np.fft.ifft(np.fft.fft(samples) * np.exp(
            -2j * np.pi * np.fft.fftfreq(len(samples)) * case.fractional_delay))
    samples = samples * np.exp(2j * np.pi * case.cfo_hz / 1e6 * np.arange(len(samples))) * 400
    expected = ((np.rint(samples.real).astype(np.int64) & 65535) << 16) | (
        np.rint(samples.imag).astype(np.int64) & 65535)
    words, _ = stimulus(case, PAYLOAD)
    np.testing.assert_array_equal(words, expected)


@pytest.mark.parametrize('sfo', [-10000, 10000])
def test_sfo_sign_and_event_coordinate_are_consistent(sfo):
    ramp = np.arange(101, dtype=complex)
    warped = resample_clock(ramp, sfo)
    assert warped[50] == pytest.approx(50 * (1 + sfo * 1e-6))
    case = Case(512, 1000, 12, .75, sfo)
    _, truth = stimulus(case, PAYLOAD)
    assert truth['expected_origin_samples'] * (1 + sfo * 1e-6) == pytest.approx(6656.75)
    assert truth['header_start_sample'] * (1 + sfo * 1e-6) == pytest.approx(19200.75)


def unpack(words):
    real = (words >> 16).astype(np.uint16).view(np.int16).astype(float)
    imag = (words & 65535).astype(np.uint16).view(np.int16).astype(float)
    return (real + 1j * imag) / 400


def test_seeded_noise_uses_packet_power_and_bandwidth_not_guard_power():
    noisy = replace(CASE, snr_db=10, seed=123)
    words, truth = stimulus(noisy, PAYLOAD)
    repeated, repeated_truth = stimulus(noisy, PAYLOAD)
    clean, _ = stimulus(CASE, PAYLOAD)
    np.testing.assert_array_equal(words, repeated)
    assert truth == repeated_truth
    noise = unpack(words) - unpack(clean)
    # At 10 dB in BW=Fs/8, total complex noise variance is 0.8.
    assert np.mean(np.abs(noise) ** 2) == pytest.approx(.8, rel=.03)
    assert np.mean(np.abs(noise[:2048]) ** 2) == pytest.approx(.8, rel=.10)


def test_timing_matrix_has_paired_clean_noisy_cases_and_both_sfo_signs():
    cases = cases_for_suite('timing')
    assert len(cases) == len({case.name for case in cases}) == 16
    assert {case.sfo_ppm for case in cases} == {-20, 20}
    assert {case.snr_db for case in cases} == {None, 10}


def test_cli_does_not_overwrite_existing_evidence(tmp_path):
    evidence = tmp_path / 'results.json'
    evidence.write_text('[{"original": true}]')
    result = subprocess.run([sys.executable, 'tools/joint_packet_regression.py',
                             '--out', str(tmp_path)], capture_output=True, text=True)
    assert result.returncode != 0 and 'never overwritten' in result.stderr
    assert evidence.read_text() == '[{"original": true}]'


@pytest.mark.parametrize('timeout', [False, True])
def test_runner_checkpoints_failure_and_continues_with_next_packet(tmp_path, monkeypatch, timeout):
    from tools import joint_packet_regression as runner

    monkeypatch.chdir(runner.TREE)
    monkeypatch.setattr(sys, 'argv', ['joint_packet_regression.py', '--out', str(tmp_path)])
    monkeypatch.setattr(runner, 'cases_for_suite', lambda _: [CASE, replace(CASE, phase=1)])
    monkeypatch.setattr(runner, 'stimulus', lambda *_: (np.zeros(20000, dtype=np.int64), TRUTH))
    monkeypatch.setattr(runner.subprocess, 'check_output', lambda *a, **k: 'test simulator')
    calls = []

    def simulate(command, **kwargs):
        if command[0] == 'verilator':
            return SimpleNamespace(returncode=0)
        calls.append(command)
        if len(calls) == 1:
            if timeout:
                raise subprocess.TimeoutExpired(command, 1, output=b'partial trace\n')
            return SimpleNamespace(returncode=0, stdout='DONE detected=0 samples=20000\n')
        checkpoint = json.loads((tmp_path / 'summary.json').read_text())
        assert checkpoint['counts']['failed'] == checkpoint['counts']['missing'] == 1
        return SimpleNamespace(returncode=0, stdout=trace())

    monkeypatch.setattr(runner.subprocess, 'run', simulate)
    assert runner.main() == 1 and len(calls) == 2
    report = json.loads((tmp_path / 'summary.json').read_text())
    assert report['counts']['completed'] == 2 and report['counts']['passed'] == 1
    rows = json.loads((tmp_path / 'results.json').read_text())
    assert rows[1]['passed'] and not rows[0]['passed']
    assert ('simulator_timeout' in rows[0]['failures']) == timeout
