# ADR-0005: Keep hardware timestamping and receiver synchronization in this repository

**Status:** Accepted  
**Date:** 2026-09-17  
**Deciders:** Project maintainer

## Context

The project already has a verified 64-bit programmable-logic sample counter and
an atomic coarse/fractional ToA metadata path. The next positioning milestone
requires moving from a single-board relative sample timebase to a common epoch
across three ZynqSDR receivers without turning a third-party firmware fork into
the authoritative implementation of the LoRa timing architecture.

Two upstream projects are useful references:

- `F5OEO/maia-sdr`, branch `refactor`, contains the `fishball7020` board support,
  AD936x receive path, PPS/clock-related board logic, and the integration point
  around `util_ad9361_adc_pack` and `axi_ad9361_adc_dma`.
- Phil Greenland's `pgreenland/plutosdr-hdl-quantulum` demonstrates receive
  sample timestamp insertion between the channel packer and RX DMA with a
  64-bit sample counter and an asynchronous clock-domain crossing.

The timestamping feature belongs to the LoRa/ToA/TDoA system architecture, not
to a generic PlutoSDR or Tezuka firmware fork. A permanent fork would also make
project ownership, reproducibility and upstream tracking less clear.

## Decision

`Lay007/zynq-lora-phy` is authoritative for:

- the 64-bit valid-sample timebase;
- PPS epoch synchronization;
- timestamp/event capture;
- LoRa packet-start timestamp semantics;
- detector-latency and RF/baseband delay calibration;
- ToA/TDoA metadata and verification;
- the integration patches and build tooling needed for the target ZynqSDR.

The existing `fpga/wrappers/lora_sample_counter_capture.v` remains the canonical
sample counter. We will extend and integrate it rather than introduce an
independent Greenland-style counter with different semantics.

For the Fishball/HAMGEEK integration path, `F5OEO/maia-sdr:refactor` is treated
as a pinned upstream board-support/build dependency, not copied wholesale into
this repository. The initial reference revision is:

`79119c57dff1ea1d969e3453644819f081ef6dcd`

Before any generated bitstream is called compatible with a local board, the
exact FPGA package, DDR/PS configuration, AD936x interface and external
reference/PPS pins must be checked against that physical board. This decision
does not invalidate ADR-0004: the existing hardware-qualified CLG400 path stays
the first proven receiver integration; Fishball/Tezuka support is an additional
board/synchronization integration path for the multi-receiver milestone.

Phil Greenland's implementation is a reference design, not the project build
base. The pinned reference revision is:

`pgreenland/plutosdr-hdl-quantulum@d70102267713f5bbc99805be5f4f08b0a07766cb`

That repository is MIT licensed. If source code is copied or adapted rather
than independently reimplemented from the architecture, the applicable MIT
copyright/license notice must be preserved with the derived files.

## RX-first architecture

The first synchronization implementation is RX-only. Scheduled TX timestamping
is intentionally deferred because it is not required to prove LoRa ToA/TDoA.

The target receive path is conceptually:

```text
AD936x
  |
  v
accepted IQ sample stream ----> existing 64-bit valid-sample counter
  |                                      |
  |                                      +---- PPS/common epoch
  v                                      |
LoRa packet detector --------------------+----> timestamp latch
  |                                               |
  v                                               v
fractional ToA -------------------------> atomic ToA metadata
  |
  v
software / multi-receiver association / calibrated TDoA
```

For a Tezuka/Fishball-style DMA capture path, optional timestamped raw-IQ debug
support may be inserted at the existing boundary:

```text
util_ad9361_adc_pack
        |
        v
RX timestamp/debug adapter
        |
        v
axi_ad9361_adc_dma
```

Raw-IQ timestamp insertion is a verification/debug facility. The production
positioning path should latch the sample time directly when the LoRa timing
event is generated, so ToA does not depend on host scheduling or DMA-buffer
arrival time.

## Synchronization contract

A common sample counter value alone is insufficient for TDoA. The three
receivers require a documented synchronization contract:

1. a common or disciplined frequency reference to control sample-rate drift;
2. a common epoch pulse (PPS or equivalent) brought into PL;
3. explicit CDC/synchronization of the epoch event into the sample domain;
4. deterministic counter epoch semantics on every receiver;
5. measurement and removal of fixed per-channel RF, AD936x, digital-pipeline
   and detector latency;
6. monitoring of residual drift between epoch events.

Frequency coherence and epoch alignment are separate requirements. A GPSDO or
shared reference can reduce drift but does not by itself prove sample-phase or
packet-timestamp alignment.

## Repository layout

Do not vendor the complete `maia-sdr` tree. When implementation begins, use a
small project-owned integration surface, for example:

```text
hardware/
  fishball7020/
    README.md
    upstream.lock
    patches/
    build.sh

fpga/
  wrappers/
    lora_sample_counter_capture.v
    ...
```

`upstream.lock` (or an equivalent machine-readable manifest) must identify the
exact upstream commit. Patches should contain only the changes required to
expose PPS/common timing, connect the LoRa timing path and, if needed, insert
raw-IQ timestamp metadata.

## Verification gates

The synchronization work is not complete when the HDL merely builds. Evidence
must progress through these gates:

1. **Single board:** accepted-sample counter behavior remains bit-exact with the
   current RTL regression.
2. **PPS epoch:** a hardware PPS event establishes the documented epoch without
   duplicate/missed resets or captures.
3. **Two receivers:** a common injected RF event demonstrates stable measured
   sample-count difference over repeated PPS intervals.
4. **Three receivers:** fixed offsets are measured, calibrated and shown to be
   repeatable across reboot/re-arm cycles.
5. **LoRa event:** the hardware detector latches coarse time and fractional ToA
   atomically for the same packet.
6. **TDoA:** calibrated inter-receiver differences feed the existing
   multilateration model with raw evidence, configuration and uncertainty
   retained.

Passing a simulation, timestamped DMA capture or GPS lock indication alone is
not evidence of synchronized three-receiver ToA.

## Consequences

- The LoRa repository remains self-contained at the algorithm and timing-contract
  level while still reusing proven upstream board support.
- The existing coarse sample counter is reused instead of duplicated.
- `maia-sdr` updates can be evaluated deliberately by changing one pinned
  revision and reapplying a small patch set.
- Greenland's work is explicitly credited and can be compared against our
  implementation without making Pluto firmware an execution dependency.
- M6 gains a concrete implementation path: frequency reference + PL epoch +
  sample counter + LoRa event latch + calibration + three-receiver TDoA.

## Deferred work

- TX scheduled-timestamp support (`util_upack2_timestamp`-style behavior).
- Absolute UTC/GPS timestamp representation beyond the sample epoch required
  for TDoA.
- FDoA/common-frequency estimation beyond the synchronization needed for the
  first three-receiver TDoA experiment.
