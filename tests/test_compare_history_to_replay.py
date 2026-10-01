"""Alignment rules of the board-history vs replay comparison (no hardware)."""

from __future__ import annotations

import pytest

from tools.compare_history_to_replay import compare, packet_decisions


def _entry(bin_: int, conf: int, drop: int = 0, detected: bool = False) -> dict:
    return {
        "bin": bin_,
        "confidence_q15": conf,
        "drop_count_low": drop,
        "detected": detected,
        "sample_count_low": 0,
    }


PACKET = [60] * 12 + [68, 76, 20, 20, 30, 40]


def _record(bins: list[int], drops: list[int] | None = None) -> dict:
    drops = drops or [0] * len(bins)
    entries = [_entry(0, 0) for _ in range(5)]
    entries += [_entry(b, 500, d) for b, d in zip(bins, drops)]
    entries += [_entry(0, 0) for _ in range(5)]
    return {"decision_history": {"entries": entries}}


def test_the_packet_starts_at_the_first_non_silent_decision() -> None:
    decisions = packet_decisions(_record(PACKET)["decision_history"], window=3)

    assert [d["bin"] for d in decisions] == [60, 60, 60]


def test_the_matching_replay_phase_is_found_and_agreement_reported() -> None:
    replays = [
        {"shift": 0, "det": [[1, 2, 3]], "symbols": [0] * 7 + [44] * 12 + [52, 60]},
        {"shift": 128, "det": [[1, 2, 3]], "symbols": [0] * 9 + PACKET + [0] * 4},
    ]

    report = compare(_record(PACKET), replays)

    assert report["replay_shift"] == 128
    assert report["first_difference"] is None or report["first_difference"] >= len(PACKET)
    assert report["drops_during_packet"] is False


def test_a_board_that_lost_samples_mid_preamble_is_located() -> None:
    board = [60] * 5 + [59] * 7 + [67, 75, 20, 20, 30, 40]
    drops = [0] * 5 + [8] * 13

    report = compare(_record(board, drops), [{"shift": 64, "det": [[1]], "symbols": [0] * 3 + PACKET}])

    assert report["first_difference"] == 5
    assert report["drops_during_packet"] is True


def test_a_record_without_history_is_refused() -> None:
    with pytest.raises(ValueError, match="no decision history"):
        compare({"status": "failed"}, [])
