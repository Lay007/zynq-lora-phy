#!/usr/bin/env python3
"""Measure LoRa packet error rate against SNR on the bench (docs/per-curves-experiment.md).

The CLG400's own AD9361 transmitter is the signal source: board/per/lora_tx_noise
streams clean template packets (tools/lora_tx_waveform.py --templates) with fresh
AWGN at a set SNR into iio_writedev, through the attenuators, into the receiver
under test:

  --receiver pl        the PL receiver of the same board (board/per/lora_trace_stream,
                       decoded here with the project's packet decoder)
  --receiver COMx      an SX1262/LR1121 board running firmware/*-rx (one line per packet)

Packets carry sequence numbers cycling through the templates, so a receiver's
losses are the gaps between successive valid packets. PER = lost / sent, where
sent counts every sequence step between the first and the last valid packet.

    python tools/per_measure.py --receiver pl --sf 7 --cr 1 --snr -10 -9 -8 -7 -6 \\
        --packets 500 --tx-atten 30 --out experiments/per/sf7_cr1_pl.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "tools"))

from zynq_lora_phy import decode_lora_symbol_trace  # noqa: E402

KNOWN_HOSTS = ROOT / "fpga/build/clg400-board/known_hosts.current"
PHY = "/sys/bus/iio/devices/iio:device0"
TEMPLATE_COUNT = {7: 64, 8: 64, 9: 32, 10: 16, 11: 8, 12: 8}


def ssh(password: str):
    import paramiko  # only the bench needs it; keeps the module importable in CI

    c = paramiko.SSHClient()
    c.load_host_keys(str(KNOWN_HOSTS))
    c.set_missing_host_key_policy(paramiko.RejectPolicy())
    c.connect("192.168.40.1", username="root", password=password, timeout=15,
              look_for_keys=False, allow_agent=False)
    return c


def run(c, cmd: str, timeout: float = 120) -> str:
    _, o, e = c.exec_command(cmd, timeout=timeout)
    out = o.read().decode()
    o.channel.recv_exit_status()
    return out + e.read().decode()


def put(c, local: Path, remote: str) -> None:
    i, o, _ = c.exec_command(f"cat > {remote}")
    i.write(local.read_bytes())
    i.channel.shutdown_write()
    o.channel.recv_exit_status()


def tx_configure(c, tx_atten_db: float) -> str:
    return run(c, f"echo 868100000 > {PHY}/out_altvoltage1_TX_LO_frequency; "
                  f"echo 0 > {PHY}/out_altvoltage1_TX_LO_powerdown; "
                  f"echo -{abs(tx_atten_db)} > {PHY}/out_voltage0_hardwaregain; "
                  f"cat {PHY}/out_altvoltage1_TX_LO_frequency {PHY}/out_voltage0_hardwaregain")


def tx_off(c) -> None:
    run(c, "killall iio_writedev lora_tx_noise 2>/dev/null; sleep 0.3; "
           f"echo -89.75 > {PHY}/out_voltage0_hardwaregain; echo 1 > {PHY}/out_altvoltage1_TX_LO_powerdown")


def tx_start(c, templates: int, spp: int, gap: int, snr: float, bw_hz: float, seed: int) -> None:
    run(c, "killall iio_writedev lora_tx_noise 2>/dev/null; sleep 0.3; "
           f"(/tmp/lora_tx_noise /tmp/tpl.c64 {templates} {spp} {gap} {snr} {bw_hz} -14 {seed} "
           "2>/tmp/tx_noise.err | iio_writedev -b 262144 cf-ad9361-dds-core-lpc "
           ">/tmp/tx_writedev.log 2>&1 &) ; sleep 1")


def seq_of(payload: bytes) -> int | None:
    if len(payload) >= 8 and payload[:4] == b"ZLP1":
        return int.from_bytes(payload[4:8], "little")
    return None


def per_from_sequences(seqs: list[int], first: int, period: int) -> dict:
    """Losses are the steps skipped between successive valid packets (mod period)."""

    order = [(s - first) % period for s in seqs]
    sent = lost = dup = 0
    for a, b in zip(order, order[1:]):
        step = (b - a) % period
        if step == 0:
            dup += 1
            continue
        sent += step
        lost += step - 1
    received = len(order) - dup
    return {"received_valid": received, "sent_spanned": sent + (1 if order else 0),
            "lost": lost, "duplicates": dup,
            "per": lost / (sent + 1) if order else None}


def measure_pl(c, packets: int, first: int, period: int) -> dict:
    out = run(c, f"/tmp/lora_trace_stream {packets} 4000", timeout=packets * 10 + 60)
    seqs, crc_bad, timeouts, records = [], 0, 0, []
    for line in out.splitlines():
        if line.startswith("TIMEOUT"):
            timeouts += 1
            continue
        if not line.startswith("PKT"):
            continue
        f = dict(kv.split("=", 1) for kv in line.split()[2:])
        syms = [int(f["sym"][2 * k:2 * k + 2], 16) for k in range(int(f["n"]))]
        pbin = 0 if f["realigned"] == "1" else int(f["pbin"])
        r = decode_lora_symbol_trace(syms, pbin).result
        s = seq_of(bytes(r.payload)) if r.crc_valid else None
        if s is None:
            crc_bad += 1
        else:
            seqs.append(s)
        records.append({"t_ms": int(line.split()[1]), "crc": bool(r.crc_valid), "seq": s,
                        "joint": f["joint"], "p0frac": int(f["p0frac"])})
    res = per_from_sequences(seqs, first, period)
    res.update(crc_fail=crc_bad, timeouts=timeouts, records=records)
    return res


def measure_serial(port: str, seconds: float, first: int, period: int, profile: dict) -> dict:
    import serial
    s = serial.Serial(port, 115200, timeout=0.2)
    time.sleep(0.3)
    s.reset_input_buffer()
    for cmd in (f"set sf {profile['sf']}", f"set bw {profile['bw_khz']}", f"set cr {profile['cr'] + 4}",
                "set sync 0x12", "set crc on", "rx start"):
        s.write((cmd + "\n").encode())
        time.sleep(0.3)
    s.reset_input_buffer()
    lines, t_end = [], time.time() + seconds
    while time.time() < t_end:
        lines += [ln for ln in s.read(4096).decode(errors="replace").splitlines() if ln.startswith("RX ")]
    s.write(b"rx stop\n")
    s.close()
    seqs, crc_bad, records = [], 0, []
    for ln in lines:
        m = re.search(r"state=(\S+) .*rssi=(\S+) snr=(\S+) .*payload=([0-9a-f]*)", ln)
        if not m:
            continue
        ok = m.group(1) == "0"
        seq = seq_of(bytes.fromhex(m.group(4))) if ok else None
        if seq is None:
            crc_bad += 1
        else:
            seqs.append(seq)
        records.append({"state": m.group(1), "rssi": float(m.group(2)), "snr": float(m.group(3)), "seq": seq})
    res = per_from_sequences(seqs, first, period)
    res.update(crc_fail=crc_bad, records=records)
    return res


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--receiver", required=True, help="pl, or a COM port of an *-rx firmware board")
    ap.add_argument("--sf", type=int, default=7)
    ap.add_argument("--bw", type=float, default=125.0)
    ap.add_argument("--cr", type=int, default=1, help="1..4 for 4/5..4/8")
    ap.add_argument("--snr", type=float, nargs="+", required=True)
    ap.add_argument("--packets", type=int, default=500)
    ap.add_argument("--gap", type=float, default=0.3, help="seconds between packets")
    ap.add_argument("--tx-atten", type=float, default=30.0, help="AD9361 TX attenuation, dB")
    ap.add_argument("--password", default="analog")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    from lora_tx_waveform import packet_waveform  # noqa: F401  (import check)
    import subprocess
    templates = TEMPLATE_COUNT[args.sf]
    tpl = args.out.with_suffix(".c64")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(ROOT / "tools/lora_tx_waveform.py"), "--templates",
                    "--sf", str(args.sf), "--bw", str(args.bw), "--cr", str(args.cr),
                    "--packets", str(templates), "--out", str(tpl)], check=True)
    side = json.loads(tpl.with_suffix(".c64.json").read_text())
    spp, gap = side["samples_per_packet"], int(args.gap * 1e6)
    period_s = (spp + gap) / 1e6

    c = ssh(args.password)
    for local, remote in ((ROOT / "board/per/lora_tx_noise", "/tmp/lora_tx_noise"),
                          (ROOT / "board/per/lora_trace_stream", "/tmp/lora_trace_stream"), (tpl, "/tmp/tpl.c64")):
        put(c, local, remote)
    run(c, "chmod +x /tmp/lora_tx_noise /tmp/lora_trace_stream")
    tx_state = tx_configure(c, args.tx_atten)
    points = []
    try:
        for i, snr in enumerate(args.snr):
            tx_start(c, templates, spp, gap, snr, args.bw * 1e3, 1000 + i)
            profile = {"sf": args.sf, "bw_khz": args.bw, "cr": args.cr}
            if args.receiver.lower() == "pl":
                res = measure_pl(c, args.packets, 0, templates)
            else:
                res = measure_serial(args.receiver, args.packets * period_s, 0, templates, profile)
            res["tx_noise"] = run(c, "cat /tmp/tx_noise.err; cat /tmp/tx_writedev.log").strip()[-400:]
            res["snr_db"] = snr
            points.append(res)
            print(f"SNR {snr:+6.1f} dB  PER {res['per']}  valid {res['received_valid']}  "
                  f"lost {res['lost']}  crc_fail {res['crc_fail']}", flush=True)
    finally:
        tx_off(c)
        c.close()
    args.out.write_text(json.dumps({
        "receiver": args.receiver, "sf": args.sf, "bw_khz": args.bw, "cr": args.cr,
        "coding_rate": f"4/{args.cr + 4}", "packets": args.packets, "gap_s": args.gap,
        "tx_atten_db": args.tx_atten, "tx_state": tx_state, "templates": templates,
        "samples_per_packet": spp, "snr_definition": "in the signal bandwidth, AWGN added digitally at the transmitter",
        "points": points}, indent=1) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
