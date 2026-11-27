# Wideband IQ recordings of a hopping LoRa signal

Four MATLAB functions in `model/matlab` work on long int16 I/Q recordings
(interleaved I, Q; for example 40 MS/s from an SDR) that contain a
frequency-hopping LoRa signal. They measure the SNR, identify the PHY
parameters without prior knowledge, and make copies of a recording at a set SNR
for testing receivers and detectors on real traffic. Usage is in the
[MATLAB README](../model/matlab/README.md#wideband-iq-recordings).

| Function | Purpose |
| --- | --- |
| `lora_iq_snr` | Dwells (time on one channel) and the SNR of each in the LoRa bandwidth |
| `lora_iq_identify` | BW, SF, preamble, sync word, header mode, payload size, CFO and period of one dwell |
| `lora_iq_set_snr` | A copy of the recording with the LoRa signal at a requested SNR |
| `lora_iq_synth` | A synthetic recording with known SNR and parameters, for the tests |

## SNR definition

The SNR is the signal power over the noise power in the LoRa bandwidth BW,
before dechirping, the axis of the PER bench. The model campaigns give it per
sample; see [SNR in the signal bandwidth](ber-methodology.md#snr-in-the-signal-bandwidth)
for the conversion. Levels are dBFS (int16 full scale), not dBm: the recording
is not calibrated.

## Method

**SNR.** An STFT with a Hann window, scaled so the bins add up to the
mean-square of the samples. In every frame the BW-wide window with the largest
power is the channel. The noise per bin is the median of the passband bins with
each frame's channel left out, divided by ln 2, and then, if at least 5 % of the
frames carry no signal, the plain mean of those frames, which is not raised by
the spectral splatter of symbol edges. Signal frames are grouped into dwells by
channel; a frame joins the longest open dwell on its channel, so a stray noise
frame or a frame whose channel estimate wanders (it sees only part of the
sweep) does not split a dwell.

**Identification.** The dwell's occupied −3 dB bandwidth, snapped to a standard
value, gives BW; dechirping with each SF gives SF (two modes with the same
chirp rate, e.g. SF7/500 kHz and SF5/250 kHz, differ in BW). On a symbol grid
with an arbitrary start the preamble dechirps to bin `cfo − lag` and the SFD
downchirps to `cfo + lag`, which gives both; the corrected grid then gives the
sync word, preamble length and payload symbol count, with no assumption about
either. An explicit header is validated by its checksum; for an implicit one
the function lists the payload length / coding rate / CRC combinations that fit
the symbol count and confirms the one whose CRC checks, if any.

**Set SNR.** Every dwell is band-passed out (one BW plus 5 %, 100 µs tapers),
all dwells are set to one level, and white complex Gaussian noise is added so
that the noise in BW gives the requested SNR, optionally band-limited like a
receiver's front end (`NoiseBW`). The recording's own noise outside the channel
is dropped, so the copy has the noise asked for; its in-channel noise, about
40 dB below the signal in the recordings so far, sets a ceiling of ~38 dB. A
whole recording is processed in 1 s chunks read with 50 ms margins, so a hop
across a chunk border is cut out whole; the level and the int16 gain are fixed
on the first chunk.

## Accuracy (synthetic recordings)

`model/matlab/tests/TestIqRecordingTools.m`, nine tests:

- SNR within 0.2 dB from 10 to 40 dB (within 0.15 dB from 8 dB in the
  development sweep; nearer the 6 dB detection threshold it reads high);
- no dwell from noise alone;
- set SNR reached within 0.3 dB, also when 70 ms chunks cut through the hops;
- parameters identified exactly at 10 dB: an ELRS-like implicit-header mode,
  an implicit payload confirmed by CRC with a different sync word, an explicit
  header, and SF9/250 kHz against SF11/500 kHz.

## Example: one recording

One second of a 40 MS/s recording (`IQREC-03-07-26-10h33m43s888.iq`):

| Quantity | Value |
| --- | --- |
| SNR in 500 kHz | about 42.5 dB |
| Noise in 500 kHz / signal | −60 / −17.6 dBFS |
| Hops | ~38.8 ms dwells, 4 packets each, period 10 ms |
| PHY | 500 kHz, SF7, preamble 7, sync word 0x12, implicit header |
| Payload | 22 symbols, CR 4/7, no LoRa CRC |
| Airtime | 8.51 ms |
| CFO from the dwell centre | −11.7 kHz |

The receiver's flat passband is about ±13 MHz; the analysis uses ±12 MHz.

## Reference detection curve

`model/matlab/examples/run_elrs_reference_curve.m` gives the reference for a
detector run on copies made by `lora_iq_set_snr`: the project's stream receiver
on packets in the mode above, white noise, 100 packets per point.

| SNR in 500 kHz, dB | −12 | −10 | −9 | −8 | −7 | −6 |
| --- | --- | --- | --- | --- | --- | --- |
| Detected, % | 0 | 24 | 62 | 84 | 100 | 100 |
| Decoded with a valid CRC, % | 0 | 1 | 25 | 77 | 99 | 100 |

No false alarms. A detector on the copies should be judged against this curve
on the same axis; a loss well above −6 dB is the detector's, not the signal's.

## Evidence boundary

These are model and recording-analysis results. The SNR copies keep the real
packets, timing and hops but replace the noise with ideal white noise; they do
not reproduce the recording receiver's noise figure, phase noise or AGC, and the
levels are not calibrated in dBm.
