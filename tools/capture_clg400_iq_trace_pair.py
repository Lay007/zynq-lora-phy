#!/usr/bin/env python3
"""Capture one Heltec packet as a simultaneous RX1 IQ recording and PL trace.

The stage-by-stage differential needs both halves of the same packet: the raw
samples the AD9361 delivered and the decisions the programmable logic froze
from them. Recording them separately is not good enough — the comparison only
means something if both describe the same transmission.

Per attempt: arm the PL trace, start the DMA recording so it brackets the
transmission, issue exactly one ``send``, read the frozen trace, download the
IQ. The transmitter is stopped before and immediately after the send and
``start`` is never issued, so no periodic transmission can be left running.

Everything on the receiver is read-only apart from the receive-stream reset
that re-arms the trace. QSPI, the boot loader, the FPGA manager and every RF
transmit enable are untouched.

The recording is written to the board's tmpfs and streamed back over the same
SSH connection, so nothing is left on the board and the multi-megabyte capture
never enters Git — ``experiments/runs/`` is ignored.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.read_clg400_symbol_trace import (  # noqa: E402
    CONTROL,
    _run_remote,
    build_report,
    TraceNotComplete,
    read_history,
    read_trace,
)
from tools.run_clg400_payload_capture import (  # noqa: E402
    EXPECTED_PROFILE,
    _read_profile,
    parse_profile,
    parse_transmit_line,
)
from tools.run_phy_experiment import SerialTransmitter  # noqa: E402


# 1.5 s at 1 MS/s. The packet is ~83 ms, so this brackets it with room for the
# arming delay either side without making the transfer slow.
DEFAULT_IQ_SAMPLES = 1_500_000
REMOTE_IQ = "/tmp/lora_rx1.bin"


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def arm_receive_stream(args: argparse.Namespace, full: bool = True) -> str:
    """Re-arm for the next capture.

    ``full=True`` pulses ``stream_reset`` (control bit 1): it also zeros the
    absolute sample counter in ``lora_iq_history_buffer``, so the first
    attempt of a series uses it to guarantee a clean start. ``full=False``
    pulses ``trace_rearm`` (control bit 2, M6) instead: it re-arms the
    one-shot symbol trace and the grid resync's ``armed`` latch (see
    ``fpga/board/clg400/lora_clg400_gpreg_bridge.v``) without touching that
    counter, so attempts after the first keep one continuous timebase across
    the whole series.
    """

    set_bit, clear_mask = (2, 0xFFFFFFFD) if full else (4, 0xFFFFFFFB)
    # Both also release the decision-history freeze (bit 3) that the previous
    # recording set, so the ring runs again for this attempt.
    clear_mask &= 0xFFFFFFF7
    script = f"""set -eu
orig=$(devmem {CONTROL} 32)
reset=$(((orig & 0xFFFFFFF7) | {set_bit}))
run=$((orig & {clear_mask}))
devmem {CONTROL} 32 "$reset" >/dev/null
sleep 1
devmem {CONTROL} 32 "$run" >/dev/null
printf 'armed control=0x%08x\\n' "$run"
"""
    return _run_remote(args, script).strip()


def iio_capture_command(samples: int, remote_path: str) -> str:
    """Build the detached DMA recording command.

    ``iio_readdev`` writes one interleaved little-endian int16 pair per sample
    with both channels selected, which is exactly the format the analysis
    tools expect. It is detached so the transmission can happen while the
    buffer fills; the exit status lands in a sentinel file.
    """

    if samples <= 0:
        raise ValueError("samples must be positive")
    if "'" in remote_path:
        raise ValueError("remote_path must not contain a single quote")
    # The remote script is fed to `sh -s` on stdin, so a plain `... &` job is
    # killed when that shell exits and the recording silently comes back empty.
    # nohup with stdin detached from the closing channel is what keeps it
    # alive long enough to span the transmission.
    # The moment the recording ends, freeze the decision-history ring (control
    # bit 3, M8 diagnostic image; unused and harmless on older images). The
    # ring holds about four seconds of decisions and the packet is about 1.3 s
    # into a 1.5 s recording, so it must stop here, not after the trace read,
    # or a missed packet's decisions are overwritten before anyone looks.
    inner = (
        f"iio_readdev -u local: -b 32768 -s {samples} cf-ad9361-lpc "
        f"voltage0 voltage1 > {remote_path} 2>{remote_path}.err; "
        f"s=$?; devmem {CONTROL} 32 $(( $(devmem {CONTROL} 32) | 8 )); "
        f"echo $s > {remote_path}.done"
    )
    return (
        f"rm -f {remote_path} {remote_path}.done {remote_path}.err; "
        f"nohup sh -c '{inner}' </dev/null >/dev/null 2>&1 &"
    )


def wait_for_capture(
    args: argparse.Namespace, remote_path: str, timeout_s: float
) -> tuple[int, int]:
    """Block until the detached recording writes its sentinel."""

    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        # The board image is busybox without `stat`, and a missing `stat`
        # plus a `|| echo 0` fallback reports every recording as empty. `wc -c`
        # is present and portable.
        fields = _run_remote(
            args,
            f"if [ -f {remote_path}.done ]; then cat {remote_path}.done; "
            f"else echo pending; fi; "
            f"wc -c < {remote_path} 2>/dev/null || echo 0",
        ).split()
        if fields and fields[0] != "pending":
            return int(fields[0]), int(fields[1])
        time.sleep(0.5)
    raise TimeoutError("the DMA recording did not finish before the deadline")


def fetch_binary(args: argparse.Namespace, remote_path: str, local: Path) -> int:
    """Stream a remote binary back; the board image has no SFTP subsystem."""

    if args.password_env:
        import paramiko

        password = os.environ.get(args.password_env)
        if password is None:
            raise ValueError(
                f"SSH password environment variable {args.password_env!r} is not set"
            )
        client = paramiko.SSHClient()
        if args.known_hosts:
            client.load_host_keys(str(args.known_hosts))
        else:
            client.load_system_host_keys()
        client.set_missing_host_key_policy(paramiko.RejectPolicy())
        try:
            client.connect(
                args.host,
                username=args.user,
                password=password,
                timeout=args.connect_timeout,
                allow_agent=False,
                look_for_keys=False,
            )
            stdin, stdout, stderr = client.exec_command(
                f"cat {remote_path}", timeout=args.command_timeout
            )
            stdin.channel.shutdown_write()
            written = 0
            with local.open("wb") as handle:
                while True:
                    chunk = stdout.channel.recv(65536)
                    if not chunk:
                        if stdout.channel.exit_status_ready():
                            break
                        continue
                    handle.write(chunk)
                    written += len(chunk)
            if stdout.channel.recv_exit_status():
                raise RuntimeError(stderr.read().decode(errors="replace").strip())
        finally:
            client.close()
        return written

    command = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        f"ConnectTimeout={args.connect_timeout}",
    ]
    if args.known_hosts:
        command.extend(["-o", f"UserKnownHostsFile={args.known_hosts}"])
    if args.identity:
        command.extend(["-i", str(args.identity)])
    command.extend([f"{args.user}@{args.host}", "cat", remote_path])
    completed = subprocess.run(command, capture_output=True, check=False)
    if completed.returncode:
        raise RuntimeError(
            f"reading {remote_path} failed: {completed.stderr.decode(errors='replace').strip()}"
        )
    local.write_bytes(completed.stdout)
    return len(completed.stdout)


def burst_ratio(path: Path) -> float:
    """Peak-to-median smoothed power of a recording.

    A full-length file is not the same as a file with a packet in it. When the
    send lands outside the recording window the result is exactly the right
    size and contains only noise, which every size check passes. One packet in
    1.5 s lifts this ratio by three orders of magnitude; noise alone leaves it
    near one.
    """

    import numpy as np

    raw = np.fromfile(path, dtype="<i2")
    if raw.size < 4:
        return 0.0
    power = raw[0::2].astype(np.float64) ** 2 + raw[1::2].astype(np.float64) ** 2
    if power.size < 1024:
        return 0.0
    smooth = np.convolve(power, np.ones(1024) / 1024, mode="valid")
    median = float(np.median(smooth))
    if median <= 0.0:
        return 0.0
    return float(smooth.max() / median)


def iq_worth_keeping(report: dict) -> bool:
    """Whether a successful attempt's recording is evidence worth its 6 MB.

    Failed attempts always keep theirs (the failure path never deletes). Of
    the successful ones, keep what a later replay would be needed for: a CRC
    failure, and a packet accepted only through one of the detector's rescue
    paths (straddle, split, early sync) or with the joint estimate aborted,
    rejected or not applied. An ordinary decoded packet's recording adds
    nothing its trace record does not already say.
    """

    if not report.get("decode", {}).get("crc_valid"):
        return True
    joint = report.get("joint_estimate") or {}
    if not joint.get("precise_correction_applied"):
        return True
    return any(
        joint.get(flag)
        for flag in (
            "detector_straddle_accepted",
            "detector_split_accepted",
            "detector_early_sync_accepted",
            "up_search_aborted",
            "down_search_aborted",
            "timing_rejected_out_of_range",
        )
    )


def capture_once(
    args: argparse.Namespace, full_rearm: bool = True
) -> dict[str, object]:
    """Run one capture attempt.

    ``full_rearm`` selects which control bit ``arm_receive_stream`` pulses
    (see there); it does not affect anything else about the attempt.

    Every attempt writes a ``clg400-trace-<stamp>.json`` record, even one
    that fails partway through: a capture campaign that silently dropped
    failed attempts could not tell "the transmitter never sent" from "the
    packet was never detected" from "the trace read timed out" after the
    fact, and the run's own attempt/capture/detection/CRC counts would not
    add up to the number of attempts actually made.
    """

    stamp = utc_stamp()
    args.run_dir.mkdir(parents=True, exist_ok=True)
    serial_log = args.run_dir / f"heltec-{stamp}.log"
    local_iq = args.run_dir / f"rx1-iq-{stamp}.bin"
    stage = "prepare_transmitter"
    record = None
    try:
        # The transmitter is prepared *before* the recording starts. Verifying
        # the profile takes seconds of serial round trips; doing it inside the
        # recording window pushes the send past the end of a 1.5 s capture and
        # yields a full-length file with no packet in it.
        transmitter = SerialTransmitter(args.port, args.baud, serial_log)
        try:
            transmitter.command("stop", quiet_s=0.4)
            version = next(
                (l for l in transmitter.command("version", quiet_s=0.4)
                 if l.startswith("zynq-lora")), "")
            profile = _read_profile(transmitter)
            fields = parse_profile(profile)
            if fields.get("power_dbm") != EXPECTED_PROFILE["power_dbm"]:
                transmitter.command(
                    f"set power {EXPECTED_PROFILE['power_dbm']}", quiet_s=0.4)
                profile = _read_profile(transmitter)
                fields = parse_profile(profile)
            mismatch = {
                key: {"expected": value, "actual": fields.get(key)}
                for key, value in EXPECTED_PROFILE.items()
                if fields.get(key) != value
            }
            if mismatch:
                raise RuntimeError(f"transmitter profile mismatch: {mismatch}")

            stage = "arm"
            print(f"[{stamp}] {arm_receive_stream(args, full=full_rearm)}")
            _run_remote(args, iio_capture_command(args.iq_samples, REMOTE_IQ))
            time.sleep(args.settle_s)

            stage = "send"
            send_lines = transmitter.command(
                "send", quiet_s=0.4, required_prefix="TX seq=",
                response_timeout_s=15,
            )
            transmitter.command("stop", quiet_s=0.4)
        finally:
            transmitter.close()

        record = parse_transmit_line(send_lines)
        if record["state"] != 0:
            raise RuntimeError(f"transmitter reported state={record['state']}")
        identity = {"version": version, "profile": profile}

        stage = "wait_for_capture"
        status, remote_size = wait_for_capture(
            args, REMOTE_IQ, args.capture_timeout_s)
        if status != 0:
            raise RuntimeError(f"iio_readdev exited {status}")
        expected_bytes = args.iq_samples * 4
        if remote_size != expected_bytes:
            raise RuntimeError(
                f"recording is {remote_size} bytes, expected {expected_bytes}"
            )

        stage = "read_trace"
        time.sleep(args.settle_s)
        report = build_report(read_trace(args))

        stage = "fetch_iq"
        downloaded = fetch_binary(args, REMOTE_IQ, local_iq)
        _run_remote(args, f"rm -f {REMOTE_IQ} {REMOTE_IQ}.done {REMOTE_IQ}.err")

        report["serial"] = {
            "port": args.port,
            "log": serial_log.name,
            "transmitted_utc": stamp,
            "iq_capture": local_iq.name,
            "version": identity["version"],
            "profile": identity["profile"],
            "tx_sequence": record["sequence"],
            "tx_payload_length": record["payload_length"],
            "tx_state": record["state"],
            "tx_start_ms": record["start_ms"],
            "tx_duration_ms": record["duration_ms"],
        }

        stage = "check_burst_ratio"
        ratio = burst_ratio(local_iq)
        if ratio < args.min_burst_ratio:
            raise RuntimeError(
                f"recording holds no packet: peak-to-median power {ratio:.1f} "
                f"below {args.min_burst_ratio:.1f}; the send probably fell "
                f"outside the recording window"
            )

        report["iq_bytes"] = downloaded
        report["iq_samples"] = downloaded // 4
        report["iq_burst_ratio"] = round(ratio, 1)
    except Exception as error:
        failure = {
            "schema": "zynq-lora-clg400-symbol-trace-v1",
            "status": "failed",
            "stage": stage,
            "error": f"{type(error).__name__}: {error}",
            "serial": {
                "port": args.port,
                "log": serial_log.name,
                "transmitted_utc": stamp,
            },
        }
        if record is not None:
            failure["serial"]["tx_sequence"] = record["sequence"]
            failure["serial"]["tx_start_ms"] = record["start_ms"]
        # The sticky bits are cleared by the next attempt's re-arm, so the
        # programmable logic's own account of a miss exists only right now.
        if isinstance(error, TraceNotComplete):
            failure["pl_state"] = error.state
            # On the M8 diagnostic image the ring still holds the decisions
            # the detector took over the missed packet. Reading 4096 entries
            # takes tens of seconds; only a miss is worth it.
            try:
                slow = argparse.Namespace(**vars(args))
                slow.command_timeout = max(args.command_timeout, 600)
                failure["decision_history"] = read_history(slow)
            except Exception as history_error:  # noqa: BLE001
                failure["decision_history_error"] = (
                    f"{type(history_error).__name__}: {history_error}"
                )
        # When the recording finished but the trace could not be read, the
        # IQ still says whether a packet was on the air: without it, "the
        # programmable logic never detected it" and "nothing was received"
        # look identical in the record. Best effort only; a failure here must
        # not replace the original error.
        if stage in ("read_trace", "fetch_iq", "check_burst_ratio"):
            try:
                if not local_iq.exists():
                    fetch_binary(args, REMOTE_IQ, local_iq)
                failure["iq_capture"] = local_iq.name
                failure["iq_burst_ratio"] = round(burst_ratio(local_iq), 1)
            except Exception as fetch_error:  # noqa: BLE001
                failure["iq_fetch_error"] = (
                    f"{type(fetch_error).__name__}: {fetch_error}"
                )
        trace_path = args.run_dir / f"clg400-trace-{stamp}.json"
        trace_path.write_text(
            json.dumps(failure, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        raise

    if args.keep_iq == "anomalies" and not iq_worth_keeping(report):
        local_iq.unlink()
        report["serial"]["iq_capture"] = None
        report["iq_discarded"] = True
    trace_path = args.run_dir / f"clg400-trace-{stamp}.json"
    trace_path.write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    decode = report["decode"]
    print(
        f"[{stamp}] seq={record['sequence']} "
        f"capture_sequence={report['capture_sequence']} "
        f"count={report['captured_count']} realigned={report['grid_realigned']} "
        f"preamble_bin={report['preamble_bin']} "
        f"header={decode['header_valid']} crc={decode['crc_valid']} "
        f"iq={downloaded} bytes burst={ratio:.0f}x"
    )
    return report


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="192.168.40.1")
    parser.add_argument("--user", default="root")
    parser.add_argument("--identity", type=Path)
    parser.add_argument(
        "--password-env",
        help="read the SSH password from environment variable NAME via paramiko",
    )
    parser.add_argument("--known-hosts", type=Path)
    parser.add_argument("--connect-timeout", type=int, default=5)
    parser.add_argument("--command-timeout", type=int, default=600)
    parser.add_argument("--depth", type=int, default=128)
    parser.add_argument("--port", default="COM10")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--attempts", type=int, default=1)
    parser.add_argument("--iq-samples", type=int, default=DEFAULT_IQ_SAMPLES)
    parser.add_argument("--settle-s", type=float, default=0.25)
    parser.add_argument("--gap-s", type=float, default=1.5)
    parser.add_argument("--capture-timeout-s", type=float, default=60)
    parser.add_argument(
        "--full-rearm-every-attempt",
        action="store_true",
        help="pulse stream_reset (which zeros the absolute sample counter) "
        "before every attempt instead of only the first; the control arm "
        "for comparing against the default trace_rearm path",
    )
    parser.add_argument(
        "--min-burst-ratio",
        type=float,
        default=50.0,
        help="reject a recording whose peak-to-median power is below this; "
        "a real packet gives several hundred, noise alone gives about one",
    )
    parser.add_argument(
        "--keep-iq",
        choices=["all", "anomalies"],
        default="all",
        help="'anomalies' deletes the 6 MB recording of an ordinary decoded "
        "packet after its record is written (see iq_worth_keeping); failed "
        "attempts always keep theirs. For long series on a full disk.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    completed = 0
    for index in range(args.attempts):
        try:
            # Only the first attempt of a series pulses the full stream_reset
            # (guaranteeing a clean start); every attempt after it re-arms
            # with trace_rearm instead (M6), so the series keeps one
            # continuous absolute sample counter across all of it.
            capture_once(
                args, full_rearm=(index == 0 or args.full_rearm_every_attempt)
            )
            completed += 1
        except Exception as error:  # noqa: BLE001 - one attempt must not end the run
            print(
                f"ATTEMPT {index + 1} FAILED: {type(error).__name__}: {error}",
                file=sys.stderr,
            )
        if index + 1 < args.attempts:
            time.sleep(args.gap_s)
    print(f"attempts={args.attempts} captured={completed}")
    return 0 if completed else 1


if __name__ == "__main__":
    raise SystemExit(main())
