# LoRa packet error rate against SNR: bench experiment

[Русская версия](ru/per-curves-experiment.md)

Status: 2026-10-02. Finite bench tools support matched experimental FPGA
profiles for BW500/SF5..12. The committed generated core remains SF7/L8.
Changing wrapper parameters alone does not create a receiver for another mode.
Each new image requires DSP regeneration, a matching reference ROM, full-packet
RTL verification, routed timing sign-off and hardware qualification.

## Goal

Packet error rate (PER) against SNR for every LoRa mode the parts can do, for
three receivers on **the same signal**, next to the ideal:

| Receiver | What it is |
|---|---|
| ideal | Monte Carlo model: perfect timing, no CFO, non-coherent FFT decision, the project's packet decoder (`tools/lora_per_ideal.py`) |
| PL | this project's receiver in the CLG400 programmable logic (M10 image), decoded by the same packet decoder |
| LR1121 | LILYGO T3-S3 V1.2 running `firmware/lilygo-t3s3-lr1121-rx` |
| SX1262 | Heltec WiFi LoRa 32 V4 running `firmware/heltec-v4-sx1262-rx` |

Modes: SF5..12, BW 125/250/500 kHz, CR 4/5..4/8; 32-byte payload, explicit
header, payload CRC on, preamble 12, sync word 0x12, LDRO on for SF11/12 at
125 kHz. The PL receiver is built for SF7/BW125 only: CR 4/5..4/8 can be
measured on it now (coding is decoded on the host); other SF/BW need a
regenerated correlator per mode (the roadmap at the end).

For a separately regenerated BW500 image at 1 MS/s, use
`tools/finite_per_measure.py --receiver pl --pl-wideband --sf <5..12> --bw 500`
with explicitly built measurement binaries (`tools/build_per_tools.py`). The
harness verifies the FPGA SF/L profile before enabling TX, captures enough
symbols for the packet, and decodes SF9..12 symbols as 16-bit integers.
`--rms-dbfs` sets total stream RMS; inspect the generator's clipping count.
Only complete finite, unclipped TX batches and CRC/full-payload matches are
accepted for PER. Keep software IQ diagnostics separate from FPGA outcomes.

SF5/SF6 TX includes two extra bin-1 upchirps after the 2.25-downchirp SFD
for the supported SX1262/LR1121 framing. All upchirps have consistent phase.

The build profile page is CONTROL bit 5, STATUS `0x5742SFLL`. Runtime capture
length requires CONTROL bit 6; bits 31 and 23:19 encode pairs (zero means 128).
Without bit 6, the shared decision-history address bits retain legacy behavior.
The profile declares compile-time parameters; it does not replace source hashes,
DSP regeneration or build qualification. The four CR use one image per SF/BW.

The joint estimator rejects zero-valued interpolation triplets and bounds a
missing fractional response to 64 clocks. It returns the withheld symbol-grid
guard and declines the precise timestamp for that packet; later packets remain
processable. A valid generated interpolation completes within 38 clocks.

Trace records also expose the hardware clock-page counters: sample interval,
minimum sample interval, last MAC busy duration, and completed MAC searches.
`mac_search_clocks / 62.5` is microseconds for the fixed 62.5 MHz board clock.
It measures the last MAC search, not the complete detection-to-ToA latency;
do not equate it with a host collection timestamp or a ranging delay.

`--preserve-pl-state` skips the batch's full PL stream reset for explicit
continuity experiments. Configure RF and reset PL in the first batch, then
use this flag without `--restore-profile`. Return to a strong signal after
the weak batches to check recovery without a receiver reset. Trace rearming
still releases the capture buffer; it does not reset the joint estimator.

## Method: noise added in digital, not by attenuation

Attenuators alone cannot reach the interesting SNR range. The lowest Heltec
output is -9 dBm; through the 30 + 30 dB available the receiver sees about -69
dBm against a noise floor of about -120 dBm in 125 kHz, i.e. +50 dB SNR, while
the curves live between -24 and 0 dB. Getting there needs another 50-60 dB and
a shielded box (at those levels the transmitter couples past the cable).

Instead the **CLG400's own AD9361 transmitter supplies digitally specified SNR**:

1. `tools/lora_tx_waveform.py --templates` makes clean packets on the host
   (the project's modulator and encoder; distinct sequence numbers).
2. On the board, `board/per/lora_tx_noise` streams template k, a gap, template
   k+1, ... and adds **independent complex Gaussian noise to every sample**,
   scaled so that the SNR *in the signal bandwidth BW* is what is asked for
   (noise density N0 with N0 * BW = 10^(-SNR/10) for unit signal power; white
   over the 1 MHz sample band). The stream is piped into `iio_writedev`
   (non-cyclic, so no noise realisation ever repeats).
3. The signal goes through the attenuators to the receiver under test at a
   level far above the receiver's own noise, so the SNR is the one set in
   digital, not the receiver's noise figure.
4. Every receiver reports every packet. The sequence numbers cycle through the
   templates; losses are the steps skipped between successive valid packets
   (`tools/per_measure.py`, `per_from_sequences`). A packet counts only with a
   valid CRC *and* the right 'ZLP1' header and sequence.

## Wiring

```
Scheme A -- the PL receiver (same board transmits and receives)

  ZynqSDR CLG400                                           ZynqSDR CLG400
  ┌──────────┐    ┌────────────┐    ┌──────────────────┐    ┌──────────┐
  │   TX1 ───┼───►│ 30 dB fixed├───►│ step 0..30 dB    ├───►│ RX1      │
  │ AD9361   │    └────────────┘    │ (start at 30 dB) │    │ AD9361   │
  └──────────┘                      └──────────────────┘    └──────────┘
        lora_tx_noise | iio_writedev          lora_trace_stream (PL trace)

Scheme B -- an SX126x/LR11xx receiver on the same stream

  ZynqSDR TX1 ─► 30 dB fixed ─► step 0..30 dB ─► antenna port of the
                                                 LilyGO LR1121 / Heltec SX1262
                                                 (USB serial: *-rx firmware)
```

The receivers are measured one after the other on the same generated stream
(the same templates, the same SNR settings); a power splitter would allow
simultaneous measurement and is not needed for the method.

### Level budget

| Point | Level |
|---|---|
| DAC stream RMS | -14 dBFS (signal + noise; clipping counted by `lora_tx_noise`) |
| AD9361 TX output at 0 dB attenuation | about 0 dBm for that RMS (to be measured) |
| TX attenuation (`--tx-atten`) | 30 dB to start |
| cable attenuation | 30 + 30 dB |
| at the receiver | about -90 dBm total, of which noise dominates at low SNR |
| receiver's own noise in 125 kHz | about -120 dBm (NF ~ 3-5 dB) |

At SNR = -20 dB (in 125 kHz) with the stream at -90 dBm the injected noise in
the 125 kHz channel is about -99 dBm, 20 dB above the receiver's own floor: the
receiver adds 0.04 dB to the set SNR. Keep the injected noise >= 15 dB above the
floor at every point; the ideal curves then compare directly. For the PL
receiver the level also has to sit inside the correlator's window (M10: < 5 to
~5000 LSB at the ADC).

**As built and measured on 2026-09-30.** TX1 - step attenuator at 20 dB - fixed
30 dB - RX1, TX attenuation 10 dB. Noise at the ADC (RMS):

| RX gain | TX off | stream at SNR -7 dB |
|---|---|---|
| 37 dB | 0.7 LSB | 5.7 LSB, peak 26 |
| 47 dB | 1.3 LSB | 17.8 LSB |
| 57 dB | 2.4 LSB | 57 LSB, peak 277 of 2047 |

**For the PL receiver the absolute level matters, not only the SNR.** The M10
correlator keeps |X|^2 on 20 bits with an LSB of 2 (`ufix20_E1`); at a few LSB
of noise weak bins quantize to 0 or 2, ties go to bin 0 and sensitivity is lost
(#34). PER at SNR -7 dB:

| TX attenuation | RX gain | PER |
|---|---|---|
| 0 dB | 37 dB | 0.037 |
| 4 dB | 37 dB | 0.070 |
| 8 dB | 37 dB | 1.0 |
| 12-20 dB | 37 dB | 1.0, nothing detected |
| 10 dB | 47 dB | 0.023 |
| 0 dB | 27 dB | 0.93 |

Fixed in M11 (PR #35, deployed 2026-09-30): the peak search sees |X|^2 on 40
bits, and at 37 dB the curve matches the M10 curve at 57 dB (table below).
`per_measure.py --rx-gain` defaults to 57 dB, which keeps the ADC noise well
above quantization; the gain goes back to 37 dB after the run. A narrow AD9361 RX FIR (`RX_FIR=lora125 restore_rx_profile.sh`) changes
nothing: the PL correlator is a matched filter over the whole window, so
out-of-channel noise does not fold into the decision (A/B on 2026-09-30, same
PER within statistics at -8.5..-7 dB).

### Calibration checks before a curve

1. **TX off, RX on** (`iio_readdev`): the RX noise floor; confirms nothing leaks
   into RX when the transmitter is idle.
2. **Stream at SNR +20 dB**: every receiver must decode 100 %; the PL records
   are also a regression of the generator against SX126x (a wrong chirp or
   symbol convention would show as 0 %).
3. **Stream at a fixed SNR, RX IQ recorded** (`iio_readdev`): the SNR measured
   from the recording (packet power over noise density in BW) must match the
   set value within 0.5 dB; this is also where the TX level and the receiver's
   own noise contribution are measured.
4. **Clipping**: `lora_tx_noise` reports clipped samples on stderr (kept in the
   result JSON); must be 0.

Found during calibration (2026-09-29/30):

- **The DAC mode depends on RX DMA.** While `iio_readdev` runs, the DAC core
  (set to 2R2T on the 1R1T AD9361) takes the stream at 0.5 MS/s with zero
  stuffing: a +50 kHz tone comes out at +25 kHz plus an equal image at -475 kHz.
  Without RX DMA it plays at 1 MS/s. Curves run without RX DMA, so the working
  templates are 1 MS/s (`--tx-rate`, the default); calibration recordings need
  0.5 MS/s templates.
- **The PL receiver is off after a boot** (CONTROL = 0); `per_measure.py`
  enables it (0x1203, then 0x1201) as `verify_board_b_cold_boot.sh` does.
- **SNR is checked with a preamble-aided estimate.** Picking the best windows
  is biased high at low SNR. Set 0 / -6 / -12 dB measured -0.3 / -6.3 / -12.5 dB.

### AD9361 receiver noise

Measured 2026-09-30 (`tools/ad9361_noise_vs_gain.py`, data in
`docs/data/ad9361_noise_vs_gain.json`): transmitter off, RX1 terminated by the
attenuator chain (the thermal noise of a matched load), 1 MS/s, generic FIR,
`rf_bandwidth` 200 kHz.

| RX gain, dB | 0 | 20 | 30 | 35 | 40 | 45 | 50 | 55 | 60 | 65 | 70 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| noise at the ADC, RMS LSB | 0.54 | 0.78 | 0.97 | 0.62 | 0.79 | 1.12 | 1.69 | 1.98 | 3.29 | 5.03 | 8.16 |
| in 125 kHz, LSB | 0.19 | 0.31 | 0.41 | 0.23 | 0.32 | 0.49 | 0.78 | 0.91 | 1.56 | 2.37 | 3.88 |
| input-referred noise vs 70 dB, dB | +43.9 | +28.2 | +20.6 | +10.6 | +8.4 | +7.1 | +6.1 | +2.4 | +2.1 | +0.7 | 0 |

The last row is the in-band density divided by the gain: the sensitivity penalty
against maximum gain. The gain steps were checked with a tone
(`tools/ad9361_gain_steps.py`): within +-1.3 dB of the setting over 0..70 dB.

- Below ~40 dB the ADC sees a floor of 0.5-1 LSB (12-bit quantization, ~0.4 LSB
  per complex sample, plus the digital path); the input's thermal noise is below it.
- At the standard 37 dB the input-referred noise is 9-10 dB above the 70 dB value:
  over the air, where only the receiver's own noise is present, sensitivity at
  37 dB is ~10 dB short of what the front end can do; at 57 dB ~2 dB, at 65 dB 0.7 dB.
- Between 30 and 35 dB the ADC noise drops while the gain rises: the gain table
  changes how the gain is split between stages; up to 30 dB the stages in use have
  a poor noise figure.
- Over the air the receiver wants ~60-70 dB; a strong nearby signal (the Heltec at
  1 m clipped at 50 dB) then overloads the ADC, so an AGC or a per-scenario gain
  is needed.
- The absolute noise figure needs a dBm-to-LSB calibration with a calibrated
  generator.

## Procedure

```sh
# build the board programs (Vitis 2021.1 cross-compiler) and the templates
sh board/per/build.sh

# PL receiver, SF7 CR4/5, 500 packets per point (about 3 minutes per point)
python tools/per_measure.py --receiver pl --sf 7 --cr 1 \
    --snr -10 -9.5 -9 -8.5 -8 -7.5 -7 -6.5 -6 -5.5 -5 -4.5 -4 \
    --packets 500 --tx-atten 10 --rx-gain 57 --out experiments/per/sf7_cr1_pl_g57.json

# recompute PER from the stored traces after a host decoder change
python tools/per_redecode.py experiments/per/sf7_cr1_pl_g57.json

# LR1121 (COM9) on scheme B, same points
python tools/per_measure.py --receiver COM9 --sf 7 --cr 1 --snr ... \
    --packets 500 --tx-atten 30 --out experiments/per/sf7_cr1_lr1121.json
```

`per_measure.py` uploads the programs and templates, sets the TX LO to 868.1 MHz
and the attenuation, runs one stream per SNR point, collects the receiver's
reports and switches the transmitter off (attenuation -89.75 dB, LO powered
down) at the end, also on error.

Statistics: 500 packets per point resolve PER down to ~1 % (95 % Wilson upper
bound of 0/500 is 0.76 %); points near PER = 1e-3 need 3000+.

## Ideal curves (computed)

`docs/data/lora_per_ideal.json`, 1000 packets per point, 0.5 dB steps. SNR (dB,
in BW) at PER = 10 % / 1 %:

| SF | CR 4/5 | CR 4/6 | CR 4/7 | CR 4/8 |
|---|---|---|---|---|
| 7 | -8.2 / -7.2 | -8.0 / -7.3 | -9.6 / -8.9 | -9.6 / -8.8 |
| 8 | -11.0 / -10.1 | -10.9 / -9.5 | -12.3 / -11.7 | -12.3 / -11.0 |
| 9 | -13.8 / -12.8 | -13.8 / -12.9 | -15.0 / -14.3 | -15.1 / -14.3 |
| 10 | -16.6 / -15.9 | -16.5 / -15.0 | -17.8 / -17.1 | -17.8 / -17.0 |
| 11 | -19.4 / -18.5 | -19.3 / -18.5 | -20.5 / -20.0 | -20.6 / -19.9 |
| 12 | -22.3 / -21.4 | -22.3 / -21.3 | -23.4 / -22.8 | -23.4 / -22.7 |

![Ideal PER vs SNR, SF7..12, one panel per CR](figures/per_ideal.png)

**The model checked against theory.** After dechirping, the 2^SF LoRa symbols
are orthogonal tones, so with perfect timing the symbol error rate has an
exact non-coherent M-ary orthogonal form (Rician correct bin, M-1 Rayleigh
bins, Es/N0 = 2^SF x SNR), evaluated numerically in `tools/lora_per_plots.py`
(the alternating closed-form sum is unstable at M = 4096). The Monte Carlo
model's symbol error rate lies on it for every SF; the largest gap where SER >
2e-3 (enough errors to measure) is 0.62 dB in SER ratio, within the statistics
of ~58 000 symbols per point. The isolated circles near 2e-5 are single errors.
So the packet curves stand on a correct symbol layer, and what the PER adds is
only the packet coding (Gray, interleaving, Hamming, CRC).

![Symbol error rate: theory vs model](figures/ser_model_vs_theory.png)

The small bumps in the PER tails (e.g. SF7 CR 4/6 rising from 3e-3 to 5e-3)
are counting noise: at 1000 packets a point there has three to five errors.

About 2.8 dB per SF step. CR 4/5 and 4/6 are the same curve (their codes only
detect an error); 4/7 and 4/8 correct one error per codeword and gain about
1.4 dB. For reference the SX1262 datasheet quotes demodulator SNR limits of
-7.5 (SF7) .. -20 dB (SF12); the ideal receiver is expected to be 1-2 dB better.

## State

| Piece | State |
|---|---|
| ideal model | done, SF7..12 x CR 4/5..4/8; symbol layer matches exact theory (0.62 dB worst, statistics); figures in `docs/figures/` |
| generator (`lora_tx_waveform.py`) | done; SNR calibration checked (-0.2 dB at 0 dB set); packets decode |
| AD9361 TX on the board | device tree fixed: the DDS node (`cf-ad9361-dds-core-lpc@79024000`) had been removed from the card's devicetree.dtb although the DAC core and TX DMA are in the PL; restored from the ADI AD9364 reference (dtb sha256 7404aa91...), RX unchanged (5/5 CRC valid after the change) |
| `lora_tx_noise` | built; 24 MB of stream in 3.1 s on the Cortex-A9 (real time needs 4 MB/s) |
| `lora_trace_stream` | built; 10 consecutive over-the-air Heltec packets, all CRC valid, none missed |
| LR1121 receiver firmware | flashed on COM9; 3/3 Heltec packets received, CRC valid |
| SX1262 receiver firmware | built; needs a free Heltec |
| scheme A | built: step 20 dB + fixed 30 dB; calibration passed |
| PL curves SF7 at 57 dB | CR 4/5..4/8 measured (below) |
| 3.5 dB loss of the first curve | |X|^2 precision in the correlator (#34); fixed in M11, deployed and measured |
| host trace decoder | fixed 2026-09-30: it returned the first CRC-valid hypothesis; on CR 4/6 that made a false ~1 % PER floor |

## Measured curves

SF7, BW 125 kHz, PL receiver, 500 packets per point, TX attenuation 10 dB, RX
gain 57 dB, PER recomputed with the fixed decoder.

| SNR, dB | -10 | -9.5 | -9 | -8.5 | -8 | -7.5 | -7 | -6.5 | -6 | >= -5.5 |
|---|---|---|---|---|---|---|---|---|---|---|
| CR 4/5 | 0.94 | 0.83 | 0.64 | 0.38 | 0.19 | 0.052 | 0.010 | 0.006 | 0 | 0 |
| CR 4/6 | 0.96 | 0.88 | 0.61 | 0.32 | 0.15 | 0.056 | 0.016 | 0.006 | 0.004 | 0 |
| CR 4/7 | 0.74 | 0.50 | 0.24 | 0.11 | 0.038 | 0.014 | 0.004 | 0 | 0 | 0 |
| CR 4/8 | 0.80 | 0.51 | 0.22 | 0.090 | 0.038 | 0.010 | 0.002 | 0 | 0 | 0 |

Figures: `docs/figures/per_sf7_cr{1,2,3,4}_pl_g57_rd.png`; the first,
low-level curve is `docs/figures/per_sf7_cr1_pl_all.png`.

**M11 at the standard 37 dB** (bitstream 0f6c4167..., 500 packets per point):

| SNR, dB | -10 | -9.5 | -9 | -8.5 | -8 | -7.5 | -7 | -6.5 | -6 | -5.5 |
|---|---|---|---|---|---|---|---|---|---|---|
| M11, 37 dB | 0.96 | 0.88 | 0.68 | 0.40 | 0.21 | 0.044 | 0.014 | 0.004 | 0.006 | 0 |
| M10, 57 dB | 0.94 | 0.83 | 0.64 | 0.38 | 0.19 | 0.052 | 0.010 | 0.006 | 0 | 0 |
| M10, 37 dB | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 0.95 | 0.84 |

Figure: `docs/figures/per_sf7_cr1_pl_m11_g37_rd.png`.

CR 4/5 thresholds: PER 10 % at -7.8 dB (ideal -8.2), PER 1 % at -7.0 dB
(ideal -7.2): the PL receiver is 0.2-0.4 dB from ideal. The first curve
(2026-09-29, RX gain 37 dB, ~6 LSB of noise at the ADC) was 3.5 dB worse, and
all of its 1315 symbol errors sat in raw bin 0 (#34).

CR 4/7 and 4/8 are further from ideal: PER 10 % near -8.4..-8.6 dB and 1 %
near -7.3..-7.4 dB against -9.6 and -8.8..-8.9, i.e. 1.1-1.6 dB. Ideally the
correcting codes gain ~1.4 dB over 4/5; in the PL they gain ~0.5 dB. The
cause is detection, not decoding. The ideal model assumes known timing;
the PL first has to find the preamble. Share of packets never detected
(sequence numbers absent from the records) against PER, CR 4/7:

| SNR, dB | -9.5 | -9 | -8.5 | -8 | -7.5 | -7 |
|---|---|---|---|---|---|---|
| missed | 0.37 | 0.21 | 0.105 | 0.036 | 0.014 | 0.004 |
| PER | 0.50 | 0.24 | 0.113 | 0.038 | 0.014 | 0.004 |

With CR 4/7 and 4/8, PER is almost exactly the missed-detection rate.
Symbol errors do not cluster (as many interleaver blocks with two or more
errors as for random placement), and every packet whose errors are
correctable decodes (101 of 101 at -8 dB). The PL detection threshold is
about -8.5 dB at 10 % missed, level with the SX1262 datasheet sensitivity
for SF7 (-7.5 dB). The next gain is in preamble detection (#36).

## Limits and caveats

- The AD9361 transmitter's own error (EVM around -35..-40 dB) bounds the
  highest usable SNR; irrelevant for the curves, which end below +5 dB.
- The generated packets have no carrier offset and a perfect symbol clock;
  real transmitters have both. A CFO sweep is a separate axis (the generator
  can apply one).
- PER counting needs fewer consecutive losses than templates (64 for SF7/8,
  fewer for high SF where a template is long); near PER = 1 the count is a
  lower bound.
- The PL receiver's timestamps (page 0) are recorded per packet as a by-product,
  for a later ToA-against-SNR curve.

## Roadmap for other modes in the PL

- BW 250/500 kHz at 1 MS/s: 4 and 2 samples per chip; a smaller correlator.
- SF8/SF9 at 8 samples per chip: 2048/4096-point FFTs, at the edge of the BRAM
  (86 of 140 tiles used now).
- SF10..SF12: need fewer samples per chip (decimation before the correlator).
Each is a regenerated correlator, its own image and its own curve.
