import pytest

from tools.read_clg400_symbol_trace import (
    JointEstimate,
    ClockAccounting,
    _clock_summary,
    TraceNotComplete,
    parse_history,
    _joint_summary,
    grid_phase,
    parse_trace,
)
from tools.run_clg400_payload_capture import (
    parse_profile,
    parse_transmit_line,
)


NEWLINE = chr(10)


def _trace_page(grid_realigned: bool) -> str:
    lines = ["SIGNATURE 0x4c4f5241"]
    for index in range(128):
        status = 0x53590280
        sequence = 3
        symbol = 10 + index
        sample = 1000 + 1024 * index
        metrics = (2 << 16) | (0x4000 + index)
        debug = (7 << 16) | (index << 9) | (0x100 if grid_realigned else 0) | 128
        lines.append(
            "ENTRY "
            f"{index} 0x{status:08x} 0x{sequence:08x} 0x{symbol:08x} "
            f"0x{sample & 0xffffffff:08x} 0x{sample >> 32:08x} "
            f"0x{metrics:08x} 0x{debug:08x}"
        )
    return "\n".join(lines)


def test_parse_frozen_symbol_trace_page() -> None:
    trace = parse_trace(_trace_page(grid_realigned=False))

    assert trace.capture_sequence == 3
    assert trace.preamble_bin == 7
    assert trace.captured_count == 128
    assert not trace.grid_realigned
    assert trace.entries[5].symbol == 15
    assert trace.entries[5].sample_count == 6120
    assert trace.entries[5].confidence_q15 == 0x4005
    assert trace.entries[5].flags == 2


def test_parse_reports_a_realigned_symbol_grid() -> None:
    """Debug bit 8 says the decisions were taken on the packet grid."""

    trace = parse_trace(_trace_page(grid_realigned=True))

    assert trace.grid_realigned
    assert trace.preamble_bin == 7
    assert trace.captured_count == 128


PROFILE_LINE = (
    "PROFILE freq_mhz=868.100 bw_khz=125.0 sf=7 cr=4/5 sync=0x12 power_dbm=-9 "
    "preamble=12 crc=on iq=normal interval_ms=500 payload=counter length=32 "
    "running=no board_revision=v4.3 fem=kct8103l-bypass revision_probe=0/32 "
    "firmware=0.2.0"
)


def test_parse_profile_reads_the_firmware_show_line() -> None:
    fields = parse_profile(PROFILE_LINE)

    assert fields["freq_mhz"] == "868.100"
    assert fields["sf"] == "7"
    assert fields["cr"] == "4/5"
    assert fields["power_dbm"] == "-9"
    assert fields["running"] == "no"
    assert fields["length"] == "32"


def test_parse_transmit_line_accepts_the_single_send_record() -> None:
    record = parse_transmit_line(
        [
            "OK single packet queued",
            "TX seq=41 len=32 state=0 start_ms=123456 duration_ms=62",
        ]
    )

    assert record == {
        "sequence": 41,
        "payload_length": 32,
        "state": 0,
        "start_ms": 123456,
        "duration_ms": 62,
    }


def test_parse_transmit_line_rejects_a_response_without_a_tx_record() -> None:
    with pytest.raises(RuntimeError):
        parse_transmit_line(["OK transmitter stopped"])


def test_grid_phase_is_removed_only_when_the_receiver_did_not() -> None:
    """Subtracting the preamble bin off a realigned grid would remove it twice."""

    free_running = parse_trace(_trace_page(grid_realigned=False))
    realigned = parse_trace(_trace_page(grid_realigned=True))

    assert grid_phase(free_running) == free_running.preamble_bin == 7
    assert realigned.preamble_bin == 7
    assert grid_phase(realigned) == 0


def _clock_page(
    clocks_per_sample: int = 63,
    minimum: int = 62,
    search_clocks: int = 135443,
    search_count: int = 1,
    overflow: bool = False,
    marker: int = 0x434B,
) -> str:
    status = (marker << 16) | (1 if overflow else 0)
    return (
        f"CLOCK 0x{status:08x} 0x{clocks_per_sample:08x} "
        f"0x{search_clocks:08x} 0x{minimum:08x} 0x{search_count:08x}"
    )


def test_clock_page_reports_the_receiver_clock() -> None:
    text = _trace_page(grid_realigned=False)
    text = text.replace("SIGNATURE 0x4c4f5241", "SIGNATURE 0x4c4f5241\n" + _clock_page())

    trace = parse_trace(text)

    assert trace.clock is not None
    assert trace.clock.clocks_per_sample == 63
    assert trace.clock.clocks_per_sample_min == 62
    assert trace.clock.search_clocks == 135443
    assert not trace.clock.crossing_overflow


def test_clock_summary_accepts_the_fixed_receiver_clock() -> None:
    summary = _clock_summary(
        ClockAccounting(
            clocks_per_sample=63,
            clocks_per_sample_min=62,
            search_clocks=135443,
            search_count=1,
            crossing_overflow=False,
        )
    )

    assert summary is not None
    assert summary["clocks_per_sample_ok"]
    assert summary["sfd_deadline_clocks"] == 145152
    assert summary["search_within_sfd"]


def test_clock_summary_rejects_the_ad9361_derived_clock() -> None:
    """One clock per sample is the defect this page exists to catch.

    The AD9361 divided data clock equals the sample rate, so the whole SFD is
    2304 clocks and the joint search cannot fit in it. Scoring the search
    against the deadline the design *wants* rather than the one it *has* is
    exactly how a fifty-nine-fold overshoot went unnoticed.
    """

    summary = _clock_summary(
        ClockAccounting(
            clocks_per_sample=1,
            clocks_per_sample_min=1,
            search_clocks=55552,
            search_count=1,
            crossing_overflow=False,
        )
    )

    assert summary is not None
    assert not summary["clocks_per_sample_ok"]
    assert summary["sfd_deadline_clocks"] == 2304
    assert not summary["search_within_sfd"]


def test_clock_page_marker_mismatch_is_rejected() -> None:
    text = _trace_page(grid_realigned=False)
    text = text.replace(
        "SIGNATURE 0x4c4f5241",
        "SIGNATURE 0x4c4f5241\n" + _clock_page(marker=0x5359),
    )

    with pytest.raises(ValueError, match="clock page marker"):
        parse_trace(text)


def test_trace_without_a_clock_page_still_parses() -> None:
    """Older bitstreams have no clock page and must stay readable."""

    trace = parse_trace(_trace_page(grid_realigned=False))

    assert trace.clock is None
    assert _clock_summary(trace.clock) is None


def _clock_pages(intervals: list[int]) -> str:
    return NEWLINE.join(
        _clock_page(clocks_per_sample=value, minimum=min(intervals))
        for value in intervals
    )


def test_burst_readings_do_not_look_like_the_ad9361_clock() -> None:
    """util_wfifo hands out eight samples at a time.

    A reading taken inside a burst reports a one-clock gap that is real but is
    not the steady-state ratio, so the page is read several times and the
    largest interval wins. Otherwise a healthy receiver would intermittently
    look exactly like the defect this check exists to catch.
    """

    text = _trace_page(grid_realigned=False).replace(
        "SIGNATURE 0x4c4f5241",
        "SIGNATURE 0x4c4f5241\n" + _clock_pages([1, 63, 1, 62, 63, 63, 1, 63]),
    )

    trace = parse_trace(text)

    assert trace.clock is not None
    assert trace.clock.clocks_per_sample == 63
    summary = _clock_summary(trace.clock)
    assert summary is not None
    assert summary["clocks_per_sample_ok"]


def test_every_reading_one_clock_is_still_caught() -> None:
    """On the AD9361-derived clock there are no spare clocks for a gap."""

    text = _trace_page(grid_realigned=False).replace(
        "SIGNATURE 0x4c4f5241",
        "SIGNATURE 0x4c4f5241\n" + _clock_pages([1] * 8),
    )

    trace = parse_trace(text)

    assert trace.clock is not None
    assert trace.clock.clocks_per_sample == 1
    summary = _clock_summary(trace.clock)
    assert summary is not None
    assert not summary["clocks_per_sample_ok"]
    assert summary["sfd_deadline_clocks"] == 2304


def _joint_page(
    correction: int = -7,
    up_offset: int = 12,
    up_coarse: int = 0x13880,
    packet_start: int = 0x12345,
    chips: int = 31,
    bin_: int = 97,
    seen: bool = True,
    up_search_aborted: bool = False,
    down_search_aborted: bool = False,
    timing_rejected_out_of_range: bool = False,
    precise_correction_applied: bool = False,
    detector_straddle_accepted: bool = False,
    detector_split_accepted: bool = False,
    marker: int = 0x4A54,
) -> str:
    status = (
        (marker << 16)
        | (1 if seen else 0)
        | (2 if up_search_aborted else 0)
        | (4 if down_search_aborted else 0)
        | (8 if timing_rejected_out_of_range else 0)
        | (16 if precise_correction_applied else 0)
        | (32 if detector_straddle_accepted else 0)
        | (64 if detector_split_accepted else 0)
    )
    packed = (chips << 16) | bin_
    return (
        f"JOINT 0x{status:08x} 0x{correction & 0xffffffff:08x} "
        f"0x{up_offset & 0xffffffff:08x} 0x{up_coarse:08x} "
        f"0x{packet_start:08x} 0x{packed:08x}"
    )


def test_joint_page_reports_signed_values() -> None:
    text = _trace_page(grid_realigned=False).replace(
        "SIGNATURE 0x4c4f5241",
        "SIGNATURE 0x4c4f5241\n" + _joint_page(),
    )

    trace = parse_trace(text)

    assert trace.joint is not None
    assert trace.joint.correction_samples == -7
    assert trace.joint.up_offset_samples == 12
    assert trace.joint.chips_to_boundary == 31
    assert trace.joint.preamble_bin == 97
    assert trace.joint.seen
    assert not trace.joint.up_search_aborted
    assert not trace.joint.down_search_aborted
    assert not trace.joint.timing_rejected_out_of_range
    assert not trace.joint.precise_correction_applied


def test_joint_page_reports_sticky_outcome_bits_independently() -> None:
    """Each of the four sticky bits (STATUS 4:1) must decode on its own.

    Before these existed, an abort never set `seen` (the controller's
    timing_valid never pulses on an abort), so a failed estimate and "no
    packet yet" were indistinguishable on this page -- and up/down aborts
    shared one bit further upstream.
    """

    text = _trace_page(grid_realigned=False).replace(
        "SIGNATURE 0x4c4f5241",
        "SIGNATURE 0x4c4f5241\n"
        + _joint_page(
            seen=False,
            up_search_aborted=True,
            down_search_aborted=False,
            timing_rejected_out_of_range=False,
            precise_correction_applied=False,
        ),
    )

    trace = parse_trace(text)

    assert trace.joint is not None
    assert not trace.joint.seen
    assert trace.joint.up_search_aborted
    assert not trace.joint.down_search_aborted
    assert not trace.joint.timing_rejected_out_of_range
    assert not trace.joint.precise_correction_applied

    summary = _joint_summary(trace.joint)
    assert summary is not None
    assert summary["up_search_aborted"] is True
    assert summary["down_search_aborted"] is False
    assert summary["estimate_seen"] is False


def test_joint_page_reports_the_straddle_accepted_bit_on_its_own() -> None:
    """STATUS bit 5 (M7): a packet accepted only through the detector's
    straddle-tolerant path, independent of the four outcome bits below it."""

    def parse(**flags: bool):
        text = _trace_page(grid_realigned=False).replace(
            "SIGNATURE 0x4c4f5241",
            "SIGNATURE 0x4c4f5241\n" + _joint_page(**flags),
        )
        trace = parse_trace(text)
        assert trace.joint is not None
        return trace.joint

    plain = parse(precise_correction_applied=True)
    assert not plain.detector_straddle_accepted
    assert plain.precise_correction_applied

    straddled = parse(detector_straddle_accepted=True)
    assert straddled.detector_straddle_accepted
    assert not straddled.precise_correction_applied
    assert not straddled.up_search_aborted
    assert not straddled.down_search_aborted
    assert not straddled.timing_rejected_out_of_range

    both = parse(detector_straddle_accepted=True, precise_correction_applied=True)
    assert both.detector_straddle_accepted and both.precise_correction_applied


def test_joint_page_reports_the_split_accepted_bit_on_its_own() -> None:
    """STATUS bit 6 (M9): accepted only through the split-tolerant path."""

    text = _trace_page(grid_realigned=False).replace(
        "SIGNATURE 0x4c4f5241",
        "SIGNATURE 0x4c4f5241" + chr(10) + _joint_page(detector_split_accepted=True),
    )
    joint = parse_trace(text).joint
    assert joint is not None
    assert joint.detector_split_accepted
    assert not joint.detector_straddle_accepted

    plain = parse_trace(
        _trace_page(grid_realigned=False).replace(
            "SIGNATURE 0x4c4f5241",
            "SIGNATURE 0x4c4f5241" + chr(10) + _joint_page(detector_straddle_accepted=True),
        )
    ).joint
    assert plain is not None
    assert plain.detector_straddle_accepted and not plain.detector_split_accepted


def test_joint_summary_recomputes_the_controllers_origin() -> None:
    """The controller derives up_coarse_start from these two inputs.

    Recomputing it in software is the whole point of the page: if the board's
    own value and the formula disagree, the estimator is searching somewhere
    other than where its inputs say it should.
    """

    summary = _joint_summary(
        JointEstimate(
            correction_samples=-7,
            up_offset_samples=12,
            up_coarse_start=0x13880,
            packet_start_count=0x12345,
            chips_to_boundary=31,
            preamble_bin=97,
            seen=True,
            up_search_aborted=False,
            down_search_aborted=False,
            timing_rejected_out_of_range=False,
            precise_correction_applied=True,
        )
    )

    assert summary is not None
    assert summary["derived_up_coarse_start"] == 0x12345 + 31 * 8


def test_joint_page_marker_mismatch_is_rejected() -> None:
    text = _trace_page(grid_realigned=False).replace(
        "SIGNATURE 0x4c4f5241",
        "SIGNATURE 0x4c4f5241\n" + _joint_page(marker=0x434B),
    )

    with pytest.raises(ValueError, match="joint page marker"):
        parse_trace(text)


def test_trace_without_a_joint_page_still_parses() -> None:
    trace = parse_trace(_trace_page(grid_realigned=False))

    assert trace.joint is None
    assert _joint_summary(trace.joint) is None


def _unfinished_trace(extra: str) -> str:
    """A frozen buffer that never captured: not active, not complete, count 0."""

    lines = ["SIGNATURE 0x4c4f5241", extra]
    for index in range(128):
        lines.append(
            f"ENTRY {index} 0x53590000 0x00000003 0x00000000 0x00000000 "
            "0x00000000 0x00000000 0x00000080"
        )
    return "\n".join(lines)


def test_an_unfinished_trace_reports_what_the_rest_of_the_logic_saw() -> None:
    """A miss must leave evidence: the sticky bits die at the next re-arm."""

    extra = "\n".join(
        [
            "PAGE0 0x00011243 0x00000007 0x000f4240 0x00000001 0xfffff800 0x00012345",
            _joint_page(seen=False),
            _clock_page(overflow=True),
        ]
    )

    with pytest.raises(TraceNotComplete, match="not complete") as caught:
        parse_trace(_unfinished_trace(extra))

    state = caught.value.state
    assert state["page0_status"] == "0x00011243"
    assert state["page0_sequence"] == 7
    assert state["page0_coarse"] == 0x1_000F_4240
    assert state["page0_fraction_q12"] == -2048
    assert state["page0_log_peak_q12"] == 0x12345
    assert state["joint_seen"] is False
    assert state["crossing_overflow"] is True
    assert state["capture_sequence"] == 3


def test_an_unfinished_trace_without_the_extra_pages_still_raises() -> None:
    with pytest.raises(TraceNotComplete) as caught:
        parse_trace(_unfinished_trace(""))

    assert "page0_status" not in caught.value.state
    assert isinstance(caught.value, ValueError)


def _history_page(newest: int, written: int, drops: int, entries: dict[int, tuple]) -> str:
    lines = [f"HSTATUS 0x{(0x4448 << 16) | (1 << 12) | newest:08x} 0x{written:08x} 0x{drops:08x}"]
    for index in range(8):
        if index in entries:
            count, bin_, conf, drop, flags = entries[index]
            packed = (flags << 24) | (drop << 16) | conf
            lines.append(f"H {index} 0x{count:08x} 0x{packed:08x} 0x{bin_:08x}")
        else:
            lines.append(f"H {index} 0x00000000 0x00000000 0x00000000")
    return "\n".join(lines)


def test_history_before_the_ring_wraps_is_read_from_entry_zero() -> None:
    text = _history_page(
        newest=2, written=3, drops=5,
        entries={0: (1000, 0, 0, 0, 1), 1: (2024, 64, 0x300, 0, 1), 2: (3048, 72, 0x310, 5, 0b1011)},
    )

    history = parse_history(text, depth=8)

    assert history["frozen"] is True
    assert history["crossing_drop_count"] == 5
    assert [e["sample_count_low"] for e in history["entries"]] == [1000, 2024, 3048]
    last = history["entries"][-1]
    assert last["bin"] == 72 and last["confidence_q15"] == 0x310
    assert last["drop_count_low"] == 5
    assert last["detected"] and not last["straddle"] and last["grid_resync_armed"]


def test_a_wrapped_ring_is_read_oldest_first_from_after_the_newest_entry() -> None:
    entries = {i: (100 * i, i, 1, 0, 1) for i in range(8)}

    history = parse_history(_history_page(newest=2, written=20, drops=0, entries=entries), depth=8)

    assert [e["index"] for e in history["entries"]] == [3, 4, 5, 6, 7, 0, 1, 2]


def test_history_on_an_image_without_the_page_is_refused() -> None:
    with pytest.raises(ValueError, match="predates the M8"):
        parse_history("HSTATUS 0x00011243 0x00000007 0x00000000\nH 0 0x0 0x0 0x0", depth=1)


def test_the_history_line_adds_the_crossing_drop_count_to_the_clock() -> None:
    text = _trace_page(grid_realigned=False).replace(
        "SIGNATURE 0x4c4f5241",
        "SIGNATURE 0x4c4f5241\nHISTORY 0x44480123 0x00000400 0x00000007\n" + _clock_page(),
    )

    trace = parse_trace(text)

    assert trace.clock is not None and trace.clock.crossing_drop_count == 7


def test_an_old_image_reports_no_drop_count() -> None:
    # Bit 4 selects nothing on older images: the read falls through to page 0.
    text = _trace_page(grid_realigned=False).replace(
        "SIGNATURE 0x4c4f5241",
        "SIGNATURE 0x4c4f5241\nHISTORY 0x00011243 0x00000009 0x00012345\n" + _clock_page(),
    )

    trace = parse_trace(text)

    assert trace.clock is not None and trace.clock.crossing_drop_count is None


def test_a_completed_trace_carries_the_published_timestamp() -> None:
    text = _trace_page(grid_realigned=True).replace(
        "SIGNATURE 0x4c4f5241",
        "SIGNATURE 0x4c4f5241\nPAGE0 0x00011267 0x00000009 0x02345678 0x00000000 0x00000400 0x00001000",
    )

    trace = parse_trace(text)

    assert trace.timestamp == {
        "page0_status": "0x00011267",
        "page0_sequence": 9,
        "page0_coarse": 0x02345678,
        "page0_fraction_q12": 1024,
        "page0_log_peak_q12": 4096,
    }
    assert build_report_timestamp(trace) == trace.timestamp


def build_report_timestamp(trace):
    from tools.read_clg400_symbol_trace import build_report

    return build_report(trace)["timestamp"]

