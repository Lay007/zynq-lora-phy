# Finite ZynqSDR to Heltec V4 trials

Use `firmware/heltec-v4-sx1262-rx` on the ESP32-S3/SX1262 Heltec V4.
Version 0.2.0 prints the selected LDRO state and `rx_packets` in `PROFILE`.
LDRO is explicitly set after SF/BW/CR, so source and receiver use the same
packet geometry. The host verifies the profile before transmitting.

Connect ZynqSDR TX1 through the bench's attenuators to the Heltec RF input;
connect Heltec USB to the host. Keep the RF profile and attenuation in the
measurement record. Build and upload from the firmware directory:

```powershell
pio run
pio run -t upload --upload-port COM7
```

Replace COM7 with the actual Heltec port. Build the finite ARM transmitter
using `tools/build_per_tools.py` with the board's ARM Linux toolchain and
retain `per-tools-manifest.json`. Preserve a verified SSH host-key file.

Start with a small high-SNR packet-compatibility test, then sweep SNR:

```powershell
python tools/finite_per_measure.py --receiver COM7 --sf 7 --bw 125 --cr 1 `
  --packets 8 --snr 20 --gap 0.3 --restore-profile `
  --known-hosts artifacts/known_hosts --bin-dir artifacts/per-bin `
  --out artifacts/heltec-sf7-bw125-cr1-smoke.json
```

The serial branch supports SF7–12, BW125/250/500 kHz and CR1–4 (wire coding
rates 4/5–4/8). The PL branch remains SF7/BW125: other profiles require a
different generated FPGA receiver. Command-line parameters do not reconfigure
its FFT/reference/detector.

The denominator is the entire planned ID range, including losses at both
edges. A CRC-valid packet must also have the exact expected payload. All
serial records, generator summaries, writer exit statuses and profile replies
are retained. Missing serial counters, including a lost final line, invalidate
the point instead of becoming apparent RF losses. Serial timeout fragments
are buffered until a complete line arrives. CRC failures remain records.
Zero received RF packets is a valid PER=1 point if TX and serial collection
completed. A failed/interrupted transmitter produces no PER.

Long SF12 waveforms need small batches: templates are uploaded to the board's
RAM filesystem. The harness checks batch size and available space before TX.
Use distinct `--first-sequence` ranges and preserve each finite batch before
aggregating counts. Do not average batches with unequal denominators.
Report binomial uncertainty: zero losses in N trials has a one-sided 95%
upper bound `1 - 0.05**(1/N)`, approximately 3/N.

The injected SNR is defined digitally in BW before the DAC. It is not a
measurement of absolute receiver-input sensitivity; characterize the RF
filters, actual sample rate, attenuation and noise floor for that claim.
The offline `lora_tx_waveform.py` noisy-stream mode now widens its noise
passband for BW500; older versions cut noise off at 150 kHz and understated
noise power in that bandwidth. The finite C generator is white over Fs.

## Ideal reference curves with explicit bandwidth

```shell
python tools/lora_per_ideal.py --sf 7 8 9 10 11 12 --cr 1 2 3 4 \
  --bw 125 250 500 --packets 1000 --demodulator exact-decision \
  --out artifacts/per-ideal-modes.json
python tools/plot_per_modes.py artifacts/per-ideal-modes.json --out artifacts/per-figures
```

`exact-decision` samples the Rician correct FFT bin and the exact maximum of
the other exponential bin powers, then uses the real FEC/header/CRC decoder.
Tests compare independent draws with waveform/FFT Monte Carlo. This is an
ideal perfect-timing/no-CFO AWGN model, not a hardware measurement. Identical
SF/CR/LDRO profiles share normalized trials across BW; changing LDRO requires
a different packet simulation. Figures show pointwise Wilson intervals and
upper bounds when no losses were observed.
