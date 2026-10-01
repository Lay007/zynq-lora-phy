"""Measure interval repeatability after removing epoch and linear clock scale.

This is a relative, conditional timing study. It cannot establish RF arrival
bias, absolute accuracy, or inter-receiver synchronization from a loopback.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
import hashlib
from pathlib import Path

import numpy as np


def robust_line(x: np.ndarray, y: np.ndarray) -> tuple[float, float]:
    """Median pairwise slope and median intercept; keep every residual afterward."""
    slopes = [(y[j] - y[i]) / (x[j] - x[i])
              for i in range(len(x)) for j in range(i+1, len(x)) if x[j] != x[i]]
    if not slopes:
        raise ValueError('control timestamps must span distinct transmissions')
    slope = float(np.median(slopes))
    return slope, float(np.median(y - slope*x))


def analyze(report: dict) -> dict:
    if report.get('schema') != 'finite-per-v1': raise ValueError('unsupported finite series schema')
    config = report['configuration']
    fs = float(config['tx_rate'])
    period = report['samples_per_packet'] + int(config['gap'] * fs)
    trials = {t['sequence']: t for t in report.get('template_sidecar', {}).get('trials', [])}
    points = []
    for point in report['points']:
        rows = [r for r in point['records'] if r.get('capture_valid') and r.get('crc')
                and r.get('toa_valid') and r.get('seq') is not None
                and config['first_sequence'] <= r['seq'] < config['first_sequence'] + config['packets']]
        counts = Counter(r['seq'] for r in rows)
        rows = sorted([r for r in rows if counts[r['seq']] == 1], key=lambda r: r['seq'])
        result = {'snr_db': point['snr_db'], 'planned_transmissions': config['packets'],
                  'qualified_per': point.get('per'), 'measurement_valid': point.get('measurement_valid', False),
                  'usable_unique_toa': len(rows),
                  'toa_rejection_reasons': dict(Counter(reason for r in point['records']
                      for reason in r.get('toa_rejection_reasons', [])))}
        drop_counts = {r[k] for r in point['records'] if r.get('kind') in ('packet', 'timeout')
                       for k in ('drop_before', 'drop_after') if k in r}
        result['sample_counter_continuity_valid'] = len(drop_counts) <= 1
        result['drop_counter_values'] = sorted(drop_counts)
        if len(rows) >= 3:
            # Subtract the integer epoch before conversion, retaining small Q12
            # differences even when a 64-bit coarse timestamp is above 2**53.
            origin = trials.get(rows[0]['seq'], {}).get('start_offset_samples', 0)
            tx = np.array([(r['seq'] - rows[0]['seq']) * period +
                           trials.get(r['seq'], {}).get('start_offset_samples', 0) - origin
                           for r in rows], dtype=float)
            rx = np.array([(r['toa_samples_q12'] - rows[0]['toa_samples_q12']) / 4096 for r in rows])
            slope, offset = np.linalg.lstsq(np.column_stack((tx, np.ones(len(tx)))), rx, rcond=None)[0]
            residual = rx - (slope * tx + offset)
            interval_error = np.diff(rx) - np.diff(tx)
            result.update(clock_scale_ppm=float((slope - 1) * 1e6),
                          affine_residual_std_ns=float(np.std(residual, ddof=1) / fs * 1e9),
                          affine_residual_rmse_ns=float(np.sqrt(np.mean(residual**2)) / fs * 1e9),
                          affine_residual_abs_p95_ns=float(np.percentile(np.abs(residual), 95) / fs * 1e9),
                          affine_residual_abs_p99_ns=float(np.percentile(np.abs(residual), 99) / fs * 1e9),
                          interval_error_std_ns=float(np.std(interval_error, ddof=1) / fs * 1e9),
                          samples=[{'seq': r['seq'], 'affine_residual_ns': float(e / fs * 1e9)}
                                   for r, e in zip(rows, residual)])
            if trials:
                groups = {}
                for row, e in zip(rows, residual):
                    cfo = str(trials[row['seq']]['cfo_hz'])
                    groups.setdefault(cfo, []).append(float(e / fs * 1e9))
                result['by_injected_cfo_hz'] = {key: {'count': len(values),
                    'residual_mean_ns': float(np.mean(values)),
                    'residual_std_ns': float(np.std(values, ddof=1)) if len(values)>1 else None}
                    for key, values in groups.items()}
                control = np.array([trials[r['seq']]['cfo_hz'] == 0 for r in rows])
                if np.count_nonzero(control) >= 3:
                    ca, cb = robust_line(tx[control], rx[control])
                    errors = rx - (ca*tx+cb)
                    control_groups = {}
                    for row, error in zip(rows, errors):
                        key = str(trials[row['seq']]['cfo_hz'])
                        control_groups.setdefault(key, []).append(float(error))
                    result['zero_cfo_reference'] = {
                        'interpretation': 'median pairwise slope/median epoch on zero-CFO controls; all records, including control outliers, retained in residuals',
                        'fit_method': 'median pairwise slope and median intercept',
                        'clock_scale_ppm': float((ca-1)*1e6),
                        'groups': {key: {'count':len(values),
                            'median_error_ns':float(np.median(values)/fs*1e9),
                            'std_ns':float(np.std(values,ddof=1)/fs*1e9) if len(values)>1 else None,
                            'abs_p95_ns':float(np.percentile(np.abs(values),95)/fs*1e9),
                            'abs_p99_ns':float(np.percentile(np.abs(values),99)/fs*1e9),
                            'over_one_sample':int(np.count_nonzero(np.abs(values)>1))}
                            for key,values in control_groups.items()},
                        'samples': [{'seq':r['seq'],'cfo_hz':trials[r['seq']]['cfo_hz'],
                                     'error_ns':float(e/fs*1e9)} for r,e in zip(rows,errors)]}
        points.append(result)
    return {'schema': 'finite-toa-repeatability-v1', 'sample_rate_hz': fs, 'period_samples': period,
            'analysis_source_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'interpretation': 'conditional repeatability after fitted epoch and linear clock scale; not absolute RF ToA accuracy',
            'points': points}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('series', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    result = analyze(json.loads(args.series.read_text(encoding='utf-8')))
    result['input_sha256'] = hashlib.sha256(args.series.read_bytes()).hexdigest()
    args.out.write_text(json.dumps(result, indent=2, allow_nan=False) + '\n', encoding='utf-8')
