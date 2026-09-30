#!/usr/bin/env python3
"""Put the board's decisions over a missed packet next to the RTL replay's.

Every M7 detection miss on the board is detected at every arrival phase when
its recording is replayed through the same RTL, so the board must have taken
different decisions than the replay. On the M8 diagnostic image a miss's
failure record carries the decision-history ring (every decision, with its
correlator confidence and the receive crossing's drop count). This finds the
replayed phase whose decisions best match the board's over the packet and
prints both, position by position, with the first disagreement marked.

    python tools/replay_iq_through_rtl.py --vvp-file replay_tb --no-joint \\
        --lead 20000 --phases 0:1024:8 --out miss_replay.json <rx1-iq-*.bin>
    python tools/compare_history_to_replay.py <clg400-trace-*.json> miss_replay.json
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

WINDOW = 40  # decisions compared: preamble, sync, SFD and the first header ones


def packet_decisions(history: dict[str, object], window: int = WINDOW) -> list[dict[str, object]]:
    """The board's decisions from the first non-silent one after silence.

    A silent correlator gives exactly zero confidence (measured, M7), so the
    first non-zero entry after a zero one is the packet's first window.
    """

    entries = list(history["entries"])
    for k in range(1, len(entries)):
        if entries[k]["confidence_q15"] and not entries[k - 1]["confidence_q15"]:
            return entries[k : k + window]
    raise ValueError("no silence-to-signal transition in the decision history")


def best_alignment(
    board_bins: list[int], replays: list[dict[str, object]]
) -> tuple[int, dict[str, object], int, int]:
    """(matches, replay result, offset into its symbols) with the most equal bins."""

    best: tuple[int, dict[str, object], int, int] | None = None
    for result in replays:
        symbols = list(result["symbols"])
        # A replay can end before the board's window does (its recording
        # is cut shorter), so partial windows at the end are allowed.
        for offset in range(0, max(1, len(symbols))):
            window = symbols[offset : offset + len(board_bins)]
            matches = sum(1 for a, b in zip(board_bins, window) if a == b)
            if best is None or matches > best[0]:
                best = (matches, result, offset, len(window))
    if best is None:
        raise ValueError("no replay results")
    return best


def compare(record: dict[str, object], replays: list[dict[str, object]]) -> dict[str, object]:
    history = record.get("decision_history")
    if not history:
        raise ValueError("the record carries no decision history (not a miss on the M8 image?)")
    board = packet_decisions(history)
    board_bins = [int(e["bin"]) for e in board]
    matches, result, offset, compared = best_alignment(board_bins, replays)
    replay_bins = list(result["symbols"])[offset : offset + len(board_bins)]
    rows = []
    first_difference = None
    for k, entry in enumerate(board):
        replay_bin = replay_bins[k] if k < len(replay_bins) else None
        same = replay_bin == entry["bin"]
        if not same and first_difference is None:
            first_difference = k
        rows.append(
            {
                "k": k,
                "board_bin": entry["bin"],
                "replay_bin": replay_bin,
                "confidence_q15": entry["confidence_q15"],
                "drop_count_low": entry["drop_count_low"],
                "detected": entry["detected"],
                "same": same,
            }
        )
    drops = {e["drop_count_low"] for e in board}
    return {
        "replay_shift": result.get("shift"),
        "replay_detected": bool(result.get("det")),
        "matches": matches,
        "compared": compared,
        "first_difference": first_difference,
        "drops_during_packet": len(drops) > 1,
        "rows": rows,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("record", type=Path, help="failure record with decision_history")
    parser.add_argument("replay", type=Path, help="replay_iq_through_rtl.py --out JSON")
    args = parser.parse_args()
    report = compare(
        json.loads(args.record.read_text(encoding="utf-8")),
        json.loads(args.replay.read_text(encoding="utf-8")),
    )
    print(
        f"best replay shift {report['replay_shift']} (detected={report['replay_detected']}): "
        f"{report['matches']}/{report['compared']} equal bins; "
        f"first difference at k={report['first_difference']}; "
        f"samples dropped during the packet: {report['drops_during_packet']}"
    )
    for row in report["rows"]:
        mark = "  " if row["same"] else "<>"
        print(
            f"{row['k']:3d} {mark} board {row['board_bin']:3d} replay "
            f"{str(row['replay_bin']):>4s} conf {row['confidence_q15']:5d} "
            f"drop {row['drop_count_low']:3d}{'  DET' if row['detected'] else ''}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
