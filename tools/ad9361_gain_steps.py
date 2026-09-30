"""Check the AD9361 RX gain steps with a fixed tone: TX1 -> attenuators -> RX1, TX attenuation 40 dB,
RX gain 0..70 dB (step 5). The tone power (strongest FFT bin +-2 bins) must follow the set gain
dB for dB if the input-referred noise figures of noise_sweep.py are to be trusted.
RX DMA makes the DAC play the stream at 0.5 MS/s, so the tone sits at +25 kHz (and an image);
only the strongest line is used."""
import json
import sys
import time
from pathlib import Path

import numpy as np

SP = Path(__file__).resolve().parents[1] / "experiments" / "noise"
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import per_measure as pm  # noqa: E402

PHY = pm.PHY
N = 262144
TX_ATT = float(sys.argv[1]) if len(sys.argv) > 1 else 40.0
GAINS = range(int(sys.argv[2]), int(sys.argv[3]) + 1, 5) if len(sys.argv) > 3 else range(0, 75, 5)
tone = np.exp(2j * np.pi * 50e3 / 1e6 * np.arange(100000)).astype(np.complex64)
(SP / "cal").mkdir(exist_ok=True)
(SP / "cal/tone.c64").write_bytes(tone.tobytes())
c = pm.ssh("analog")
pm.put(c, SP / "cal/tone.c64", "/tmp/tone.c64")
pm.put(c, ROOT / "board/per/lora_tx_noise", "/tmp/lora_tx_noise")
pm.run(c, "chmod +x /tmp/lora_tx_noise")
pm.tx_off(c)
pm.tx_configure(c, TX_ATT)
pm.run(c, "killall iio_writedev lora_tx_noise 2>/dev/null; (/tmp/lora_tx_noise /tmp/tone.c64 1 100000 0 60 125000 -14 5 "
          "2>/tmp/tx_noise.err | iio_writedev -b 262144 cf-ad9361-dds-core-lpc >/tmp/tx_writedev.log 2>&1 &) ; sleep 1.5")
rows = []
try:
    for g in GAINS:
        pm.run(c, f"echo {g} > {PHY}/in_voltage0_hardwaregain; echo {g} > {PHY}/in_voltage1_hardwaregain")
        time.sleep(0.2)
        pm.run(c, f"rm -f /tmp/rx.iq; iio_readdev -u local: -b 32768 -s {N + 40000} cf-ad9361-lpc > /tmp/rx.iq", timeout=120)
        _, o, _ = c.exec_command("cat /tmp/rx.iq")
        raw = np.frombuffer(o.read(), dtype="<i2")
        x = (raw[0::2].astype(float) + 1j * raw[1::2])[-N:]
        w = np.hanning(N)
        spec = np.abs(np.fft.fft((x - x.mean()) * w)) ** 2 / np.sum(w ** 2) / N
        fk = np.fft.fftfreq(N, 1e-6)
        win = np.nonzero(np.abs(fk - 25e3) < 2e3)[0]
        k = int(win[np.argmax(spec[win])])  # the +25 kHz line only (fixed digital spurs sit at DC and +-500 kHz)
        p_tone = float(spec[max(0, k - 2):k + 3].sum())  # LSB^2 (mean square of the tone)
        f_tone = float(np.fft.fftfreq(N, 1e-6)[k])
        peak = float(np.max(np.abs(np.concatenate([x.real, x.imag]))))
        rows.append({"gain_set_db": g, "tone_lsb2": p_tone, "tone_hz": f_tone, "peak_abs": peak})
        print(f"gain {g:2d}: tone {10 * np.log10(p_tone):+7.2f} dB LSB^2 at {f_tone / 1e3:+.1f} kHz  peak {peak:.0f}", flush=True)
finally:
    pm.tx_off(c)
    pm.run(c, f"echo 37 > {PHY}/in_voltage0_hardwaregain; echo 37 > {PHY}/in_voltage1_hardwaregain")
    c.close()
ref = rows[-1]
for r in rows:
    r["tone_rel_db"] = 10 * np.log10(r["tone_lsb2"] / ref["tone_lsb2"])
    r["gain_error_db"] = r["tone_rel_db"] - (r["gain_set_db"] - ref["gain_set_db"])
print("gain error against the set step, relative to 70 dB:",
      " ".join(f"{r['gain_set_db']}:{r['gain_error_db']:+.1f}" for r in rows))
out = ROOT / f"docs/data/ad9361_gain_steps_tx{TX_ATT:g}.json"
out.write_text(json.dumps({"date": time.strftime("%Y-%m-%dT%H:%M"), "tx_atten_db": TX_ATT,
                           "setup": "tone +50 kHz at -14 dBFS through lora_tx_noise (SNR 60 dB), TX1 - step 20 dB - fixed 30 dB - RX1; RX DMA running, so the DAC plays at 0.5 MS/s",
                           "rows": rows}, indent=1) + "\n", encoding="utf-8")
print("saved", out)
