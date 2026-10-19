# Reproducible experiments

Create one immutable configuration per run by copying the relevant template:

```text
experiments/templates/toa.yaml
experiments/templates/tdoa.yaml
experiments/templates/phy-capture.yaml
        ↓ copy and fill
experiments/runs/2026-08-01_toa_cable_001.yaml
        ↓ execute
artifacts/2026-08-01_toa_cable_001/
```

Generated `artifacts/` and unreviewed full IQ captures are ignored by Git.
Commit the completed run configuration, compact result tables, plots, and
checksums when an experiment contributes project evidence. A reviewed,
redistributable reference capture may be promoted to `captures/reference/`;
raw IQ files in that directory are stored with Git LFS and must have a manifest.

## Required provenance

- exact repository commit and dirty/clean state;
- board, RFIC, firmware, bitstream, and host software revisions;
- waveform and RF settings with explicit units;
- clock/epoch topology and calibration identifier;
- receiver coordinates and coordinate frame for TDoA;
- random seed for simulations;
- raw-data paths and SHA-256 checksums;
- acceptance criterion chosen before the run.

Use `phy-capture.yaml` for raw RTL-SDR or PlutoSDR recordings made to validate
the MATLAB LoRa packet model before starting timestamp experiments.

For a synchronized host-controlled PHY run, copy one of the JSON files in
`configs/` to a machine-local `*.local.json` file and use
`tools/run_phy_experiment.py`. It configures the serial transmitter, arms the
SDR, sends acknowledged packets, records checksums and logs, and launches the
MATLAB inspection report. See the
[one-machine workflow](../docs/automated-phy-experiment.md).

Do not edit raw results after acquisition. If processing changes, create a new
analysis output that points to the same immutable source capture.

## FM positioning waveform simulation

The self-contained floating-point comparison of equal-duration,
equal-bandwidth, equal-energy LFM, NLFM, and optimized FM laws is run with:

```powershell
python tools/run_fm_positioning_experiment.py `
  --output artifacts/fm-positioning
```

The committed methodology and reference results are in
[`docs/fm-positioning-waveform-experiment.md`](../docs/fm-positioning-waveform-experiment.md).

## Hardware mode sweeps

The repository contains matching 27-mode matrices for both reference
transmitters:

- `experiments/sweeps/lr1121-pluto-modes.json`;
- `experiments/sweeps/heltec-v43-pluto-modes.json`.

Apply the required matrix to a reviewed machine-local base configuration:

```powershell
python tools/run_phy_sweep.py `
  --sweep experiments/sweeps/lr1121-pluto-modes.json `
  --base-config experiments/configs/my-pluto.local.json `
  --execute
```

For Heltec V4.3, substitute `heltec-v43-pluto-modes.json`. Its base profile and
all overrides keep the SX1262 setting between -9 and -5 dBm while the external
KCT8103L PA remains disabled in transmit-bypass mode.

Use `tools/analyze_phy_sweep.py` to process completed/repair sweep directories
in one MATLAB session. After reviewing the reports, `tools/curate_phy_sweep.py`
rechecks every size and SHA-256 and promotes only completed cases to a new
`captures/reference/` dataset.
