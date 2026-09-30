"""Hard-decision LoRa packet coding and symbol-trace decoding.

This module mirrors the authoritative MATLAB packet-coding layer.  It starts
at CSS symbol indices: preamble detection, SFD validation, soft metrics, and
sample-grid refinement remain receiver-front-end responsibilities.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Sequence


@dataclass(frozen=True)
class LoRaHeader:
    payload_length: int
    coding_rate: int
    payload_crc: bool
    checksum_valid: bool
    valid_fields: bool

    @property
    def valid(self) -> bool:
        return self.valid_fields and self.checksum_valid


@dataclass(frozen=True)
class LoRaDecodeResult:
    success: bool
    header_valid: bool
    crc_valid: bool
    failure_reason: str
    payload: bytes
    header: LoRaHeader | None
    consumed_symbol_count: int
    header_distances: tuple[int, ...]
    payload_distances: tuple[int, ...]


@dataclass(frozen=True)
class LoRaTraceDecode:
    result: LoRaDecodeResult
    symbol_offset: int
    bin_adjustment: int
    normalized_symbols: tuple[int, ...]


@dataclass(frozen=True)
class LoRaEncodeResult:
    """CSS symbols and every packet-coding intermediate that produced them."""

    symbols: tuple[int, ...]
    whitened_payload: bytes
    header_nibbles: tuple[int, ...]
    payload_nibbles: tuple[int, ...]
    crc_nibbles: tuple[int, ...]
    header_codewords: tuple[tuple[bool, ...], ...]
    payload_codewords: tuple[tuple[bool, ...], ...]
    header_interleaved_labels: tuple[int, ...]
    payload_interleaved_labels: tuple[int, ...]
    coding_rate: int = 1
    padding_nibble_count: int = 0

    @property
    def payload_determined_symbol_count(self) -> int:
        """Symbols fully determined by the payload, excluding padding effects.

        The final block is filled to ``sf_app`` nibbles when the data does not
        divide evenly.  Interleaving spreads those padding nibbles across every
        symbol of that block, and the padding value is a transmitter choice
        that the payload does not fix, so those symbols are not a sound
        comparison point against another implementation.
        """

        if not self.padding_nibble_count:
            return len(self.symbols)
        return len(self.symbols) - (4 + self.coding_rate)


def _integer_bits(value: int, width: int) -> list[bool]:
    return [bool((value >> shift) & 1) for shift in range(width - 1, -1, -1)]


def _bits_integer(bits: Sequence[bool]) -> int:
    value = 0
    for bit in bits:
        value = (value << 1) | int(bit)
    return value


def _hamming_encode(nibble: int, coding_rate: int) -> list[bool]:
    if not 0 <= nibble <= 15:
        raise ValueError("nibble must be in [0, 15]")
    if not 1 <= coding_rate <= 4:
        raise ValueError("coding_rate must be in [1, 4]")

    b3, b2, b1, b0 = _integer_bits(nibble, 4)
    systematic = [b0, b1, b2, b3]
    if coding_rate == 1:
        return systematic + [b0 ^ b1 ^ b2 ^ b3]
    parities = [b0 ^ b1 ^ b2, b1 ^ b2 ^ b3, b0 ^ b1 ^ b3, b0 ^ b2 ^ b3]
    return systematic + parities[:coding_rate]


def _hamming_decode(
    codewords: Sequence[Sequence[bool]], coding_rate: int
) -> tuple[list[int], list[int]]:
    codebook = [_hamming_encode(nibble, coding_rate) for nibble in range(16)]
    nibbles: list[int] = []
    distances: list[int] = []
    for received in codewords:
        candidate_distances = [
            sum(left != right for left, right in zip(candidate, received, strict=True))
            for candidate in codebook
        ]
        distance = min(candidate_distances)
        nibbles.append(candidate_distances.index(distance))
        distances.append(distance)
    return nibbles, distances


def _unmap_symbols(
    symbols: Sequence[int], spreading_factor: int, reduced_rate: bool
) -> list[int]:
    symbol_count = 1 << spreading_factor
    labels: list[int] = []
    for symbol in symbols:
        if not 0 <= symbol < symbol_count:
            raise ValueError("CSS symbol is outside the spreading-factor range")
        binary = (symbol - 1) % symbol_count
        if reduced_rate:
            binary //= 4
        labels.append(binary ^ (binary >> 1))
    return labels


def _gray_to_binary(value: int, width: int) -> int:
    binary = 0
    for shift in range(width - 1, -1, -1):
        bit = ((value >> shift) & 1) ^ ((binary >> (shift + 1)) & 1)
        binary |= bit << shift
    return binary


def _map_labels_to_symbols(
    labels: Sequence[int], spreading_factor: int, reduced_rate: bool
) -> list[int]:
    """Inverse of :func:`_unmap_symbols`.

    The reduced-rate inverse resolves the two bits ``_unmap_symbols`` divides
    away by choosing the multiple-of-four representative, which is what a
    reduced-rate transmitter actually sends.  Gray decoding therefore runs at
    ``sf_app`` width *before* the shift, not at full width after it.
    """

    symbol_count = 1 << spreading_factor
    sf_app = spreading_factor - 2 * int(reduced_rate)
    symbols: list[int] = []
    for label in labels:
        if not 0 <= label < (1 << sf_app):
            raise ValueError("interleaver label is outside the sf_app range")
        binary = _gray_to_binary(label, sf_app) << (2 * int(reduced_rate))
        symbols.append((binary + 1) % symbol_count)
    return symbols


def _diagonal_deinterleave(
    labels: Sequence[int],
    spreading_factor: int,
    coding_rate: int,
    reduced_rate: bool,
) -> list[list[bool]]:
    if len(labels) != 4 + coding_rate:
        raise ValueError("expected 4+CR interleaver labels")
    sf_app = spreading_factor - 2 * int(reduced_rate)
    interleaved = [_integer_bits(label, sf_app) for label in labels]
    codewords = [[False] * (4 + coding_rate) for _ in range(sf_app)]
    for bit_index in range(4 + coding_rate):
        for symbol_bit in range(sf_app):
            destination_row = (bit_index - symbol_bit - 1) % sf_app
            codewords[destination_row][bit_index] = interleaved[bit_index][symbol_bit]
    return codewords


def _diagonal_interleave(
    codewords: Sequence[Sequence[bool]],
    spreading_factor: int,
    coding_rate: int,
    reduced_rate: bool,
) -> list[int]:
    """Inverse of :func:`_diagonal_deinterleave`, sharing its one index rule."""

    sf_app = spreading_factor - 2 * int(reduced_rate)
    if len(codewords) != sf_app:
        raise ValueError("expected sf_app codewords")
    labels: list[int] = []
    for bit_index in range(4 + coding_rate):
        bits = [False] * sf_app
        for symbol_bit in range(sf_app):
            source_row = (bit_index - symbol_bit - 1) % sf_app
            bits[symbol_bit] = codewords[source_row][bit_index]
        labels.append(_bits_integer(bits))
    return labels


def _explicit_header_encode(
    payload_length: int, coding_rate: int, payload_crc_present: bool
) -> list[int]:
    h0 = payload_length >> 4
    h1 = payload_length & 0xF
    h2 = 2 * coding_rate + int(payload_crc_present)
    b0 = _integer_bits(h0, 4)
    b1 = _integer_bits(h1, 4)
    b2 = _integer_bits(h2, 4)
    c4 = b0[0] ^ b0[1] ^ b0[2] ^ b0[3]
    c3 = b0[0] ^ b1[0] ^ b1[1] ^ b1[2] ^ b2[3]
    c2 = b0[1] ^ b1[0] ^ b1[3] ^ b2[0] ^ b2[2]
    c1 = b0[2] ^ b1[1] ^ b1[3] ^ b2[1] ^ b2[2] ^ b2[3]
    c0 = b0[3] ^ b1[2] ^ b2[0] ^ b2[1] ^ b2[2] ^ b2[3]
    return [h0, h1, h2, int(c4), _bits_integer([c3, c2, c1, c0])]


def _explicit_header_decode(nibbles: Sequence[int]) -> LoRaHeader:
    if len(nibbles) < 5 or any(not 0 <= value <= 15 for value in nibbles[:5]):
        raise ValueError("explicit header requires five nibbles")
    received = list(nibbles[:5])
    payload_length = 16 * received[0] + received[1]
    coding_rate = received[2] >> 1
    payload_crc_present = bool(received[2] & 1)
    valid_fields = 1 <= coding_rate <= 4 and received[2] <= 9
    checksum_valid = False
    if valid_fields:
        expected = _explicit_header_encode(
            payload_length, coding_rate, payload_crc_present
        )
        checksum_valid = received[3:5] == expected[3:5]
    return LoRaHeader(
        payload_length=payload_length,
        coding_rate=coding_rate,
        payload_crc=payload_crc_present,
        checksum_valid=checksum_valid,
        valid_fields=valid_fields,
    )


def whitening_sequence(length: int) -> bytes:
    if length < 0:
        raise ValueError("length must be nonnegative")
    state = 0xFF
    sequence = bytearray()
    for _ in range(length):
        sequence.append(state)
        feedback = ((state >> 7) ^ (state >> 5) ^ (state >> 4) ^ (state >> 3)) & 1
        state = ((state << 1) & 0xFF) | feedback
    return bytes(sequence)


def payload_crc(payload: bytes | bytearray | Iterable[int]) -> int:
    data = bytes(payload)
    crc = 0
    for value in data[: max(0, len(data) - 2)]:
        for shift in range(7, -1, -1):
            feedback = ((crc >> 15) & 1) ^ ((value >> shift) & 1)
            crc = (crc << 1) & 0xFFFF
            if feedback:
                crc ^= 0x1021
    if len(data) >= 2:
        crc ^= data[-2] << 8
    if data:
        crc ^= data[-1]
    return crc


def _nibbles_to_bytes(nibbles: Sequence[int]) -> bytes:
    if len(nibbles) % 2:
        raise ValueError("nibble count must be even")
    return bytes(
        nibbles[index] | (nibbles[index + 1] << 4)
        for index in range(0, len(nibbles), 2)
    )


def _nibbles_to_crc(nibbles: Sequence[int]) -> int:
    if len(nibbles) != 4:
        raise ValueError("CRC requires four nibbles")
    return sum(value << (4 * index) for index, value in enumerate(nibbles))


def _bytes_to_nibbles(data: bytes) -> list[int]:
    """Inverse of :func:`_nibbles_to_bytes`: the low nibble of each byte first."""

    return [value for byte in data for value in (byte & 0xF, byte >> 4)]


def _crc_to_nibbles(crc: int) -> list[int]:
    """Inverse of :func:`_nibbles_to_crc`."""

    if not 0 <= crc <= 0xFFFF:
        raise ValueError("CRC must be a 16-bit value")
    return [(crc >> (4 * index)) & 0xF for index in range(4)]


def encode_lora_packet(
    payload: bytes | bytearray | Iterable[int],
    *,
    spreading_factor: int = 7,
    coding_rate: int = 1,
    explicit_header: bool = True,
    low_data_rate_optimization: bool = False,
    payload_crc_present: bool = True,
) -> LoRaEncodeResult:
    """Build the CSS symbols a LoRa transmitter sends for ``payload``.

    This is the exact inverse of :func:`decode_lora_packet` and an independent
    implementation of the authoritative MATLAB packet-coding layer.  Every
    intermediate is returned so a differential regression can name the stage at
    which an implementation first disagrees, instead of only the final bytes.
    """

    data = bytes(payload)
    if not 5 <= spreading_factor <= 12:
        raise ValueError("spreading_factor must be between 5 and 12")
    if not 1 <= coding_rate <= 4:
        raise ValueError("coding_rate must be in [1, 4]")

    whitening = whitening_sequence(len(data))
    whitened = bytes(value ^ mask for value, mask in zip(data, whitening, strict=True))
    payload_nibbles = _bytes_to_nibbles(whitened)
    crc_nibbles = _crc_to_nibbles(payload_crc(data)) if payload_crc_present else []
    data_nibbles = payload_nibbles + crc_nibbles

    header_reduced_rate = spreading_factor >= 7
    symbols: list[int] = []
    header_nibbles: list[int] = []
    header_codewords: list[list[bool]] = []
    header_labels: list[int] = []

    if explicit_header:
        header_nibbles = _explicit_header_encode(
            len(data), coding_rate, payload_crc_present
        )
        # The first block is always sent at CR 4/8 and at reduced rate.  For
        # SF7 it holds exactly the five header nibbles; wider first blocks
        # carry data nibbles after them, which is what the decoder expects.
        first_count = spreading_factor - 2 * int(header_reduced_rate)
        carried = max(0, first_count - len(header_nibbles))
        first_block = header_nibbles[:first_count] + data_nibbles[:carried]
        first_block += [0] * (first_count - len(first_block))
        header_codewords = [_hamming_encode(value, 4) for value in first_block]
        header_labels = _diagonal_interleave(
            header_codewords, spreading_factor, 4, header_reduced_rate
        )
        symbols.extend(
            _map_labels_to_symbols(
                header_labels, spreading_factor, header_reduced_rate
            )
        )
        remaining = data_nibbles[carried:]
    else:
        remaining = data_nibbles

    payload_sf = spreading_factor - 2 * int(low_data_rate_optimization)
    block_count = (len(remaining) + payload_sf - 1) // payload_sf
    padded = list(remaining) + [0] * (block_count * payload_sf - len(remaining))
    payload_codewords: list[list[bool]] = []
    payload_labels: list[int] = []
    for block in range(block_count):
        nibbles = padded[block * payload_sf : (block + 1) * payload_sf]
        codewords = [_hamming_encode(value, coding_rate) for value in nibbles]
        labels = _diagonal_interleave(
            codewords, spreading_factor, coding_rate, low_data_rate_optimization
        )
        payload_codewords.extend(codewords)
        payload_labels.extend(labels)
        symbols.extend(
            _map_labels_to_symbols(
                labels, spreading_factor, low_data_rate_optimization
            )
        )

    return LoRaEncodeResult(
        symbols=tuple(symbols),
        whitened_payload=whitened,
        header_nibbles=tuple(header_nibbles),
        payload_nibbles=tuple(payload_nibbles),
        crc_nibbles=tuple(crc_nibbles),
        header_codewords=tuple(tuple(word) for word in header_codewords),
        payload_codewords=tuple(tuple(word) for word in payload_codewords),
        header_interleaved_labels=tuple(header_labels),
        payload_interleaved_labels=tuple(payload_labels),
        coding_rate=coding_rate,
        padding_nibble_count=block_count * payload_sf - len(remaining),
    )


def decode_lora_packet(
    symbols: Sequence[int],
    *,
    spreading_factor: int = 7,
    explicit_header: bool = True,
    low_data_rate_optimization: bool = False,
    payload_length: int | None = None,
    coding_rate: int = 1,
    payload_crc_present: bool = True,
) -> LoRaDecodeResult:
    """Decode hard CSS decisions beginning at the first header symbol."""

    decisions = [int(symbol) for symbol in symbols]
    empty = dict(
        success=False,
        crc_valid=False,
        payload=b"",
        consumed_symbol_count=0,
        payload_distances=(),
    )
    if len(decisions) < 8:
        return LoRaDecodeResult(
            header_valid=False,
            failure_reason="fewer than eight first-block symbols",
            header=None,
            header_distances=(),
            **empty,
        )

    header_reduced_rate = spreading_factor >= 7
    header_labels = _unmap_symbols(
        decisions[:8], spreading_factor, header_reduced_rate
    )
    header_codewords = _diagonal_deinterleave(
        header_labels, spreading_factor, 4, header_reduced_rate
    )
    first_nibbles, header_distances = _hamming_decode(header_codewords, 4)

    header: LoRaHeader | None
    header_nibble_count: int
    if explicit_header:
        header = _explicit_header_decode(first_nibbles[:5])
        if not header.valid:
            return LoRaDecodeResult(
                header_valid=False,
                failure_reason="explicit-header checksum or fields invalid",
                header=header,
                header_distances=tuple(header_distances),
                **empty,
            )
        payload_length = header.payload_length
        coding_rate = header.coding_rate
        payload_crc_present = header.payload_crc
        header_nibble_count = 5
    else:
        if payload_length is None:
            raise ValueError("implicit-header decoding requires payload_length")
        header = None
        header_nibble_count = 0

    assert payload_length is not None
    data_nibble_count = 2 * payload_length + 4 * int(payload_crc_present)
    first_count = spreading_factor - 2 * int(header_reduced_rate)
    first_data_available = max(0, first_count - header_nibble_count)
    first_data_count = min(data_nibble_count, first_data_available)
    data_nibbles = first_nibbles[
        header_nibble_count : header_nibble_count + first_data_count
    ]
    remaining_count = data_nibble_count - first_data_count

    payload_sf = spreading_factor - 2 * int(low_data_rate_optimization)
    payload_block_count = (remaining_count + payload_sf - 1) // payload_sf
    required_symbols = 8 + payload_block_count * (4 + coding_rate)
    if len(decisions) < required_symbols:
        return LoRaDecodeResult(
            success=False,
            header_valid=True,
            crc_valid=False,
            failure_reason="truncated payload symbols",
            payload=b"",
            header=header,
            consumed_symbol_count=required_symbols,
            header_distances=tuple(header_distances),
            payload_distances=(),
        )

    payload_distances: list[int] = []
    padded_nibbles: list[int] = []
    for block in range(payload_block_count):
        first_symbol = 8 + block * (4 + coding_rate)
        block_symbols = decisions[first_symbol : first_symbol + 4 + coding_rate]
        labels = _unmap_symbols(
            block_symbols, spreading_factor, low_data_rate_optimization
        )
        codewords = _diagonal_deinterleave(
            labels, spreading_factor, coding_rate, low_data_rate_optimization
        )
        nibbles, distances = _hamming_decode(codewords, coding_rate)
        padded_nibbles.extend(nibbles)
        payload_distances.extend(distances)
    data_nibbles.extend(padded_nibbles[:remaining_count])

    whitened_payload = _nibbles_to_bytes(data_nibbles[: 2 * payload_length])
    payload = bytes(
        value ^ whitening
        for value, whitening in zip(
            whitened_payload, whitening_sequence(payload_length), strict=True
        )
    )
    if payload_crc_present:
        received_crc = _nibbles_to_crc(data_nibbles[-4:])
        crc_valid = received_crc == payload_crc(payload)
    else:
        crc_valid = True

    return LoRaDecodeResult(
        success=crc_valid,
        header_valid=True,
        crc_valid=crc_valid,
        failure_reason="" if crc_valid else "payload CRC invalid",
        payload=payload,
        header=header,
        consumed_symbol_count=required_symbols,
        header_distances=tuple(header_distances),
        payload_distances=tuple(payload_distances),
    )


def quarter_symbol_bin_adjustments(
    spreading_factor: int, residual: Iterable[int] = range(-2, 3)
) -> list[int]:
    """Bin adjustments a free-running symbol grid can require.

    The receiver never resynchronises its FFT symbol grid, so the grid stays
    aligned to the preamble.  The SFD is 2.25 downchirps, which puts the first
    payload symbol a quarter symbol away from that grid; a quarter symbol is
    exactly ``2 ** (SF - 2)`` bins.  Both signs are searched because the sign
    depends on the chirp convention of the front end, and a residual bin or two
    covers integer CFO.  This is the whole hypothesis set: nothing else about
    the raw decisions is scanned.
    """

    quarter = 1 << (spreading_factor - 2)
    return [
        base + offset
        for base in (0, -quarter, quarter)
        for offset in residual
    ]


def decode_lora_symbol_trace(
    raw_symbols: Sequence[int],
    preamble_bin: int,
    *,
    spreading_factor: int = 7,
    symbol_offsets: Iterable[int] = range(0, 9),
    bin_adjustments: Iterable[int] | None = None,
) -> LoRaTraceDecode:
    """Search the bounded CLG400 trace for a CRC-valid explicit-header packet.

    The raw FFT decisions carry the common preamble timing/CFO bin.  Each
    candidate subtracts that bin plus one of the
    :func:`quarter_symbol_bin_adjustments` hypotheses, then scans the few
    plausible SFD-to-header offsets.  CRC success dominates header-only
    candidates; lower aggregate hard-decision distance breaks ties.

    Every hypothesis is decoded before choosing. Returning the first CRC
    success let a neighbouring bin adjustment win whenever it happened to
    pass the 16-bit CRC: on the PER bench (SF7 CR 4/6, 2026-09-30) 55 of
    5937 packets decoded to a wrong 11- or 53-byte payload although the
    true packet decoded cleanly two symbols later.
    """

    symbol_count = 1 << spreading_factor
    if bin_adjustments is None:
        bin_adjustments = quarter_symbol_bin_adjustments(spreading_factor)
    candidates: list[LoRaTraceDecode] = []
    for adjustment in bin_adjustments:
        normalized = tuple(
            (int(symbol) - preamble_bin - adjustment) % symbol_count
            for symbol in raw_symbols
        )
        for offset in symbol_offsets:
            if offset >= len(normalized):
                continue
            result = decode_lora_packet(
                normalized[offset:], spreading_factor=spreading_factor
            )
            candidates.append(
                LoRaTraceDecode(result, offset, adjustment, normalized)
            )

    if not candidates:
        raise ValueError("symbol trace contains no candidate offsets")
    successes = [item for item in candidates if item.result.success]
    if successes:
        return min(
            successes,
            key=lambda item: (
                sum(item.result.header_distances)
                + sum(item.result.payload_distances),
                abs(item.bin_adjustment),
                item.symbol_offset,
            ),
        )
    return min(
        candidates,
        key=lambda item: (
            not item.result.header_valid,
            sum(item.result.header_distances),
            abs(item.bin_adjustment),
            item.symbol_offset,
        ),
    )
