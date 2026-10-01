# Fractional time-of-arrival methodology

[Русская версия](ru/toa-methodology.md)

The floating-point reference separates three timing quantities:

1. `startIndex` is MATLAB's one-based integer matched-filter peak.
2. `fractionalOffsetSamples` is the local correction in `[-0.5, 0.5]`.
3. `toaSamples = startIndex - 1 + fractionalOffsetSamples` is the zero-based
   timestamp used for measurement and later TDoA subtraction.

`lora_phy.estimate_fractional_toa` correlates a known complex reference with
the capture, normalizes every candidate by reference and window energy, and
fits a three-point parabola to the logarithm of the correlation magnitude
around the integer peak, bounded to +/-0.5 sample
(`matched-filter-log-magnitude-v1`; the MATLAB source gives 0.0066 sample RMS
against 0.0625 for a parabola on power). It
also reports normalized peak score and peak-to-sidelobe ratio. An optional
coarse start and search radius keep the fine estimator on the intended packet.

```matlab
toa = lora_phy.estimate_fractional_toa(iq, knownPreamble, Fs, ...
    CoarseStartIndex=coarseIndex, SearchRadiusSamples=8);
```

## Reproducible AWGN benchmark

`lora_phy.simulate_toa_accuracy` draws a uniform fractional delay for every
trial, adds complex AWGN, runs the estimator, and returns raw errors plus bias,
standard deviation, RMS error, and the 95th absolute-error percentile.

```matlab
result = lora_phy.simulate_toa_accuracy([-25; -20; -15; -10; -5], ...
    TrialsPerPoint=100, SpreadingFactor=7, SamplesPerChip=2, ...
    RandomSeed=31415);
```

The committed deterministic run gives 0.177 sample RMS error at -20 dB and
0.070 sample RMS error at -5 dB. At -25 dB the estimator crosses its threshold
region and reaches 1.50 samples RMS. These are algorithmic AWGN results, not an
absolute propagation-delay or hardware calibration claim.

![Fractional ToA accuracy in AWGN](images/toa-accuracy-awgn.png)

## Calibrated TDoA and 2D solution

`tdoa_from_toas` subtracts the fixed delay of every receiver before forming
differences relative to receiver 1. `predict_tdoa` implements the geometric
forward model. `solve_tdoa` uses weighted Gauss-Newton least squares and returns
the position, time residuals, convergence state, covariance approximation, and
geometry condition number. It accepts a full observation covariance: TDoA
errors are correlated because the reference-receiver timestamp appears in
every difference.

```matlab
tdoa = lora_phy.tdoa_from_toas(measuredToaSeconds, ...
    ReceiverDelaySeconds=calibratedChannelDelays);
position = lora_phy.solve_tdoa(receiverPositionsMeters, tdoa, ...
    MeasurementStdSeconds=timestampUncertaintySeconds);
```

The reproducible four-receiver Monte Carlo and its limitations are reported in
[MATLAB M1 floating-point acceptance](matlab-m1-acceptance.md).

![Calibrated 2D TDoA accuracy](images/tdoa-positioning-accuracy.png)

## Hardware acceptance sequence

When the bench is available, preserve the same estimator and replace the
synthetic source in this order:

1. cable loop with fixed attenuator, repeated at each SF/BW and gain setting;
2. estimate constant RF/baseband delay and temperature-dependent drift;
3. report bias, standard deviation, 95th percentile, outlier rate, and raw IQ
   checksum;
4. only then subtract calibrated receiver timestamps for TDoA and propagate
   their uncertainty into the weighted position solution.

The present estimator does not remove multipath bias, AD936x group delay,
buffer timestamp uncertainty, or clock offset. Those terms belong in the
calibration and uncertainty budget rather than in the AWGN curve.

For a curated reference sweep containing counter payloads, reproduce the
fixed-geometry OTA repeatability report with:

```matlab
addpath examples
result = evaluate_reference_toa(datasetDirectory, "toa-sf7-bw125", ...
    OutputDirectory=datasetDirectory);
```

The affine fit removes the unrelated TX/RX epochs and their linear clock-scale
error. The residual still includes transmitter timestamp quantization,
scheduling, RF/baseband latency variation, multipath, and RX estimation error.
