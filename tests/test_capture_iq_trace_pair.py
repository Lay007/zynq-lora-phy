"""Checks for the paired IQ/trace capture tool.

Most of the tool drives hardware, so these cover the parts that decide what the
board is asked to do. A wrong recording command is the failure that would
silently produce an unusable capture after a bench session has already been
spent.
"""

import pytest

import inspect

import numpy as np

from tools import capture_clg400_iq_trace_pair as tool
from tools.capture_clg400_iq_trace_pair import (
    DEFAULT_IQ_SAMPLES,
    REMOTE_IQ,
    iio_capture_command,
    utc_stamp,
)


def test_the_default_recording_brackets_one_packet() -> None:
    # 1.5 s at 1 MS/s against an ~83 ms SF7 packet.
    assert DEFAULT_IQ_SAMPLES == 1_500_000
    assert DEFAULT_IQ_SAMPLES / 1_000_000 > 10 * 0.083


def test_the_recording_command_selects_both_iq_channels() -> None:
    command = iio_capture_command(DEFAULT_IQ_SAMPLES, REMOTE_IQ)
    # Both channels, or the analysis gets real samples instead of complex ones.
    assert "voltage0 voltage1" in command
    assert "cf-ad9361-lpc" in command
    assert f"-s {DEFAULT_IQ_SAMPLES}" in command


def test_the_recording_command_detaches_and_records_its_status() -> None:
    command = iio_capture_command(1000, REMOTE_IQ)
    # Detached, so the transmission can happen while the buffer fills.
    assert command.rstrip().endswith("&")
    # The exit status has to survive detaching or a failed recording looks
    # identical to a slow one. It is iio_readdev's status, taken before the
    # history freeze runs, not the freeze's.
    assert f"2>{REMOTE_IQ}.err; s=$?;" in command
    assert f"echo $s > {REMOTE_IQ}.done" in command
    # A stale recording or sentinel from a previous attempt must not be
    # mistaken for this one.
    assert command.startswith(f"rm -f {REMOTE_IQ} {REMOTE_IQ}.done")
    # The script reaches the board on `sh -s` stdin. A plain background job
    # dies when that shell exits, and the recording then comes back empty.
    assert "nohup " in command and "</dev/null" in command


def test_the_recording_command_writes_where_the_caller_asked() -> None:
    command = iio_capture_command(64, "/tmp/other.bin")
    assert "> /tmp/other.bin" in command
    assert "/tmp/other.bin.done" in command


@pytest.mark.parametrize("samples", [0, -1])
def test_a_nonpositive_sample_count_is_rejected(samples: int) -> None:
    with pytest.raises(ValueError, match="positive"):
        iio_capture_command(samples, REMOTE_IQ)


def test_a_quoted_remote_path_is_rejected() -> None:
    # The path is embedded in a single-quoted `sh -c` argument.
    with pytest.raises(ValueError, match="single quote"):
        iio_capture_command(64, "/tmp/we'ird.bin")


def test_the_stamp_is_a_sortable_utc_basename() -> None:
    stamp = utc_stamp()
    assert stamp.endswith("Z") and "T" in stamp
    assert len(stamp) == len("20260908T065448Z")
    assert stamp.replace("T", "").replace("Z", "").isdigit()


def test_the_size_probe_avoids_stat() -> None:
    """The board image is busybox without `stat`.

    A missing `stat` behind a `|| echo 0` fallback reports every recording as
    empty, which reads as a failed capture on a link that is actually fine.
    """

    source = inspect.getsource(tool.wait_for_capture)
    assert "wc -c" in source
    assert "stat " not in source


def test_burst_ratio_separates_a_packet_from_noise(tmp_path) -> None:
    """A full-length recording with no packet must not pass as a capture."""

    from tools.capture_clg400_iq_trace_pair import burst_ratio

    rng = np.random.default_rng(3)
    size = 200_000
    noise = rng.normal(0, 2, size * 2)

    quiet = tmp_path / "quiet.bin"
    np.round(noise).astype("<i2").tofile(quiet)
    assert burst_ratio(quiet) < 10

    withburst = noise.copy()
    withburst[40_000:120_000] += rng.normal(0, 60, 80_000)
    loud = tmp_path / "loud.bin"
    np.round(withburst).astype("<i2").tofile(loud)
    assert burst_ratio(loud) > 100


def test_the_transmitter_is_prepared_before_the_recording_starts() -> None:
    """Profile verification costs seconds of serial round trips.

    Doing it inside the recording window pushes the send past the end of a
    1.5 s capture, which yields a correctly sized file containing only noise.
    """

    source = inspect.getsource(tool.capture_once)
    prepare = source.index('transmitter.command("stop"')
    start = source.index("iio_capture_command")
    send = source.index('"send"')
    assert prepare < start < send


def test_the_recording_freezes_the_decision_history_before_reporting_done() -> None:
    """The ring holds ~4 s; the packet is ~1.3 s before the recording ends.

    The freeze has to happen on the board the moment the recording ends. If
    the host saw the sentinel first, the trace read that follows would take
    long enough for a missed packet's decisions to be overwritten.
    """

    command = iio_capture_command(1000, REMOTE_IQ)
    freeze = command.index("| 8 ))")
    assert command.index("iio_readdev") < freeze < command.index(f"> {REMOTE_IQ}.done")


@pytest.mark.parametrize("full", [True, False])
def test_every_arm_releases_the_decision_history_freeze(monkeypatch, full) -> None:
    scripts = []
    monkeypatch.setattr(tool, "_run_remote", lambda args, script: scripts.append(script) or "armed")

    tool.arm_receive_stream(object(), full=full)

    script = scripts[0]
    # Both the pulse value and the run value clear bit 3.
    assert "orig & 0xFFFFFFF7" in script
    run_line = next(line for line in script.splitlines() if line.startswith("run="))
    mask = int(run_line.split("& ")[1].rstrip("))"), 0)
    assert not mask & 0x8



def _ok_report(**joint) -> dict:
    base = {"precise_correction_applied": True}
    base.update(joint)
    return {"decode": {"crc_valid": True}, "joint_estimate": base}


def test_an_ordinary_decoded_packet_does_not_keep_its_recording() -> None:
    assert not tool.iq_worth_keeping(_ok_report())


@pytest.mark.parametrize(
    "flag",
    [
        "detector_straddle_accepted",
        "detector_split_accepted",
        "detector_early_sync_accepted",
        "up_search_aborted",
        "down_search_aborted",
        "timing_rejected_out_of_range",
    ],
)
def test_a_rescued_or_irregular_packet_keeps_its_recording(flag) -> None:
    assert tool.iq_worth_keeping(_ok_report(**{flag: True}))


def test_a_crc_failure_or_an_unapplied_estimate_keeps_its_recording() -> None:
    bad_crc = _ok_report()
    bad_crc["decode"]["crc_valid"] = False
    assert tool.iq_worth_keeping(bad_crc)
    assert tool.iq_worth_keeping(_ok_report(precise_correction_applied=False))
    assert tool.iq_worth_keeping({"decode": {"crc_valid": True}})


def test_keep_iq_defaults_to_keeping_everything(monkeypatch) -> None:
    monkeypatch.setattr("sys.argv", ["x", "--run-dir", "r"])
    assert tool.parse_args().keep_iq == "all"
