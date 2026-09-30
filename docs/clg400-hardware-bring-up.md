# CLG400 LoRa receiver bring-up

## Purpose and stop condition

This procedure brings the first board-integrated SF7/BW125 timestamp receiver
up on the hardware-qualified ZynqSDR `xc7z020clg400-2`. It begins with a
conducted, two-board link. Do not start OTA testing or multi-receiver clock
synchronization until the single-receiver metadata path passes 1,000 packets.

The current repository contains the portable receiver, tests, a fully routed
CLG400 design, and a complete checksum-verified development SD directory in the
ignored build tree. It does **not** yet contain a hardware-qualified boot image:
the packaged directory has not been copied to a card or cold-booted. Keep the
working course card unchanged and use only a cloned or spare card for the first
boot.

## Required stand

- Two CLG400 ZynqSDR boards: course board A as transmitter and board B as
  receiver.
- One 915 MHz-capable SMA coax path from A `TX1` to B `RX1`.
- At least 30 dB fixed attenuation in that path. Never connect `TX1` directly
  to `RX1`.
- Separate board power supplies and USB/Ethernet access to both boards.
- Serial consoles are strongly recommended for the first development boot.
- A spare SD card for the LoRa receiver image. Keep the working course card
  unchanged.
- Optional for later stages: spectrum analyzer/power meter and common
  10 MHz/PPS distribution. They are not needed for the first receiver test.

Keep antennas disconnected during the conducted test. Start with the minimum
usable TX gain/power and verify that the RX ADC does not clip before increasing
it.

## Trusted baseline

The board evidence (boot sets, bitstreams, routed reports and capture
manifests) is kept in a separately maintained evidence archive with a
manifest per item. Before powering the stand:

1. Verify the archive's manifests (`python verify_manifests.py` in the
   archive checkout).
2. Preserve the known working board-B card. The manifest-backed recovery set is
   `boot-sets\board-b-course`; board B is documented at `192.168.20.1`.
3. Keep the QSPI backups under `qspi-backups\board-a` and
   `qspi-backups\board-b` untouched.
4. Cold-boot the working image and confirm Linux, the AD9361 IIO context, and
   the existing course receiver before testing any new PL image.

Useful baseline observations to record are the boot log, `iio_info -s`, the
number and names of IIO devices, the AD9361 LO/sample-rate/bandwidth readbacks,
and a short quiet-input IQ capture. Board A has historically used
`192.168.40.1`; confirm addresses from the live consoles rather than assuming
them.

Do not treat the reconstructed source overlay in `zynq-sdr-course` as a
drop-in recovery image. The manifest-backed deployed artifacts are the board
baseline. For development, clone the card, install the complete generated boot
set, and cold-cycle the board. Previous course work showed that loading an
arbitrary bitstream into a running Linux system can leave the AD9361 RX/DMA
path unusable even when configuration itself appears successful.

## Packaged development boot set

The reproducible packager is
`fpga/board/clg400/package_board_b_boot_set.ps1`. Run it after bitstream/XSA
generation with Windows PowerShell 5.1 as follows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  fpga\board\clg400\package_board_b_boot_set.ps1
```

It validates every inherited file and both new build artifacts against fixed
SHA-256 values, refuses to overwrite an existing output directory, and writes:

`fpga/build/clg400-board/boot-set-board-b`

The six SD payload files are `BOOT.bin`, `system_top.bit`, `uImage`,
`devicetree.dtb`, `uramdisk.image.gz`, and `uEnv.txt`. `manifest.json` records
their provenance and checksums; `README_FIRST.txt` records the deployment stop
conditions. The routed bitstream SHA-256 is
`8c39730d9f5d6f7732d0e143e010c2efebfd310d2f82454ad8656977e1a2cc17`.

The archived `board-b-course` directory accidentally omitted `uImage`. The
packager restores the byte-identical course kernel from the sibling course
repository; its SHA-256 is
`e675f26c955d76bccaacc14943619be44b45fcf06a52e9e6faebaada40f06f34`,
which matches the original board image `course_sd_boardB/uImage`.
Packaging changes no card, QSPI contents, or running board. The concise
tracked record is
[`docs/data/rtl-m4-clg400-board-boot-package.csv`](data/rtl-m4-clg400-board-boot-package.csv).

## Receiver integration contract

The board adapter must satisfy all of these conditions:

- Target part is exactly `xc7z020clg400-2`; CLG484 constraints or bitstreams
  are incompatible.
- Consume the formatted AD9361 FIFO samples
  (`util_ad9361_adc_fifo/dout_data_*`) or reproduce the course bridge's explicit
  offset-binary-to-two's-complement conversion. Raw ADC data is not assumed to
  be signed two's complement.
- Run the portable receiver in a coherent DSP/sample clock domain derived from
  `util_ad9361_divclk/clk_out`.
- The first SF7/L=8 image fixes `util_clkdiv` to its divide-by-four leg. With
  the 250 MHz constrained RX root this is at most 62.5 MHz; the runtime
  divide-by-two/125 MHz leg is intentionally unsupported by this image.
- Cross the completed timestamp metadata record to `sys_cpu_clk` with an
  asynchronous FIFO or equivalent atomic CDC. Do not synchronize the fields
  independently.
- Preserve AXI backpressure and expose sticky overflow/error status.
- Preserve a software-selectable raw-IQ observation path for diagnosis.

The committed SF7/L=8 core expects exactly 1,000,000 complex samples/s for
BW 125 kHz. Configure that rate only if the AD9361 attribute readback confirms
it. A live rate of 2 MHz, 3.84 MHz, or 30.72 MHz must not be fed into this core.
If 1 MHz is unavailable with the selected FIR chain, either add a documented
resampler to 1 MHz or regenerate and reverify the receiver for the actual
integer oversampling factor; do not compensate by changing metadata alone.

## Bring-up sequence

### 0. Baseline the unchanged boards

With the attenuated A `TX1` to B `RX1` path connected, cold-boot both known
working images. Confirm the course link still behaves as documented and save
the configuration/readback record. This separates stand faults from LoRa RTL
faults.

### 1. Validate the new image without RF

Boot the development card in board B with A powered off. Confirm:

- clean boot and no FPGA/clock/AD9361 driver errors;
- expected IIO devices and sample activity;
- the configured sample rate reads back as exactly 1 MHz;
- AXI identity/version registers and timestamp status are readable;
- no overflow, CDC, or metadata error flag is set;
- the formatted-sample activity flag is set; once packets arrive, metadata
  sequence and coarse timestamps are monotonic across accepted records.

The no-RF PL checks are automated by
`fpga/board/clg400/verify_board_b_cold_boot.sh`. Copy it to `/tmp` after Linux
boots and run it as root:

```sh
sh /tmp/verify_board_b_cold_boot.sh
```

It performs a reversible receiver reset/enable, verifies both `0x4c4f5241`
identity words, checks sample-domain activity and overflow, and reads one
atomic metadata snapshot. It does not use FPGA manager, change QSPI, or enable
RF transmission. A zero metadata sequence is valid before the first LoRa
packet; missing formatted-sample activity is not.

If any item fails, return to the baseline card before changing RF settings.

### 2. Replay a deterministic conducted LoRa waveform

Use board A to transmit the repository's known SF7/BW125 preamble/sync waveform
at 915 MHz through the 30 dB path. Record the exact waveform checksum, TX/RX LO,
sample rate, RF bandwidth, gain mode, gain values, and packet count. Begin at
low power and check raw-IQ headroom. The first RTL search evaluates 17 × 1,024
complex products iteratively, so use at least 25 ms between packet starts; 100
ms is the preferred initial interval. A packet arriving while
`toa_search_busy` is asserted is a traffic-rate violation, not a valid
single-search measurement.

First compare one packet at the internal boundaries: formatted IQ, FFT peak
bin/confidence, packet-start sample, the 17 matched-filter powers, peak triplet,
and final coarse/fractional timestamp. Only then start the long run.

### 3. Acceptance run

Send at least 1,000 packets with a sequence number and save both raw host
observations and PL metadata. Pass criteria are:

- 1,000 expected packets produce 1,000 complete, ordered metadata records;
- no overflow, truncation, CDC, or AXI protocol error is observed;
- sequence numbers and coarse timestamps are monotonic;
- fractional ToA remains in its documented half-sample interval;
- selected internal vectors match the MATLAB/Simulink/Verilog checkpoints;
- the timestamp residual distribution, missed-detection rate, and outliers are
  reported rather than summarized only by a best example.

Package the bitstream, boot files, Vivado reports, software revision, captured
data, configuration, and checksums in a generated artifact manifest. A passing
out-of-context synthesis report is not a substitute for this board evidence.

## After the first pass

Next add cable-delay calibration and repeat over input level, fixed/AGC gain,
CFO, and temperature. Common 10 MHz/PPS belongs to the later three-receiver
TDoA milestone; it should not complicate this first single-receiver closure.
