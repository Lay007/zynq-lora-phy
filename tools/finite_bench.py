"""Finite-transmission accounting and lossless parsing of CLG400 trace records."""
from __future__ import annotations

from collections import Counter
import re

from per_measure import decode_lora_symbol_trace, seq_of
from lora_per_ideal import test_payload


def parse_record(line: str) -> dict:
    """Preserve failed reads as records; never silently discard a malformed attempt."""
    record = {"raw": line.rstrip("\n"), "kind": "invalid", "capture_valid": False}
    try:
        parts = line.split()
        if len(parts) < 3 or parts[0] not in ("PKT", "TIMEOUT"):
            raise ValueError("unrecognized trace record")
        record["t_ms"] = int(parts[1])
        fields = dict(item.split("=", 1) for item in parts[2:])
        if len(fields) != len(parts) - 2:
            raise ValueError("duplicate trace field")
        record["fields"] = fields
        if parts[0] == "TIMEOUT":
            record.update(kind="timeout", status=int(fields["status"], 0))
            for name in ('joint', 'clock_status', 'drop_before', 'drop_after'):
                if name in fields: record[name] = int(fields[name], 0)
            return record
        integers = ("cap", "pbin", "realigned", "n", "p0seq", "p0coarse", "p0frac",
                    "p0status", "p0log", "p0debug", "joint", "clock_status",
                    "drop_before", "drop_after", "p0fresh", "changed")
        record.update({name: int(fields[name], 0) for name in integers})
        for name in ('joint_correction', 'joint_up_offset', 'joint_up_coarse',
                     'joint_packet_start', 'joint_phase_bin', 'sample_interval_clocks',
                     'sample_interval_min_clocks', 'mac_search_clocks', 'mac_search_completed'):
            if name in fields: record[name] = int(fields[name], 0)
        n = record["n"]
        symbols = fields["sym"]
        sf = int(fields.get('sf', '7'))
        bits = int(fields.get('sym_bits', '8'))
        if not 5 <= sf <= 12 or bits not in (8, 16) or (sf > 8 and bits != 16):
            raise ValueError('invalid SF/symbol width')
        digits = bits // 4
        if not 1 <= n <= 128 or len(symbols) != digits*128 or not re.fullmatch(r"[0-9a-fA-F]+", symbols):
            raise ValueError("invalid symbol trace length/encoding")
        values = [int(symbols[k:k+digits], 16) for k in range(0, digits*n, digits)]
        if any(value >= 1 << sf for value in values):
            raise ValueError('symbol outside configured SF')
        for name in ("changed", "p0fresh", "realigned"):
            if record[name] not in (0, 1):
                raise ValueError("invalid boolean flag")
        if not 0 <= record["p0coarse"] < 2**64 or not -(2**31) <= record["p0frac"] < 2**31:
            raise ValueError("timestamp out of range")
        record.update(kind="packet", capture_valid=record["changed"] == 0,
                      sym=symbols[:digits*n], spreading_factor=sf, symbol_bits=bits)
        result = decode_lora_symbol_trace(values,
                                         0 if record["realigned"] else record["pbin"],
                                         spreading_factor=sf,
                                         require_payload_crc=True).result
        # This finite bench sends explicit-header packets with payload CRC.
        # The general decoder accepts CRC-disabled packets by design; a noisy
        # header can flip that flag and must not bypass the bench CRC policy.
        record["payload_crc_enabled"] = bool(result.header is not None and result.header.payload_crc)
        record["crc"] = bool(record["payload_crc_enabled"] and result.crc_valid)
        record["payload_hex"] = bytes(result.payload).hex()
        record["seq"] = seq_of(bytes(result.payload)) if record["crc"] else None
        reasons = []
        if record["changed"]: reasons.append("snapshot_changed")
        if not record["p0fresh"]: reasons.append("stale_metadata")
        if not record["p0status"] & 4: reasons.append("metadata_not_valid")
        if record["p0status"] & 8: reasons.append("metadata_overflow")
        if record["joint"] >> 16 != 0x4a54 or not record["joint"] & 16:
            reasons.append("joint_not_applied")
        if record["joint"] & 14: reasons.append("joint_error")
        if record["clock_status"] >> 16 != 0x434b: reasons.append("clock_abi")
        if record["drop_after"] != record["drop_before"]: reasons.append("sample_drop")
        record["toa_rejection_reasons"] = reasons
        record["toa_valid"] = not reasons
        record['joint_diagnostics_valid'] = bool(record['p0fresh'] and record['joint'] & 16
                                                 and not record['changed'])
        # Integer Q12 retains all 64 coarse bits; do not round them through float.
        record["toa_samples_q12"] = record["p0coarse"] * 4096 + record["p0frac"]
    except (ValueError, KeyError, TypeError, IndexError) as exc:
        record.update(kind="invalid", capture_valid=False, error=str(exc))
    return record


def summarize(records: list[dict], first_sequence: int, planned: int,
              *, tx_complete: bool, collection_complete: bool) -> dict:
    if planned < 1 or first_sequence < 0 or first_sequence + planned > 2**32:
        raise ValueError("invalid finite sequence range")
    counts = Counter(r.get("kind", "invalid") for r in records)
    decoded = [r for r in records if r.get("capture_valid") and r.get("crc") and r.get("seq") is not None]
    unvalidated = sum("payload_hex" not in r for r in decoded)
    good = [r for r in decoded if r.get("payload_hex") == test_payload(r["seq"]).hex()]
    expected = range(first_sequence, first_sequence + planned)
    received = Counter(r["seq"] for r in good if r["seq"] in expected)
    unexpected = sorted({r["seq"] for r in decoded if r["seq"] not in expected})
    mismatches = sum(r["seq"] in expected and "payload_hex" in r and
                     r["payload_hex"] != test_payload(r["seq"]).hex() for r in decoded)
    outcomes = []
    for seq in expected:
        matching = [r for r in good if r["seq"] == seq]
        outcomes.append({"seq": seq, "crc_valid": bool(matching),
                         "toa_valid": any(r.get("toa_valid", False) for r in matching),
                         "capture_ids": [r["cap"] for r in matching]})
    invalid = counts["invalid"] + unvalidated + sum(r.get("kind") == "packet" and not r.get("capture_valid") for r in records)
    valid = bool(tx_complete and collection_complete and not invalid and not unexpected)
    return {"planned_transmissions": planned, "received_unique": len(received),
            "lost": planned - len(received), "per_method": "finite planned transmissions",
            "per_observed": 1 - len(received) / planned,
            "per": 1 - len(received) / planned if valid else None,
            "measurement_valid": valid, "tx_complete": tx_complete,
            "collection_complete": collection_complete,
            "duplicates": sum(n - 1 for n in received.values()), "unexpected_sequences": unexpected,
            "payload_mismatches": mismatches, "unvalidated_payload_records": unvalidated,
            "packet_records": counts["packet"], "timeouts": counts["timeout"],
            "invalid_records": invalid,
            "crc_fail": sum(r.get("kind") == "packet" and not r.get("crc", False) for r in records),
            "usable_toa": sum(x["toa_valid"] for x in outcomes), "outcomes": outcomes}
