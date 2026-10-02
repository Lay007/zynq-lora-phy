# BER/SER/PER methodology

[Русская версия](ru/ber-methodology.md)

The repository keeps demodulator errors and packet-decoder errors as two
separate AWGN experiments. Both use fixed random seeds, raw error counts,
explicit denominators, and two-sided 95% Wilson score intervals.

## Uncoded demodulator and coherent reference

`simulate_uncoded_ber` transmits independent uniformly distributed CSS symbol
indices with known timing. It adds circular complex AWGN and compares the
detected symbol index and its natural binary label with the transmitted values.

The campaign runs four receivers on the same seeded waveform and noise
realization: the legacy first-decimation-phase FFT, the legacy noncoherent
polyphase FFT-power sum, the new FFT correlator, and an exact matched-filter
reference. The last two circularly correlate all complex samples with every
cyclically shifted CSS chirp and therefore combine `L` coherently.

| Parameter | Value |
|---|---:|
| Spreading factor | 7 |
| Samples per chip, `L` | 1, 2, 4, 8 |
| Demodulators | single-phase, polyphase, fft-correlator, matched-filter |
| Symbols per SNR/mode | 4,000 |
| Label bits per SNR/mode | 28,000 |
| SNR sweep | −20:2:−4 dB |
| Seed | `70 + L` |

![Current demodulator versus matched-filter reference](images/css-ber-current-vs-ideal.png)

Raw results: [`css-ber-demodulator-comparison.csv`](data/css-ber-demodulator-comparison.csv).
At `L=8`, log-BER interpolation gives the legacy polyphase power sum a penalty
of `5.33 dB` at BER `1e−2` and `6.03 dB` at BER `1e−3`. The FFT correlator is
algebraically equivalent to the exact matched filter and its measured gap is
`0 dB` for every tested `L` and BER threshold:

![Measured gap to the matched filter](images/css-ber-ideal-gap.png)

Thresholds and gaps: [`css-ber-ideal-gap.csv`](data/css-ber-ideal-gap.csv).
The legacy loss is not exactly `10 log10(L)`: its power sum is noncoherent,
and adjacent-bin energy around the cyclic chirp wrap changes the waterfall,
especially at `L=2`.

For `M=N·L`, the FFT correlator computes an `M`-point FFT, multiplies it by the
conjugated reference spectrum, sums bins `m+rN`, and applies an `N`-point
forward FFT. The resulting values are exactly the required matched-filter
correlations at lags `−kL`; the full `M`-point IFFT and a time-domain template
bank are unnecessary. This decomposition is the selected Simulink candidate.

The matched filter is an ideal receiver only inside this experiment: symbol
timing and the waveform are exact, the channel is AWGN, and there is no CFO,
SFO, multipath, clipping, or quantization. It is not a Shannon bound and it
does not represent packet acquisition performance.

The uncoded experiment excludes preamble acquisition, whitening, interleaving,
FEC, header, CRC, packet rejection, CFO/SFO, multipath, and clipping. It is a
demodulator baseline, not application-visible packet performance.

## SNR and energy convention

`SNR_dB` is average complex signal-sample power divided by average complex
noise-sample power before dechirp. For `L = samplesPerChip`:

```text
Fs = BW × L
Ns = 2^SF × L
Es/N0 [dB] = SNRsample [dB] + 10 log10(Ns)
Eb/N0 [dB] = SNRsample [dB] + 10 log10(Ns / SF)
```

The last expression applies to the `SF` uncoded label bits. The uncoded CSV
stores both converted axes. For the coded experiment, `EbN0_dB` uses the total
header/payload-symbol energy divided by user payload bits; no preamble is
included because the experiment starts at a known packet boundary.

## Coded SF5/SF6/SF7 campaign

`simulate_coded_ber` builds the explicit header, payload CRC, whitening,
Hamming FEC, diagonal interleaving, Gray mapping, and CSS waveform, then
reverses the chain after AWGN. It evaluates hard and soft decoders from the
same per-bin FFT metrics.

| Parameter | Value |
|---|---:|
| Spreading factors | 5, 6, 7 |
| Samples per chip | 8 |
| Coding rate | 4/5 |
| Payload | 16 bytes |
| Header / CRC | explicit / enabled |
| Packets per SNR/SF | 200 |
| Payload bits per SNR/SF | 25,600 |
| SNR sweep | −20:2:−4 dB |
| Seeds | 105, 106, 107 |

![Coded low-SF BER and PER](images/lora-coded-ber-sf5-sf7-fft-correlator.png)

Raw results: [`lora-coded-ber-sf5-sf7-fft-correlator.csv`](data/lora-coded-ber-sf5-sf7-fft-correlator.csv).
At −10 dB, no symbol, payload, or packet errors were observed in 200 packets
for each of SF5, SF6, and SF7. This finite Monte Carlo result is not proof of a
zero error probability; the Wilson upper bound remains part of the CSV.

## Real-waveform robustness

An earlier nominal pass decoded only 118 of 130 committed SX1262→ZynqSDR
transmissions, and the first hybrid pass selected the FFT correlator for 56
packets and polyphase fallback for 74. The cause was primarily synchronization
ambiguity: an upchirp dechirp bin mixes whole-chip timing error and CFO. The
updated receiver combines signed upchirp and downchirp bins, whose timing terms
have opposite signs, to estimate timing and CFO separately. Reprocessing now
decodes 130/130 with all 130 selecting the FFT correlator and zero selecting
polyphase. The fallback remains a guard until broader hardware sensitivity and
interference campaigns justify its removal; the old split is not evidence of
proven real-chirp mismatch.

## Metric definitions

| Metric | Comparison | Interpretation |
|---|---|---|
| SER | transmitted/detected CSS indices | demodulator symbol errors |
| Pre-FEC BER | transmitted/received interleaver codeword bits | channel plus hard CSS decisions |
| Hard/soft payload BER | original/dewhitened payload | decoder-specific residual errors |
| Hard/soft PER | exact payload plus header/CRC status | decoder-specific packet failure |
| Soft recovered | hard packet failed, soft packet exact | incremental soft-decoder recovery |
| Undetected errors | CRC passed but payload differed | CRC safety observation |

If a decoder returns the wrong payload length, every user payload bit counts as
an error. A packet error is a failed header, failed CRC, wrong length, or any
payload mismatch. No failed packet disappears from a denominator.

## Confidence intervals and zero observations

CSV rates remain exact observed ratios. Each uncoded BER/SER and primary coded
BER/PER metric includes a two-sided 95% Wilson interval. A zero-error run does
not prove a zero underlying rate. The logarithmic curve breaks at that
observation; an unconnected downward triangle marks the two-sided 95% Wilson
upper bound. This is a statistical bound, not an observed BER/PER. The old
`0.5/N` substitution and connected artificial tails are no longer used.
For example, zero packet errors in 200 trials still has a 95% Wilson upper
bound of about 1.88%.

## Reproduce

```matlab
cd model/matlab
addpath examples
campaign = plot_ber_campaign;
```

To redraw the figures from saved counts without rerunning Monte Carlo or
changing the CSV/MAT evidence:

```matlab
figures = redraw_ber_campaign;
```

`plot_ber_campaign` regenerates three PNGs, three CSVs, and
[`ber-demodulator-campaign.mat`](data/ber-demodulator-campaign.mat). Historical
results remain available through Git history. The current MAT schema is
`zynq-lora-ber-campaign-v3` and includes `idealGap` with both legacy and current
penalties.

The coded experiment still assumes known timing and sends no preamble. A later
acquisition-inclusive hardware sweep must separately count attempted packets,
detected preambles, synchronized frames, decoded headers, CRC-pass packets,
and bit-correct payloads.
