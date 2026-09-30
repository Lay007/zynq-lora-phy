#!/usr/bin/env python3
"""Arm, read, and hard-decode the frozen CLG400 LoRa symbol trace."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import asdict, dataclass, replace
from pathlib import Path

from zynq_lora_phy import decode_lora_symbol_trace


CONTROL = "0x79040404"
STATUS = "0x79040408"
SEQUENCE = "0x79040448"
SYMBOL = "0x79040488"
SAMPLE_LO = "0x790404c8"
SAMPLE_HI = "0x79040508"
METRICS = "0x79040548"
DEBUG = "0x79040588"
SIGNATURE = "0x790405c8"

# "DH": the decision-history page (gp_ctrl bit 4) of the M8 diagnostic image.
HISTORY_MARKER = 0x4448
HISTORY_DEPTH = 4096


def _signed32(value: int) -> int:
    """Two's complement: the correction and the offset are both signed."""

    return value - (1 << 32) if value & (1 << 31) else value


@dataclass(frozen=True)
class TraceEntry:
    index: int
    symbol: int
    sample_count: int
    confidence_q15: int
    flags: int


@dataclass(frozen=True)
class ClockAccounting:
    """What the receiver clock actually is, read from the board.

    The receiver spent this project clocked from the AD9361 divided data
    clock, which is the sample rate itself, so it had one clock per
    sample where the joint search budget assumes sixty-three. Nothing in
    RTL or simulation can see that - the coupling lives in the board
    wiring - so the board reports it and every capture checks it.
    """

    clocks_per_sample: int
    clocks_per_sample_min: int
    search_clocks: int
    search_count: int
    crossing_overflow: bool
    # Samples the receive crossing has dropped since boot (M8 diagnostic
    # image). crossing_overflow is "at least once since boot" and was set on
    # every capture of the M7 series; the count, compared between attempts,
    # says whether a particular attempt lost samples. None on older images.
    crossing_drop_count: int | None = None


@dataclass(frozen=True)
class JointEstimate:
    """What the board's joint estimator was told, found and concluded.

    The correction the board applies is not the one the reference model
    derives from the same packet, and the two cannot be compared without
    these: the board measures its offsets from packet_start_count plus
    chips_to_boundary, the model from an origin it derives from the trace.
    """

    correction_samples: int
    up_offset_samples: int
    # Low 32 bits only: the joint page has one register for it. The sample
    # counter passes 2^32 every 71.6 minutes at 1 MS/s, so compare it with
    # the 64-bit page-0 timestamp modulo 2^32 (on 2026-09-25 about half the
    # records of a 3-hour series differed from page0_coarse by 2^32 or 2^33
    # exactly, following the page-0 high word).
    up_coarse_start: int
    packet_start_count: int
    chips_to_boundary: int
    preamble_bin: int
    seen: bool
    # Sticky since the last stream reset (STATUS bits 4:1). An abort never
    # pulses the controller's timing_valid, so before these existed a failed
    # estimate and "no packet yet" looked identical on this page -- `seen`
    # alone cannot tell them apart, and up/down aborts used to share one
    # bit upstream too.
    up_search_aborted: bool
    down_search_aborted: bool
    timing_rejected_out_of_range: bool
    precise_correction_applied: bool
    # STATUS bit 5, sticky like the four above: at least one packet since the
    # last re-arm was accepted only through the detector's straddle-tolerant
    # path (M7), i.e. one the generated sync rule alone would have lost.
    detector_straddle_accepted: bool = False
    # STATUS bit 6, sticky likewise: accepted only through the detector's
    # split-tolerant path (M9) -- the preamble peak split into two lobes.
    detector_split_accepted: bool = False
    # STATUS bit 7, sticky likewise: accepted only through the detector's
    # early-sync path -- the tie window at half a symbol read as sync.
    detector_early_sync_accepted: bool = False


class TraceNotComplete(ValueError):
    """The frozen trace buffer holds no finished capture.

    ``state`` is what the same read saw of the rest of the programmable logic:
    the page-0 counters (metadata sequence, coarse ToA, status), the joint
    page's sticky outcome bits and the clock page's crossing flag. Without it
    a detection miss ("the detector never fired") cannot be told from a packet
    that was detected but never traced, or from a sample stream that stalled,
    once the next attempt's re-arm has cleared the sticky bits.
    """

    def __init__(self, message: str, state: dict[str, object]) -> None:
        super().__init__(message)
        self.state = state


@dataclass(frozen=True)
class SymbolTrace:
    capture_sequence: int
    preamble_bin: int
    captured_count: int
    grid_realigned: bool
    entries: tuple[TraceEntry, ...]
    clock: ClockAccounting | None = None
    joint: JointEstimate | None = None
    # Page 0 at the time of the read (M8 tooling): the published timestamp.
    timestamp: dict[str, object] | None = None


def _ssh_args(args: argparse.Namespace) -> list[str]:
    command = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        f"ConnectTimeout={args.connect_timeout}",
    ]
    if args.identity:
        command.extend(["-i", str(args.identity)])
    command.extend([f"{args.user}@{args.host}", "sh", "-s"])
    return command


def _run_remote(args: argparse.Namespace, script: str) -> str:
    if args.password_env:
        password = os.environ.get(args.password_env)
        if password is None:
            raise ValueError(
                f"SSH password environment variable {args.password_env!r} is not set"
            )
        try:
            import paramiko
        except ImportError as error:
            raise RuntimeError(
                "password SSH requires the hardware extra (paramiko)"
            ) from error

        client = paramiko.SSHClient()
        if args.known_hosts:
            client.load_host_keys(str(args.known_hosts))
        else:
            client.load_system_host_keys()
        client.set_missing_host_key_policy(paramiko.RejectPolicy())
        try:
            try:
                client.connect(
                    args.host,
                    username=args.user,
                    password=password,
                    timeout=args.connect_timeout,
                    banner_timeout=args.connect_timeout,
                    auth_timeout=args.connect_timeout,
                    allow_agent=False,
                    look_for_keys=False,
                )
                stdin, stdout, stderr = client.exec_command(
                    "sh -s", timeout=args.command_timeout
                )
                stdin.write(script)
                stdin.flush()
                stdin.channel.shutdown_write()
                output = stdout.read().decode("utf-8", errors="replace")
                detail = stderr.read().decode("utf-8", errors="replace").strip()
                status = stdout.channel.recv_exit_status()
            except paramiko.SSHException as error:
                raise RuntimeError(f"remote CLG400 SSH failed: {error}") from error
        finally:
            client.close()
        if status:
            raise RuntimeError(f"remote CLG400 command failed: {detail or output.strip()}")
        return output

    completed = subprocess.run(
        _ssh_args(args),
        input=script,
        text=True,
        capture_output=True,
        check=False,
        timeout=args.command_timeout,
    )
    if completed.returncode:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"remote CLG400 command failed: {detail}")
    return completed.stdout


def arm_trace(args: argparse.Namespace) -> None:
    # This only resets/re-arms the receive stream. It does not touch QSPI,
    # FPGA manager, AD9361 TX controls, or any RF transmitter.
    script = f"""set -eu
orig=$(devmem {CONTROL} 32)
reset=$((orig | 2))
run=$((orig & 0xfffffffd))
devmem {CONTROL} 32 "$reset" >/dev/null
sleep 1
devmem {CONTROL} 32 "$run" >/dev/null
printf 'armed control=0x%08x\\n' "$run"
"""
    output = _run_remote(args, script).strip()
    print(output)


def _read_script(depth: int) -> str:
    return f"""set -eu
orig=$(devmem {CONTROL} 32)
restore() {{ devmem {CONTROL} 32 "$orig" >/dev/null; }}
trap restore EXIT HUP INT TERM
sig=$(devmem {SIGNATURE} 32)
printf 'SIGNATURE %s\\n' "$sig"
histsel=$(((orig & 0x8000ffef) | 0x10))
devmem {CONTROL} 32 "$histsel" >/dev/null
printf 'HISTORY %s %s %s\\n' "$(devmem {STATUS} 32)" \\
  "$(devmem {SEQUENCE} 32)" "$(devmem {METRICS} 32)"
page0sel=$((orig & 0x80f8ffff))
devmem {CONTROL} 32 "$page0sel" >/dev/null
printf 'PAGE0 %s %s %s %s %s %s\\n' "$(devmem {STATUS} 32)" \\
  "$(devmem {SEQUENCE} 32)" "$(devmem {SYMBOL} 32)" \\
  "$(devmem {SAMPLE_LO} 32)" "$(devmem {SAMPLE_HI} 32)" \\
  "$(devmem {METRICS} 32)"
jointsel=$(((orig & 0x80f8ffff) | 0x00040000))
devmem {CONTROL} 32 "$jointsel" >/dev/null
printf 'JOINT %s %s %s %s %s %s\\n' "$(devmem {STATUS} 32)" \\
  "$(devmem {SEQUENCE} 32)" "$(devmem {SYMBOL} 32)" \\
  "$(devmem {SAMPLE_LO} 32)" "$(devmem {SAMPLE_HI} 32)" \\
  "$(devmem {METRICS} 32)"
clocksel=$(((orig & 0x80f8ffff) | 0x00020000))
devmem {CONTROL} 32 "$clocksel" >/dev/null
c=0
while [ "$c" -lt 8 ]; do
  printf 'CLOCK %s %s %s %s %s\\n' "$(devmem {STATUS} 32)" \\
    "$(devmem {SEQUENCE} 32)" "$(devmem {SYMBOL} 32)" \\
    "$(devmem {SAMPLE_LO} 32)" "$(devmem {SAMPLE_HI} 32)"
  c=$((c + 1))
done
i=0
while [ "$i" -lt {depth} ]; do
  selector=$(((orig & 0x80f8ffff) | 0x00010000 | (i << 24)))
  devmem {CONTROL} 32 "$selector" >/dev/null
  status=$(devmem {STATUS} 32)
  sequence=$(devmem {SEQUENCE} 32)
  symbol=$(devmem {SYMBOL} 32)
  sample_lo=$(devmem {SAMPLE_LO} 32)
  sample_hi=$(devmem {SAMPLE_HI} 32)
  metrics=$(devmem {METRICS} 32)
  debug=$(devmem {DEBUG} 32)
  printf 'ENTRY %u %s %s %s %s %s %s %s\\n' \
    "$i" "$status" "$sequence" "$symbol" "$sample_lo" "$sample_hi" \
    "$metrics" "$debug"
  i=$((i + 1))
done
"""


def _timestamp_summary(page0: list[int]) -> dict[str, object]:
    """Page 0: the last packet timestamp the board published, as software sees it.

    Registers in read order: STATUS, SEQUENCE, SYMBOL (coarse low word),
    SAMPLE_LO (coarse high word), SAMPLE_HI (Q12 fraction, signed), METRICS
    (log peak, signed). Until 2026-09-24 the script read only STATUS, SEQUENCE,
    SAMPLE_LO and SAMPLE_HI and labelled the last two coarse_lo/coarse_hi, so
    those two fields in earlier failure records are really coarse_hi and the
    fraction.
    """

    return {
        "page0_status": f"0x{page0[0]:08x}",
        "page0_sequence": page0[1],
        "page0_coarse": page0[2] | (page0[3] << 32),
        "page0_fraction_q12": _signed32(page0[4]),
        "page0_log_peak_q12": _signed32(page0[5]),
    }


def parse_trace(text: str) -> SymbolTrace:
    signature: int | None = None
    clock: ClockAccounting | None = None
    joint: JointEstimate | None = None
    page0: list[int] | None = None
    history: list[int] | None = None
    rows: list[tuple[int, ...]] = []
    for line in text.splitlines():
        fields = line.split()
        if not fields:
            continue
        if fields[0] == "SIGNATURE" and len(fields) == 2:
            signature = int(fields[1], 0)
        elif fields[0] == "PAGE0" and len(fields) == 7:
            page0 = [int(value, 0) for value in fields[1:]]
        elif fields[0] == "HISTORY" and len(fields) == 4:
            values = [int(value, 0) for value in fields[1:]]
            # Older images have no history page: bit 4 selects nothing and
            # the read falls through to page 0, whose status has no marker.
            if (values[0] >> 16) == HISTORY_MARKER:
                history = values
        elif fields[0] == "JOINT" and len(fields) == 7:
            values = [int(value, 0) for value in fields[1:]]
            if (values[0] >> 16) != 0x4A54:
                raise ValueError(
                    "joint page marker is 0x%04x, not 0x4a54; the bitstream "
                    "predates the joint estimator page" % (values[0] >> 16)
                )
            joint = JointEstimate(
                correction_samples=_signed32(values[1]),
                up_offset_samples=_signed32(values[2]),
                up_coarse_start=values[3],
                packet_start_count=values[4],
                chips_to_boundary=(values[5] >> 16) & 0xFFFF,
                preamble_bin=values[5] & 0xFFFF,
                seen=bool(values[0] & 1),
                up_search_aborted=bool(values[0] & 2),
                down_search_aborted=bool(values[0] & 4),
                timing_rejected_out_of_range=bool(values[0] & 8),
                precise_correction_applied=bool(values[0] & 16),
                detector_straddle_accepted=bool(values[0] & 32),
                detector_split_accepted=bool(values[0] & 64),
                detector_early_sync_accepted=bool(values[0] & 128),
            )
        elif fields[0] == "CLOCK" and len(fields) == 6:
            values = [int(value, 0) for value in fields[1:]]
            status = values[0]
            if (status >> 16) != 0x434B:
                raise ValueError(
                    "clock page marker is 0x%04x, not 0x434b; the bitstream "
                    "predates the fixed receiver clock" % (status >> 16)
                )
            # util_wfifo bursts eight samples at a time, so one reading
            # can land inside a burst and report a one-clock gap that
            # is real but not the steady-state ratio. Keep the largest.
            clock = ClockAccounting(
                clocks_per_sample=max(
                    values[1],
                    clock.clocks_per_sample if clock else 0,
                ),
                clocks_per_sample_min=values[3],
                search_clocks=max(
                    values[2],
                    clock.search_clocks if clock else 0,
                ),
                search_count=values[4],
                crossing_overflow=bool(status & 1)
                or bool(clock and clock.crossing_overflow),
            )
        elif fields[0] == "ENTRY" and len(fields) == 9:
            rows.append(tuple([int(fields[1], 10)] + [int(value, 0) for value in fields[2:]]))
    if signature != 0x4C4F5241:
        raise ValueError(f"unexpected bridge signature: {signature!r}")
    if history is not None and clock is not None:
        clock = replace(clock, crossing_drop_count=history[2] & 0xFFFF)
    if not rows:
        raise ValueError("remote output contained no trace entries")

    status_values = {row[1] for row in rows}
    sequence_values = {row[2] for row in rows}
    debug_values = {row[7] & 0xFFFF01FF for row in rows}
    if len(status_values) != 1 or len(sequence_values) != 1 or len(debug_values) != 1:
        raise ValueError("trace status changed while the frozen buffer was read")

    status = rows[0][1]
    if status >> 16 != 0x5359:
        raise ValueError(f"symbol-trace page is unavailable: status=0x{status:08x}")
    captured_count = status & 0xFF
    capture_active = bool(status & 0x100)
    capture_complete = bool(status & 0x200)
    if capture_active or not capture_complete:
        state: dict[str, object] = {
            "trace_status": f"0x{status:08x}",
            "capture_sequence": rows[0][2],
        }
        if page0 is not None:
            state.update(
                **_timestamp_summary(page0),
            )
        if joint is not None:
            state.update(
                joint_seen=joint.seen,
                up_search_aborted=joint.up_search_aborted,
                down_search_aborted=joint.down_search_aborted,
                detector_straddle_accepted=joint.detector_straddle_accepted,
                detector_split_accepted=joint.detector_split_accepted,
                detector_early_sync_accepted=joint.detector_early_sync_accepted,
            )
        if clock is not None:
            state.update(
                crossing_overflow=clock.crossing_overflow,
                clocks_per_sample_min=clock.clocks_per_sample_min,
            )
        if history is not None:
            state.update(
                crossing_drop_count=history[2] & 0xFFFF,
                history_frozen=bool(history[0] & (1 << 12)),
                history_newest=history[0] & 0xFFF,
                history_written=history[1],
            )
        raise TraceNotComplete(
            f"symbol trace is not complete: active={capture_active}, "
            f"captured={captured_count}",
            state,
        )
    if captured_count > len(rows):
        raise ValueError("captured count exceeds returned trace depth")

    preamble_bin = rows[0][7] >> 16
    grid_realigned = bool(rows[0][7] & 0x100)
    entries = tuple(
        TraceEntry(
            index=row[0],
            symbol=row[3],
            sample_count=row[4] | (row[5] << 32),
            confidence_q15=row[6] & 0xFFFF,
            flags=(row[6] >> 16) & 0xFF,
        )
        for row in rows[:captured_count]
    )
    return SymbolTrace(
        rows[0][2], preamble_bin, captured_count, grid_realigned, entries,
        clock, joint, _timestamp_summary(page0) if page0 is not None else None
    )


def _history_script(depth: int) -> str:
    """Read the frozen decision-history ring (M8 diagnostic image).

    Bit 3 is forced on so the ring stays stopped while it is read (the
    recording command already set it the moment the recording ended); the
    trap restores CONTROL as it found it, still frozen, and the next attempt's
    arm releases it. The read index is 12 bits: 24-30 low, 19-23 high.
    """

    return f"""set -eu
orig=$(devmem {CONTROL} 32)
restore() {{ devmem {CONTROL} 32 "$orig" >/dev/null; }}
trap restore EXIT HUP INT TERM
base=$(((orig & 0x8000ffef) | 0x18))
devmem {CONTROL} 32 "$base" >/dev/null
printf 'HSTATUS %s %s %s\\n' "$(devmem {STATUS} 32)" \\
  "$(devmem {SEQUENCE} 32)" "$(devmem {METRICS} 32)"
i=0
while [ "$i" -lt {depth} ]; do
  devmem {CONTROL} 32 $((base | ((i & 0x7f) << 24) | ((i >> 7) << 19))) >/dev/null
  printf 'H %u %s %s %s\\n' "$i" "$(devmem {SYMBOL} 32)" \\
    "$(devmem {SAMPLE_LO} 32)" "$(devmem {SAMPLE_HI} 32)"
  i=$((i + 1))
done
"""


def parse_history(text: str, depth: int = HISTORY_DEPTH) -> dict[str, object]:
    """Decode a history read into the ring's entries, oldest first."""

    status: list[int] | None = None
    raw: dict[int, tuple[int, int, int]] = {}
    for line in text.splitlines():
        fields = line.split()
        if fields[:1] == ["HSTATUS"] and len(fields) == 4:
            status = [int(value, 0) for value in fields[1:]]
        elif fields[:1] == ["H"] and len(fields) == 5:
            raw[int(fields[1], 10)] = tuple(int(value, 0) for value in fields[2:])
    if status is None or (status[0] >> 16) != HISTORY_MARKER:
        raise ValueError(
            "no decision-history page: the bitstream predates the M8 diagnostics"
        )
    frozen = bool(status[0] & (1 << 12))
    newest = status[0] & 0xFFF
    written = status[1]
    if written >= depth:
        order = [(newest + 1 + k) % depth for k in range(depth)]
    else:
        order = list(range(written))
    entries = []
    for index in order:
        if index not in raw:
            continue
        sample_count, packed, bin_word = raw[index]
        flags = (packed >> 24) & 0xFF
        if not flags & 1:
            continue
        entries.append(
            {
                "index": index,
                "sample_count_low": sample_count,
                "bin": bin_word & 0xFF,
                "confidence_q15": packed & 0xFFFF,
                "drop_count_low": (packed >> 16) & 0xFF,
                "detected": bool(flags & 2),
                "straddle": bool(flags & 4),
                "grid_resync_armed": bool(flags & 8),
            }
        )
    return {
        "frozen": frozen,
        "newest_index": newest,
        "written": written,
        "crossing_drop_count": status[2] & 0xFFFF,
        "entries": entries,
    }


def read_history(args: argparse.Namespace, depth: int = HISTORY_DEPTH) -> dict[str, object]:
    return parse_history(_run_remote(args, _history_script(depth)), depth)


def read_trace(args: argparse.Namespace) -> SymbolTrace:
    return parse_trace(_run_remote(args, _read_script(args.depth)))


def _payload_summary(payload: bytes) -> dict[str, object]:
    printable = "".join(chr(value) if 32 <= value < 127 else "." for value in payload)
    summary: dict[str, object] = {"hex": payload.hex(), "ascii": printable}
    if len(payload) >= 12 and payload[:4] == b"ZLP1":
        summary.update(
            {
                "format": "ZLP1",
                "sequence": int.from_bytes(payload[4:8], "little"),
                "start_ms": int.from_bytes(payload[8:12], "little"),
            }
        )
    return summary


def grid_phase(trace: SymbolTrace) -> int:
    """The bin offset software still has to remove from the raw decisions.

    The preamble bin measures where the symbol grid sat when the packet
    arrived. If the receiver then realigned its grid to that packet, it has
    already removed the offset -- including the integer part of any carrier
    offset, which an upchirp-only measurement cannot tell apart from timing --
    and the raw decisions are the transmitted symbols. Subtracting the measured
    bin again would remove it twice.
    """

    return 0 if trace.grid_realigned else trace.preamble_bin


# One 1 MS/s sample every 62.5 clocks of the fixed 62.5 MHz receiver clock.
# Anything near one clock per sample means the receiver is back on the AD9361
# divided data clock, where the joint search cannot finish inside a packet.
EXPECTED_CLOCKS_PER_SAMPLE = 63
CLOCKS_PER_SAMPLE_TOLERANCE = 3


def _clock_summary(clock: ClockAccounting | None) -> dict[str, object] | None:
    """Report the receiver clock and whether it is the one the design needs."""

    if clock is None:
        return None
    low = EXPECTED_CLOCKS_PER_SAMPLE - CLOCKS_PER_SAMPLE_TOLERANCE
    high = EXPECTED_CLOCKS_PER_SAMPLE + CLOCKS_PER_SAMPLE_TOLERANCE
    healthy = low <= clock.clocks_per_sample <= high
    return {
        "clocks_per_sample": clock.clocks_per_sample,
        "clocks_per_sample_min": clock.clocks_per_sample_min,
        "clocks_per_sample_expected": EXPECTED_CLOCKS_PER_SAMPLE,
        "clocks_per_sample_ok": healthy,
        "search_clocks": clock.search_clocks,
        "search_count": clock.search_count,
        # The deadline follows the clock that is actually running, not the
        # one that should be: on the AD9361-derived clock the whole SFD is
        # 2304 clocks, and scoring against 145152 is how a fifty-nine-fold
        # overshoot came to look comfortable in the first place.
        "sfd_deadline_clocks": 2304 * clock.clocks_per_sample,
        "search_within_sfd": (
            clock.search_clocks > 0
            and clock.search_clocks <= 2304 * clock.clocks_per_sample
        ),
        "crossing_overflow": clock.crossing_overflow,
        "crossing_drop_count": clock.crossing_drop_count,
    }

def _joint_summary(joint: JointEstimate | None) -> dict[str, object] | None:
    """Report what the board's estimator was told, found and concluded."""

    if joint is None:
        return None
    return {
        "correction_samples": joint.correction_samples,
        "up_offset_samples": joint.up_offset_samples,
        "up_coarse_start": joint.up_coarse_start,
        "packet_start_count": joint.packet_start_count,
        "chips_to_boundary": joint.chips_to_boundary,
        "preamble_bin": joint.preamble_bin,
        # The controller derives its origin this way; recomputing it here lets
        # a mismatch between the two be seen without reading the RTL.
        "derived_up_coarse_start": (
            joint.packet_start_count + joint.chips_to_boundary * 8
        ),
        "estimate_seen": joint.seen,
        # Sticky since the last stream reset. An abort never sets
        # estimate_seen (the controller's timing_valid does not pulse), so
        # these are what tell "no packet yet" apart from "it ran and one of
        # the three silent paths back to idle fired" -- and from each other.
        "up_search_aborted": joint.up_search_aborted,
        "down_search_aborted": joint.down_search_aborted,
        "timing_rejected_out_of_range": joint.timing_rejected_out_of_range,
        "precise_correction_applied": joint.precise_correction_applied,
        "detector_straddle_accepted": joint.detector_straddle_accepted,
        "detector_split_accepted": joint.detector_split_accepted,
        "detector_early_sync_accepted": joint.detector_early_sync_accepted,
    }


def build_report(trace: SymbolTrace) -> dict[str, object]:
    candidate = decode_lora_symbol_trace(
        [entry.symbol for entry in trace.entries], grid_phase(trace)
    )
    result = candidate.result
    header = asdict(result.header) if result.header is not None else None
    return {
        "schema": "zynq-lora-clg400-symbol-trace-v1",
        "capture_sequence": trace.capture_sequence,
        "preamble_bin": trace.preamble_bin,
        "grid_phase_removed": grid_phase(trace),
        "captured_count": trace.captured_count,
        "grid_realigned": trace.grid_realigned,
        "receiver_clock": _clock_summary(trace.clock),
        "joint_estimate": _joint_summary(trace.joint),
        # The published packet timestamp (page 0), read with the trace. On
        # the M8 image it is the joint (up + down) / 2 time; before, the up
        # leg's peak. Compare with joint_estimate: up_coarse_start + correction
        # is the new one's whole-sample part, up_coarse_start + up_offset the
        # old one's.
        "timestamp": trace.timestamp,
        "decode": {
            "success": result.success,
            "header_valid": result.header_valid,
            "crc_valid": result.crc_valid,
            "failure_reason": result.failure_reason,
            "symbol_offset": candidate.symbol_offset,
            "bin_adjustment": candidate.bin_adjustment,
            "consumed_symbol_count": result.consumed_symbol_count,
            "header": header,
            "payload": _payload_summary(result.payload),
        },
        "entries": [asdict(entry) for entry in trace.entries],
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="192.168.40.1")
    parser.add_argument("--user", default="root")
    parser.add_argument("--identity", type=Path)
    parser.add_argument(
        "--password-env",
        metavar="NAME",
        help="read the SSH password from environment variable NAME via paramiko",
    )
    parser.add_argument(
        "--known-hosts",
        type=Path,
        help="pinned known_hosts file for password SSH; system known_hosts otherwise",
    )
    parser.add_argument("--depth", type=int, default=128, choices=[128])
    parser.add_argument("--connect-timeout", type=int, default=5)
    parser.add_argument("--command-timeout", type=int, default=60)
    parser.add_argument(
        "--arm",
        action="store_true",
        help="re-arm the RX-only trace before reading; send the packet separately",
    )
    parser.add_argument("--output", type=Path, help="write the full trace/report JSON")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.arm:
            arm_trace(args)
            print("Trace armed. Send one packet, wait 0.2 s, then rerun without --arm.")
            return 0
        report = build_report(read_trace(args))
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    rendered = json.dumps(report, indent=2, ensure_ascii=False)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered + "\n", encoding="utf-8")
    decode = report["decode"]
    payload = decode["payload"]
    print(
        f"capture={report['capture_sequence']} symbols={report['captured_count']} "
        f"preamble_bin={report['preamble_bin']} "
        f"grid_realigned={report['grid_realigned']} "
        f"offset={decode['symbol_offset']} "
        f"bin_adjust={decode['bin_adjustment']}"
    )
    print(
        f"header_valid={decode['header_valid']} crc_valid={decode['crc_valid']} "
        f"payload={payload['hex']}"
    )
    if payload.get("format") == "ZLP1":
        print(f"ZLP1 sequence={payload['sequence']} start_ms={payload['start_ms']}")
    if args.output:
        print(f"saved {args.output}")
    return 0 if decode["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
