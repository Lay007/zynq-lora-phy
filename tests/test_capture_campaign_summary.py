import json

import pytest

from tools.summarize_capture_campaign import summarize


def records(tmp_path, values):
    paths = []
    for index, value in enumerate(values):
        path = tmp_path / f"clg400-trace-{index}.json"
        path.write_text(json.dumps({"schema": "zynq-lora-clg400-symbol-trace-v1", **value}))
        paths.append(path)
    return paths


def test_failures_and_missing_attempts_are_not_phy_errors(tmp_path):
    paths = records(tmp_path, [
        {"iq_samples": 100, "decode": {"crc_valid": True}},
        {"iq_samples": 100, "decode": {"crc_valid": False}},
        {"status": "failed", "stage": "fetch_iq"},
    ])
    result = summarize(paths, 4)
    assert result["captured"] == 2
    assert result["crc_pass"] == result["crc_fail_captured"] == 1
    assert result["failed_attempts"] == result["missing_records"] == 1
    assert result["crc_pass_fraction_of_captures"] == 0.5
    assert not result["accounting_complete"]
    assert not result["toa_qualified"]


def test_empty_and_failed_campaigns_do_not_divide_by_zero(tmp_path):
    assert summarize([], 3)["crc_pass_fraction_of_captures"] is None
    result = summarize(records(tmp_path, [{"status": "failed"}]), 1)
    assert result["accounting_complete"]
    assert result["crc_pass_fraction_of_captures"] is None


@pytest.mark.parametrize("value", [
    {"decode": {"crc_valid": True}},
    {"iq_samples": 100, "decode": {"crc_valid": "false"}},
    {"status": "unexpected", "iq_samples": 100, "decode": {"crc_valid": True}},
    {"iq_samples": True, "decode": {"crc_valid": True}},
    {"iq_samples": 100, "decode": None},
    {"iq_samples": 100, "decode": []},
    {"iq_samples": -1, "decode": {"crc_valid": True}},
])
def test_incomplete_or_unknown_record_is_not_success(tmp_path, value):
    result = summarize(records(tmp_path, [value]), 1)
    assert result["unclassified_records"] == 1
    assert not result["accounting_complete"]


def test_extra_records_and_invalid_planned_count_are_rejected(tmp_path):
    with pytest.raises(ValueError, match="positive"):
        summarize([], 0)
    with pytest.raises(ValueError, match="more records"):
        summarize(records(tmp_path, [{}, {}]), 1)


def test_duplicate_paths_do_not_fill_missing_attempts(tmp_path):
    paths = records(tmp_path, [{"status": "failed"}])
    with pytest.raises(ValueError, match="duplicate"):
        summarize(paths * 2, 2)


@pytest.mark.parametrize("value", [None, [], {"schema": "unknown"}])
def test_unsupported_records_have_clear_errors(tmp_path, value):
    path = tmp_path / "trace.json"
    path.write_text(json.dumps(value))
    with pytest.raises(ValueError, match="unsupported schema"):
        summarize([path], 1)


def test_missing_failure_stage_is_reported_as_unknown(tmp_path):
    result = summarize(records(tmp_path, [
        {"status": "failed", "stage": None},
        {"status": "failed", "stage": ["fetch_iq"]},
    ]), 2)
    assert result["failures_by_stage"] == {"unknown": 2}


def test_cli_returns_nonzero_for_missing_attempts(tmp_path):
    from pathlib import Path
    import subprocess
    import sys

    records(tmp_path, [{"status": "failed", "stage": "send"}])
    script = Path(__file__).resolve().parents[1] / "tools/summarize_capture_campaign.py"
    for planned, expected in [(1, 0), (2, 1)]:
        result = subprocess.run(
            [sys.executable, str(script), str(tmp_path), "--planned-attempts", str(planned)],
            capture_output=True, text=True,
        )
        assert result.returncode == expected
        assert json.loads(result.stdout)["accounting_complete"] == (expected == 0)
