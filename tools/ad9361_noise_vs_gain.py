"""AD9361 receive noise against RX gain, transmitter off, RX1 terminated by the attenuator chain.

For each manual gain 0..70 dB (step 5): 400k samples at 1 MS/s through iio_readdev, then
total RMS, DC, RMS without DC, noise density in the LoRa band (+-62.5 kHz, DC bin excluded) and
at the band edges (+-300..+-450 kHz). Written to docs/data/ad9361_noise_vs_gain.json.

input_referred_rel_top_db is the in-band density divided by the gain, relative to the highest
gain: the receiver's sensitivity penalty against maximum gain (the gain steps were checked
with a tone by tools/ad9361_gain_steps.py, within +-1.3 dB)."""
import json
import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import per_measure as pm  # noqa: E402

PHY = pm.PHY
N = 400000
c = pm.ssh("analog")
pm.tx_off(c)
state = pm.run(c, f"cat {PHY}/out_voltage0_hardwaregain {PHY}/out_altvoltage1_TX_LO_powerdown "
                  f"{PHY}/in_voltage_rf_bandwidth {PHY}/in_voltage_sampling_frequency {PHY}/out_altvoltage0_RX_LO_frequency")


def grab():
    pm.run(c, f"rm -f /tmp/rx.iq; iio_readdev -u local: -b 32768 -s {N} cf-ad9361-lpc > /tmp/rx.iq", timeout=120)
    _, o, _ = c.exec_command("cat /tmp/rx.iq")
    raw = np.frombuffer(o.read(), dtype="<i2")
    x = raw[0::2].astype(float) + 1j * raw[1::2]
    return x[len(x) // 10:]


rows = []
for g in range(0, 75, 5):
    pm.run(c, f"echo {g} > {PHY}/in_voltage0_hardwaregain; echo {g} > {PHY}/in_voltage1_hardwaregain")
    got = float(pm.run(c, f"cat {PHY}/in_voltage0_hardwaregain").split()[0])
    time.sleep(0.2)
    x = grab()
    dc = x.mean()
    y = x - dc
    L = 4096
    segs = y[: len(y) // L * L].reshape(-1, L) * np.hanning(L)
    psd = np.mean(np.abs(np.fft.fft(segs, axis=1)) ** 2, axis=0) / np.sum(np.hanning(L) ** 2)  # per bin, LSB^2
    f = np.fft.fftfreq(L, 1e-6)
    band = (np.abs(f) <= 62.5e3) & (np.abs(f) > 2e3)
    edge = (np.abs(f) >= 300e3) & (np.abs(f) <= 450e3)
    row = {
        "gain_set_db": g, "gain_read_db": got,
        "rms_total": float(np.sqrt(np.mean(np.abs(x) ** 2))),
        "dc_i": float(dc.real), "dc_q": float(dc.imag),
        "rms_no_dc": float(np.sqrt(np.mean(np.abs(y) ** 2))),
        "density_band_lsb2_per_hz": float(np.mean(psd[band]) / 1e6),
        "density_edge_lsb2_per_hz": float(np.mean(psd[edge]) / 1e6),
        "peak_abs": float(np.max(np.abs(np.concatenate([x.real, x.imag])))),
        "temps": pm.board_temps(c),
    }
    row["noise_in_125k_lsb_rms"] = float(np.sqrt(row["density_band_lsb2_per_hz"] * 125e3))
    rows.append(row)
    print(f"gain {g:2d} ({got:4.1f}): rms {row['rms_no_dc']:7.2f}  dc ({row['dc_i']:+6.1f},{row['dc_q']:+6.1f})  "
          f"125k {row['noise_in_125k_lsb_rms']:6.2f}  band/edge {10 * np.log10(row['density_band_lsb2_per_hz'] / row['density_edge_lsb2_per_hz']):+5.1f} dB  "
          f"peak {row['peak_abs']:.0f}", flush=True)
pm.run(c, f"echo 37 > {PHY}/in_voltage0_hardwaregain; echo 37 > {PHY}/in_voltage1_hardwaregain")
c.close()
top = rows[-1]
for r in rows:
    r["input_referred_rel_top_db"] = float(10 * np.log10(
        (r["density_band_lsb2_per_hz"] / 10 ** (r["gain_set_db"] / 10))
        / (top["density_band_lsb2_per_hz"] / 10 ** (top["gain_set_db"] / 10))))
    print(f"{r['gain_set_db']:2d} dB: input-referred noise {r['input_referred_rel_top_db']:+5.1f} dB against {top['gain_set_db']} dB")
out = ROOT / "docs/data/ad9361_noise_vs_gain.json"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps({"date": time.strftime("%Y-%m-%dT%H:%M"), "board_state": state.split(),
                           "setup": "RX1 terminated by step 20 dB + fixed 30 dB to TX1, TX off (-89.75 dB, LO powered down), 1 MS/s, generic RX FIR, rf_bandwidth 200 kHz",
                           "rows": rows}, indent=1) + "\n", encoding="utf-8")
print("saved", out)
