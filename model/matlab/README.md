# MATLAB floating-point model

This directory is the authoritative algorithm layer. It contains the CSS
waveform model, complete LoRa packet TX/RX, hard and soft coding chains,
continuous-IQ acquisition, fractional ToA, calibrated TDoA observations, and
weighted 2D multilateration.

Run all tests from MATLAB:

```matlab
cd model/matlab
results = run_tests;
assertSuccess(results);
```

Generate acquisition, uncoded CSS, and coded packet figures plus CSV tables:

```matlab
outputs = run_visualizations;
```

Reproduce the complete M1 packet and positioning acceptance campaign:

```matlab
addpath examples
report = run_m1_acceptance;
```

The symbol-demodulation figure can also be generated independently without
regenerating the Monte Carlo plots:

```matlab
addpath examples
[result, figureHandle] = plot_symbol_demodulation;
```

Open the visual IQ packet inspector:

```matlab
addpath apps
app = lora_phy_inspector;
```

It reads headerless RTL-SDR CU8 and Pluto/GNU Radio CF32 files and estimates the
strongest CSS burst's BW, SF, carrier offset, symbol duration, SNR, DC/IQ
impairments, and dechirped FFT bins. Generate a deterministic input with
`generate_inspector_demo_capture` from the `examples` directory. Full usage and
measurement limits are documented in
[`docs/lora-phy-inspector.md`](../../docs/lora-phy-inspector.md).

Package functions use column vectors and normalized CFO in cycles per sample.
For physical rate `Fs`, convert with `cfoNormalized = cfoHz / Fs`.

`lora_phy.apply_channel_impairments` provides a deterministic, toolbox-free
channel/front-end model for offline verification. It combines fractional
delay, multipath, sample-rate offset (SFO), carrier offset, I/Q gain and phase
imbalance, DC offset, and seeded complex AWGN:

```matlab
rx = lora_phy.apply_channel_impairments(tx, Fs, ...
    FractionalDelaySamples=2.25, SampleRateOffsetPpm=20, ...
    MultipathDelaysSamples=[0; 3.5], MultipathGains=[1; 0.3j], ...
    FrequencyOffsetHz=1800, IqGainImbalanceDb=0.5, ...
    IqPhaseImbalanceDegrees=2, SnrDb=-8, RandomSeed=42);
```

Positive SFO advances through the nominal transmit samples faster; positive
fractional delay moves the received waveform later. The output length is
always equal to the input length, with zeros outside the interpolated range.

Export the committed deterministic packet vector after changing a coding block:

```matlab
vector = export_golden_vectors;
```

Export the stage-level FFT-correlator vectors consumed by Simulink and, later,
by HDL cosimulation:

```matlab
manifest = export_correlator_stage_vectors;
```

The 15 committed cases live in `golden/fft-correlator/`. Their construction,
file format, and guard tests are documented in
[`docs/simulink-m2-interfaces.md`](../../docs/simulink-m2-interfaces.md).
`lora_phy.fft_correlator_stages` is the single numerical definition of the
correlator: `lora_phy.fft_correlator_metrics` is a thin wrapper around it, so
the exported vectors cannot drift away from the receiver.

Avoid HDL-specific optimizations here; those belong in the Simulink stage.

## Current frame receiver

`build_css_frame` creates a research acquisition frame with eight upchirps, two
downchirps, and uncoded payload symbols. `receive_css_frame` searches all
integer-sample start candidates, estimates CFO from the first upchirp, and
demodulates the requested payload length. This deliberately tests acquisition
independently of the packet-coding path and exact LoRa sync-word waveform.

## Standard on-air packet receiver

`encode_packet` produces CSS symbol indices and exposes every intermediate
vector. `decode_packet` accepts hard symbol decisions. `receive_lora_packet`
adds acquisition of a standard LoRa preamble, two sync-word symbols, the
2.25-downchirp SFD, CFO correction, timing search, explicit-header decoding,
deinterleaving, FEC, dewhitening, and payload CRC validation. SX126x SF5/SF6
explicit-header framing and inverted IQ are supported.

Decode and visualize the committed Heltec/SX1262 reference capture:

```matlab
d = "../../captures/reference/2026-08-03-heltec-v43-zynqsdr-mode-sweep";
[iq, ~] = lora_phy.load_iq_capture(fullfile(d, "sf7-bw125.cf32"), "cf32");
rx = lora_phy.receive_lora_packet(iq, 1e6, 125e3, 7, ...
    PreambleSymbols=12, SyncWord=hex2dec("12"), ...
    ExpectedCarrierOffsetHz=-250e3);
lora_phy.visualize_lora_packet(iq, 1e6, rx);
```

Run the entire hardware matrix with `decode_reference_sweep` from `examples`.
For every packet plus BER/PER counters, run:

```matlab
addpath examples
report = evaluate_reference_sweep(d, OutputDirectory=d);
```

`receive_lora_packets` enumerates energy-separated transmissions in time
order. Each packet exposes hard decisions, per-bin FFT metrics, max-log bit
LLRs, hard and soft FEC results, and the selected CRC-valid decode. The
reference-sweep evaluator rebuilds the deterministic firmware payload from the
TX log and reports acquisition, header, CRC, pre-FEC BER, payload BER, and PER
separately.

`build_lora_packet` and `build_lora_stream` generate standard complete packets
inside continuous IQ. `receive_lora_stream` fuses energy and chirp-sequence
candidates, validates sync and SFD transitions, and passes explicit or implicit
header configuration to the packet decoder. `evaluate_lora_stream` pairs time
truth and candidates without removing misses, false alarms, duplicates, or CRC
failures from the denominators. `simulate_lora_stream_performance` supplies
reproducible acquisition-inclusive BER/PER evidence.

`fft_correlator_metrics` is the selected coherent symbol-demodulation
candidate. For `M=N·L`, it performs an `M`-point FFT, multiplies by the
conjugated reference spectrum, aliases frequency bins spaced by `N`, and
performs an `N`-point forward FFT. It is numerically equivalent to the exact
matched-filter bank without a full `M`-point IFFT.

The on-air packet receiver learns a phase-aligned reference from the repeated
preamble and keeps the legacy polyphase path as a packet-level guard. Joint
timing/CFO resolution from the upchirp/downchirp pair removed the earlier
ambiguity: all 130 committed SX1262 packets now select the FFT correlator and
decode exactly; none require fallback. This supersedes the earlier 118/130
nominal result and the 56/74 hybrid split.

`joint_timing_cfo_from_bins` splits whole-chip timing from carrier offset given
the signed dechirp bins of one upchirp and one downchirp. It works in units of
half a bin, so `cfoHalfBins` and `timingHalfChips` are exact integers and the
Simulink and HDL implementation can be bit-exact rather than merely close.
`receive_lora_packet` delegates to it.

`receive_lora_packet` and `receive_lora_packets` accept `ReturnSymbolWindows`,
off by default. When enabled they return the corrected per-symbol windows the
correlator actually consumed, plus the adaptive and nominal references. Those
windows are the real-signal stimulus for the Simulink DUT.

`tdoa_from_toas` subtracts fixed per-channel delays before differencing against
receiver 1. `predict_tdoa` and `solve_tdoa` implement the forward model and a
weighted Gauss-Newton multilateration solver with residual, covariance, and
geometry-condition diagnostics. `simulate_tdoa_accuracy` provides seeded
position-error Monte Carlo results.

## Wideband IQ recordings

Four top-level functions handle long int16 I/Q recordings (interleaved I, Q,
for example 40 MS/s from an SDR) that contain a frequency-hopping LoRa signal.
Each also takes a complex sample vector instead of a file name.

| Function | Purpose |
| --- | --- |
| `lora_iq_snr` | Finds the dwells (time on one channel) and the SNR of each in the LoRa bandwidth |
| `lora_iq_identify` | Measures BW, SF, preamble length, sync word, header mode, payload size, CFO and packet period of one dwell |
| `lora_iq_set_snr` | Makes a copy of the recording with the LoRa signal at a requested SNR |
| `lora_iq_synth` | Builds a synthetic recording with known SNR and parameters |

```matlab
f = 'IQREC-03-07-26-10h33m43s888.iq';
r  = lora_iq_snr(f);                          % first second, 40 MS/s
id = lora_iq_identify(f);                     % one dwell in the first 0.1 s
y  = lora_iq_set_snr(f, 10, Out='snr10.iq');  % the same packets at 10 dB
lora_iq_set_snr(f, 10, Out='all10.iq', Duration=Inf);  % whole file, 1 s chunks
```

The SNR is in-band, before dechirping, and the levels are dBFS, not dBm.
`lora_iq_identify` aligns on the preamble and SFD itself, so it assumes neither
the sync word nor the preamble length. An implicit header leaves the payload
length ambiguous: it lists the combinations of length, coding rate and CRC that
fit the symbol count and keeps the one whose CRC checks, if any.

`tests/TestIqRecordingTools.m` checks all four on synthetic recordings:

- SNR within 0.2 dB from 10 to 40 dB;
- no dwell from noise alone;
- parameters identified exactly down to 10 dB SNR, including a different sync
  word and two modes with the same chirp rate (SF9 at 250 kHz and SF11 at
  500 kHz).

`examples/run_elrs_reference_curve.m` gives the reference against which a
detector run on such copies can be judged: the stream receiver on packets in the
mode of the ELRS recording (SF7, 500 kHz, preamble 7, sync word 0x12, CR 4/7),
white noise, SNR in 500 kHz. It takes about a minute and a half per point at 100
packets, loads the CPU fully, and saves each point as it finishes. With 100
packets per point:

| SNR in 500 kHz, dB | -12 | -10 | -9 | -8 | -7 | -6 |
| --- | --- | --- | --- | --- | --- | --- |
| Detected, % | 0 | 24 | 62 | 84 | 100 | 100 |
| Decoded with a valid CRC, % | 0 | 1 | 25 | 77 | 99 | 100 |

No false alarms at any point.

## BER definitions

`simulate_uncoded_ber` compares natural binary labels of transmitted and
detected CSS indices in complex AWGN. Its fifth argument selects
`"single-phase"`, `"polyphase"`, `"fft-correlator"`, or `"matched-filter"`;
logical false/true remain aliases for the first two modes. The matched filter coherently
correlates every complex sample with the complete cyclic-shift waveform bank
and remains the independent floating-point AWGN reference. The FFT correlator
is the algebraically equivalent HDL-oriented decomposition.
The table contains BER/SER, raw counts, denominators, energy-axis conversions,
and 95% Wilson intervals.

`simulate_coded_ber` additionally reports pre-FEC BER, hard and soft payload
BER/PER, soft-recovered packets, header/CRC failures, undetected errors, and
confidence intervals. Failed packet decodes count all payload bits as errors.

Generate the current three-figure campaign with:

```matlab
addpath examples
campaign = plot_ber_campaign;
```
