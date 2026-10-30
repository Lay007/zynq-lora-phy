"""Pure-function checks for the IQ replay driver (no simulator needed)."""

from __future__ import annotations

import numpy as np

from tools.replay_iq_through_rtl import parse_output, parse_phases, write_window


def test_phases_cover_one_symbol_by_default_spec() -> None:
    assert parse_phases("0:1024:256") == [0, 256, 512, 768]
    assert parse_phases("656:760:8")[0] == 656
    assert parse_phases("656:760:8")[-1] == 752


def test_window_words_carry_i_high_and_q_low_as_twos_complement(tmp_path) -> None:
    iq = np.array([1 + 2j, -1 - 2j, 2047 - 2048j], dtype=np.complex128)
    path = tmp_path / "w.hex"

    write_window(iq, 0, 3, path)

    assert path.read_text().split() == ["00010002", "fffffffe", "07fff800"]


def test_window_can_start_mid_recording(tmp_path) -> None:
    iq = np.arange(10, dtype=np.float64) + 0j
    path = tmp_path / "w.hex"

    write_window(iq, 4, 3, path)

    assert path.read_text().split() == ["00040000", "00050000", "00060000"]


def test_output_parser_reads_every_line_kind() -> None:
    text = "\n".join(
        [
            "SYM 64 1024",
            "SYM 64 2048",
            "PRE 64 64 n=13000",
            "DET 64 64 n=14000 straddle=1",
            "PSC 7168 n=14001",
            "META 7300 -1234",
            "JNT up_coarse=7680 corr=1 range=0 upab=0 dnab=0 precise=1 up_off=-2 skip=17",
            "DONE detected=1 samples=25000",
        ]
    )

    parsed = parse_output(text)

    assert parsed["det"] == [[64, 64, 14000]]
    assert parsed["straddle"] == [1]
    assert parsed["psc"] == [7168]
    assert parsed["meta"] == [[7300, -1234]]
    assert parsed["symbols"] == [64, 64]
    assert parsed["joint"] == [
        "up_coarse=7680 corr=1 range=0 upab=0 dnab=0 precise=1 up_off=-2 skip=17"
    ]


def test_output_parser_reports_a_missed_packet_as_no_detection() -> None:
    parsed = parse_output("SYM 0 1024\nPRE 0 0 n=9000\nDONE detected=0 samples=100")

    assert parsed["det"] == []
    assert parsed["psc"] == []


def _write_burst(path) -> None:
    rng = np.random.default_rng(3)
    iq = 2.0 * (rng.standard_normal(40_000) + 1j * rng.standard_normal(40_000))
    iq[20_000:30_000] *= 400.0
    raw = np.empty(iq.size * 2, dtype="<i2")
    raw[0::2] = np.round(iq.real).astype("<i2")
    raw[1::2] = np.round(iq.imag).astype("<i2")
    raw.tofile(path)


def test_run_one_passes_the_detection_sample_gap_to_the_simulator(
    tmp_path, monkeypatch
) -> None:
    import subprocess

    from tools import replay_iq_through_rtl as replay

    iq_path = tmp_path / "rx1-iq-test.bin"
    _write_burst(iq_path)
    seen = {}

    def fake_run(cmd, **kwargs):
        seen["cmd"] = cmd
        return subprocess.CompletedProcess(cmd, 0, stdout="DONE detected=0", stderr="")

    monkeypatch.setattr(replay.subprocess, "run", fake_run)

    replay.run_one((iq_path, 8, "replay_tb", tmp_path, True, 2048, 63))

    assert "+gap_det=63" in seen["cmd"]
    assert "+wait_joint=1" in seen["cmd"]
