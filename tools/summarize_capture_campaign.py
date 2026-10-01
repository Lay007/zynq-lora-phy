#!/usr/bin/env python3
"""Account for every planned capture; this summary does not qualify ToA or PER."""

import argparse
from collections import Counter
import json
from pathlib import Path


def summarize(paths: list[Path], planned_attempts: int) -> dict:
    if type(planned_attempts) is not int or planned_attempts < 1:
        raise ValueError("planned_attempts must be positive")
    if len({path.resolve() for path in paths}) != len(paths):
        raise ValueError("duplicate records; select each attempt once")
    if len(paths) > planned_attempts:
        raise ValueError("more records than planned attempts; select one campaign")
    captured = crc_pass = unknown = 0
    failures: Counter[str] = Counter()
    for path in paths:
        record = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(record, dict) or record.get("schema") != "zynq-lora-clg400-symbol-trace-v1":
            raise ValueError(f"unsupported schema: {path}")
        if record.get("status") == "failed":
            stage = record.get("stage")
            failures[stage if isinstance(stage, str) and stage else "unknown"] += 1
        elif (record.get("status") in (None, "ok")
              and type(record.get("iq_samples")) is int
              and record["iq_samples"] > 0
              and isinstance(record.get("decode"), dict)
              and isinstance(record.get("decode", {}).get("crc_valid"), bool)):
            captured += 1
            crc_pass += int(record["decode"]["crc_valid"])
        else:
            # A bare symbol trace or malformed success must not be a capture.
            unknown += 1
    return {
        "schema": "zynq-lora-capture-campaign-v1",
        "planned_attempts": planned_attempts,
        "records": len(paths),
        "missing_records": planned_attempts - len(paths),
        "unclassified_records": unknown,
        "failed_attempts": sum(failures.values()),
        "failures_by_stage": dict(sorted(failures.items())),
        "captured": captured,
        "crc_pass": crc_pass,
        "crc_fail_captured": captured - crc_pass,
        "crc_pass_fraction_of_captures": crc_pass / captured if captured else None,
        "accounting_complete": len(paths) == planned_attempts and unknown == 0,
        "toa_qualified": False,
        "limitations": "Capture/CRC accounting only; no PHY PER, epoch continuity or calibrated ToA claim.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", type=Path)
    parser.add_argument("--planned-attempts", required=True, type=int)
    args = parser.parse_args()
    report = summarize(sorted(args.run_dir.glob("clg400-trace-*.json")), args.planned_attempts)
    print(json.dumps(report, indent=2, allow_nan=False))
    return 0 if report["accounting_complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
