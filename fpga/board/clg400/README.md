# CLG400 board overlay

This directory composes the portable SF7/L=8 timestamp receiver with the
hardware-qualified AD9361 shell recovered in the sibling `zynq-sdr-course`
checkout. It creates a separate project under `fpga/build/clg400-board`; the
course project and its deployed artifacts are read-only inputs.

## Build inputs

- Vivado 2021.1.
- This repository and `zynq-sdr-course` checked out as sibling directories, or
  `ZYNQ_SDR_COURSE_ROOT` set to the latter.
- The generated, namespaced HDL snapshots committed under `fpga/generated`.
- `fpga/rom/lora_sf7_l8_reference_q10.mem`.

Create the project:

```powershell
& G:\Xilinx\Vivado\2021.1\bin\vivado.bat -mode batch -nojournal -nolog `
  -source fpga\board\clg400\system_project.tcl
```

Run the synthesis evidence gate before implementation:

```powershell
& G:\Xilinx\Vivado\2021.1\bin\vivado.bat -mode batch -nojournal -nolog `
  -source fpga\board\clg400\synth_board.tcl
```

The reports are written under the ignored
`fpga/build/clg400-board/reports` directory.

If Windows Vivado finishes `synth_design` and writes `system_top.dcp` but its
run launcher does not return, do not repeat synthesis. After confirming the log
contains `0 Errors` and the completion marker exists, generate the same reports
directly from the checkpoint:

```powershell
& G:\\Xilinx\\Vivado\\2021.1\\bin\\vivado.bat -mode batch -nojournal -nolog `
  -source fpga\\board\\clg400\\report_board_checkpoint.tcl
```

If instead the launcher hangs after synthesis *without* writing
`system_top.dcp` (the synthesis log ends with `0 Errors`, `impl_1` is never
created, `vivado.exe` processes sit idle; seen on the M6 and first M7 builds),
the checkpoint path above cannot help. Stop the hung `vivado.exe` processes,
reset the stale run, and run `build_bitstream.tcl` again:

```powershell
& G:\Xilinx\Vivado\2021.1\bin\vivado.bat -mode batch -nojournal -nolog `
  -source fpga\board\clg400\reset_stale_synth_run.tcl
```

Build implementation and bitstream only after project creation succeeds:

```powershell
& G:\Xilinx\Vivado\2021.1\bin\vivado.bat -mode batch -nojournal -nolog `
  -source fpga\board\clg400\build_bitstream.tcl
```

The target is exactly `xc7z020clg400-2`. The overlay keeps the vendor RX/TX DMA
paths intact and taps the formatted RX1 FIFO stream. It does not connect to raw
offset-binary ADC pins and does not replace the vendor DAC path. This low-rate
image pins the shared ADI `util_clkdiv` selector to its divide-by-four leg:
62.5 MHz at the shell's 250 MHz worst-case input constraint. The divide-by-two
125 MHz mode is deliberately unsupported because the current generated FFT does
not meet that clock. The required radio/sample configuration is 1 Msps.

## Recorded synthesis gate

The complete `system_top` synthesis for `xc7z020clg400-2` completed with zero
errors and zero critical warnings (checkpoint checksum `45823695`). With the
authoritative root clocks restored for checkpoint reporting, all timing
constraints are met: overall WNS is +0.433 ns and the active 62.5 MHz
`clk_div_sel_0_s` domain has +1.695 ns WNS. The structurally retained 125 MHz
leg has no setup endpoints.

The synthesized design uses 34,820 LUTs, 40,166 registers, 78 BRAM tiles and 84
DSPs; the 64K x 32 IQ history maps to 64 RAMB36 blocks and the 128 x 128-bit
symbol trace adds exactly 2 more. `TIMING-6`, `TIMING-7` and `LUTAR-1` are
absent from the final methodology report. The custom bridge has no Critical CDC
findings; its CDC-3/CDC-6 entries are the declared `ASYNC_REG` synchronizers of
the status, debug, and trace-state words. The Critical CDC-1/CDC-13 rows in the
whole-design report all belong to the inherited ADI DMA and are not part of this
bridge. The concise evidence row is in
[`docs/data/rtl-m4-clg400-board-synthesis.csv`](../../../docs/data/rtl-m4-clg400-board-synthesis.csv).
This is not yet post-route or live-board evidence.

## Recorded implementation gate

The complete design also places and routes successfully. All 59,523 routable
nets are fully routed, with exact post-route WNS +0.031 ns and WHS +0.035 ns
over 100,045 setup/hold endpoints and zero total violation. The active 62.5 MHz
domain is the setup limit at +0.031 ns; the unused 125 MHz leg still has no
setup endpoints. This margin is small enough that `build_bitstream.tcl` pins the
router to `AggressiveExplore` and runs a post-route physical optimization pass
before the bitstream is accepted. Bitgen and XSA export complete with zero
errors and zero critical warnings.

The implemented design uses 32,193 LUTs, 39,462 registers, 78 BRAM tiles and 84
DSPs. The generated files are ignored build products:

- `lora_receiver_clg400.runs/impl_1/system_top.bit` — 2,530,520 bytes,
  SHA-256 `65544c8b3c36a34feedc36943ab0c33ee0792b93cf228967ad8e4eb54b58b0c0`;
- `lora_receiver_clg400.sdk/system_top.xsa` — 1,336,738 bytes,
  SHA-256 `b5d4cabebfd03cfdb9d10f259c3124cf6410aa4548c3dc8f63d221b167f718db`.

If a Vivado session is interrupted after `write_bitstream` but before the XSA is
written, do not re-run implementation: a fresh route would change the artifact
that was already signed off. Export the platform from the completed run instead,
which re-checks the run status and the timing summary first:

```powershell
& G:\Xilinx\Vivado\2021.1\bin\vivado.bat -mode batch -nojournal -nolog `
  -source fpga\board\clg400\export_hw_platform.tcl
```

The routed DRC contains no errors, but retains warnings from the inherited ADI
shell and generated DSP: asynchronous-reset checks on BRAM controls and
pipeline recommendations for DSP48 cells. The complete development boot set is
now packaged and checksum-verified offline, but it is not qualified firmware
until it has been cold-booted. The concise implementation record is
[`docs/data/rtl-m4-clg400-board-implementation.csv`](../../../docs/data/rtl-m4-clg400-board-implementation.csv).

## PS control plane

The overlay extends the existing AXI interconnect with `axi_gpreg_lora` at
`0x79040000`. Its core ID and bridge signature are both `0x4c4f5241` (`LORA`).

| Address | Direction | Meaning |
|---|---|---|
| `0x79040000` | read | `axi_gpreg` version |
| `0x79040004` | read | core ID, `0x4c4f5241` |
| `0x79040404` | read/write | control: bit 0 enable, bit 1 stream reset, bits 15:8 sync word; bit 16 selects the symbol page; bits 30:24 select its trace entry; zero sync word selects `0x12` |
| `0x79040408` | read | status/build word |
| `0x79040448` | read | accepted metadata sequence |
| `0x79040488` | read | coarse timestamp `[31:0]` |
| `0x790404c8` | read | coarse timestamp `[63:32]` |
| `0x79040508` | read | signed fractional ToA Q12 |
| `0x79040548` | read | signed log peak Q12 |
| `0x79040588` | read | sticky receiver-stage/error diagnostics and packet-start count low word |
| `0x790405c8` | read | bridge signature, `0x4c4f5241` |

Status bits are:

- bit 0: enable requested in the PS domain;
- bit 1: enable observed in the sample domain;
- bit 2: at least one atomic metadata snapshot accepted;
- bit 3: sticky metadata/mailbox overflow;
- bit 4: ToA search busy;
- bit 5: packet start seen since stream reset;
- bit 6: valid formatted sample seen since stream reset;
- bit 7: stream reset requested;
- bits 15:8: requested sync word;
- bits 31:16: bridge build version (`0x0001`).

Read `SEQUENCE`, then all timestamp words, then `SEQUENCE` again; retry if the
two sequence reads differ. The board bridge transfers all timestamp fields as
one request/acknowledge mailbox entry, and status bit 3 reports an event that
arrived before the prior one was acknowledged.

Control bit 16 selects a second, read-only view of the same gpreg outputs. It
exposes a frozen 128-entry post-acquisition symbol trace without changing the
timestamp page-zero ABI. Bits 30:24 select the entry. On this page `STATUS`
contains the `0x5359` (`SY`) marker, complete/active flags in bits 9:8, and the
captured count in bits 7:0; `SEQUENCE` is the trace sequence; the next three
words contain the raw symbol and 64-bit sample count; `LOG_PEAK` contains trace
flags and confidence; and `DEBUG` contains the preamble bin, selected index,
the grid-realigned flag in bit 8, and the count. A complete trace reports
`STATUS=0x53590280`.

Control bit 17 selects a third read-only page carrying clock accounting, and it
wins over bit 16. It exists because the receiver spent this project clocked
from `util_ad9361_divclk/clk_out`, which is the AD9361 data clock divided by
four while that clock is four times the sample rate - so it equalled the sample
rate exactly, giving the fabric one clock per sample where the joint search
budget assumes sixty-three. Nothing in the RTL or in simulation can see that,
because the coupling lives in the board wiring, so the board reports it.

On this page `STATUS` carries the `0x434b` (`CK`) marker in bits 31:16 and the
receive-crossing overflow flag in bit 0; `SEQUENCE` is the number of receiver
clocks between the last two accepted samples; `SYMBOL` is the number of clocks
the last joint search held the fabric; `SAMPLE_LO` is the smallest sample
interval seen; and `SAMPLE_HI` is the number of completed searches. All of them
clear on a stream reset except the overflow flag, which is sticky because a
dropped sample invalidates every sample count that follows it.

Sixty-three clocks per sample means the receiver is on its own fixed clock; one
means it is back on the AD9361-derived clock and no joint estimate can succeed.
`tools/read_clg400_symbol_trace.py` reads the page and every capture report
carries the numbers under `receiver_clock`, with the SFD deadline computed from
the measured ratio rather than the intended one.

The overlay also enables two ADI clock monitors inside `axi_gpreg_lora`, which
measure frequency directly against the 100 MHz control clock:

| Address | Direction | Meaning |
|---|---|---|
| `0x79040800` | write | monitor 0 enable, write `1` |
| `0x79040808` | read | monitor 0 count: `util_ad9361_divclk/clk_out` |
| `0x79040840` | write | monitor 1 enable, write `1` |
| `0x79040848` | read | monitor 1 count: the fixed receiver clock |

Frequency is `count * 100e6 / 65536`. Monitor 1 sits on a clock of known
frequency, so it calibrates the formula and turns monitor 0 into an absolute
measurement rather than an inference from the divider setting.

Control bit 18 selects a fourth read-only page carrying the joint estimator's
own numbers, and it wins over bits 17 and 16. It exists because the correction
the board applies is not the one the reference model derives from the same
packet, and the two cannot be compared without it: the board measures its
offsets from `packet_start_count` plus `chips_to_boundary`, the model from an
origin it derives from the trace alignment, so comparing the two corrections
directly compares nothing.

| Register | Meaning |
|---|---|
| `STATUS` | `0x4a54` (`JT`) marker in bits 31:16; sticky outcome bits 4:0, see below |
| `SEQUENCE` | `timing_correction_samples`, signed |
| `SYMBOL` | `up_offset_samples`, signed: how far the up peak was from the coarse start |
| `SAMPLE_LO` | `up_coarse_start[31:0]`: where the up search was told to look |
| `SAMPLE_HI` | `packet_start_count[31:0]` |
| `METRICS` | `{chips_to_boundary[15:0], preamble_bin[15:0]}` |

`STATUS` bits 4:0 (added because the controller has three silent paths back
to idle without a correction, plus a distinct success case, none of which
used to reach software in a distinguishable form -- they were folded into
the plain single-search's own `toa_search_restart_error` /
`toa_peak_boundary_error` sticky bits, or not exposed at all):

| Bit | Meaning |
|---:|---|
| 0 | an estimate completed, applied or declined (unchanged, for compatibility with saved captures) |
| 1 | the up-search aborted at least once |
| 2 | the down-search aborted at least once |
| 3 | an estimate was rejected as outside `+/-FINE_GUARD_SAMPLES` |
| 4 | a precise correction was actually applied to the grid |

Bits 1-4 are sticky and independent of each other and of bit 0: an abort
never pulses bit 0's underlying `joint_timing_valid`, so before this it left
this whole page indistinguishable from "no packet has arrived yet". `SEQUENCE`
through `METRICS` are frozen only when the estimate completes (bit 0/4 case);
on an abort or rejection they keep whichever values an earlier successful
estimate left, if any -- bits 1:3 are what say that happened. All of `STATUS`
bits 4:0 hold until the next stream reset. The remaining quantities of a
completed estimate follow from `SEQUENCE`/`SYMBOL`:
`down_coarse_start = up_coarse_start + 10240` and
`down_offset = 2 * timing_correction_samples - up_offset_samples`.

`tools/read_clg400_symbol_trace.py` reads the page and every capture report
carries it under `joint_estimate`, including `derived_up_coarse_start`, which
recomputes `packet_start_count + chips_to_boundary * 8` in software. If the
board's own `up_coarse_start` and that recomputation disagree, the estimator is
searching somewhere other than where its inputs say it should.

 The full capture and
software-decoder contract is documented in
[`docs/clg400-symbol-trace.md`](../../../docs/clg400-symbol-trace.md).

This page carried the first decoded over-the-air LoRa payload on this
board: a Heltec packet whose frozen trace passed the explicit-header
checksum and the LoRa payload CRC and returned the transmitted sequence
number. The receiver now also realigns its symbol grid to the packet it
acquired, so those decisions are taken on the packet grid and `DEBUG` bit 8
says so. Both runs are recorded in
[`docs/clg400-payload-session-2026-09-03.md`](../../../docs/clg400-payload-session-2026-09-03.md).

`DEBUG` is cleared by stream reset. Bits 15:0 capture
`packet_start_count[15:0]` on the latest acquisition, bit 16 is the internal
receiver-enable state, and bits 17, 18, 19, 20, and 21 respectively indicate
that metadata, fractional ToA, peak triplet, matched-filter correlation, and
ToA-search stages were reached. Bits 31:22 are sticky errors in this order:
alignment, symbol-index width,
search underflow, search restart, MAC window mismatch, MAC read miss, MAC
response mismatch, MAC restart, peak-at-boundary, and peak restart.

## Package the board-B SD directory

After implementation, assemble the six-file SD payload and its manifest:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  fpga\board\clg400\package_board_b_boot_set.ps1
```

The script validates fixed SHA-256 values for the deployed board-B baseline,
the course kernel, the new bitstream, and the XSA. It refuses to overwrite an
existing output and creates the ignored directory
`fpga/build/clg400-board/boot-set-board-b`. The archived board-B artifact set
omitted `uImage`; the selected sibling-course copy is byte-identical to the
original deployed source. `manifest.json` explicitly marks the result
unqualified and offline-only. The tracked six-row evidence record is
[`docs/data/rtl-m4-clg400-board-boot-package.csv`](../../../docs/data/rtl-m4-clg400-board-boot-package.csv).

After the first cold boot, copy `verify_board_b_cold_boot.sh` to `/tmp` on the
board and run it as root. It checks the two `LORA` identity words, performs a
receiver-only reset/enable, verifies formatted RX activity and overflow, and
reads an atomic metadata snapshot. It does not touch FPGA manager, QSPI, or TX
controls.

The AD9361 comes up at 30.72 MS/s with a bypassed filter chain, so every cold
boot also needs `restore_rx_profile.sh` before any receive experiment. It writes
only transceiver IIO attributes and reads them back, failing if the chain did
not land on the requested rate with both FIR paths enabled. The attribute order
is the part worth keeping: the RX FIR cannot be enabled while the chain still
sits at a rate the filter cannot serve, and the driver answers that with a bare
`EINVAL`. The script follows `ad9361_set_bb_rate()` from libad9361-iio — park at
3 MS/s bypassed, load the 128-tap decimate- and interpolate-by-4 filter, enable
the transmit side, move to the target rate, enable the receive side — and then
sets bandwidth, LO, and manual gain. The expected read-back is:

```text
BBPLL:1024000000 ADC:32000000 R2:16000000 R1:8000000 RF:4000000 RXSAMP:1000000
```

## Deployment boundary

Project creation, synthesis, implementation, and bitstream generation are
separate evidence gates. A generated `.bit` must not be hot-loaded into the
running course Linux image: earlier hardware work demonstrated that this can
leave RX DMA unusable while the gpreg window still responds. Copy the prepared
six-file boot set to a cloned SD card, verify checksums, and cold-boot it by the
procedure in `docs/clg400-hardware-bring-up.md`.
