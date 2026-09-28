import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from per_measure import per_from_sequences  # noqa: E402


def test_no_loss_counts_every_packet() -> None:
    r = per_from_sequences([0, 1, 2, 3, 4], 0, 64)
    assert (r["lost"], r["sent_spanned"], r["per"]) == (0, 5, 0.0)


def test_gaps_are_losses_and_wrap_around_the_template_cycle() -> None:
    # 62, 63, [0 lost], 1, 2, [3, 4 lost], 5 with 64 templates
    r = per_from_sequences([62, 63, 1, 2, 5], 0, 64)
    assert r["lost"] == 3
    assert r["sent_spanned"] == 8
    assert abs(r["per"] - 3 / 8) < 1e-12


def test_a_repeated_capture_is_not_a_packet() -> None:
    r = per_from_sequences([3, 3, 4], 0, 64)
    assert r["duplicates"] == 1 and r["lost"] == 0 and r["received_valid"] == 2


def test_nothing_received_has_no_per() -> None:
    assert per_from_sequences([], 0, 64)["per"] is None
