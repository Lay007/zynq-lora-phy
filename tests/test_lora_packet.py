import json
from pathlib import Path

import numpy as np

from zynq_lora_phy import (
    CssConfig,
    decode_lora_packet,
    decode_lora_symbol_trace,
    modulate_symbol,
    payload_crc,
    quarter_symbol_bin_adjustments,
    reference_chirp,
    whitening_sequence,
)


GOLDEN = (
    Path(__file__).parents[1]
    / "model"
    / "matlab"
    / "golden"
    / "lora-phy-sf7-cr1.json"
)

HARDWARE_TRACE = (
    Path(__file__).parents[1]
    / "docs"
    / "data"
    / "clg400-symbol-trace-2026-09-03.json"
)

REALIGNED_TRACE = (
    Path(__file__).parents[1]
    / "docs"
    / "data"
    / "clg400-grid-resync-2026-09-04.json"
)


def test_python_hard_decoder_matches_matlab_golden_vector() -> None:
    vector = json.loads(GOLDEN.read_text(encoding="utf-8"))

    decoded = decode_lora_packet(vector["cssSymbols"], spreading_factor=7)

    assert decoded.success
    assert decoded.header_valid
    assert decoded.crc_valid
    assert decoded.payload == bytes(vector["payload"])
    assert decoded.header is not None
    assert decoded.header.payload_length == len(vector["payload"])
    assert decoded.header.coding_rate == 1
    assert decoded.header.payload_crc
    assert decoded.consumed_symbol_count == len(vector["cssSymbols"])


def test_whitening_and_crc_match_matlab_golden_vector() -> None:
    vector = json.loads(GOLDEN.read_text(encoding="utf-8"))
    payload = bytes(vector["payload"])

    assert whitening_sequence(len(payload)) == bytes(vector["whiteningSequence"])
    assert payload_crc(payload) == int(vector["payloadCrcHex"], 16)


def test_trace_search_removes_preamble_bin_and_two_sfd_symbols() -> None:
    vector = json.loads(GOLDEN.read_text(encoding="utf-8"))
    preamble_bin = 11
    raw = [37, 91] + [
        (symbol + preamble_bin) % 128 for symbol in vector["cssSymbols"]
    ]
    raw.extend([0] * (128 - len(raw)))

    candidate = decode_lora_symbol_trace(raw, preamble_bin)

    assert candidate.result.success
    assert candidate.symbol_offset == 2
    assert candidate.bin_adjustment == 0
    assert candidate.result.payload == bytes(vector["payload"])


def test_truncated_packet_reports_valid_header_without_success() -> None:
    vector = json.loads(GOLDEN.read_text(encoding="utf-8"))

    decoded = decode_lora_packet(vector["cssSymbols"][:8], spreading_factor=7)

    assert decoded.header_valid
    assert not decoded.success
    assert decoded.failure_reason == "truncated payload symbols"


def _free_running_grid_bins(
    stream: np.ndarray, config: CssConfig, start: int, window_count: int
) -> list[int]:
    """Peak bin of each fixed-grid window using the generated two-FFT identity."""

    size = config.samples_per_symbol
    chips = config.symbol_count
    samples_per_chip = config.samples_per_chip
    reference_spectrum = np.conjugate(np.fft.fft(reference_chirp(config)))
    bins = []
    for index in range(window_count):
        begin = start + index * size
        window = stream[begin : begin + size]
        if window.size < size:
            break
        product = np.fft.fft(window) * reference_spectrum
        partition = product.reshape(samples_per_chip, chips).sum(axis=0)
        magnitude = np.abs(np.fft.fft(partition)) ** 2
        bins.append(int(np.argmax(magnitude)) % chips)
    return bins


def _build_frame(
    config: CssConfig, symbols, *, sync_word: int = 0x12, preamble: int = 12
) -> np.ndarray:
    count = config.symbol_count
    quarter = config.samples_per_symbol // 4
    upchirp = reference_chirp(config, up=True)
    downchirp = reference_chirp(config, up=False)
    sync = [(8 * (sync_word >> 4)) % count, (8 * (sync_word & 0xF)) % count]
    parts = [np.tile(upchirp, preamble)]
    parts.extend(modulate_symbol(value, config) for value in sync)
    parts.extend([downchirp, downchirp, downchirp[:quarter]])
    parts.extend(modulate_symbol(int(value), config) for value in symbols)
    return np.concatenate(parts)


def test_quarter_symbol_bin_adjustments_bracket_the_sfd_offset() -> None:
    adjustments = quarter_symbol_bin_adjustments(7)

    assert 0 in adjustments
    assert -32 in adjustments
    assert 32 in adjustments
    assert adjustments[:5] == [-2, -1, 0, 1, 2]
    assert max(abs(value) for value in adjustments) == 34


def test_free_running_grid_trace_decodes_the_golden_packet() -> None:
    """The PL grid never resynchronises, so the payload sits a quarter symbol off.

    The overlay ties the correlator resync input low: its symbol grid stays
    where the stream started and only the preamble bin reports that phase. The
    2.25-downchirp SFD therefore shifts every payload decision by a quarter
    symbol, which the trace decoder has to absorb.
    """

    vector = json.loads(GOLDEN.read_text(encoding="utf-8"))
    config = CssConfig(spreading_factor=7, samples_per_chip=8)
    frame = _build_frame(config, vector["cssSymbols"])
    lead = np.zeros(4096, dtype=np.complex128)
    tail = np.zeros(80 * config.samples_per_symbol, dtype=np.complex128)

    for grid_delta in (0, 57, 200, 1000):
        stream = np.concatenate([lead, frame, tail])
        bins = _free_running_grid_bins(stream, config, lead.size + grid_delta, 128)
        preamble_bins = bins[1:11]
        preamble_bin = max(set(preamble_bins), key=preamble_bins.count)
        # Present the decoder with the same window the PL trace would freeze:
        # the two full SFD decisions and everything after them.
        raw = bins[14:]

        candidate = decode_lora_symbol_trace(raw, preamble_bin)

        assert candidate.result.success, grid_delta
        assert candidate.result.crc_valid
        assert candidate.result.payload == bytes(vector["payload"])
        assert candidate.bin_adjustment == -32


def test_recorded_hardware_trace_decodes_the_heltec_payload() -> None:
    """Replay the accepted 2026-09-03 over-the-air capture.

    These are the raw FFT decisions the CLG400 froze for one Heltec packet, so
    this pins the decoder to a real board rather than to the model that
    predicted its behaviour.
    """

    evidence = json.loads(HARDWARE_TRACE.read_text(encoding="utf-8"))
    attempt = evidence["accepted_attempt"]
    raw = [entry["symbol"] for entry in attempt["entries"]]

    candidate = decode_lora_symbol_trace(raw, attempt["preamble_bin"])
    result = candidate.result

    assert len(raw) == 128
    assert candidate.symbol_offset == 2
    assert candidate.bin_adjustment == -32
    assert result.success
    assert result.crc_valid
    assert result.header is not None
    assert result.header.checksum_valid
    assert result.header.payload_length == 32
    assert result.header.coding_rate == 1
    assert result.header.payload_crc

    payload = result.payload
    sequence = attempt["serial"]["tx_sequence"]
    start_ms = attempt["serial"]["tx_start_ms"]
    assert payload[:4] == b"ZLP1"
    assert int.from_bytes(payload[4:8], "little") == sequence
    assert int.from_bytes(payload[8:12], "little") == start_ms
    # The counter payload is fully determined by the transmitted sequence.
    assert payload == b"ZLP1" + sequence.to_bytes(4, "little") + start_ms.to_bytes(
        4, "little"
    ) + bytes((sequence + index - 12) & 0xFF for index in range(12, 32))


def test_realigned_grid_trace_decodes_without_removing_a_bin() -> None:
    """What the PL grid realignment is expected to hand software.

    The receiver withholds ``mod(chipsToBoundary + 2**(SF-2), 2**SF)`` chips on
    the detector pulse, which lands the window grid on the payload boundaries.
    The raw decisions are then the transmitted symbols, so the reader must pass
    a grid phase of zero rather than the measured preamble bin: the skip already
    removed it.
    """

    vector = json.loads(GOLDEN.read_text(encoding="utf-8"))
    config = CssConfig(spreading_factor=7, samples_per_chip=8)
    frame = _build_frame(config, vector["cssSymbols"])
    lead = np.zeros(4096, dtype=np.complex128)
    tail = np.zeros(80 * config.samples_per_symbol, dtype=np.complex128)
    size = config.samples_per_symbol
    count = config.symbol_count

    for grid_delta in (0, 57, 200, 1000):
        stream = np.concatenate([lead, frame, tail])
        base = lead.size + grid_delta
        bins = _free_running_grid_bins(stream, config, base, 40)
        preamble_bins = bins[1:11]
        preamble_bin = max(set(preamble_bins), key=preamble_bins.count)

        chips_to_boundary = (-preamble_bin) % count
        skip = ((chips_to_boundary + count // 4) % count) * config.samples_per_chip
        # The detector fires on the second sync window; any grid boundary gives
        # the same phase, so start from the one that window began on.
        detector_boundary = base + 14 * size
        aligned = _free_running_grid_bins(
            stream, config, detector_boundary + skip, 128
        )

        candidate = decode_lora_symbol_trace(aligned, 0)

        assert candidate.result.success, grid_delta
        assert candidate.result.crc_valid
        assert candidate.result.payload == bytes(vector["payload"])
        assert candidate.bin_adjustment == 0


def test_recorded_realigned_hardware_trace_decodes_without_a_grid_phase() -> None:
    """Replay the accepted capture from the realigned-grid build.

    The receiver moved its own symbol grid onto the packet for this capture, so
    the raw decisions are the transmitted symbols and the decoder must not
    remove a bin of its own. The free-running counterpart in
    `clg400-symbol-trace-2026-09-03.json` needs a quarter symbol; this one needs
    nothing, and that difference is the whole point of the change.
    """

    evidence = json.loads(REALIGNED_TRACE.read_text(encoding="utf-8"))
    attempt = evidence["accepted_attempt"]
    raw = [entry["symbol"] for entry in attempt["entries"]]

    assert attempt["grid_realigned"]
    assert attempt["grid_phase_removed"] == 0

    candidate = decode_lora_symbol_trace(raw, attempt["grid_phase_removed"])
    result = candidate.result

    assert len(raw) == 128
    assert candidate.bin_adjustment == 0
    assert result.success
    assert result.crc_valid
    assert result.header is not None
    assert result.header.checksum_valid
    assert result.header.payload_length == 32

    sequence = attempt["serial"]["tx_sequence"]
    start_ms = attempt["serial"]["tx_start_ms"]
    assert result.payload == b"ZLP1" + sequence.to_bytes(
        4, "little"
    ) + start_ms.to_bytes(4, "little") + bytes(
        (sequence + index - 12) & 0xFF for index in range(12, 32)
    )


def test_trace_decoder_prefers_the_closest_crc_valid_hypothesis() -> None:
    # PER bench, SF7 CR 4/6, SNR -9.5 dB (2026-09-30). The first hypothesis
    # the search reaches (bin adjustment -2, offset 6) passes the 16-bit CRC
    # with a 53-byte payload; the transmitted 32-byte packet decodes cleanly
    # at adjustment 0, offset 2. Returning the first CRC success lost 55 of
    # 5937 bench packets this way.
    trace = (
        "4d362141050d75196d11721b3936261c0c115a54757f7f342731080c69626f3d"
        "726c5554552a061b437d1128211449634f33454d6b4e0127005e463b277d4629"
        "0c067d446171014c093f367a1d75206f3873620325586f191d5a6b0c7e7b4475"
        "217a5f4c15047915151a5b5d2719593f4e2053563d603f6509310f48410a6c7b"
    )
    raw = [int(trace[2 * k:2 * k + 2], 16) for k in range(len(trace) // 2)]

    candidate = decode_lora_symbol_trace(raw, 0)

    assert candidate.result.crc_valid
    assert candidate.result.payload[:4] == b"ZLP1"
    assert int.from_bytes(candidate.result.payload[4:8], "little") == 45
