# System architecture

## End-to-end view

```mermaid
flowchart LR
    TX["SX1262 or ZynqSDR transmitter"] --> RF["RF channel or calibrated cable network"]
    RF --> R1["ZynqSDR receiver 1"]
    RF --> R2["ZynqSDR receiver 2"]
    RF --> R3["ZynqSDR receiver 3"]
    CLK["Common reference and epoch/PPS"] --> R1
    CLK --> R2
    CLK --> R3
    R1 --> NET["Ethernet: payload, timestamp, metrics, IQ excerpt"]
    R2 --> NET
    R3 --> NET
    NET --> POS["Calibration and TDoA solver"]
```

Ethernet transports results but is not a timing reference. Fine arrival time is
measured against a counter in programmable logic. A common reference stabilizes
sample clocks; a common epoch signal aligns the counters.

## Receiver partition

```mermaid
flowchart LR
    ADC["AD936x IQ"] --> FE["DC/IQ correction and channel filter"]
    FE --> DET["Preamble detector"]
    DET --> SYNC["Coarse timing and CFO/SFO estimation"]
    SYNC --> DCH["Dechirp"]
    DCH --> FFT["FFT and peak estimator"]
    FFT --> DEC["PHY decode and CRC"]
    DET --> TS["Coarse counter + fractional ToA"]
    DEC --> DMA["AXI DMA / PS"]
    TS --> DMA
```

### Programmable logic (PL)

- deterministic sample-rate processing;
- channel selection and decimation;
- preamble correlation and dechirp/FFT detection;
- coarse 64-bit sample counter and fractional ToA;
- capture trigger and bounded IQ snapshot;
- AXI-Stream metadata framing.

### Processing system (PS)

- AD936x and clock-tree configuration;
- run control and health monitoring;
- packet assembly and non-real-time decode stages during early development;
- calibration table management;
- Ethernet transport and capture storage.

### Host

- golden-model regression;
- experiment orchestration;
- cross-receiver event association;
- delay correction and TDoA multilateration;
- plots, reports, and dataset provenance.

## Timing model

For receiver `i`, the reported timestamp is modeled as

```text
t_i = t_tx + range_i / c + d_i + noise_i
```

where `d_i` includes clock epoch offset, cable delay, RF/ADC group delay, and
DSP latency. TDoA eliminates the unknown transmit time, but not unequal `d_i`.
The calibrated observation relative to receiver 0 is

```text
Δt_i0 = (t_i - d_i) - (t_0 - d_0).
```

The system therefore separates:

- a coarse PL counter for unambiguous event time;
- a fractional estimator derived from correlation or FFT phase;
- a versioned per-channel calibration correction;
- an uncertainty estimate carried into the position solution.

## MATLAB-to-hardware traceability

The implementation flow is intentionally unidirectional:

```text
MATLAB floating point
        ↓ verified test vectors and numerical requirements
Simulink streaming architecture
        ↓ fixed-point types, rates, latency, and HDL-compatible controls
HDL Coder generated Verilog
        ↓ Vivado integration, constraints, and AXI wrappers
ZynqSDR hardware
```

Each hardware DSP block has four representations when applicable:

| Layer | Purpose | Required evidence |
|---|---|---|
| MATLAB float | Authoritative algorithm | `matlab.unittest`, plots, golden vectors |
| Simulink | Streaming architecture and fixed point | Error bounds vs MATLAB float |
| Generated Verilog | Cycle-accurate implementation | HDL cosimulation and golden-vector regression |
| Hardware | Real RF behavior | Versioned configuration and measurements |

The Simulink DUT boundary initially contains the coherent FFT correlator:
an `N·L` FFT, reference-spectrum multiply, `L`-partition accumulation, `N` FFT,
and peak detection. A second, separate DUT carries the joint timing/CFO
estimator, which consumes upchirp and downchirp dechirp bins rather than
samples. Both are built by script and compared against MATLAB stage by stage;
see [M2 acceptance](simulink-m2-acceptance.md). Adaptive reference estimation,
the polyphase fallback, channel filtering, preamble detection, timestamping,
fractional ToA, and AXI-Stream control will be added after the symbol detector
is verified. TDoA
event association, calibration, and multilateration remain software algorithms
validated in MATLAB; they are not initial HDL Coder targets. Generated Verilog
is treated as a build artifact of the reviewed model and generation scripts,
not as a second hand-maintained implementation.

## Metadata contract

Every received event should eventually expose at least:

```text
station_id, sequence_id, center_frequency_hz, bandwidth_hz, spreading_factor,
coarse_sample_count, fractional_toa_samples, cfo_hz, sfo_ppm, rssi_dbfs,
snr_db, crc_ok, payload, calibration_id, software_revision
```

Field names include units so that experiments can be compared without hidden
conventions.

## Processing chains

The same chains run in simulation, on recorded IQ and on the board, so a
result can be traced from a synthetic stimulus to a hardware measurement.

**Transmit / stimulus.** `zynq_lora_phy.encode_lora_packet` (whitening,
Hamming/FEC, diagonal interleaving, header, CRC) gives the symbols;
`tools/lora_tx_waveform.py` modulates them into IQ at the receiver sample
rate; `board/per/lora_tx_noise.c` streams packets through the AD9361
transmitter with AWGN added per sample at a set SNR. SX1262 (Heltec V4) and
LR1121 (LilyGO T3-S3) firmware in `firmware/` serve as independent
transmitters and reference receivers.

**Receive.** AD9361 IQ at 1 MS/s → PL: FFT correlator (dechirp + FFT
identity, generated from Simulink), preamble and sync-word detection, symbol
grid alignment, joint timing/CFO search on the IQ history buffer, CFO
derotation, 64-bit sample counter and fractional ToA → symbol trace and
timestamp metadata over AXI-Lite → host decode
(`zynq_lora_phy.lora_packet.decode_lora_symbol_trace`: Gray mapping,
deinterleaving, Hamming, header checksum, dewhitening, CRC).

**Experiment.** Synthetic IQ with CFO/SFO/noise impairments → RTL replay
(`tools/replay_iq_through_rtl.py`, `fpga/tb/tb_replay_detect.sv`) →
single-board validation → board route → packet campaigns
(`tools/run_clg400_payload_capture.py`) and the PER bench
(`tools/per_measure.py`, [PER curves](per-curves-experiment.md)) → multiple
synchronized receivers → ToA/TDoA baseline. Every run records its
configuration, board state and provenance next to the data.

**Positioning.** Per-receiver PL timestamps → delay calibration (`d_i`
above) → cross-receiver event association → TDoA multilateration
(`zynq_lora_phy.tdoa`, `model/matlab`) with an uncertainty estimate.

## Relationship to related research

This repository provides the reusable PHY, SDR acquisition, synchronization,
timestamping and positioning baseline used by related research projects.
Experimental waveform design and unpublished optimization methods are
intentionally maintained separately; they depend on a pinned revision of this
repository and never the reverse. See
[repository scope and boundary](public_private_boundary.md).
