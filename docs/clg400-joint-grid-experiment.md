# Next hardware experiment: joint-grid receiver on the board

This is the experiment that closes, or refutes, the sample-phase root cause
identified in [stage-differential.md](stage-differential.md). It is written to
be executed verbatim.

The claim under test is narrow and falsifiable:

> The one-sided `+1 bin` symbol bias is caused by the sample phase left
> unresolved by the integer-chip resync. A receiver that applies the joint
> up/down sample correction in PL will deliver symbols that equal the
> transmitted symbols, with no bin adjustment, on captures where the previous
> build produced a two-bin split.

Everything needed to decide this offline already exists: the reference model,
the packet encoder, and `tools/export_stage_differential.py`. What is missing
is a board that actually applies the correction.

## Why this experiment and not a PER run

A packet-error-rate campaign now would measure the defect, not the link. The
previous build decoded 3 payloads in 16 at a strong signal level; that number
is a property of where each packet happened to land on an unaligned grid. PER
is only meaningful once the symbol stage agrees, which is exactly what this
experiment establishes.

## Prerequisites

The joint up/down estimator is already proven in the reference model, in
packet-rate RTL simulation, and in portable out-of-context synthesis at
71.266 MHz against a 62.5 MHz requirement
([`data/rtl-joint-chirp-grid-2026-09-04.json`](data/rtl-joint-chirp-grid-2026-09-04.json)).
It has **not** been routed in the complete board design.

Step 0 is therefore a build, not a measurement:

```bash
# From the repository root, with Vivado 2021.1 on PATH.
vivado -mode batch -source fpga/board/clg400/system_project.tcl
vivado -mode batch -source fpga/board/clg400/build_bitstream.tcl
vivado -mode batch -source fpga/board/clg400/export_hw_platform.tcl
```

Gate before going near the board: zero routing errors, zero critical warnings,
post-route WNS and WHS both positive. The previous accepted board build closed
at +0.031 ns WNS and +0.035 ns WHS, so this is known to be tight — if the
router lands negative, re-run with `AggressiveExplore` and the post-route
physical optimization pass, which `build_bitstream.tcl` already does by
default. **Do not deploy a bitstream that missed timing**; one earlier attempt
routed to −0.003 ns and was correctly discarded.

Then package and deploy the SD image exactly as
[`clg400-payload-session-2026-09-03.md`](clg400-payload-session-2026-09-03.md)
describes: back up the active `system_top.bit`, checksum it, copy the new one
to a temporary file on the same mount, compare checksums, rename atomically,
sync, and re-verify in place. Cold boot. Do not touch QSPI.

## Transmitter — Heltec WiFi LoRa 32 V4.3 / SX1262

Firmware `zynq-lora-heltec-v4-sx1262-tx` 0.2.0, serial on `COM10` at 115200.

| Setting | Value |
|---|---|
| Frequency | 868.100 MHz |
| Bandwidth | 125 kHz |
| Spreading factor | 7 |
| Coding rate | 4/5 |
| Sync word | 0x12 |
| Preamble | 12 symbols |
| Payload CRC | on |
| IQ | normal |
| Payload | `counter`, length 32 (the `ZLP1` frame) |
| TX power | **−9 dBm** |
| Periodic transmission | **off** — single `send` only |

The transmitter defaults back to 0 dBm after its own power cycle, so set and
**read back** −9 dBm before every attempt. `stop` before and immediately after
each `send`; never issue `start`. Keep both antennas fitted.

Hold TX power fixed. Raising it will not change the bias — the residual is a
property of the grid, not of SNR — and changing two variables at once would
make the result unattributable.

## Receiver — CLG400 ZynqSDR board B, RX1

After the cold boot the AD9361 comes up at 30.72 MS/s and must be returned to
the LoRa profile. The attribute order matters and getting it wrong returns a
bare `EINVAL`; the script already encodes the correct order:

```sh
sh /path/to/restore_rx_profile.sh
```

It must read back exactly:

```text
BBPLL:1024000000 ADC:32000000 R2:16000000 R1:8000000 RF:4000000 RXSAMP:1000000
```

| Setting | Value |
|---|---|
| RX sample rate | 1 MS/s |
| RX LO | 868.100 MHz (reads back 868,099,998 Hz) |
| RF bandwidth | 200 kHz |
| Gain control | **manual**, both channels |
| Hardware gain | **50 dB**, both channels |
| RX FIR / TX FIR | both enabled, 128-tap decimate/interpolate by 4 |

Then confirm the overlay:

```sh
sh /path/to/verify_board_b_cold_boot.sh
```

Expect `fpga_manager` reporting `operating`, both `0x4C4F5241` signatures
present, page one answering with the `0x53590000` symbol marker, and a status
of `0x00011243` — receiver enabled in both domains, formatted RX activity,
no sticky overflow.

## What to capture

**Twelve** individually commanded transmissions. Each attempt must produce
**both** artefacts from the same packet, or it does not count:

1. a raw RX1 DMA recording — 1,500,000 complex samples of interleaved
   little-endian int16 I/Q, i.e. 6,000,000 bytes, 1.5 s at 1 MS/s;
2. the frozen 128-entry PL symbol trace, armed before the transmission and
   read after it.

Twelve is chosen deliberately: the previous builds gave 10 and 16 attempts, so
twelve is directly comparable and is enough to separate "every capture agrees"
from "most do", which is the only distinction this experiment has to make. It
is *not* enough for a PER figure and must not be reported as one.

```powershell
$env:CLG400_SSH_PASSWORD = [System.Net.NetworkCredential]::new(
  '', (Read-Host -AsSecureString 'CLG400 SSH password')).Password
python tools/capture_clg400_iq_trace_pair.py `
    --password-env CLG400_SSH_PASSWORD `
    --known-hosts fpga/build/clg400-board/known_hosts.current `
    --connect-timeout 20 --port COM10 --attempts 12 `
    --run-dir experiments/runs/<date>-clg400-joint-grid
```

`capture_clg400_iq_trace_pair.py` does both halves in one attempt: it arms the
trace, starts the DMA recording so it brackets the transmission, sends once,
reads the frozen trace and streams the recording back over the same SSH
connection. It refuses an attempt whose recording is short, because a
truncated packet is worse than a missing one - it still looks like data. The
2026-09-03 session did this by hand.

The board runs from a RAM disk, so its host key is regenerated on every boot.
Re-pin it for the current power cycle before the run:

```bash
ssh-keyscan -T 8 192.168.40.1 > fpga/build/clg400-board/known_hosts.current
```

Also record, per attempt: the transmitter's reported `TX seq`, `len`,
`start_ms` and `duration_ms`; the capture sequence; `preamble_bin`; and the
`DEBUG` bits, including bit 8 (grid realigned).

Keep the raw IQ out of Git — `experiments/runs/` is ignored. Commit only the
JSON summaries and their SHA-256 hashes, as the previous sessions did.

## Analysis — the exact commands

For every attempt:

```bash
python tools/export_stage_differential.py \
    experiments/runs/<date>-clg400-joint-grid/clg400-trace-<stamp>.json \
    --csv stages-<stamp>.csv --json stages-<stamp>.json
```

The IQ path is taken from `serial.iq_capture` in the trace. The exit code is
`0` when no stage diverged.

For continuity with the previous session, also run:

```bash
python tools/analyze_clg400_iq_trace.py \
    experiments/runs/<date>-clg400-joint-grid/clg400-trace-<stamp>.json \
    experiments/runs/<date>-clg400-joint-grid/rx1-iq-<stamp>.bin
```

## What confirms the hypothesis

The prediction is specific. On the joint-grid build:

| Quantity | Predicted |
|---|---|
| `first_divergent_stage` | `null` on the large majority of attempts |
| `symbol` stage | agreed — delivered symbols equal transmitted symbols |
| `raw_decision_bin_spread` | **1**, not 2 |
| `bin_error_histogram` | `{0: 53}` |
| `bin_adjustment` in the trace decode | 0 |
| `DEBUG` bit 8 | set on every capture |
| Payload CRC valid | on the large majority of attempts |
| `joint_chirp_timing.correction_samples` | small, since PL already applied it |

`raw_decision_bin_spread` is the sharpest single number. On the previous build
it was 2 on all three analysed captures — the packet's raw decisions split
across two adjacent bins, which is what forces a one-sided residual no integer
adjustment can remove. If the PL correction works, that split collapses to a
single bin and the spread becomes 1. **A spread of 1 with a valid CRC is the
result that confirms the root cause.**

## What refutes it, and what each failure would mean

This is the part worth reading before the bench is packed up.

- **Spread stays 2, `symbol` still diverges one-sided.** The PL correction is
  not reaching the grid. Check `DEBUG` bit 8 and the withheld-guard arithmetic
  first: the coarse resync deliberately withholds a 16-sample guard that the
  late request must add back together with the signed joint correction. A sign
  error there would leave the residual untouched or double it.
- **Spread becomes 1 but the errors move to a constant non-zero offset.** The
  correction is being applied with the wrong sign or the wrong guard. The
  offline `joint_chirp_timing.correction_samples` in the report tells you the
  size and direction the model wanted; compare it against the skip the trace
  actually shows.
- **Spread becomes 1, CRC passes, but only on some attempts.** Then the
  remaining failures are a *different* effect and the sample-phase story is
  closed. Look at SNR and at `correlator_margin_db` in the CSV before assuming
  anything.
- **An earlier stage diverges.** `iq_format`, `sample_grid`, or `peak_bin`
  going red would mean the new build changed something upstream that the
  previous one had right. The ladder names it directly; that is what it is
  for.

## Result — 2026-09-08: refuted for this build

The experiment was executed. The joint-grid board design was routed
(post-route WNS +0.062 ns, WHS +0.011 ns, TNS/THS 0, 100 % of nets routed,
zero errors), the routed netlist was confirmed to contain `u_joint_grid_timing`,
`u_grid_resync`, `u_toa_search`, `u_iq_history` and `u_receiver`, the bitstream
was installed on the SD card against a checksum with the previous image backed
up, and the board rebooted onto it. Eleven paired captures were taken under the
documented profile. Full data in
[`data/clg400-joint-grid-result-2026-09-08.json`](data/clg400-joint-grid-result-2026-09-08.json).

**The prediction failed.** `raw_decision_bin_spread` stayed at 2 on ten of the
eleven captures. It did not collapse to 1.

The reason is specific, and it is the "wrong guard" branch of the failure list
below rather than a defect in the root cause:

| Quantity | Baseline arm | Joint-grid arm |
|---|---:|---:|
| Resync skips per capture | 1 | 1 |
| `skip` − `mod(chipsToBoundary + 2**(SF−2), 2**SF)·L` | **0** on 12/12 | **−16** on 11/11 |
| Offline joint correction still needed, mean | +0.83 samples | **+19.8 samples** |
| `raw_decision_bin_spread` | 2 on 7/12 | 2 on 10/11 |

The coarse resync withholds the 16-sample `FINE_GUARD_SAMPLES` on every
capture, exactly as designed. **The late fine request that must return that
guard together with the signed joint correction never arrives**: every trace
still shows exactly one resync skip, and the correction the offline estimator
then needs moves from a mean of +0.83 samples to +19.8. This build is therefore
strictly worse than the one it replaces — it removes sixteen samples and never
gives them back.

### What is not refuted

The root cause itself. Applying the joint up/down correction offline to these
same eleven captures takes ten of them to a fully agreeing symbol stage and a
valid packet decode, exactly as it did on the baseline arm. What failed is this
build's ability to apply that correction, not the correction.

### Reproduced offline, and the defect named

The failure was then reproduced in simulation without the bench.
`tb_lora_joint_grid_completion` drives the packet at a non-zero arrival phase
(`+grid_phase=N`, a silence prefix rather than a partial chirp so the stimulus
is not itself an artefact). At any non-zero phase:

```
search_failed=1  fine_resync=0  state=IDLE
peakboundary=1   macreadmiss=0  range_error=0
```

**This is not the board's mechanism, and it should not be reported as one.**
The abort trigger differs — a peak at the search boundary here, a history read
miss there — and probing at detection shows why: with a silence prefix the
detector still reports `preamble_bin = 0` and `chips_to_boundary = 0`, so the
coarse resync removes nothing and the search faces the full injected offset
against a ±16-sample radius. `FINE_GUARD_SAMPLES must cover SEARCH_RADIUS` is
asserted in the controller, so a residual that large is outside what the design
claims to handle. The simulated abort is a property of this stimulus.

What it does establish is the *consequence* of any abort, whatever causes it:
the search fails, no fine request is issued, and the coarse resync has already
withheld the guard. That consequence is what the board showed.

**That asymmetry is the defect.** Withholding the guard is unconditional;
returning it was conditional on the estimate succeeding. Any search failure,
through any of the three paths, left the grid permanently sixteen samples
short — strictly worse than never attempting the correction. It is why this
build measured worse than the one it replaced rather than merely no better.

The fix makes the return unconditional: every abort path now issues a fine
request carrying the bare `FINE_GUARD_SAMPLES` with a zero correction, so a
declined estimate degrades to exactly the coarse-only grid. A new
`search_abort_error` output feeds `toa_peak_boundary_error`, because a silent
abort is what made this cost a full bench run to find.

| Arrival phase | Searches | Aborted | `timing_valid` | `fine_skip` |
|---:|---:|---:|---:|---:|
| 0 | 2 | 0 | 1 | 23 (guard + correction 7) |
| 64 | 1 | 1 | 0 | **16** (bare guard returned) |
| 512 | 1 | 1 | 0 | **16** |

The regression now requires the guard back whatever the estimate does. The
controller, joint-path, receiver-top and CLG400 bridge regressions are
unchanged by it, and the joint path still reports `fine_skip=27`.

**Still open, and the next thing to settle:** why the board's search hits a
history read miss on every packet. It remains unreproduced offline — the
simulation reaches an abort by a different route. What is now known is that it
is deterministic and phase independent, so the next steps are:

- Establish why the detector reports `preamble_bin = 0` for a packet delayed by
  a silence prefix. Either the testbench delay is not the same thing as a real
  arrival phase, or the reported bin does not carry it; both matter, because
  the coarse resync depends on that bin.
- ~~Correlate the read miss with `preamble_bin` on the board.~~ **Done
  2026-09-09, and it refutes the phase hypothesis.** Fourteen packets, the
  sticky word cleared before each: `read_miss` on **14 of 14**, across
  `preamble_bin` 5 to 118, with an identical sticky word every time and
  `toa_peak_boundary_error` clear throughout. The miss does not depend on where
  the packet lands — it is deterministic on every packet. That rules out a
  marginal history-depth or timing effect and points at a systematic
  addressing or counter-domain error in the joint search. It also confirms the
  simulated boundary abort and the board's abort are different events.

### The board's read miss, reproduced offline

`tb_lora_joint_grid_completion` takes `HISTORY_DEPTH` as a parameter. At the
production 65536 the buffer never fills in this stimulus, `oldest_sample_count`
stays 0, and the "read too old" half of the miss condition is unreachable. On
the board the count runs into the millions and that half is always live.

Building the same test with a shallow history reproduces the board's flag
exactly:

```bash
iverilog -g2012 -DLORA_NAMESPACED_GENERATED -s tb_lora_joint_grid_completion   -Ptb_lora_joint_grid_completion.HISTORY_DEPTH=4096 -o /tmp/jg.vvp <sources>
vvp /tmp/jg.vvp
```

| `HISTORY_DEPTH` | Result |
|---:|---|
| 65536 | passes; 2 searches, no abort, `fine_skip=23` |
| 4096 | `macreadmiss=1`, every other flag clear |

That single flag, alone, is precisely what the board reported. **But it is the
same flag reached by a different route, and the board was then measured
directly to settle which.**

The miss condition has two halves: a read below `oldest_sample_count`, and a
read at or above `next_sample_count`. The receive-stream reset zeroes the
history counters, so `oldest` stays 0 until 65536 samples accumulate — 65.5 ms
at 1 MS/s. Sending a packet immediately after the reset therefore makes a
too-old read impossible. With the transmitter prepared beforehand and the
interval measured at the serial write rather than at the response:

| arm → send | read miss |
|---:|---|
| 0.2 ms ×4 | set |
| 3000 ms ×2 | set |

At 0.2 ms only a few hundred samples exist and detection lands near twelve
thousand, far short of the 65536 needed before anything is overwritten. Nothing
can have aged out, yet the miss occurs. **The board's failing read is ahead of
the stream, not behind it.** The shallow-history simulation reproduced the flag
through a `TOO_OLD` read and so matched the symptom, not the mechanism; it must
not be cited as the board's failure.

A future read points at one asymmetry. Both searches read
`coarse_start − SEARCH_RADIUS` through `coarse_start + REF_SAMPLES +
SEARCH_RADIUS`. The down search always waited for that window via
`STATE_WAIT_DOWN_DATA`. **The up search did not** — it launched as soon as the
shared search was free, whether or not its window had arrived.
`STATE_LAUNCH_UP` now waits on the same condition against `up_ready_count`.

The guard fix already makes this failure harmless rather than harmful.

A further step is now clearly worth its cost: `history_next_sample_count`,
`history_oldest_sample_count` and `history_samples_retained` are left
unconnected in `lora_clg400_gpreg_bridge`, so the retained window cannot be
read from the PS. Exposing them would say immediately whether the failing read
is too old or in the future, which splits the remaining hypotheses in half.

The guard fix makes an abort harmless rather than harmful. It does not deliver
the correction, and the joint-grid build should not be re-deployed as an
improvement until the abort itself is understood.

### Where to look next

`lora_joint_chirp_grid_controller` has three paths that reach `STATE_IDLE`
without asserting `fine_resync_valid`:

1. `search_failed` during the upchirp search;
2. `search_failed` during the downchirp search;
3. a rounded timing estimate outside `±FINE_GUARD_SAMPLES`, which sets
   `timing_range_error` and a zero `fine_skip`.

The first two emit no status at all, and `timing_valid` is left unconnected in
`lora_packet_toa_receiver_top`, so a frozen trace cannot tell them apart. That
observability gap is why this took a full bench run to find, and it is the same
gap `DEBUG` bit 8 was added to close for the coarse aligner.

The 15-bit diagnostic sticky word does separate them, and it names path 1 or 2:

| Diagnostic sticky | Baseline build | Joint-grid build |
|---|---|---|
| value | `0x0058` | `0x0218` |
| `toa_mac_read_miss_error` | clear | **set** |
| `toa_peak_boundary_error` | set | clear |

`toa_peak_boundary_error` carries `joint_grid_timing_range_error`, and it is
**not** set on the joint-grid build, so path 3 — a rejected out-of-range
estimate — did not fire. `toa_mac_read_miss_error` is set only when the joint
controller is active. **The abort is a `search_failed` caused by an IQ history
read miss:** the joint up/down search asks the history buffer for samples it
will not serve, the search fails, the controller returns to `STATE_IDLE`
without asserting `fine_resync_valid`, and the guard is never returned.

That makes the next step concrete: the history the joint search reaches back
to, not the timing budget, is what the packet-rate RTL regression did not
model. `HISTORY_DEPTH` is 65536 samples; the search's coarse start and the
guard-shifted grid together need to be checked against what the buffer
actually still holds at the moment the down search launches.

**The prerequisite for the next attempt is an observable "fine correction
applied" flag beside `DEBUG` bit 8, plus a sticky bit per abort reason.**
Without it the next build cannot distinguish "the estimator never ran" from
"it ran and was rejected" any better than this one could.

Until that build exists, the previous integer-chip image is the better one to
run: it is the arm whose skip matches the formula exactly. It is preserved on
the card as `system_top.bit.pre_jointgrid_20260908T173805Z`.

## Guard return, verified on hardware — 2026-09-09

The board design was rebuilt with both changes and closes better than the one
before it: post-route WNS +0.264 ns, WHS +0.034 ns, 100 % of nets routed. The
routed netlist still carries every joint-grid cell. Evidence:
[`data/clg400-guard-return-2026-09-09.json`](data/clg400-guard-return-2026-09-09.json).

**The guard return works.** Every capture now shows *two* resync skips instead
of one:

| seq | preamble bin | coarse skip | fine skip | total | formula | total − formula |
|---:|---:|---:|---:|---:|---:|---:|
| 76 | 41 | 936 | 16 | 952 | 952 | **0** |
| 77 | 21 | 72 | 16 | 88 | 88 | **0** |
| 78 | 74 | 672 | 16 | 688 | 688 | **0** |
| 80 | 86 | 576 | 16 | 592 | 592 | **0** |
| 81 | 29 | 8 | 16 | 24 | 24 | **0** |

Against `−16` on eleven of eleven captures before the fix. The delivered grid
now lands exactly on the coarse formula, so the joint-grid build is no longer
worse than the integer-chip build it replaces. That was the whole point of
making the return unconditional.

The analysis tool was corrected alongside: its `sample_grid` rung allowed one
resync skip, which was right for the integer-chip build and wrong for this one.
A coarse-plus-fine pair is now the expected shape.

**What is still not fixed.** The joint estimate itself is still declined — the
search continues to hit a history read miss — so the grid degrades to
coarse-only rather than being refined. Adding the missing data-ready wait to
the up search did **not** remove the miss: sending a packet 0.1 ms after the
stream reset, where nothing can have been overwritten, still produces it. The
failing read is still ahead of the stream and it is not the up search's first
read.

### The read miss, explained to the sample

The fine skip lands around trace entry 53 — roughly fifty symbols, not the
dozen the geometry predicts. That number turned out to be the whole answer.

`lora_iq_history_buffer` raises `read_miss` for **two different things**:

```verilog
wire read_write_collision = sample_valid && (read_addr == write_addr);
...
if (read_in_range && !read_write_collision) read_valid <= 1'b1;
else                                        read_miss  <= 1'b1;
```

A sample outside `[oldest, next)` is one. A read address that equals the write
address on a cycle when a sample arrives is the other, and it is reported
identically. The joint search reads a **fixed** window 9.75 symbols behind the
write pointer. While it runs the write pointer advances, and after a full
65,536-sample wrap it reaches that window. The collision fires, `read_miss`
feeds `search_failed`, and the estimate is abandoned.

The model predicts the timing exactly:

```text
samples from trace start to the fine skip = DEPTH − lookback + coarse_advance
```

| seq | preamble bin | coarse advance | fine skip at sample | minus advance |
|---:|---:|---:|---:|---:|
| 80 | 86 | 336 | 55888 | 55552 |
| 78 | 74 | 432 | 55984 | 55552 |
| 76 | 41 | 696 | 56248 | 55552 |
| 81 | 29 | 792 | 56344 | 55552 |
| 77 | 21 | 856 | 56408 | 55552 |

**55552 on all five, zero residual** — the slope against the advance is exactly
1. `65536 − 55552 = 9984` samples, 9.75 symbols, which is precisely the
lookback from the write pointer to the read window at search start.

This supersedes the future-read conclusion above. That was reached by
elimination — a too-old read is impossible so soon after a stream reset — and
the elimination missed this third cause. The up-search data-ready wait added on
the strength of it is correct and harmless, but it was not the fix.

### Root cause: the receiver got one clock per sample

The receiver's `sample_clk` came from `util_ad9361_divclk/clk_out`
(`lora_overlay_injection.tcl`, `clk_sel` tied to GND). Two static facts fix
what that clock is:

- `util_clkdiv` is instantiated with its defaults, `SEL_0_DIV = "4"`, and
  `BUFGMUX_CTRL` selects `I0` when `clk_sel` is 0. The output is the input
  divided by four.
- The AD9361 data clock is four times the sample rate. That is what makes the
  overlay's own comment - "62.5 MHz at the 250 MHz XDC maximum" - come out
  right: 250/4, at 61.44 MS/s.

Multiply them and the divider output is the sample rate itself. **The receiver
had exactly one fabric clock per sample, and no choice of AD9361 sample rate
changes that**, because both terms scale together. The 62.5 MHz the design is
written and constrained for exists only at the maximum sample rate, and even
there it is one clock per sample.

Measured rather than inferred, with ADI's clock monitor inside `axi_ad9361`
(`ADI_REG_CLK_FREQ` at `0x79020054`, against `fclk0` read from the PS clock
tree as 99,999,999 Hz):

| AD9361 sample rate | `CLK_FREQ` | AD9361 data clock | ratio to sample rate |
|---:|---:|---:|---:|
| 1.00 MS/s | 2624 | 4.0039 MHz | 4.004 |
| 2.00 MS/s | 5248 | 8.0078 MHz | 4.004 |
| 4.00 MS/s | 10496 | 16.016 MHz | 4.004 |
| 8.00 MS/s | 20992 | 32.031 MHz | 4.004 |
| 15.36 MS/s | 40306 | 61.505 MHz | 4.004 |
| 30.72 MS/s | 80613 | 123.00 MHz | 4.004 |

Linear over the whole range, so the receiver clock at the LoRa profile was
4.0039/4 = **1.001 MHz**, one clock per sample.

That single fact explains the whole investigation:

- The joint search costs 135,443 clocks. The SFD deadline is 2304 samples,
  which at one clock per sample is 2304 clocks. The search is **fifty-nine
  times** over its deadline and cannot fit at any profile.
- It therefore never completes. The history read window sits 9,984 samples
  behind the write pointer, so it ages out 65,536 - 9,984 = 55,552 samples
  after the search is armed - and 55,552 is well short of the 135,443 the
  search would need. The abort is the age-out, every time.
- **The read miss and the missed deadline are the same root cause**, which is
  why every attempt to fix one of them left the other in place.

Three independent measurements agree: the abort lands 55,552 samples after the
phase-corrected origin with zero residual across five captures; the fine skip
appears 50 to 51 symbols after the coarse resync in the traces; and
`toa_search_busy` is held 60 ms against the 55.5 ms the model predicts, on a
poll with 13.8 ms granularity.

An earlier estimate in this document put the clock at 1.9 to 3.2 MHz. It was
derived from that same busy window while assuming the search ran to
completion, and it was wrong by about a factor of two in one direction and
sixty in the other - the search does not complete, so its duration measures the
age-out rather than the cost. The number above is measured at a register, not
derived.

And it explains why no regression caught it.
`tb_lora_joint_chirp_grid_path` checks the deadline as
`SFD_SAMPLES * CLOCKS_PER_SAMPLE_CEIL` with `CLOCKS_PER_SAMPLE_CEIL = 63`, and
`tb_lora_joint_grid_completion` offers `+sample_gap=63` as the setting that
"reproduces the board's density". Sixty-three is the assumption, not the
board: a fifty-nine-fold overshoot was scored as 135,443 against 145,152 and
read as comfortable. No simulation could catch it, because nothing in the RTL
says the fabric clock and the sample rate are tied together on this platform.

**This is a design-level problem, not a bug to patch.** The joint up/down
estimator as specified cannot complete inside the SFD while the receiver is
clocked from the AD9361 data clock, at any sample rate. The options are to
clock the receiver from a fixed PL clock, to cut the search cost by about
sixty, or to stop requiring the correction inside the SFD.

### The fix: a fixed receiver clock

The receiver now has its own clock, and the samples cross into it.

`lora_overlay_injection.tcl` adds a `clk_wiz` fed from `sys_cpu_clk` producing
62.5 MHz, a `proc_sys_reset` for the new domain held until the MMCM locks, and
drives `lora_clg400_bridge/sample_clk` from it. `util_ad9361_divclk/clk_out`
stays connected, but only as `rx_clk`, carrying arriving samples.

62.5 MHz is not a free choice. It is the frequency the design is already
written and constrained for, and the last board build closed at `WNS +0.264 ns`
against it, which puts the routed ceiling near 63.5 MHz. The 71.266 MHz on
record is out-of-context synthesis of the receiver alone, not the routed board;
treating those two numbers as interchangeable would be the same class of
mistake as the clock itself. At 62.5 MHz and 1 MS/s the SFD deadline is
2304 * 62.5 = 144,000 clocks against the 135,443 the search needs - a 6 %
margin, thin but positive, and now a measured quantity rather than an
assumption.

The crossing is `lora_async_sample_fifo`, a small dual-clock FIFO with
Gray-coded pointers, not a toggle handshake. On the old clock `rx_valid` is
asserted on essentially every `rx_clk` cycle, because the clock *is* the sample
rate, so a handshake with acknowledgement would pass one sample per round trip
and drop most of the stream. A bare toggle would work at this rate and fail
silently if the sample rate were ever raised; the FIFO turns that case into an
explicit `wr_overflow`.

### Measuring it rather than believing it

The estimate this section replaces was wrong because it was derived and then
reported alongside measurements. The same build therefore carries two
independent ways to check the claim.

`axi_gpreg_lora` now instantiates two ADI clock monitors: monitor 0 on
`util_ad9361_divclk/clk_out` and monitor 1 on the new fixed clock. Monitor 1
sits on a clock of known frequency, so it calibrates the count-to-frequency
formula and turns monitor 0 into an absolute measurement.

The bridge counts, in the receiver's own domain, the clocks between two
accepted samples and the clocks the last joint search held the fabric, and
reports them on a third register page selected by `gp_ctrl[17]`.
`tools/read_clg400_symbol_trace.py` reads that page on every capture and puts
the numbers in the report under `receiver_clock`, with the SFD deadline
computed from the **measured** ratio. Scoring a search against the deadline the
design wants rather than the one it has is precisely how a fifty-nine-fold
overshoot came to look comfortable.

The page is read eight times and the largest interval kept, because
`util_wfifo` hands out samples in bursts of eight and a single reading can
legitimately land inside a burst.

### Result on hardware, 2026-09-09

Bitstream `dce57510e6aa77c69de907adbaa1183c`, routed at `WNS +0.052 ns`,
`WHS +0.030 ns`, no failing endpoints. 37,747 receiver endpoints moved onto
`clk_out1_system_lora_receiver_clk_0`; the old divider leg retains 1,735 at
+9.43 ns, and the inter-clock table is empty, so every crossing is covered by
the clock groups.

The clock, measured at both monitors:

| | raw | frequency |
|---|---:|---:|
| monitor 1, fixed receiver clock | 40960 | 62.5000 MHz |
| monitor 0, AD9361 divided clock | 656 | 1.0010 MHz |

Monitor 1 read its known frequency exactly, calibration factor 1.0000, so
monitor 0 is an absolute measurement. The receiver really did have one clock
per sample. The AD9361 driver agrees independently: `rx_path_rates` reports
`RF:4000000` at `RXSAMP:1000000`.

| | before | after |
|---|---:|---:|
| clocks per sample | 1 | 63 |
| SFD deadline | 2,304 clocks | 145,152 clocks |
| joint search cost | never completed | **135,443 clocks** |
| fine correction applied at trace entry | 53 | **1** |

135,443 is the number simulation gives. The search does not merely fit now; it
costs exactly what was predicted, and the correction lands before the header
instead of fifty symbols after it. The search duration also turns out to be a
usable status: 135,443 means both passes ran and a fine skip was applied,
while 67,721 - almost exactly half - means the search stopped after the first
pass and applied nothing.

**The decision bias is not fixed.** `raw_decision_bin_spread` is still 2 and
the histogram is still one-sided: across 318 compared symbols, 190 errors on
one side against 34 on the other. The clock was the root cause of a real
defect, but not of the one this investigation started on; it was masking it,
because before the fix no joint estimate was ever applied at all.

Ten paired captures localise what remains:

- every rung through `peak_bin` agrees 58/58, so the PL computes the correct
  answer for the window it chose;
- the first divergence is still `symbol`;
- applying the reference's joint correction to the reconstructed grid gives
  **53/53 on eight of ten captures**.

So the estimator as specified is sufficient to recover every symbol, and the
open question is where the PL's grid ends up. One packet of ten passed CRC:
the decode threshold is sharp, because coding rate 4/5 is parity only, and the
one that passed had 52 of 53 decisions on a single bin.

### A fourth wrong answer, caught before it was written down

The applied fine skip does not match the reference's correction. Over the
eight captures where a skip was applied, `pl + reference` has mean 1.4 and mean
absolute value 2.6 while `pl - reference` has mean absolute value 17.4, and a
least-squares fit over the captures inside the plus/minus 16 search radius
gives a slope of **-0.885**. That reads as an inverted sign.

It is not one. `tb_lora_joint_chirp_grid_path` drives an upchirp at sample 1008
and a downchirp at 11254 against a declared `packet_start_count` of 1000 with
`chips_to_boundary` zero. Those give true offsets of +8 and +14, hence a true
timing of **+11** and a built-in CFO displacement of **-3**. The controller
reports +11 and a fine skip of 27. The testbench's expected values follow from
its stimulus rather than from the implementation, and the implementation
matches them, so the RTL arithmetic and sign are right.

The two numbers are therefore measured from different origins - the PL's from
`packet_start_count` plus `chips_to_boundary`, the model's from an origin
derived from the trace alignment - and a systematic difference between those
origins that grows with the preamble bin would produce the same
anti-correlation. Both quantities do correlate with the preamble bin. Closing
this needs `up_coarse_start` and `timing_correction_samples` brought out so the
two sides can be compared against one origin, which is another rebuild.

The second candidate is uncompensated CFO. Its displacement is stable at -3.50,
-3.50 and -3.53 samples here and -3.33 to -3.49 across the earlier twelve:
about -427 Hz, -0.49 ppm at 868.1 MHz, -0.44 of a bin.
`lora_joint_chirp_grid_controller` forms only the half-sum, which cancels CFO
by construction; the half-difference is never formed and nothing in the RTL
consumes it. Against that, the reference model reaches 53/53 without
compensating it either, so it cannot be the whole story.

### Root cause of the decision bias, 2026-09-10

The joint estimator page answered on its first question.

The controller's own `up_coarse_start` is an exact multiple of 1024 on every
capture, and exactly equal to `packet_start_count`:

| seq | preamble bin | `up_coarse_start` | mod 1024 | advance that was due |
|---:|---:|---:|---:|---:|
| 116 | 97 | 454656 | 0 | 248 |
| 117 | 22 | 455680 | 0 | 848 |
| 118 | 77 | 455680 | 0 | 408 |
| 119 | 117 | 466944 | 0 | 88 |

The advance that should have been added is `chips_to_boundary * 8`: 248, 848,
408 and 88 samples here. None is a multiple of 1024, so adding any of them
would have destroyed that alignment. Nothing was added. This argument shares no
convention with the reference model, which is what makes it decisive where the
earlier comparison of corrections was not.

Simulation reproduces it in one run. Drive the packet 296 samples late - 37
chips - and print the signal at two points:

```text
INFO at detected:        chips_to_boundary=37  preamble_bin=91
INFO packet_start_valid: chips_to_boundary=0   preamble_bin=0
```

**The detector presents the arrival phase on `detected`. The joint controller
samples it on `packet_start_valid`, a later pulse, by which time it has
returned to zero.** The detector's arithmetic is right: 296/8 is 37 chips and
`(128 - 37) & 127` is 91.

The consequence follows from the search radius. The window is plus or minus 16
samples around `up_coarse_start`; without the arrival phase that point can sit
up to 1016 samples from the chirp boundary it is looking for. The window
contains no chirp start, the matched filter returns the best of 33 equally poor
lags, and the correction is spurious - which is exactly the observed behaviour:
large corrections where a few samples were due, uncorrelated with the truth,
roughly doubling the grid error instead of removing it.

It also explains why the coarse resync was always right. It reads the same
signal on `detected`, its own pulse. Only the joint estimate was affected.

### Why no regression caught it

```verilog
reg [15:0] chips_to_boundary = 16'd0;   // tb_lora_joint_chirp_grid_path
```

A constant. The controller's use of the signal was never exercised at all.
`tb_lora_joint_grid_completion` drove the packet straight onto the grid, where
zero is legitimate, and its own comment recorded that this left the interaction
unexercised. The `+grid_phase` option added to close that gap kept the
timestamp expectation pinned at 1024, so a non-zero phase simply failed and was
put down to a stimulus artefact.

### The fix and what supports it

The arrival phase is held from the pulse that carries it to the pulse that
consumes it, and handed to the joint controller only; the coarse resync keeps
reading the live signal on its own pulse.

With the same 296-sample arrival the integrated ToA metadata reads **1320**,
which is 1024 plus the arrival phase. Before the fix the same stimulus read
1023: the phase was dropped silently.

`tb_lora_joint_chirp_grid_path` now takes `+chips_to_boundary=N` and derives
its expectation from the stimulus geometry as `11 - 8N`, passing at N of 0, 1
and 2 with fine skips of 27, 19 and 11. The controller uses the value correctly
once it receives it, so the arithmetic was right throughout; one pulse was
wrong.

### An open boundary at half a symbol

Sweeping the arrival phase: 0, 8, 120 and 296 samples give an exact timestamp.
At 512 and 1000 the timestamp gains exactly one symbol - 2560 against 1536, and
3048 against 2024. The sub-symbol part is exact at every phase, which is why the
symbol decisions do not depend on it: a whole-symbol shift moves which trace
entry is which and the decoder's offset search absorbs it. The timestamp is a
different matter. The testbench states both properties separately rather than
relaxing to whichever one passes.

## Evidence boundary

A successful result closes the symbol-decision defect and unblocks a PER
campaign. It does **not** establish packet error rate, sensitivity,
acquisition probability, timestamp repeatability, or calibrated ToA. Twelve
packets at one power level is a decision defect measurement, not a link
measurement, and must be reported as such.

## The prerequisite from "Where to look next", closed in simulation — 2026-09-16

The observability gap this document asked for -- "an observable 'fine
correction applied' flag beside `DEBUG` bit 8, plus a sticky bit per abort
reason" -- is built. `lora_joint_chirp_grid_controller` now reports
`up_search_abort_error`, `down_search_abort_error`, `timing_range_error`, and
`precise_correction_applied` as four separate signals instead of one
`search_abort_error` shared between the up and down legs. They are no longer
folded into the plain single-search's own `toa_search_restart_error` /
`toa_peak_boundary_error` (see `lora_packet_toa_receiver_top.v`), and
`lora_clg400_gpreg_bridge` latches each sticky until the next stream reset as
joint-page `STATUS` bits 4:1, next to the existing bit 0 "estimate seen" --
see `fpga/board/clg400/README.md` for the bit table. Bit 8 of the symbol-trace
`DEBUG` register itself was not touched: it has no free neighbouring bit (see
that file), and the new flags belong to the joint estimator's own page, which
already had 31 unused bits and nowhere else worth being.

This closes the instrumentation gap only. It has been verified in simulation
(`tb_lora_joint_chirp_grid_controller`, `tb_lora_clg400_gpreg_bridge`) against
all three failure paths plus the success path, including that the sticky bits
survive a page switch and clear only on stream reset. It has **not** been run
on hardware yet, and it does not by itself explain why the search still fails
at non-zero arrival phase if it does -- it is the tool the next bench run
needs to find out, not the finding itself.

## First board run with the new bits -- 2026-09-17

The rebuilt bitstream (Vivado 2021.1, post-route WNS +0.139 ns / WHS +0.032 ns,
zero routing errors) was deployed to board B by the same atomic-swap procedure
as the 2026-09-03 session: active `system_top.bit` backed up and
checksum-verified in place, the new file streamed to a temporary name on the
same `/mnt/mmcblk0p1` mount, checksum-compared against the local build, renamed
atomically, synced, and re-verified before the cold boot. The page-0 smoke test
(`verify_board_b_cold_boot.sh`) read back the identical `status=0x00011243` on
both the old and new image, confirming the unfold in
`lora_packet_toa_receiver_top.v` did not disturb the existing single-search
ABI.

This run used the Heltec V4/SX1262 transmitter and board B RX1 on antennas
roughly 1 m apart, not the documented 30 dB conducted path -- the stand was not
available. An initial attempt at the RX hardware gain historically used
*with* that conducted path (50 dB) was first turned down to 20 dB out of
caution about ADC clipping over the air; raw-IQ inspection showed this was the
wrong direction entirely (peak `|I|`/`|Q|` of 3 codes out of 32767, burst-to-noise
ratio 3.2 against several hundred for a real packet -- the ADC was starved into
its own quantization noise, not anywhere near clipping). Gain was returned to
50 dB and every subsequent send was detected.

Of twelve commanded transmissions, eight landed inside the 1.5 s recording
window and one earlier single-packet check makes nine total joint-controller
captures with the new bits read back:

| tx seq | CRC | correction (samples) | up abort | down abort | range reject | precise applied |
|---:|:---:|---:|:---:|:---:|:---:|:---:|
| 12 | pass | +4 | no | no | no | yes |
| 13 | pass | 0  | no | no | no | yes |
| 14 | pass | +4 | no | no | no | yes |
| 15 | pass | +6 | no | no | no | yes |
| 16 | fail | +4 | no | no | no | yes |
| 17 | fail | +6 | no | no | no | yes |
| 19 | pass | -4 | no | no | no | yes |
| 22 | fail | +7 | no | no | no | yes |
| 23 | pass | -3 | no | no | no | yes |

The four attempts that produced no capture (peak-to-median power 1.5-1.7,
indistinguishable from noise) all show the same signature in the Heltec serial
log: a 3-4 s gap between issuing `send` and the transmitter's own
acknowledgement, against roughly 0.1 s on every attempt that *did* land in the
window. That delay sits on the transmitter/harness side, not in the receiver
this document is about, and is not further investigated here.

On this link, the joint controller never took the up-abort, down-abort, or
out-of-range path -- `precise_correction_applied` was `true` every time, with
a small (-4..+7 sample) correction each time. That is exactly the evidence the
new bits are readable and correct end to end, and it is also informative
about what it does *not* show: three of nine packets still failed CRC
(6 of 9 pass, the same order of magnitude as the 2026-09-10 baseline) while
`precise_correction_applied` read `true` and no abort/reject bit was set on
any of them. At this link geometry the occasional CRC failure is demonstrably
not one of the three silent joint-search failure paths this instrumentation
was built to catch. It does not identify what it is instead; nine packets at
one distance and one power level is, per the evidence-boundary note above, a
decision-defect-adjacent measurement, not a link characterization.

## A larger pooled sample narrows it further -- 2026-09-17, same session

Two more batches on the same stand (30 commanded transmissions each, 27 and
29 landed inside the recording window) push the total for this link to 56
captures. The headline numbers hold and sharpen rather than shift:

- `up_search_aborted`, `down_search_aborted`, and `timing_rejected_out_of_range`
  are `false` on all 56, and `precise_correction_applied` is `true` on all 56.
  Zero exceptions across three independently-run batches is as clean a
  negative result as this instrumentation can give for this link: whatever is
  behind the CRC failures below, it is not one of the three paths these bits
  exist to catch.
- CRC passed on 22 of 56 (39%), down from the smaller first batch's 6 of 9
  (67%) -- consistent with the first batch simply being too small to see the
  true rate, not with anything changing about the link (the antennas were not
  touched between the two 2026-09-17 batches).

`correction_samples` -- the signed sample count the joint estimator actually
applied, still ranging roughly -8..+12 -- splits the CRC outcome in a way SNR
does not:

| `correction_samples` | CRC pass rate | n |
|---:|---:|---:|
| negative | 67% | 12 |
| zero or positive | 32% | 44 |

Mean `iq_burst_ratio` is 439 for the negative group against 448 for the
zero-or-positive group (comparable spread, ~35-55), which rules out the
obvious confound: this is not a case of the better-corrected packets simply
having a stronger recorded signal. A second candidate split from the smaller
batch, `symbol_offset`, did not survive the larger sample (33% pass at
offset 1, n=9, against 40% at offset 2, n=47 -- indistinguishable given the
n=9 group). `up_offset_samples` tracks `correction_samples` almost exactly
(`correction_samples` is very close to `up_offset_samples + 4` throughout the
pooled data), so the two are not independent evidence of anything; there is
one real split here, not two.

This says nothing about mechanism. It says where the next question is: not
in the three failure paths this instrumentation targets, not in received
signal strength, and apparently tied to the sign of the correction the joint
estimator computes rather than merely whether it fires. Whether that traces
back to an up/down asymmetry in how the estimator combines its two legs, to
a rounding or sign convention at zero, or to something about this specific
stand's residual clock offset is exactly what a next, purpose-built
experiment -- not a retrospective read of a convenience sample -- would need
to isolate. 56 packets at one distance, one power level, and one antenna
placement remain, per the evidence-boundary note above, well short of a link
characterization.

## Chasing the correction-sign split -- three ruled out, none confirmed

Three cheap checks against the same 56-packet pool, each aimed at a specific
candidate mechanism, before touching the board again:

**Search-timing margin.** Every trace already carries `search_clocks` and
`sfd_deadline_clocks`; a search that overruns its SFD budget could plausibly
mean the fine correction lands after the first payload symbol already went
through the coarse-only grid, independent of its sign. `search_within_sfd`
splits CRC at 38% (n=16) against 40% (n=40) -- no effect. Restricting to the
27 packets sharing the single most common margin value (9709 clocks, i.e.
identical search timing to the clock-accounting granularity available) still
shows the same correction-sign split inside that matched subgroup. Ruled
out.

**Residual CFO.** `up_offset_samples` minus `correction_samples` is
proportional to `(up_offset - down_offset) / 2`, the up/down-search
differential the header comment attributes to CFO rather than timing. Across
all 56 packets this quantity is constant at -3 or -4 (rounding only) -- not
merely uncorrelated with CRC, but showing no per-packet variation to
correlate with anything. Two stationary radios one metre apart with no
relative motion apparently have no CFO worth measuring this way. Ruled out,
and as a side effect: `up_offset_samples` and `correction_samples` move in
lockstep here, so they were never two independent variables to begin with.

**Asymmetric application arithmetic.** Direct read of both files in the
correction's path.
`lora_joint_chirp_grid_controller.v`'s `round_away_from_zero` (take
`|sum|`, add 1, shift right 1, reapply the original sign) treats positive and
negative sums identically by construction, and `guarded_skip =
FINE_GUARD_SAMPLES + rounded_timing` is one affine expression with no
sign-dependent branch. `lora_symbol_grid_resync.v`'s two-skip composition
(coarse skip withholds the guard, fine skip supplies
`fine_resync_skip` directly) has no path that treats the sign of the fine
skip's contents differently either. No asymmetry found by inspection in
either module.

None of the three obvious candidates hold up under its own test. What is
left unchecked is the generated FFT/matched-filter correlator itself --
whether a few samples of residual sub-chip alignment error behaves
differently depending on which side of the ideal boundary it falls on is a
question about that block's numerics, not about either module read here --
and the possibility that "correction sign" is a marker for some other,
not-yet-identified population split rather than a cause in its own right
(for instance, however `chips_to_boundary` itself gets quantized upstream).
Both need more than a re-read of this pool to settle.

## A structural asymmetry that reads plausible and does not check out

Re-reading `lora_symbol_grid_resync.v` and the joint controller's own header
comment together surfaces something neither module's arithmetic shows in
isolation: the coarse skip always lands `FINE_GUARD_SAMPLES` short of its
target -- a fixed, one-sided undershoot, by construction, on every packet,
regardless of what the fine estimate will turn out to be. Between that coarse
landing and the later fine skip, the grid sits at an error of
`-(FINE_GUARD_SAMPLES + correction_samples)` relative to the true position:
smaller in magnitude when `correction_samples` is negative, larger when it is
positive (up to roughly 28 samples at the +12 end of this pool against 11 at
the -5 end). If any symbol gets decoded during that window before the fine
skip lands, a structural, sign-dependent asymmetry in how badly it is
decoded falls straight out of an otherwise perfectly symmetric pair of
formulas -- no branch, no bug, just which side of a fixed one-sided offset a
given packet happens to land on.

That is a coherent story. It is not a confirmed one. Checked against the same
pool, using the per-symbol `confidence_q15` already in every trace:

- Mean confidence over the first eight decoded symbols (indices 2-9, right
  after the two zero-confidence preamble entries) is 22903 for negative
  corrections against 22032 for zero/positive -- a small difference in the
  hypothesized direction, not the kind of split the CRC numbers show.
- The single worst-confidence symbol in each packet is essentially identical
  in magnitude between the two groups (17977 vs 18052) -- no evidence the
  correlator is struggling harder in one direction.
- A different, real pattern turned up instead: the worst symbol sits earlier
  in the trace for CRC failures (index 10.4 on average) than for passes
  (index 18.0). That is a genuine, unexplained regularity worth keeping, but
  splitting it further by correction sign shows CRC outcome dominating the
  position, not sign explaining it (fail/negative 12.5, fail/positive 10.1,
  pass/negative 15.2, pass/positive 19.5) -- sign is not doing the work in
  this view either.

So: a structurally plausible asymmetry, derived from the RTL's own stated
policy rather than assumed, does not show up cleanly in the confidence trace
this pool provides. Settling it needs either a read of the generated
FFT/matched-filter correlator's and the Python decoder's own FEC/Hamming
path -- confidence alone may not be the right signal for whatever this is --
or a new experiment built to force the coarse-to-fine gap wider and watch
what happens to it directly, rather than another pass over a sample this
document has now read three different ways.

## The mechanism, found against ground truth -- 2026-09-17

Two more checks against the same pool, both against evidence the earlier
ones did not use: the actual transmitted symbols, not just what the PL
reports about itself.

`src/zynq_lora_phy/lora_packet.py`'s `decode_lora_symbol_trace` searches up to
nine bin-adjustment hypotheses times nine symbol offsets and returns whichever
succeeds first, or the closest-distance header-valid candidate otherwise.
That search could in principle manufacture a spurious failure by missing the
right hypothesis. It does not: every one of the 56 packets, pass and fail
alike, resolves to `bin_adjustment=0` and `symbol_offset` of 1 or 2, well
inside the searched range and structurally the same regardless of outcome.
The decoder is not the defect.

`tools/export_stage_differential.py` already existed for exactly this next
step: it rebuilds the deterministic `ZLP1` counter payload from the
transmitter's own serial log -- ground truth that never touches the received
IQ -- and, with `--grid-sweep`, reports where the PL's sample grid actually
sat against that truth, independent of how the PL's own diagnostics describe
their own correction. Run with a sweep radius of 20 across all 56 captures:

| `pl_grid_error_samples` | CRC pass rate | n |
|---:|---:|---:|
| 0 | 88% | 25 |
| &plusmn;1 | 0% | 31 |

Not one exception in either direction: every packet whose final grid landed
exactly on the transmitted symbols passed CRC unless something else also
went wrong (3 of 25 still failed -- ordinary noise, not this mechanism), and
every packet off by even one sample failed outright. One sample at
`SAMPLES_PER_CHIP=8` is an eighth of a chip; this receiver's payload
demodulation has essentially zero tolerance for it.

And the sign of that one-sample error lines up with `correction_samples`
exactly as the earlier, weaker sign-based split suggested:

| `correction_samples` | `pl_grid_error_samples` distribution |
|---|---|
| negative (n=12) | 0 in 9, -1 in 3, never +1 |
| zero/positive (n=44) | +1 in 28, 0 in 16, never -1 |

This is the mechanism the last several sections were reaching for: not "the
sign of the correction" as a cause in itself, but a systematic one-sample
error in how the final corrected grid lands, whose direction tracks the sign
of the correction that was needed. It was only visible once the comparison
point stopped being the PL's own account of itself and became the
independently-known transmitted symbols.

It is not yet fixed, and the exact line responsible is not yet identified.
The stage-differential tool itself warns why the obvious next check --
comparing `correction_samples` directly against the sweep's best-fit offset
-- does not resolve it: "the two are measured from different origins," so a
raw difference between them is not interpretable without first reconciling
what each origin actually is. That reconciliation, done carefully against
the RTL's own sample-count bookkeeping rather than against another
convenience read of this pool, is the next concrete step.

## Root cause, located -- 2026-09-17

`analyze()` calls `estimate_joint_chirp_timing` from `src/zynq_lora_phy/toa.py`
on the same raw IQ, in the same coordinate system it already uses for
`best_offset_against_transmitted`, so the two are directly comparable (unlike
the PL's own `correction_samples`, which is not). Across the same 56-packet
pool, the reference estimate matches ground truth in 38 of 50 evaluable
packets and is off by exactly **+1, never -1**, in the other 12. That is a
smaller, one-sided version of the same defect the PL shows -- present even in
the trusted reference implementation.

The reason is visible in `estimate_toa` (`src/zynq_lora_phy/toa.py:39`): it
locates the integer correlation peak and then applies **parabolic
interpolation** across the peak and its two neighbours to refine the
estimate to sub-sample precision before `estimate_joint_chirp_timing` rounds
the averaged up/down offset to an integer. `lora_joint_chirp_grid_controller.v`
does no such thing. Its entire input from the search is `search_triplet_valid`
and `search_peak_sample_count` -- a bare integer index. It has no port for
the peak magnitude or its neighbours, so it cannot interpolate even in
principle; `timing_correction_samples` rounds the *unrefined* integer peak.

That the hardware is missing exactly the refinement step the reference model
uses is not a guess: `lora_peak_triplet_capture.v`, the block that already
computes `magnitude_before` / `magnitude_peak` / `magnitude_after` for
each search, documents its own purpose as "the hardware-shaped bridge between
a future sample-rate correlation stream and **the already-generated
packet-rate ToA interpolator**." That interpolator exists and is instantiated
-- in `lora_packet_timestamp_axi_path.v` and `lora_packet_toa_receiver_top.v`,
for the legacy single-search fractional-ToA path. It was never wired to the
joint chirp grid controller. The triplet magnitudes the interpolation would
need are computed, on every search, and then dropped on the floor before they
reach the module that rounds to `timing_correction_samples`.

This closes the causal chain the last four sections traced without reaching:
CRC failure <- one-sample PL grid error <- unrefined integer-only peak in
`lora_joint_chirp_grid_controller.v` <- the triplet-capture-to-interpolator
bridge its own neighbouring module already documents existing for, not
connected here. Confirming it end to end -- wiring the triplet magnitudes
into the joint controller, adding interpolation before rounding, and
re-running this same 56-packet-style comparison against ground truth -- is
an RTL change, not a documentation exercise, and belongs in its own
simulated-then-hardware pass, not this session's closing note.

## The fix, implemented and verified in simulation -- 2026-09-17 (M5)

`lora_matched_filter_search.v` already exposed `magnitude_before/peak/after`
at its top level; nothing there needed to change. Two things did:

- **`lora_packet_toa_receiver_top.v`**: the already-instantiated
  `lora_toa_ToaInterpolator` (previously used only by the legacy single-search
  path) now receives `tripletValid` from `raw_peak_triplet_valid` instead of
  the `!reference_down`-gated `peak_triplet_valid`, so it now interpolates
  both joint-grid legs, sequentially, on the same instance. This is a no-op
  for the legacy path (`reference_down` is tied low there, so the two signals
  are identical) and only changes joint-mode behaviour. One consequence had
  to be corrected in the same change: `lora_timestamp_metadata_join` expects
  exactly one `fractional_valid` per `coarse_valid`, and `coarse_valid` still
  only fires for the up leg -- so `fractional_valid` needed the same
  `!reference_down` gate, or the down leg's now-unmatched fractional fragment
  would sit waiting and could wrongly pair with the *next* packet's coarse
  count. Caught by reasoning through the timing before running anything, not
  by a failing test.
- **`lora_joint_chirp_grid_controller.v`**: two new states,
  `STATE_WAIT_UP_FRAC` and `STATE_WAIT_DOWN_FRAC`, each waiting for one
  `search_offset_valid` pulse (fixed 38-cycle latency, 6 for a flat triplet,
  no failure path) after its leg's `search_triplet_valid`. The up leg's
  fraction is registered (`up_offset_frac_q12`) because it must survive until
  the down leg finishes, many cycles later; the down leg's fraction is read
  live off `search_offset_q12` in the same cycle it arrives, since registering
  it first and reading it in the same always-block would see last cycle's
  stale value. The existing round-away-from-zero formula
  (`(offset_sum_abs + 1) >>> 1`, for a divide-by-2) generalises to Q12 fixed
  point as `(offset_sum_q12_abs + 4096) >>> 13` (divide-by-8192, since
  `offset_sum_q12` carries `2*timing*4096`) -- checked algebraically before
  implementing: with both fractions zero this collapses exactly back to the
  original formula. A first draft of this comment used the wrong divisor
  (4096/shift-12); rederiving it from the actual units caught the error
  before it reached the RTL. A new diagnostic, `diag_up_offset_frac_q12`,
  exposes the captured up-leg fraction, so a future stage-differential
  comparison does not rediscover this same invisibility gap.

Verified against the same criteria used to find the defect, not just "compiles
and runs":

- `tb_lora_joint_chirp_grid_controller.sv`: every pre-existing case now calls
  `return_peak` with a defaulted zero fraction and is unchanged -- a direct
  regression check that the Q12 generalisation reduces to the old integer
  arithmetic. Two new cases added: up=2.5/down=2.5 samples (both with a
  Q12 +0.5 fraction) gives correction +3, where the old integer-only
  arithmetic would have given +2 -- the exact class of error this
  investigation traced CRC failures to; and the precise rounding tie
  up=0.5/down=0.5, timing exactly 0.5, correctly rounding away from zero to
  +1. All pass.
- `tb_lora_joint_chirp_grid_path.sv` (all three `chips_to_boundary` sweep
  values): the interpolator is now in this testbench's chain too. The
  existing closed-form `expected_timing = 11 - 8*chips` was checked
  empirically rather than assumed, and holds unchanged -- the clean synthetic
  chirp's true peak sits on an exact sample, so the interpolator correctly
  returns ~0. Total search duration rose from 135443 to 135519 cycles (+76 =
  2*38, exactly the two legs' interpolation latency) -- negligible against
  the 145152-cycle SFD budget.
- `tb_lora_packet_toa_receiver_top.sv` and `tb_lora_clg400_gpreg_bridge.sv`:
  both already built the interpolator (for the legacy path) and both still
  pass unchanged after the wiring change, including the `metadata_join`
  gating fix above.

All four rebuilt from a clean directory with the same `iverilog`/`vvp`
commands CI uses. This is simulation-only. It has not been run on hardware:
the board was disconnected before this fix was written, and re-running the
same 56-packet-style capture against the rebuilt bitstream is the natural
next step, but a separate one.

## A coverage gap in the fix's own verification, closed -- 2026-09-18

None of the four testbenches above actually let the down leg's own
interpolation run to completion and then checked for the specific failure
mode the `lora_packet_toa_receiver_top.v` `!reference_down` gate on
`fractional_valid` prevents. `tb_lora_joint_chirp_grid_path.sv` has no
`lora_timestamp_metadata_join` in its chain at all. `tb_lora_packet_toa_receiver_top.sv`
stops driving samples before the down-search window arrives (its own
long-standing, documented limitation -- see `tb_lora_joint_grid_completion.sv`'s
header comment). `tb_lora_clg400_gpreg_bridge.sv` exercises the sticky bits by
`force`-driving the controller's own outputs directly, bypassing the search
and interpolator entirely.

`tb_lora_joint_grid_completion.sv` is the one CI job that does drive the down
leg to completion (that is its whole purpose), and it was not run during the
M5 pass -- an oversight, caught by re-reading the CI job list rather than by
a failure. Run separately once fixed: all five `grid_phase` legs pass with
the M5 changes as committed. A new check was added to it,
`dut.u_metadata_join.fractional_pending === 1'b0` once both legs have long
since finished interpolating, and verified the way this document keeps
insisting a check must be verified: with the `!reference_down` gate on
`fractional_valid` temporarily removed, this same check fails
(`fractional_pending=1`); restored, it passes on all five phases. That is the
regression test the fix itself did not have.

## Overnight follow-up work, and one item deliberately not attempted

Two more candidate improvements were considered before the rebuild. One was
implemented; the other was investigated and set aside with a specific reason,
not silently dropped.

**Attempted and closed**: the coverage gap above.

**Investigated and deferred**: exposing `diag_up_offset_frac_q12` (the M5
controller's new fractional diagnostic) through `lora_clg400_gpreg_bridge.v`
to `tools/read_clg400_symbol_trace.py`, so a future stage-differential run
would not have to rediscover this session's own invisibility problem for a
second signal. The joint-estimator page already uses all five of its
generic 32-bit register slots (`joint_a`..`joint_e`, i.e. sequence/coarse_lo/
coarse_hi/fractional_q12/log_peak_q12 in the page-multiplexing scheme shared
with the symbol-trace and clock pages) for its existing five fields. Adding
this one without disturbing anything already read by today's `pl_grid_error_samples`
analysis or by `tests/test_clg400_symbol_trace_tool.py` needs one of: a sixth
generic slot (touches the shared multiplexing scheme used by all three
pages, not just this one -- out of scope for an unsupervised pass), or a
reduced-precision pack into `joint_status`'s eleven reserved bits (bits
15:5, currently zero), which would need one fewer bit of Q12 resolution than
the interpolator natively gives (Q11, i.e. `>>> 1` before packing) and
careful placement alongside the existing sticky bits in the same 32-bit CDC
word. Both are real, buildable options -- deliberately not attempted tonight
without someone to sanity-check the bit-packing against a live capture.

## The Vivado rebuild stalled; not restarted without asking

`build_bitstream.tcl`'s synthesis step (launched to pick up the M5 RTL
changes) stopped making progress partway through `synth_1`: `runme.log`'s
last line is `Loading part: xc7z020clg400-2`, timestamped 2026-09-17 21:43,
and neither that file nor the `vivado.exe`/`parallel_synth_helper` processes'
accumulated CPU time changed at all across checks spanning the following
three and a half hours. The machine had only ~3 GB of 16 GB RAM free at the
time, partly from this session's own concurrent `iverilog`/`vvp` runs against
the M5 testbenches, which is the likely trigger for a memory-hungry step like
part/timing-database loading to stall or start thrashing.

The stuck `vivado.exe` processes were not terminated: killing another
process is exactly the kind of hard-to-reverse action this session's own
standing rules reserve for the user, and doing it on a guess -- however
well-supported -- about a hang rather than an extreme slowdown is not a call
to make unsupervised. No further `iverilog`/`vvp` work was run afterward
either, on the chance the stall really is memory pressure and the run still
finishes on its own. As of this note it has not.

## M5 on real hardware: the fix's arithmetic is verified sound, the first board run of it is not usable evidence -- 2026-09-19

The rebuild eventually completed (stale `synth_1` run status cleared with a
one-off `reset_run` after the killed processes were confirmed dead, on
explicit instruction) and the M5 bitstream was deployed to board B by the
same atomic-swap procedure as every prior image this project has shipped.
A 30-attempt capture series (`experiments/runs/2026-09-19-clg400-m5-verify/`,
28 captured) came back at **11% CRC pass (3/28)** -- worse than the M4
baseline's ~39%, and the opposite of what the interpolator fix was for. All
28 captures show `up_abort=false down_abort=false range_reject=false
precise=true`: the joint search itself is as reliable as ever. Running the
same `pl_grid_error_samples` ground-truth sweep used to find the original
defect shows why the CRC number is bad: **24 of 28 packets (86%) now land at
`pl_grid_error_samples=-1`**, against a much more mixed 0/±1 split in the M4
baseline. The fix did not merely fail to help; it looks, from this dataset
alone, like it made the systematic one-sample error *more* consistent.

Two things had to be ruled out before trusting that reading, in the order
this project always checks a surprising number: first whether the fix's own
arithmetic is wrong, then whether the measurement is wrong.

**The arithmetic is not wrong.** Every existing simulation of the M5 change
(the controller unit test, the full joint-grid-path test) only ever injects
a true arrival offset that is an exact integer number of samples -- the
fractional part the interpolator is supposed to correct is always ~0 in
every case that was run before tonight, on both legs, so none of them could
have caught a sign or combination error in the new Q12 path. A throwaway
copy of `tb_lora_joint_chirp_grid_path.sv` (kept out of the repo; this is a
diagnostic, not a regression test) added a real-valued sub-sample delay to
both the preamble and SFD chirp generators and ran it through the actual
generated interpolator and the real FSM, at +0.1, +0.3, +0.5, -0.1, -0.3 and
-0.5 samples. At every non-tie value the up-leg and down-leg interpolations
agreed with each other and with the injected shift to within quantization
noise (e.g. +0.3 samples read back as `up_frac_q12=1122 down_frac_q12=1122`,
against an exact expectation of 1229), and the final rounded correction
matched a hand-computed expectation in every case. The one apparent failure,
at exactly -0.5 samples, turned out to be the diagnostic script's own
expectation formula not accounting for which of two equally-true integer
neighbors the *unmodified* integer search resolves an exact tie to -- not a
DUT defect, and not a new tie-breaking question either, since that
resolution is the same pre-existing integer search this project has already
relied on since before M5.

**The measurement is.** Re-examining the raw IQ this time against the
AD9361's actual native resolution (12 bits, full scale +/-2048 -- not the
16-bit container's +/-32767, which is what an earlier check tonight wrongly
compared against and is corrected here) shows every one of the five
`2026-09-19-clg400-m5-verify` captures sampled has `max|I| = max|Q| = 2047`
and `min = -2048` exactly, and closer inspection of one capture's burst
window finds 25-30% of its I and Q samples sitting flat at that rail across
multiple consecutive samples -- textbook hard clipping, not "a strong clean
signal" as first read. Against this, the M4 baseline
(`2026-09-17-clg400-crc-stats`) peaks at `|I|`/`|Q|` of about 40: comfortably
inside range, at the *same* RX gain (both read back live at 50 dB manual on
both channels just now) and the *same* transmit profile (`power_dbm=-9`,
byte-identical `PROFILE` line in both datasets' serial logs). Nothing in the
receive chain configuration changed between the two sessions; the RF path
coupling did, almost certainly from one of this session's several stand
reconnects/reboots moving the antennas closer together or into a better
line of sight than the "roughly 1 m apart" of the 2026-09-17 run.

This also explains the two other loose threads from tonight's data without
needing a second mechanism: the anomalous `iq_burst_ratio` values (a clipped
peak still reads as the maximum of its smoothing window while the noise
floor stays just as quiet, so the peak/median ratio inflates rather than
saturates), and the elevated-but-partial symbol error rate per packet
(roughly a fifth to two-fifths of symbols wrong, not all of them -- a
hard-clipped chirp is distorted, not destroyed). And it gives the ±1-sample
regression a believable cause that is specific to M5: a clipped correlation
peak is not the smooth, symmetric shape the parabolic interpolator assumes,
and M5 is the first bitstream that ever lets that interpolator's output
reach the down (SFD) leg's contribution to the timing correction. In M4 the
down leg's fraction was hard-wired to zero, so a biased interpolator output
on that leg was structurally inert; M5 is the first time it can move the
final answer at all.

**Conclusion: the 2026-09-19 hardware run is not valid evidence about
whether M5 fixes the real-hardware CRC problem, in either direction.** It
needs to be repeated with the RX path back in a non-saturating regime
(antenna separation restored, or RX gain temporarily lowered below 50 dB
with headroom confirmed by raw-IQ peak inspection before trusting any
capture) before drawing any conclusion. The RTL fix itself has no open
question left in simulation as of tonight.

## M5 re-verified at a non-saturating gain -- 2026-09-19

`restore_rx_profile.sh`, unmodified, cannot simply be re-run to change gain
once the board is already at the 1 MS/s profile: it unconditionally disables
both FIR enables first, which is illegal at 1 MS/s with the target rate
already in place and fails with `write error: Invalid argument` -- exactly
the EINVAL ordering hazard the script's own header describes, just not
previously hit because every prior run started from a fresh boot. Working
around it live (writing gain sysfs attributes directly, then re-running the
full script once to restore the FIR/rate chain the partial failure had left
in an illegal 1 MS/s + FIR-disabled state) is a script gap worth fixing
later, not tonight.

`in_voltage0/1_hardwaregain` set to 25 dB (from 50 dB, both channels,
manual mode, confirmed by readback). A single test capture came back at
peak `|I|`/`|Q|` of 219 -- comfortable margin under the 2048 rail, zero
clipped samples in the burst window, CRC valid. A fresh 30-attempt series
(`experiments/runs/2026-09-19-clg400-m5-verify-gain25/`, 29 captured) stayed
under 218 peak amplitude across every capture (10.6% of full scale) with no
clipping anywhere in the run, and gave:

**28/29 CRC pass (97%)**. The `pl_grid_error_samples` ground-truth sweep
shows why: **28 of 28 packets with `grid_err=0` decoded, and the sole
failure (`tx=54`) is the sole `grid_err=+1` packet** -- both buckets exactly
where the fix predicts, and the 0-bucket pass rate is a clean 100% against
the M4 baseline's 88%. This is the confirmation the interpolation fix was
built for: with the RX path back in range, M5 does what the simulation and
the ground-truth analysis said it should.

The 2026-09-19-clg400-m5-verify (clipped, 50 dB) run stays in this document
as a worked example of why raw-IQ headroom has to be checked before trusting
a capture, not as a data point about the fix.

## A larger confirmatory run, and a script fix along the way -- 2026-09-19

Before trusting 29 captures as the final word, two things followed: fixing a
real bug the gain change had exposed in `restore_rx_profile.sh`, and running
a second, larger series at the same corrected gain.

`restore_rx_profile.sh` cannot simply be re-run to change gain on a board
that is already at the 1 MS/s profile: it unconditionally disables both FIR
enables before changing rate, which is only legal starting from the cold-boot
state (30.72 MS/s, filter bypassed) the script's own header describes -- not
from an already-configured 1 MS/s state, where that same disable is the
identical illegal combination approached from the other side, and it failed
with the same bare EINVAL. Parking the rate before touching the FIR (matching
the vendor's own `ad9361_set_bb_rate()` order more closely) was not enough by
itself, measured live: even after parking, the immediate FIR-disable write
still failed sometimes, in one case with the write reporting an error while
the readback showed the value had actually taken anyway -- the write's own
exit status turned out not to be trustworthy evidence of what the driver did.
The fix (`set_fir()`) writes, ignores that write's own reported status, and
polls the readback with a short retry budget instead of guessing a settle
delay. Verified with five consecutive re-runs against an already-configured
board, no cold boot between them, all passing.

With that fixed, a second series was captured at the same validated 25 dB
(`experiments/runs/2026-09-19-clg400-m5-verify-gain25-long/`, 60 attempts,
55 captured, peak amplitude 181/2048 across the whole run -- no clipping):
**53/55 CRC (96%)**, and by `pl_grid_error_samples`: **51/51 pass at
`grid_err=0`**, 2/4 pass at `grid_err=+1`. Pooled with the first gain-25 run
(29 captures): **81/84 CRC (96%) overall, 79/79 (100%) at `grid_err=0`,
2/5 (40%) at `grid_err=+1`**. The zero-bucket result is now backed by 79
consecutive packets with no exception, not 28; the residual failures are all
in the rare (5/84, 6%) nonzero bucket, consistent with a genuine one-sample
placement sometimes surviving decode and sometimes not, rather than with any
remaining defect in the fix itself.

## M6: re-arming a capture without losing the timebase, implemented and verified in simulation -- 2026-09-19

With M5 confirmed, the next roadmap goal is a long capture campaign that
keeps one continuous absolute sample counter across many packets, instead of
the counter restarting on every single capture the way today's tooling works.
Investigated this before writing any RTL (two parallel research passes, one
over every module with a `stream_reset` port, one over the host-side capture
tooling) rather than guessing at scope.

**The blocker, found by reading, not assuming.** The only way to re-arm the
128-entry `lora_symbol_trace_buffer` for the next packet is to pulse
`stream_reset` (`lora_clg400_gpreg_bridge.v`, control bit 1 --
`tools/capture_clg400_iq_trace_pair.py::arm_receive_stream` does this every
attempt). That same `stream_reset` zeros `next_sample_count` in
`lora_iq_history_buffer.v`, the very timebase the campaign needs to keep.
Reading every module with a `stream_reset` port (not just grepping for the
string) found exactly two things that actually need re-arming between
packets, everything else already returns to a ready state on its own:

- `lora_symbol_trace_buffer.capture_complete_sample` -- a one-shot latch,
  the expected blocker.
- `lora_symbol_grid_resync.armed` -- a second, non-obvious one-shot latch.
  Without re-arming it too, packet 2+ would decode on a stale, unrealigned
  grid: silent wrong output, not a hang. `tb_lora_symbol_grid_resync.sv`
  already asserted the old contract explicitly ("only re-arming through a
  stream reset may" move the grid again).
- Two sticky diagnostic groups in the bridge itself
  (`diagnostic_sticky_sample`, the four `joint_*_sticky_sample` bits): today
  "cleared only by stream_reset", which would misattribute an early packet's
  search abort to every later packet in a campaign that never fully resets.

Also found: page 0 of the gpreg bridge (the packet-start/coarse/fractional
timestamp mailbox) is *already* a continuously-updating atomic mailbox, never
tied to the trace buffer's re-arm cycle. `packet_seen_sample`/
`sample_seen_sample` there must stay tied to `stream_reset` only -- coupling
them to the new bit would regress that already-continuous behavior.

Also found, by grep, not assumption: `lora_packet_toa_receiver_top.v`
instantiates `lora_fft_detector_timestamp_path` (the real FFT correlator),
not the alternate `lora_detector_timestamp_path`/BlindDetector some other
testbenches exercise. Nothing in the existing suite drove two packets
through the real receiver_top with only one `reset_in` pulse at the start,
so the FFT DUT's multi-packet continuity -- asserted by design comment, used
in production -- had no regression proving it.

**The fix.** A new control bit 2, `trace_rearm`, distinct from `stream_reset`:

- `lora_clg400_gpreg_bridge.v`: `wire trace_rearm = ctrl_sample_sync[2];`,
  OR'd into the two sticky-diagnostic clear conditions and into the wire
  feeding `lora_symbol_trace_buffer`'s existing `stream_reset` port at its
  instantiation site. Neither `lora_symbol_trace_buffer.v` nor
  `lora_symbol_grid_resync.v` needed to change at all: both already do
  exactly the right thing on their `stream_reset` input, so widening what
  drives that input (rather than adding a second reset port with duplicate
  logic) reuses already-verified behavior instead of re-implementing it.
- `lora_packet_toa_receiver_top.v`: one new port, `trace_rearm_in`, OR'd
  into `reset_in` at exactly one place -- the `lora_symbol_grid_resync`
  instantiation -- and nowhere else. Every other `stream_reset`-consuming
  instance in this file (the FFT detector, IQ history buffer, matched
  filter, joint controller) keeps seeing `reset_in` alone.

**Verification, in simulation, before any hardware step.** A new testbench,
`tb_lora_joint_grid_multi_packet.sv`, drives two full packets through the
real `lora_packet_toa_receiver_top` (real FFT detector, not BlindDetector)
with exactly one `reset_in` pulse at the very start and only `trace_rearm_in`
between them. It confirms `grid_resync_armed` is genuinely 0 after packet 1
(so the re-arm check below proves something), comes back to 1 after
`trace_rearm_in` alone, both packets are detected and complete their joint
estimate with no aborts, and -- the actual point -- packet 2's coarse
timestamp is measured from the same absolute epoch as packet 1's rather than
reset back near zero. **PASS**: `packet1_coarse=1024 packet2_coarse=18832`,
history counter unchanged by the `trace_rearm_in` pulse itself
(`history_before_rearm=17408`). `tb_lora_clg400_gpreg_bridge.sv` gained a
matching bridge-level check: pulsing bit 2 alone (bit 1 held low) clears the
same sticky bits a stream reset does, while page 0's `packet_seen` survives
it -- both **PASS**. The two existing testbenches that instantiate
`lora_packet_toa_receiver_top` directly
(`tb_lora_packet_toa_receiver_top.sv`, `tb_lora_joint_grid_completion.sv`)
needed the new port tied off (`trace_rearm_in(1'b0)`) to keep compiling and
both still **PASS** unchanged (`tb_lora_joint_grid_completion.sv` re-run at
`grid_phase=0` and `grid_phase=512`).

**Host tooling, minimally.** `tools/capture_clg400_iq_trace_pair.py`:
`arm_receive_stream` now takes `full: bool`, pulsing bit 1 (`full=True`) or
bit 2 (`full=False`); `main()` uses `full=True` only for the first attempt of
a series, `trace_rearm` for every attempt after it. `capture_once` now
writes a `clg400-trace-<stamp>.json` record for a failed attempt too
(`{"status": "failed", "stage": ..., "error": ...}`, `stage` tracked coarsely
through the attempt) instead of the previous silent stderr-only drop -- a
campaign's own attempt/capture/CRC counts must add up to the number of
attempts actually made. The successful-record schema is unchanged, so
`tools/export_stage_differential.py`'s `analyze()`/`--grid-sweep` keep
working without modification. All 209 existing Python tests still pass,
including the ordering assertion in
`test_the_transmitter_is_prepared_before_the_recording_starts`.

**Explicitly not done tonight**: rebuilding the Vivado project and deploying
a new bitstream to hardware, and the follow-on ~50-60 attempt confirmatory
run this fix's own plan calls for. That is a separate, separately-agreed
step, same as every prior RTL change this project has shipped.

## M6 on hardware: the timebase survives, M5's quality is unchanged -- 2026-09-19

**Build and deployment.** Vivado 2021.1 rebuild of the M6 RTL: post-route
WNS +0.021 ns / WHS +0.019 ns, TNS and THS 0, `write_bitstream` clean; the
margin is thinner than M5's (+0.139 ns) but met. The first `build_bitstream.tcl`
attempt hit the launcher hang the board README already describes -- synthesis
wrote its report (`0 errors`) at 19:14 and then nothing: no `system_top.dcp`,
no `impl_1`, three `vivado.exe` processes with flat CPU time for over two
hours. With the user's go-ahead those three processes were stopped,
`reset_stale_synth_run.tcl` returned `synth_1` from `synth_design ERROR` to
`Not started`, and the rerun completed normally (no concurrent simulation
load this time). Image SHA-256
`86cf6b088d8fa1e7bad0b20b871f3d45eded14301f65dcbe921c4b7ecf5baec5`,
2,546,340 bytes; the M5 image (`973e98ea...a719`) was backed up on the card as
`system_top.bit.pre_m6_rearm_20260919T000000Z` and both hashes were verified
before and after the atomic swap. After a cold boot the page-0 smoke test
(`verify_board_b_cold_boot.sh`) read the same `status=0x00011243` as M5:
the existing ABI is untouched.

**Timebase.** A 50-attempt series in which only the first attempt pulses
`stream_reset` and every later one pulses the new `trace_rearm`
(`experiments/runs/2026-09-19-clg400-m6-rearm/`), 47 captured: the first
trace entry's `sample_count` is strictly increasing across all 47 captures
and spans 803.7 M samples over 803.7 s of the transmitter's own clock
(`tx_start_ms`). A line fitted through (`tx_start_ms`, `sample_count`) has
slope 1000.005 samples/ms and the worst residual is 0.51 ms, under one
symbol (1.024 ms), which is what the per-packet grid re-alignment alone
should contribute. The 5 ppm is the offset between the transmitter's
millisecond clock and the receiver's sample clock together; it is not
attributable to either. Before M6 every capture restarted this counter near
zero.

**M5's quality is unchanged.** 47/47 CRC pass on that series, and the
`pl_grid_error_samples` ground-truth sweep gives `grid_err=0` on all 47.

**Detection misses, and what this does not show.** Every failed attempt now
leaves a record (`status: failed`, `stage`, `error`) and, when the recording
finished, the IQ and its `burst_ratio`. All four failures across both series
have `burst_ratio` in the thousands: the packet was in the recording and the
PL did not detect it (`symbol trace is not complete: active=False,
captured=0`). Counts at the same gain and bitstream: `trace_rearm` 3/50 (5/56
with the 6-attempt probe), the control series with `stream_reset` before
every attempt (`--full-rearm-every-attempt`, `m6-control/`) 1/50, and 6/90 in
the two pre-M6 gain-25 series. None of these differences is significant
(Fisher p = 0.21 against the control, 0.75 against pre-M6), so M6 neither
introduced nor explains the misses -- but a roughly 7% rate of undetected,
clearly present packets is a real, still-open defect of its own.

**Still not done:** the 1000-packet campaign with separate per-stage
counters, cable-delay calibration and the two-receiver work; the misses above
are the first thing a longer campaign would need to explain.

## M7: the ~7% of packets the detector never saw -- 2026-09-20

M6 left one honest open item: about 7% of packets that are plainly in the
recording (`burst_ratio` in the thousands) are never detected by the PL
(`symbol trace is not complete: active=False, captured=0`), and the control
arm showed it is not caused by `trace_rearm`. Everything below was done
offline against the recordings already on disk; nothing here has run on
hardware yet.

**A first hypothesis, dropped by reading, not by testing.** The obvious
suspect is a preamble bin sitting on the boundary between two FFT bins, the
decision flipping between neighbours on noise and breaking the run of equal
bins. `model/simulink/build_blind_detector_model.m` already accepts
`BinTolerance = 1` on both the preamble run and the sync bins, so an
adjacent-bin flip cannot make it miss. The same file's header comment names
the real failure mode: on the free-running grid "the first sync symbol is
skipped entirely and the run reads as one extra preamble bin followed by the
second sync bin", and it measures the cost against offset in
`RUN_BLIND_DETECTOR_REGRESSION`. The receiver top realigns its grid on
`detected`, not on the preamble, so it has that caveat with no mitigation.

**Reproducing it in the RTL.** A testbench (`fpga/tb/tb_replay_detect.sv`,
driver `tools/replay_iq_through_rtl.py`) feeds a window of a recorded IQ file
through `lora_packet_toa_receiver_top` -- the real FFT correlator and blind
detector -- and prints every symbol decision. The packet's arrival phase
against the receiver's symbol grid is what varies from packet to packet and
cannot be recovered from the recording, so the window start is swept over a
symbol. Five recordings (one detected on the board, the four missed ones), 32
phases each: every recording behaves identically, detection at every phase
except one narrow band. A finer sweep (step 8 samples) of the detected
recording puts the band at 96 samples, 9.4% of a symbol. Pooling every gain-25
attempt of this investigation (6/90 before M6, 5/56 with `trace_rearm`, 1/50
control) the board saw 12/196 = 6.1% misses against 9.4% predicted, about 1.5
sigma low and not inconsistent with it. The "missed" and the "detected"
packets are the same kind of packet; the arrival phase decides.

Inside the band the decisions are `[12 x P][P][P+16]` where the detector needs
`[12 x P][P+8][P+16]`: the correlator window holds half of the last preamble
symbol and half of the first sync symbol, the two peaks are comparable, and
the larger one -- the preamble half -- wins. The second sync symbol is read
correctly. The sync word cannot be seen again on this grid, so the packet is
lost for good.

**Fix 1: accept the pattern (`lora_detector_timestamp_path.v`).** A
hand-written combinational path next to the generated detector, in the same
cycle as `symbol_valid` because `lora_detector_timestamp_align` needs the
decision on the matching timestamp cycle, accepts `[8 x ref][ref][ref +
8*lowNibble]` with the same +/-1 bin tolerance and the same ten-symbol window.
The two sync patterns differ in the ninth symbol by `8*highNibble` bins, so at
most one can match; a sync word with highNibble 0 makes them identical and the
path adds nothing. The generated HDL is untouched (the file's own rule). A
Python model of both rules, checked against the RTL's own detections on all
160 replay runs, agreed everywhere (0 mismatches), rescued all 13 misses and
added no extra detection on any run that already detected. The new unit tests
in `tb_lora_detector_timestamp_path.sv` (normal pattern, straddle pattern,
wrap-around, +/-1 jitter, another sync word, four patterns that must not
detect, reset clearing the history) fail on the old wrapper in exactly the six
straddle-acceptance checks and pass on the new one.

**Fix 2, found only by running the rest of the chain: the coarse origin.**
Detection alone would have converted a lost packet into a silently corrupted
one. In the band, `packet_start_count` still names the earlier decision window
while `chips_to_boundary * 8` has already crossed 512, so
`lora_joint_chirp_grid_controller.v`'s unwrap moves the origin back a whole
symbol. The up leg cannot tell (every preamble upchirp looks alike); the down
leg is pointed at the second sync symbol and its matched-filter peak is 6.5x
weaker (peak/median 1.4, noise). Run through the RTL's own joint search with
the flag ignored, k = 672/704/736 reported `precise=1`, no abort, no range
error -- and `corr = -7` instead of `+1`, an 8-sample grid error, applied
silently. Since M4/M5 established that one sample off kills the payload, that
would have been a lost packet with a different label. The detector now raises
`straddle_detected` in the cycle of `detected`; `lora_packet_toa_receiver_top`
holds it beside `held_chips_to_boundary`; the controller does not unwrap a
straddle-accepted packet. Ordinary detections keep the existing rule: on the
board IQ it is right on both sides of the band (positive below chips 62, wrap
from chips 74). The new controller test cases fail without the flag handling
(start 59488 instead of 60512, exactly one symbol).

**Full chain, board IQ, RTL joint search run to completion** (phases
k = 640..752 step 16; the band is 656..744): `precise=1`, no abort, no range
error, `corr = +1`, `up_off = -2` at every phase, and `up_coarse` grows by
exactly the phase step (7648, 7664, ... 7760), including across the point where
`packet_start_count` steps by one symbol. Detection at every phase: 64/64 (step
16) on the detected recording and 16/16 in the band on each of two previously
missed ones. The whole existing RTL regression set (detector, FFT detector,
receiver top, AXI path, joint path x3, gpreg bridge, multi-packet, joint-grid
completion at all five phases) and the Python suite (210) pass.

**Diagnostics.** `joint_status` bit 5 (sticky like bits 4:1, cleared by
`stream_reset` and `trace_rearm`) says at least one packet since the last
re-arm was accepted only through the straddle path; `read_clg400_symbol_trace`
reports it as `detector_straddle_accepted`. On the board this is per capture,
so it shows directly which packets the fix rescued and whether they decode.

**Not solved, deliberately.** On an ideal synthetic packet (no analog chain)
the same replay still loses two of 64 phases at the switching point, with a
different pattern: the first sync symbol read twice, `[12 x P][P+8][P+8][P+16]`.
It does not occur in any board recording tried, and handling it needs the
timestamp origin moved one decision back, which cannot be validated without
data that shows it. It is recorded here, not handled. The same replay also
puts the switch point for ideal signals near 480 samples of advance rather than
the controller's 512, and near 588 on the board: the 512 the controller
assumes is not where either flips, and the synthetic tests never exercised the
difference. The straddle flag makes the board case right; it does not make the
number universal.

Timing: the added logic sits in front of `detected`, which fans out to the
grid resync, the timestamp aligner and the trace buffer. The last build had
+0.021 ns of setup slack, so this may need attention in the rebuild.

### M7 on hardware, first run: no misses, and 5 false detections I introduced -- 2026-09-20

The M7 image (`a07c45f6...`, RTL `6d7552f`) was deployed by the usual atomic
swap (M6 kept on the card as `system_top.bit.pre_m7_straddle_20260920T000000Z`)
and cold-booted; the page-0 smoke test read the same `status=0x00011243` as
every earlier image. A 6-attempt probe and then a 100-attempt series
(`experiments/runs/2026-09-20-clg400-m7-verify/`, 25 dB, `trace_rearm`
between attempts):

- 99 of 100 captured. The one failure is at `prepare_transmitter`: the
  transmitter's profile readback came back without its payload/length/running
  fields over serial, before any packet was sent. Not a PL event.
- **No detection miss at all** -- 0 of 99 attempts with the packet in the
  recording and the trace empty, against 12 of 196 (6.1%) in the earlier
  gain-25 runs. Twelve packets (12%, 9.4% predicted) were accepted only by
  the new straddle path (joint status bit 5), all with `precise_correction_
  applied`. The 87 packets that took the ordinary path decoded 87/87.
- But only 7 of those 12 decoded. That is not the fix working "mostly": it is
  two different populations.

**Seven that decode.** `preamble_bin` 58, 63, 64, 64, 62, 64, 58 -- inside the
band predicted from replay (55..66) -- `pl_grid_error_samples = 0` in every
case, first trace entry exactly `packet_start_count + 10240` (ten symbols
after the coarse origin, as for any packet), header and payload symbols
identical to the ordinary ones. Their correction (-5..+11) is in the same
range as the ordinary packets'. This is the mechanism M7 was built for, and it
works.

**Five that do not.** `preamble_bin = 0` in every one of them; the trace's
first entry lies 4355 samples (four symbols) *before* `packet_start_count`;
its first eight decisions are a constant preamble-like bin drifting 44..48; the
ground-truth sweep gives `pl_grid_error_samples` of 7, -7, -5, 10, 4 with the
first divergent stage at the dechirp. A trace that starts inside the preamble
and a coarse origin that belongs to something else: the detector fired *early*.

**Why my replays had not seen it.** They start from reset with about two
symbols (2048 samples) of the recording before the burst, so the detector
never has a run of silence. Replaying the failing recording with 20000 samples
of real silence before the burst (`tools/replay_iq_through_rtl.py --lead
20000`) reproduces it at one of eight phases: `DET` with P = 0, ctb = 0 at
n = 23953, well before the real detection at n = 38529, from the decisions
`[0 x 20][16, 16, 16, 47, 46, 46, ...]` -- twenty exact zeros, then the first
window of the packet.

Silence is bin 0, not random. With no signal the correlator's spectrum is
exactly zero and its argmax is index 0. Measured on the recordings
(`SYM ... conf= peak= sum=` printed by `tb_replay_detect.sv`): on every silent
decision of a 25 dB recording and of two 50 dB ones (amplitude about 40),
confidence, peak and spectrum sum are all exactly 0; on every decision of a
real preamble or sync window peak is 12..67 (17..18 steady on the weak ones).
A run of eight "equal" bins is therefore free in silence, and my rule
`[8 x ref][ref][ref + 16]` then needs only one coincidence -- the first,
partial window of the next packet landing on 16 +/- 1, 3 of 128 bins, about
2.3% -- where the generated rule `[8 x ref][ref + 8][ref + 16]` needs two
(about 0.05%). Observed: 5 of 99. When I wrote the rule I estimated its false
rate as (3/128)^8 for eight random decisions; the decisions in silence are not
random, and I did not test the one input a receiver sees most of the time.

What a false detection does: it arms the symbol trace and the grid resync on
the wrong instant (the trace begins in the preamble, so the header lies beyond
the eight entry offsets the decoder tries), takes a coarse origin that is not
a chirp start, and the joint search then reports a "successful" correction
that is wrong (`precise=1`, no abort) -- the same silent corruption that the
straddle flag prevents in the other direction.

**Guard.** Two conditions on the straddle path
(`lora_detector_timestamp_path.v`), both from data: (1) the correlator's peak
is non-zero for all ten decisions of the window (silence is exactly zero,
every real preamble/sync window is not, including the weak recordings), and
(2) the reference bin lies in N/4..3N/4 (32..96), since the straddle needs the
packet about half a symbol from the window and the bin measures exactly that
(55..66 on the board, 58..64 among the rescued packets that decode); silence's
bin 0 is far outside. `peak_magnitude_squared` from the correlator is wired
into the wrapper as a new input. Seven new checks in
`tb_lora_detector_timestamp_path.sv` (silence then 16, silence then 17, a
bin-0 run with signal, one silent decision inside a straddle window, and the
band edges 31/32/96/97) fail on the previous version and pass on this one; the
two older tests whose reference bins lay outside the band (bin wrap at 120,
sync word 0x34 at 10) were rewritten to in-band references with sync word
0x34, where the second sync bin does wrap ((96 + 32) mod 128 = 0).

**Replay check of the guard.** Failing recording (tx 246) with 20000 samples
of silence in front, 8 arrival phases: exactly one `DET` per phase; the early
false `DET` (P = 0, ctb = 0, n = 23953, alt rule at symbol 20) is gone. A good
recording (`rx1-iq-20260919T195431Z`) with the same lead, shifts 96..208 step
16: detected at all 8 phases, one symbol earlier (n = 37265) at shifts 96..192
than at 208 (n = 38289). The `DET` line of the replay testbench now also prints
the flag (`straddle=`, from `packet_straddle_detected`): the same 8 phases give
straddle = 1 at shifts 112..192 (reference bin 66..56) and 0 at 96 and 208, where
the generated detector copes on its own. So the straddle path still takes the
band packets. Full RTL regression (fft
detector, receiver top, AXI path, joint controller path x3, bridge, multi-packet,
completion x5) and `pytest tests` (220) pass.

### M7 guard image on hardware: misses 12/196 -> 2/301, false detections gone -- 2026-09-20

The guard image (`eac45bda...`, RTL `43366d2`, WNS +0.025 ns / WHS +0.023 ns
after post-route phys_opt, build 32 minutes without a launcher hang) was
deployed by the same atomic swap (the first M7 image kept on the card as
`system_top.bit.pre_m7_guard_20260920T000000Z`) and cold-booted; the page-0
smoke test read `status=0x00011243` again. Runs, all at 25 dB with
`trace_rearm` between attempts: a 6-attempt probe, a 100-attempt series and a
200-attempt series (`experiments/runs/2026-09-20-clg400-m7g-*`).

| | attempts | captured | detection misses | straddle-accepted | of which decoded |
|---|---|---|---|---|---|
| first M7 image | 100 | 99 | 0 | 12 | 7 (5 false detections) |
| guard image | 306 | 301 | 2 | 17 | 17 (`pl_grid_error` 0) |

The 5 attempts that did not capture: 3 on the transmitter side (one profile
readback without fields, two `send` timeouts), 2 detection misses. Misses are
now 2 of 301 recordings with a packet (0.7%), against 12 of 196 (6.1%) before
M7. The false detections are gone: every packet accepted through the straddle
path decodes with grid error 0.

**The two remaining misses do not reproduce in RTL.** Tx 54 (normal signal
level) and attempt 163 (`burst_ratio` 2412) replayed from reset with 20000
samples of silence in front: detected at all 32 (tx 54, step 32) and all 16
(attempt 163, step 64) arrival phases, two of the latter only through the
straddle path. Neither packet lies unusually early in its recording (burst
start 193512 and 192547 samples, against 188762..218996 for all 397 recordings
of the M7 series), so the DMA start is not implicated. So the cause is state or
stream the recording does not carry. For attempt 163 the failure record now has
`pl_state`: the joint page saw no packet (`joint_seen` false) and the page-0
sequence equals the trace sequence, i.e. the detector never fired; the
clock-crossing flag is set on every capture and says nothing.
`tools/read_clg400_symbol_trace.py` now raises `TraceNotComplete` carrying this
state, because the sticky bits are cleared by the next attempt's re-arm and the
evidence exists only at the moment of the failure. What would settle it is a
ring of the detector's last decisions readable at the miss; not built.

**1-sample grid errors follow the transmitter's CFO, not the level.** The probe
and the first 100 captures after the cold boot have 6 ordinary-path packets with
`pl_grid_error` 1 (CRC fails) out of 98; the next 197 have none (one weak
recording, `burst_ratio` 1456, has a sweep best offset of -8 with a valid CRC,
an ambiguity of the sweep). By 25-capture windows in time order the reference
model's CFO displacement was -3.43, -3.39, -3.40, -3.40 samples (errors 3, 1, 0,
2), then from about 16:16 UTC -3.20, -3.20, -3.18, -3.20, -3.22, -3.18, -3.17 (errors
0 in each; the one flagged in that stretch is the sweep artefact above, CRC valid). The share of packets whose applied correction exceeds
`up_offset` by 4 rather than 3 (which is (down - up)/2 rounding, not an error in
itself: the M6 series have it at 18/47 and 13/49 with all grid errors 0) was
24-52% in the first four windows and 12-28% in the later ones. Every one of the six errors has that
difference of 4. Not amplitude: the same failing recording replayed through the RTL
at x1, x0.5 and x0.25 gives an identical `corr`, `up_off` and `skip` at every phase.
Not clipping: ADC peak 240 of 2048, no sample at the rail. Earlier series
(M6 -3.1..-3.4, first M7 -2.9..-3.1) had none. A displacement of about 3.5 samples
is 0.44 of a bin; a tone that close to the half-bin decision edge gives a
one-sample grid shift (0.125 bin) room to change the decision, which would explain why
only that CFO range shows it. This is a hypothesis fitted to the table above, not
a measurement of the mechanism.

### M7 guard image, 500-attempt series: 3 more misses, no grid errors, misses still not reproducible -- 2026-09-20/21

A 500-attempt series on the same image, 25 dB, `trace_rearm` between attempts
(`experiments/runs/2026-09-20-clg400-m7g-long500`, 17:52-20:18 UTC, 3 to 5.3
hours after the cold boot; 500 was the disk limit, 15 GB free on the drive).

492 of 500 captured; 5 attempts failed on the transmitter side (3 profile
readbacks without fields, 2 `send` timeouts) and 3 were detection misses
(attempts 113, 133 and 492, `burst_ratio` 64769, 54506 and 36662, so ordinary or
strong signals). **CRC 492 of 492 and `pl_grid_error` 0 on every capture**: 463
ordinary-path packets and 29 accepted through the straddle path.

Pooled over the guard image (probe, 100, 200 and 500 series): 806 attempts, 793
captured, 8 transmitter-side failures, **5 detection misses = 5 of 798 recordings
with a packet (0.63%, 95% Wilson interval about 0.27..1.46%)**, against 12 of 196
(6.1%) before M7. 46 packets accepted through the straddle path, all 46 decode
(7 of 12 on the first M7 image).

**Misses.** All three carry `pl_state`: `joint_seen` false and the page-0
sequence equal to the trace sequence, the same as attempt 163: the detector never
fired. Replayed from reset with 20000 samples of silence in front at 16 arrival
phases (step 64), each is detected at every phase, two of them at one phase only
through the straddle path. So five of five misses on the board do not reproduce
from the recording alone. Nothing they share was found: the previous attempt of
each was an ordinary, correct capture, the gap was 17-18 s, the burst started
193124, 192667 and 191502 samples into the file (ranks 66%, 52% and 20% in the series). One coincidence noted and not
supported by a mechanism: the low 32 bits of the absolute sample counter wrapped
twice in this series (about 19:04 and 20:15 UTC); the packet 7.7 s after the first
wrap was detected, and the miss at 20:15 lies about 4 s after the second. The
counters on the detector's path are 64-bit (`lora_detector_timestamp_align`,
receiver top), so nothing in it depends on the low word; with about six power-of-two
boundaries to choose from after the fact this is not evidence.

**Grid errors.** None in 492. Together with the earlier runs: 6 of 747 ordinary-path
packets have a 1-sample grid error, all six among the 98 of the probe and the first
series (first ~35 minutes after the cold boot), where the model CFO displacement was
-3.57..-3.33. Split by the CFO displacement after the fact: below -3.38 samples 6 of
83 packets have the error, at -3.38 and above 0 of 664 (25 of those lie between -3.38
and -3.30). The 500-series CFO stayed within -3.35..-2.80 (window means -3.28..-2.92),
so it never returned to the region where the errors occurred: the CFO hypothesis
above is neither confirmed nor refuted by it. Two things this cannot separate: the
threshold was chosen after looking (no p-value is quoted for that reason), and the
CFO region coincides with the first ~35 minutes after the cold boot, so a board
warm-up effect other than the CFO fits equally. Separating them needs the CFO
region visited at a later time (a warm board with a detuned transmitter) or a cold
boot repeated; or the synthetic test of the decode-best offset against CFO
and fractional timing.

## M8 diagnostics: decision history and a crossing drop count, for the misses -- 2026-09-24

Five of 798 packets on the M7 guard image were never detected, and none of the
five recordings reproduces the miss through the RTL at any replayed arrival
phase. The recording is taken by the vendor DMA path; the receiver is fed
through `lora_async_sample_fifo`, a separate branch. So whatever the detector
saw differently is not in the recording, and a miss left nothing on the board
beyond "the detector never fired" (the symbol trace only starts at a detection).

**What the existing flag says.** `crossing_overflow` (clock page bit 0) was set
on every capture of the M7 series. It is sticky until the PL reset, not until a
stream reset, so it means "the receive crossing dropped at least one sample
since boot", not "this capture": at least one drop did happen after the last
cold boot, at an unknown time. The FIFO's own comment explains how the boot-time
fill was removed; a later event (the profile restore changes the AD9361 rate)
could set it once. Checked against the data already on disk: the PL's absolute
sample counter against the transmitter's `tx_start_ms`, fitted per series,
leaves residuals of about 300 samples, which is the 1 ms quantisation of the
transmitter clock, with no step larger than 1032 samples and nothing unusual
across any of the five misses. So no packet lost a millisecond or more of
samples; a few samples, enough to break an eight-equal-bins preamble rule, would
not show at that resolution.

**What is added (RTL simulated, not yet built):**

- `lora_async_sample_fifo` counts dropped samples (16-bit, saturating, Gray-coded
  into the read domain). The bridge re-crosses it to the control domain and
  reports it live on the clock page (METRICS) and on the new history page. Read
  at every attempt, a change between two attempts puts a loss inside the later
  one. `tb_lora_async_sample_fifo` checks the count is exact (writer outruns the
  reader: 64 written, 36 crossed, count 28) and zero for the board's slow writer.
- `lora_decision_history_buffer` (4096 x 72-bit ring, about 4.2 s of decisions):
  every symbol decision, detected packet or not, with its sample-count low word,
  bin, confidence, the drop count's low byte, and flags (valid, detected,
  straddle, grid-resync armed; a detection or straddle pulse is held until the
  next decision so it lands on an entry). gp_ctrl bit 3 freezes it, bit 4
  selects its page (marker `0x4448` "DH"), bits 19-23 and 24-30 are the 12-bit
  index. Software sees `frozen`, the newest index and the decisions written.
  The bridge testbench checks writes, freeze (no writes while frozen), indexed
  reads at 0, 5, 128 (needs index bit 19) and 129, the drop byte, the held
  straddle flag, release, and that page 0 is untouched.
- The recording command freezes the ring on the board the moment `iio_readdev`
  returns, before the sentinel, because the packet is about 1.3 s before the
  end of a 1.5 s recording and the trace read that follows would let the ring
  overwrite it. Every arm releases the freeze. On a miss the capture tool reads
  the ring (4096 entries, tens of seconds) into the failure record; every
  record carries the drop count; `summarize_capture_run.py` reports the drop
  increments and which misses have a history. Bits 3 and 4 are unused on older
  images, so the tools stay compatible (no marker, no drop count).
- `tools/compare_history_to_replay.py` finds the replayed phase whose decisions
  best match the board's over the missed packet (from the first non-silent
  decision after silence, since a silent correlator gives exactly zero
  confidence) and prints both side by side with the first disagreement and
  whether the drop count changed during the packet.

What a miss on this image will show: either the drop byte changes inside the
packet (samples lost in the crossing; the fix is upstream of the detector), or
the board's bins differ from the replay's with no drop (the stream the PL saw
differs from the recording some other way, or the detector state before the
packet differs), or they agree and the rule still did not fire (a detector
state the replay from reset does not have).

### CFO hypothesis for the 1-sample grid errors: not supported by the model

The M7 guard-image section left a hypothesis: the six 1-sample grid errors fell
where the model CFO displacement was below -3.38 samples, and a tone that close
to a half-bin edge might flip the joint estimator's rounding. Tested without the
board, on synthetic up/down chirp pairs built as a continuous-time chirp at a
fractional delay (the closed-form phase `reference_chirp` uses, evaluated at
`n - delay`, not the integer `np.roll`), a CFO calibrated to give exactly the
displacements measured on the board, and real receiver noise cut from a quiet
stretch of a board recording at the guard series' amplitude (peak 240), through
`estimate_joint_chirp_timing` with the geometry and radius the stage
differential uses (up leg 6 symbols, down leg 14 symbols after the packet start,
radius 32):

| model CFO displacement | wrong rounding, noiseless, 401 fractions in (-0.5, 0.5) | wrong rounding, board noise, 2000 random fractions |
|---|---|---|
| -3.60 | 0 | 0 |
| -3.50 | 0 | 0 |
| -3.40 | 0 | 0 |
| -3.38 | 0 | 0 |
| -3.30 | 0 | 0 |
| -3.20 | 0 | 0 |
| -3.10 | 0 | 0 |
| -3.00 | 0 | 1 |
| -2.90 | 0 | 0 |
| -2.80 | 0 | 1 |
| 0 (none) | 2.0% (fractions within ~0.01 of +-0.5) | 26 (1.3%) |

Nothing happens at -3.4: across the whole range the board visited, the float
model rounds correctly. The only errors are at zero CFO, near the +-0.5 tie,
where the up and down legs' parabolic-interpolation biases coincide and add
instead of partly cancelling; the board never runs there. The model is floating
point and the board is not, so the same question was put to the RTL.

**The same question through the RTL.** Full synthetic packets (12 preamble
upchirps, sync 8/16, 2.25 SFD downchirps, 8 payload symbols) delayed by
base + f samples (f applied as an FFT phase ramp; the 1 MS/s stream is 8x
oversampled for 125 kHz, so the band-limited shift is exact), the calibrated
CFO, board noise, amplitude 240, through `tb_replay_detect` with the joint
search run to completion; 2 integer phases x 5 CFO levels (0, -2.9, -3.2, -3.4,
-3.6) x f in {0, 0.25, 0.375, 0.4375, 0.5, 0.5625, 0.625, 0.75}, 80 runs. The
grid origin the RTL applies (up_coarse + correction - base) is 4096 for every
f below 0.5 and 4097 for every f above it, at every CFO level and both phases:
the rounding edge does not move with CFO within 1/16 sample. The only runs
where the RTL and the float model differ are at f = 0.500 exactly (at -3.6 on
both phases and -3.2 on one), the tie itself, where either integer is half a
sample from the truth and neither is an error.

So neither the model nor the RTL shows a CFO effect in the range the board
visited. The six grid errors of the first 35 minutes after the cold boot are
not explained by the CFO value; time since boot (a warm-up effect in the board
or the transmitter that the CFO merely tracked) remains, and nothing measured
so far separates candidates within it. The scripts are in the session
scratchpad, not in `tools/` (`cfo_grid_error_synthetic.py`, `cfo_rtl_synth.py`).

## The packet timestamp carried the carrier offset; the grid errors are a half-bin effect -- 2026-09-24

Two offline investigations, no board.

### 1. The six 1-sample grid errors, replayed at the board's own phase

The earlier replays of these recordings used arbitrary arrival phases. The
board's phase can be recovered: the detector's preamble bin moves by one per
8 samples of replay shift, so the shift that reproduces the board's bin is
known to within 8 samples, and all 8 (plus margin, 24 shifts per capture,
144 runs) were replayed with the joint search run to completion
(`tb_replay_detect`, guard-image RTL). For every capture one shift reproduces
the board's preamble bin, `up_offset` **and** correction exactly. At that
shift the RTL's correction agrees with the float model's
(`estimate_joint_chirp_timing` on the same window and the same coarse starts,
`up_coarse` and `up_coarse + 10*1024`, radius 16) in 5 of 6; in the sixth
(`152702Z`) the model has timing +0.471 and rounds to 0, the RTL rounds to 1
(a fixed-point difference within 0.03 sample of the tie). So the errors are
deterministic in the signal, not a board state.

What the six share: the residual left after the grid correction,
`t - correction`, is -0.46..-0.53 sample in every one, always the same sign,
while the CFO displacement was about -3.4. The dechirped tone therefore sits
at S = displacement + residual = -3.89..-4.03 samples, and -4 samples is half
a bin (8 samples per bin). Over all 929 ordinary-path captures with ground
truth: of the 8 with S below -3.85, 6 fail CRC; of the 921 above, none. The
link to "the first 35 minutes after a cold boot" is that only then was the CFO
negative enough for a residual of about -0.5 to reach the edge.

The previous section tested whether CFO flips the *rounding* of the grid
correction and found it does not; that stands. The mechanism is downstream:
the joint (up+down)/2 grid removes the timing but leaves the CFO in every
decision, about -0.43 bin here, with 0.07 bin of margin to the half-bin edge.

Remedies tested against the ground-truth sweep of all 981 captures (which grid
offsets from the PL's decode every symbol):

| grid | captures decoding every symbol |
|---|---|
| as built, joint (up+down)/2 | 921/928 ordinary path (974/981 all) |
| constant +1 sample | 830/928 |
| constant -1 sample | 6/928 (exactly the 6 failures) |
| aligned to the up leg's peak | 0/981 |

The good window is 1-3 samples wide and always includes the built grid except
where S < -3.85, where it jumps to -1 alone. The idea that data upchirps are
best demodulated on a grid aligned to the upchirp peak (time and frequency are
interchangeable for a chirp) is refuted by these data. No grid-only rule fixes
the six; removing the fractional carrier offset before the bin decision (the
joint pair already estimates it: (up - down)/2) is the candidate, not built.

### 2. The final ToA metadata was the up leg's peak, i.e. timing plus CFO

The timestamp software receives (page 0: coarse sample count and Q12 fraction)
came from the up leg's matched-filter peak alone (`u_metadata_join` in
`lora_packet_toa_receiver_top`, fed by `peak_triplet_valid` and
`toa_offset_valid && !reference_down`). An upchirp's matched-filter peak moves
by the CFO displacement; the joint pair cancels it, but its result only
steered the grid (#28 section 1 raised this as a hypothesis).

- **On the board:** over 923 captures with a correct grid, the up leg's peak
  sat -3.15 samples (mean) from the joint timing, and the reference model's
  CFO displacement on the same packets averages -3.15 (difference 0.00 +/-
  0.36, the integer quantisation). The board's timestamps were about 3 us late
  or early by the transmitter's frequency, and drifted 0.8 us over the day as
  it warmed (-2.8..-3.6 samples).
- **Through the RTL, synthetic packets with known delay:** 5 CFO levels of both
  signs x 4 fractional delays x 2 phases, board noise. Before: metadata error
  = displacement to within 0.07 sample (-3.65..-3.59 at -3.6, +3.40..+3.45 at
  +3.41; 0 +/- 0.006 at zero CFO). After the fix: within +/-0.043 sample at
  every level and both signs; zero CFO unchanged.

**Fix.** `lora_joint_chirp_grid_controller` outputs `toa_coarse` and
`toa_fraction_q12`: the up leg's coarse start plus (up + down) / 2 (Q12 sum
halved; 1/8192-sample truncation), split as the metadata ABI is, valid on
`precise_correction_applied`. The receiver top feeds them to the metadata join
in joint-grid builds (the legacy build is unchanged). Consequences: the
timestamp now completes after the down leg rather than the up leg; a packet
whose joint estimate aborts or is rejected gets no timestamp (an up-only value
would carry the CFO error, and the joint page's sticky bits say what happened);
`toa_log_peak_q12` is held from the up leg, because the down leg's
interpolation now runs before the timestamp completes.

**What the change exposed in the testbenches.** `tb_lora_joint_grid_completion`,
`tb_lora_joint_grid_multi_packet` and `tb_lora_packet_toa_receiver_top` had no
SFD: after the sync symbols they drove upchirps "only so the down search window
arrives". The down leg locked onto an upchirp 14 samples off, and the grid they
produced was 7 samples late (`fine_skip` 23 where 16 means zero correction) -- a
fault the old timestamp check could not see because it read the up leg only.
All three now drive a real SFD (2 + 0.25 downchirps, `drive_css_downchirp`),
and `fine_skip` is 16 at zero phase. `tb_lora_packet_toa_receiver_top` asserts
both legs exactly (33 + 33 correlations from 1008 and 11248, two
interpolations, one timestamp at 1024). `tb_lora_joint_grid_completion` takes
`+cfo_nano=N`: with +/-418000 (the board's -3.4-sample displacement and its
mirror) the old RTL fails at +/-3 samples at both phases tried and the new one
passes; CI runs both signs at all five phases. `tb_lora_joint_chirp_grid_controller`
checks the new outputs, including a CFO-like pair (up peak 3.75 early, down
2.875 late) where the up peak alone would give 10436.25 and the output is
10440 - 1792/4096.

Not built or deployed yet. It belongs in the next image together with the M8
diagnostics.

## M8 image on hardware: the CFO-free timestamp holds; CRC losses are the half-bin; misses leave evidence -- 2026-09-24

Image `bac7c143...` (RTL `afdf52e`: M8 diagnostics plus the CFO-free timestamp;
WNS +0.146 ns, WHS +0.030 ns) deployed by the usual atomic swap (the M7 guard
image kept on the card as `system_top.bit.pre_m8_20260924T000000Z`), cold-booted,
smoke test `status=0x00011243`. Runs at 25 dB, `trace_rearm` between attempts:
a 6-attempt probe (5 captured, 5/5 CRC), a 78-attempt run stopped early to
restart with a tool that records the page-0 timestamp
(`2026-09-24-clg400-m8-partial`), and a 500-attempt series
(`2026-09-24-clg400-m8-series500`, 16:40-19:11 UTC).

**Series:** 500 attempts, 486 captured, 8 transmitter-side failures (1 profile
readback, 6 `send` timeouts, 1 recording without a packet), 6 detection misses
(1.2% of 492 packets), CRC 461 of 486 (95%), 29 packets accepted through the
straddle path.

**The timestamp is the joint time on the board.** Every capture now records
page 0. Over all 486: published timestamp minus `up_coarse_start` minus the
joint correction = +0.015 sample mean, within +/-0.5 (the fraction); minus
`up_offset` instead = +3.39 mean (-4.2..+4.0), the CFO displacement. The page-0
sequence equals the capture sequence in 486/486, so each timestamp belongs to
its packet. On the previous images the published value was the up leg's peak.

**All 25 CRC failures are the half-bin mechanism.** The transmitter's CFO
displacement stayed at -3.30..-3.47 samples all series (windows of 50), the
region where the M7 guard image had its only errors, and did not drift out of
it as it did on 2026-09-20. Ground truth over the 486: with S = displacement +
residual after the grid correction, 17 of 35 packets with S < -3.85 fail and 0
of 95 in -3.7..-3.5; 20 of the 25 failures have S -4.07..-3.82 and the other 5
have model timing within 0.034 sample of the +/-0.5 tie, where the RTL rounded
the other way than the model, which puts their actual S at -3.91..-4.06. Losses
from this mechanism (5% here) now exceed detection misses (1.2%): removing the
fractional carrier offset before the bin decision is the next receiver change.

**The receive crossing lost 1906 samples once, before the first attempt.** The
new drop count read 1906 right after the cold boot and profile restore, did not
move in 30 s of idle, did not move on a second profile restore, and did not move
in any of the 584 attempts of the day. So the sticky `crossing_overflow` that was
set on every M7 capture comes from one event between boot and the first read;
the next cold boot should read the count before `restore_rx_profile.sh` to tell
boot from the first profile restore. None of the misses lost samples in the
crossing.

**Misses: reproduced in the RTL, a narrow phase band my earlier replays aliased over.**
All six misses of the series and the one of the partial run carry the detector's
decision history, and the crossing drop count did not move in any of them. In each,
the preamble decisions jump by 2 bins a few symbols before sync (51 x8 then 53, 53,
53, 52, sync 60, 69), which breaks "eight preamble decisions within +/-1 of the
oldest". Five of them were replayed through the RTL (`fix_tb`, 20000 samples of
silence in front, detection only) at every 1-sample shift in a 24-sample window
around the board's phase (found from the preamble bin, which moves one bin per 8
samples of shift). **For all five, one shift reproduces the board's 16 decisions
exactly (16/16), and at that shift the RTL does not detect the packet either.**

| capture | board phase shift | blind shifts in the window |
|---|---|---|
| 163349Z | 223 | 215, 223, 231 |
| 164405Z | 142 | 134, 142, 150 |
| 164957Z | 239 | 231, 239, 247 |
| 174127Z | 1022 | 6, 1014, 1022 |
| 180856Z | 181 | 173, 181, 189 |

The blind shifts recur every 8 samples, one chip: a fixed position inside the chip
(residues 5, 6, 7 mod 8 here). Every earlier replay of the misses stepped the
arrival phase by 32 or 64 samples, always a multiple of 8, so all of them sampled
the same residue and never once the blind one. "Not reproducible from the
recording", written for the M7 guard image's five misses and taken as evidence for
a board-side cause (and the reason the M8 diagnostics were built), was an artefact
of that sampling. The diagnostics did their job the other way round: the decision
history made the exact phase known, and the replay then reproduced it.

The mechanism is a relative of the half-bin: at that position inside the chip,
together with the CFO, the preamble tone sits where the correlator's decision
alternates between two values two bins apart. The fractional-CFO compensation
proposed for the CRC losses is the natural fix for this too; widening the preamble
tolerance to +/-2 would also cover it but would weaken the detector against noise
and needs its false-detection rate measured on silence first.

An operator error to record: while the first series ran, I read the board's
registers from a second shell to check the new page-0 read. That script
switches pages through the same control register the capture tool uses, so the
read (and possibly the attempt then in flight) saw mixed pages; the series was
stopped and restarted with the timestamp-recording tool, and the partial run's
last record (`163943Z`, interrupted, no PL state) is not a miss.

## M9: fractional-CFO removal before the bin decision, and split-preamble detection -- 2026-09-25

Both remaining loss mechanisms of the M8 series come from the carrier offset
left in the correlator's input, and both were reproduced in the RTL at the
board's own phase before anything was changed.

### Why the preamble peak splits (the detection misses)

The correlator is a time-domain correlation with the reference chirp, decimated
to one lag per chip (`fft_correlator_stages`: the two-FFT identity). On the
free-running grid the window holds the tail of one preamble chirp and the head
of the next. For the blind phase of miss `163349Z` the correlation profile of
every preamble window has two nearly equal peaks at 51 and 53 with a trough at
52 (0.27): the two parts arrive in antiphase and cancel at the true lag. The
ratio of the two lobes creeps from 0.953 to 0.996 over nine symbols and then
crosses, so the argmax jumps by two bins. Rotating the recording by the
carrier offset (the model's joint estimate) makes the profile single-peaked in
all five misses (second/first 0.35-0.75 instead of ~0.99) and the preamble
decisions constant: the relative phase of the two parts is the carrier offset
accumulated over a symbol.

### Fix 1: remove the carrier offset after the joint estimate

`lora_cfo_derotator` sits in front of the generated correlator, inside
`lora_fft_detector_timestamp_path`. A 16-stage pipelined CORDIC (one sample per
clock, no multipliers in the loop, maximum error 2 LSB at full scale in
`tb_lora_cfo_derotator`) rotates each sample by a 32-bit phase accumulator
advancing `cfo_q12 * 2^7` per sample. `cfo_q12` is the joint pair's own
displacement (up - down)/2 in Q12 samples, a new controller output latched with
the precise correction; a displacement d samples is a tone of -d/8192
cycles/sample (the calibration used in the model experiments above). Rotation
starts on `precise_correction_applied` and stops on the next `detected`, a
re-arm or a stream reset, so the next preamble is searched on the raw stream as
before, and the IQ history the joint search reads stays raw. The grid-resync
request travels through the same 19-clock delay as the samples (the skip is
applied inside the generated correlator, so its order with the samples must not
change); the stream reset goes to the correlator directly and flushes the delay
line. With rotation off the output is the input, bit for bit.

Evidence:

- Reference model, series `m8-series500`: with the IQ rotated by each packet's
  joint CFO, 25 of 25 CRC failures decode on the grid the board used and 50 of
  50 random controls still do; the window of grid offsets that decode every
  symbol widens from 1-3 to 7-8 samples.
- RTL on board recordings at the board's phase, with the board's sample rate
  (`tb_replay_detect +gap_det=63`: one sample per 63 clocks from the detection
  until the joint result, where the ratio matters; one per clock elsewhere).
  The phase was pinned for 7 of the 14 recordings tried (a two-run method: the
  preamble bin gives the phase to 8 samples, the joint `up_offset` the rest;
  for the other 7 it did not converge and they are left out). The old RTL
  reproduces the board's failure on all 4 failures pinned, the new one decodes
  all 4; the 3 controls decode on both.

### Fix 2: accept the split preamble

Before detection the carrier offset is not known, so the detector has to
tolerate the split. `lora_detector_timestamp_path` gains a third path next to
the generated rule and the M7 straddle path: eight preamble decisions within
+/-2 of the oldest, the first sync decision within +/-2 of ref + 8*highNibble
(or, in the straddle form, of ref itself), the second within +/-2 of
ref + 8*lowNibble. The straddle form was needed: two of the five misses had
both the split and the straddle (the first sync symbol read as one more
preamble bin), and it raises `straddle_detected` too so the controller does not
unwrap the coarse origin. Guards as for M7 (every decision of the window from a
correlator that saw a signal; reference bin in N/4..3N/4). The path reports its
own preamble bin, the centre of the two lobes, and chips_to_boundary = N - bin,
because the generated detector's tracking restarted at the jump. It cannot fire
on an ordinary packet a symbol early or late (at sync1 the sync1 check fails, a
symbol later sync1 is inside the preamble run), and never where the generated
rule or the straddle path fired. A new sticky bit 6 on the joint page
(`detector_split_accepted`) counts it on the board.

Evidence: unit tests with the board's own decision sequences (`163349Z`
ordinary form, `180856Z` and `164405Z` straddle form) plus a 3-bin spread,
silence and an out-of-band reference, all as expected; the existing detector
tests unchanged. RTL on the five miss recordings at their blind phases, 20000
samples of silence in front, `+gap_det=63`: the old RTL detects none, the new
one detects all five (three ordinary, two straddle form; preamble bins 52, 62,
50, 79, 56 = the lobe centres) and every one decodes with a valid CRC.

(A unit test first asserted that "silence, then 8, 16" is not detected; it is --
by the generated rule, whose own pattern that is with reference 0, the known
two-coincidences-after-silence weakness. The test now asserts only the split
path's refusal.)

Regression: fft detector, receiver top, AXI path, joint path x3, bridge (bit 6),
multi-packet, completion x5 plus two with CFO, controller, derotator, detector,
FIFO; 242 Python tests. Not built or deployed yet.

### M9 build 1 failed timing; CI found an early-sync miss -- 2026-09-25

The first M9 build missed timing by 0.056 ns (WNS) on one path: interpolator
`quotientReg` -> joint controller `toa_fraction_q12` CE, 46 logic levels (36
carry chains). Since the M8 timestamp fix the (up + down)/2 sum, its rounding,
the range check and now the CFO difference were all computed in the cycle the
down leg's interpolator result arrives. The controller now registers the down
leg's refinement (`STATE_WAIT_DOWN_FRAC`), the sum and difference
(`STATE_SUM`), and rounds, range-checks and latches in `STATE_DECIDE`: the
estimate arrives two clocks later (135519 -> 135521 cycles after detection in
`tb_lora_joint_chirp_grid_path`); a sample takes 63.

CI had been red since `afdf52e` on one job: `tb_lora_joint_grid_completion`
at grid_phase 512 with CFO +/-0.000418 cycles/sample found no packet (only the
two CFO signs at this phase; all other 13 combinations passed). Grid phase 512
is exactly half a symbol: every window holds half of two chirps, and the one
holding the last preamble chirp and the first sync chirp is a tie. At CFO 0 it
went to the preamble (decisions 64 x8, 72, 80 -- the generated rule fires);
with the offset it went to the sync (64 x7, 72, 72, 81): one preamble decision
short, and neither the straddle path (the mirror case: first sync read as
preamble) nor the split path accepted it. I had run the CFO cases locally only
at phases 0 and 700.

`lora_detector_timestamp_path` gains an early-sync path:
[7 x (ref +/-1)][s1 +/-1][s1 +/-1][s2 +/-1], guards as the straddle path. Its
windows are the generated rule's own (the tie window is the one it counts as
the eighth preamble decision), so it fires on the same symbol with the same
preamble bin and chips_to_boundary = N - ref, and raises no straddle flag.
New sticky bit 7 on the joint page (`detector_early_sync_accepted`,
`early_sync_accepted` in the run summary). Not seen on the board so far: all
M8 misses were the split.

Regression: every CI RTL step run locally (the smoke job's 20 testbenches, the
completion matrix 5 phases x 3 CFO values, multi-packet), 242 Python tests.

## M9 on the board -- 2026-09-25

Image `94aee611...` (source `92d5241`: CFO derotation, split-preamble and
early-sync detection, the two-stage joint controller), deployed by the operator
over the M8 image (backup `system_top.bit.pre_m9_20260925T000000Z`), cold boot,
`GAIN=25 restore_rx_profile.sh`, cold-boot smoke PASS. Same link as M8: Heltec
V4/SX1262 -> CLG400, ~1 m over the air, 868.1 MHz, trace_rearm between attempts.

**Crossing drops happen at boot.** The drop count read straight after the cold
boot, before `restore_rx_profile.sh`, was already 1901 (0x76D); it did not move
through the profile restore or the whole series. The 1906 of the M8 day was the
same boot-time event; the receive path drops nothing while it runs.

**Series `2026-09-25-clg400-m9-series500`** (17:26-20:35 UTC, archived to
zynq-sdr-course-artifacts with its manifest):

| | M8 series500 (2026-09-24) | M9 series500 |
|---|---|---|
| attempts / captured | 500 / 486 | 500 / 492 |
| CRC valid | 461 / 486 (94.9 %) | **492 / 492 (100 %)** |
| detection misses | 6 | **0** |
| failures outside the receiver | 8 | 8 (prepare_transmitter 3, send 4, one recording without a packet, peak-to-median 1.8) |
| straddle path | -- | 26, all CRC valid |
| split path | -- | 2, both CRC valid |
| early-sync path | -- | 0 |
| timestamp residual | +0.015 mean, within +/-0.5, sd 0.291 | +0.001 mean, within +/-0.5, sd 0.285 |
| CFO displacement (up - joint) | -3.38 mean | -3.64 mean |

The timestamp residual is page-0 time minus `up_coarse_start` minus the joint
correction; its spread is the rounding of the integer correction (a uniform
+/-0.5 has sd 0.289), so the derotation did not move the published time.
Both mechanisms found on the M8 day are gone on the hardware: no CRC failure at
all (the half-bin mechanism), and no miss (the split preamble; two packets went
through the split path and decoded).

`up_coarse_start` on the joint page is the low 32 bits of the sample count; the
counter passes 2^32 every 71.6 min at 1 MS/s, so in a 3-hour series about half
the records differ from the 64-bit `page0_coarse` by 2^32 or 2^33 exactly. The
residual above is taken modulo 2^32; the reader now says so.

An overnight series with `--keep-iq anomalies` (new: the recording of an
ordinary decoded packet is deleted after its record is written; failures,
CRC failures and every rescue path keep theirs) was started at 21:09 UTC, 1400
attempts, to put numbers on the rare paths.

**Overnight series `2026-09-26-clg400-m9-overnight`** (1400 planned, from 21:09
UTC): the host disk filled at about attempt 243 (22:40 UTC; not by the series,
which used ~25 MB with `--keep-iq anomalies`), and every attempt after it failed
with `ENOSPC`. Before that: 240 captured, CRC 240/240, 0 misses; split path 1
(CRC valid), early-sync 0, straddle 10; 4 transmitter-side failures and one IQ
file truncated as the disk filled. No crossing drop.

Together with series500: **0 misses in 732 packets**, CRC 732/732. Wilson 95 %
upper bound 0.52 % (M7 had 5/798 = 0.63 %); Fisher exact, one-sided, against
M8 (6/492) p = 0.004, against M7 p = 0.04. Issue #31 closed. The early-sync
path has not fired on the board yet.

## M9: detection misses come back on a weak signal -- 2026-09-26/27

**Day series `2026-09-26-clg400-m9-day1400`** (06:33-13:40 UTC, 1400
attempts, `--keep-iq anomalies`): 1381 captured, CRC 1377/1381, **7 detection
misses**, 1 recording without a packet, 11 transmitter-side failures. Rescue
paths: straddle 64, split 23, **early-sync 4** (its first firings on the board),
all CRC valid. No crossing drop.

A miss here is a `read_trace` failure with `captured=0`, the joint page empty,
and page 0 still holding the *previous* packet (its coarse time and sequence
number): the programmable logic never detected this attempt's packet. At first
I read the ring's one `detected` entry as this packet's; ordering the ring by
sample count (the write pointer, not `newest_index`, is where the counts jump
back) puts it before the attempt's own re-arm, i.e. it is the previous packet.

**The signal dropped ~10 dB overnight; nothing on the bench moved.** Noise
power of the recordings is identical in all three series (0.82 LSB^2); the
packet's power fell from 38-40 dB to 28 dB above it. At night (21:10-22:40
UTC) the burst ratio stayed at 6600-6700 within a few percent; through the day
it moved in steps between flat plateaus (530-590 for 30 minutes, then
1300-1700, then 12500 at 10:30 UTC): indoor multipath with people in the room.
The receive configuration read back unchanged (25 dB manual, LO 868.1 MHz);
the transmit profile is byte-identical.

| Burst ratio | captured | misses | CRC fail |
|---|---|---|---|
| < 300 | 28 | 7 | 1 |
| 300-1000 | 371 | 1 | 0 |
| 1000-3000 | 318 | 0 | 2 |
| >= 3000 | 664 | 0 | 1 |

**Mechanism.** The packet peak of the missed recordings is 9-16 LSB of 2047
(the day's good ones 23-54, the evening's 57-169). The decision ring shows the
preamble with holes: `29 x6, ., 29 x4`, `100 x11, ., 108, 116` -- windows with
confidence 0 in the middle of the packet. The correlator's
`peakMagnitudeSquared` is a 16-bit quantity scaled for strong input; where a
window holds a split peak or straddles two chirps each lobe carries about a
quarter of the power, and at this level it truncates to exactly zero. The
decision becomes bin 0 and breaks the run, and the M7 silence guard (every
window's peak non-zero) refuses the rescue paths too. The radio link itself is
fine: 28 dB SNR at worst, where SF7 decodes at -7 dB.

RTL replay of six misses (M9 RTL, 28 phases, step 37): 3 detected at no phase,
the others at 2-13 of 28. The same recordings scaled x16 are detected at all 28
phases, x4 at all 15 phases tried; three strong recordings of 2026-09-25 scaled
x16 are detected at every phase (no overflow). The seventh miss (080352Z) has
no preamble in the recording at all: the burst is 42 ms instead of ~77 ms and
starts with payload symbols (dechirped bins wander 0..4, 121..127): a fade over
the preamble, not a receiver fault.

The four CRC failures: three do not decode with the reference model at any
grid correction either (072121Z agrees with the model on only 9 of 24 raw bins;
083257Z is at burst ratio 118); one (101022Z) decodes with the model at -3
while the PL applied -1, a joint-estimate error of 2 samples.

**Gain experiment on the board.** RX gain set live (sysfs, manual, both
channels). A first pair at 11 and 23 dB (300 attempts each, evening) gave 0
misses in both: the evening signal was ~22 dB stronger than the weak day
periods (peak 33-48 LSB at 11 dB). The decisive run interleaved 12 blocks of 25
attempts at **0 dB** (peak 9-14 LSB, the level of the day misses) and **12
dB**, so a change in the room hits both arms alike:

| | 0 dB | 12 dB |
|---|---|---|
| packets on air | 295 | 298 |
| detection misses | **194 (66 %)** | **0** |
| CRC of captured | 101/101 | 298/298 |

By packet peak: 9-11 LSB 5 of 5 missed, 12-14 LSB 189 of 193 missed, 30 LSB
and more none missed. The receiver needs about 20 LSB of packet peak.

**Consequences.** (1) At 25 dB this bench swings from ~15 to ~190 LSB within a
day, and at 50 dB it clipped at the rail (2026-09-19): analog gain alone leaves
too narrow a window. (2) Short term: 37 dB puts the weakest daytime packet at
~60 LSB and the strongest seen at 25 dB (219) at ~870, both inside range.
(3) The fix belongs in the PL: a digital gain of x16 in front of the
correlator costs nothing in range (12-bit ADC into a 16-bit input:
2047 x 16 = 32752) and removed every replayed miss. The gain was returned to
25 dB after the runs.

### The correlator's working window, and why M10 is not a digital gain -- 2026-09-27

The plan was M10 = a x16 left shift (with saturation) in front of the detector
correlator. Two things killed it before a build:

- **The local CI failed with it.** The testbenches drive amplitude 1024; x16
  gives 16384, and the completion testbench found no packet at 4 of 5 phases
  (`packet starts=0`). The M10 RTL did detect all six raw weak misses at all 15
  phases tried, with the joint estimate applied (`precise=1`).
- **The window has a ceiling as well as a floor.** A strong recording of
  2026-09-25 (raw peak 169) scaled to peaks of 1200/2400/4800/9600/15000/24000
  through the M9 RTL, 7 phases each: detected at 7/7, 7/7, 7/7, 6/7, 4/7, 4/7.
  With the floor at ~20 LSB the generated correlator works from about **20 to
  5000 input LSB, ~48 dB**.

The reason is in the generated types (`model/simulink/+lora_sim/fixed_point_types.m`):
every boundary is 16 bits with one guard bit over the measured range of the
golden vectors, Floor rounding, Saturate on overflow. The input is
`sfix16_En10` -- the model's unit amplitude is 1024 LSB, which is what the
testbenches drive -- and `magnitudeSquared` is `ufix16_E5`. The board's packets
at 25 dB were 9..220 LSB: the receiver had been running at the bottom of its
window all along.

So a gain in the PL only moves the signal inside the same window; so does the
AD9361 gain, and at 25 dB the AD9361's noise (~0.9 LSB rms) already exceeds the
ADC's quantization noise, so the digital shift buys nothing the analog gain
does not. x16 would have pushed today's 37 dB packets (up to 680 LSB) to 10880,
over the ceiling. **Operating point: 37 dB** (packets 36..880 LSB on this bench,
inside the window at both ends); `restore_rx_profile.sh` now defaults to 37
(was 50). The M10 change was reverted and never committed. Widening the window
itself means regenerating the correlator with wider `magnitudeSquared`,
spectrum sum and confidence (MATLAB R2025a with HDL Coder is installed).

**Series `2026-09-27-clg400-m9-gain37`** (37 dB, 06:16-13:12 UTC, 1400
attempts): 1389 captured, **0 detection misses**, CRC 1379/1389; straddle 77
(CRC 73/77), split 5, early-sync 1; 3 recordings without a packet (send
timing), 8 transmitter-side failures; no crossing drop. Packet peaks 520..680
LSB, none at the ADC rail.

**CRC failures are a separate mechanism**, ~0.4 % over all M9 series. They do
not follow the level: the joint triplet's log2 peak is 27.9..28.4 for the
failures against a median of 28.2 for the good ones (saturation at 32). With
the reference model derotated by the joint CFO (as M9 does), 3 of the 12
examined decode: 083257Z on the board's grid (it is a weak packet, 118 burst
ratio: truncated payload windows), 081344Z and 101022Z only 1..6 samples off
the board's grid (a joint-estimate error). The other nine decode at no grid
offset even derotated. At 37 dB the straddle path is over-represented: 4 of
its 77 packets failed against 6 of the other 1312.

## M10: the correlator regenerated at WordLength 20 (#32) -- 2026-09-27/28

**Why the window was where it was.** `run_fixed_point_sweep` chose 16 bits in
M2 by driving the golden vectors at one level, and `run_real_iq_regression`
normalises every window to unit RMS before replaying it: neither ever varied
the input level, so the dynamic range was never measured. The integer bits come
from range analysis (plus one guard bit), the word length only adds fraction
bits -- so more word length lowers the floor and leaves the ceiling alone.

**Regeneration.** `run_hdl_generation(WordLength=20)` (MATLAB R2025a, HDL Coder,
~8 min; now the default). Ports become `sfix20_En14` in, `ufix20_*` out;
`fft_correlator_route_top` keeps the 16-bit sample port (a raw sample enters as
`{x, 4'b0}`, the same value) and returns confidence and spectrum sum at their
old scale (top 16 bits); the peak keeps "zero means exactly zero" (a peak the
16-bit core would have truncated reads 1).

RTL replay (7 phases each, `--no-joint`):

| input peak (LSB) | 5 | 10 | 20 | 40 | 1200..4800 | 9600 | 15000 | 24000 |
|---|---|---|---|---|---|---|---|---|
| 16-bit core | 0/7 | 1/7 | 7/7 | 7/7 | 7/7 | 6/7 | 4/7 | 4/7 |
| 20-bit core | **7/7** | **7/7** | 7/7 | 7/7 | 7/7 | 6/7 | 4/7 | 4/7 |

The six weak board misses of 2026-09-26 are detected at every phase on the raw
recordings. Noise-only board recordings (pre-burst noise at 25 and 37 dB, 4 x
250k samples each): 0 detections on either core -- the M7 silence guard stayed
harmless although noise no longer truncates to exactly zero.

**Timing.** The first 20-bit build missed by 0.446 ns (77 endpoints), both paths
inside the core and both the ones that had been thin at 16 bits (+0.002..0.025
ns): FFT_N -> ScaleByM -> MagnitudeSquared -> Confidence divisor (28 levels, 17
carry chains) and resetIn -> Multiply -> AccumDelay. `run_hdl_generation` now
sets output pipelines on Multiply (1), ScaleByM (1), MagnitudeSquared (2) and
GuardedSum (1) -- outside the AccumSum/AccumDelay and SpectrumSum/SpectrumDelay
loops, so the function is unchanged and HDL Coder balances the parallel paths;
core latency 42 -> 47. Result: **WNS +0.220 ns**, the best margin of the
project (M9 +0.018), worst path now inside axi_ad9361; LUT 39154 (73.6 %), DSP
102, BRAM 86. The pipelined core replays identically (5/10/4800 at 7/7, 9600 at
6/7, the weak misses at 7/7). CI (smoke 20 testbenches, completion 5 phases x
CFO 0/+-, multi-packet) all pass. Commit `b054731`, image `27f50b0b...`
(bitstreams/lora-clg400-m10-wide-correlator).

The ci_local runner's joint-grid jobs hung twice with no simulator process
left (once across a sleep, once not); running each `vvp` of those jobs directly
from a compiled binary completed normally -- a runner problem, not a design one.

**On the board.** Deployed by the operator, loaded by a software `reboot`
(u-boot loads `system_top.bit` from the SD card on every boot, so no power
cycle is needed), profile restored at the new default 37 dB, smoke PASS; drop
count 1883 after boot, unchanged by the profile restore. Probe at 37 dB: 9/9
CRC valid. The decisive repeat of the M9 experiment -- 12 blocks of 25
attempts, 0 dB and 12 dB interleaved -- at 225/224 attempts:

| | M9, 0 dB | **M10, 0 dB** | M10, 12 dB |
|---|---|---|---|
| packets on air | 295 | 221 | 223 |
| detection misses | 194 (66 %) | **0** | 0 |
| CRC of captured | 101/101 | 221/221 | 223/223 |
| packet peak (median, kept IQ) | 12 LSB | 11 LSB | 40 LSB |
