# Development guide

How to build, test and extend the project without breaking the evidence chain
from model to hardware.

## Environment

- Python 3.10+ (`python -m pip install -e ".[dev]"`), used for the reference
  package `src/zynq_lora_phy`, host tools in `tools/` and tests in `tests/`.
- Icarus Verilog 11+ for the RTL testbenches in `fpga/tb/`.
- MATLAB/Simulink R2025a with HDL Coder for the authoritative model
  (`model/matlab`) and HDL generation (`model/simulink`). Optional for work that
  does not touch the model or the generated HDL; CI runs the MATLAB suites.
- Vivado 2021.1 for the CLG400 board image (`fpga/board/clg400/README.md`).
- The Vitis 2021.1 ARM cross-compiler for the small board programs in
  `board/per/` (`sh board/per/build.sh`).

## Before changing the receiver

Run the regressions that cover the part you touch; CI runs all of them.

| Area | Command |
|---|---|
| Python reference, host tools, decoder | `pytest` |
| MATLAB model | `matlab -batch "cd model/matlab; r = run_tests; assertSuccess(r)"` |
| Simulink timestamp metadata | `matlab -batch "cd model/simulink; r = run_timestamp_metadata_regression; assert(r.passed)"` |
| RTL wrappers and integration | the `rtl-wrapper-smoke` job in `.github/workflows/ci.yml` (each step is a plain `iverilog` + `vvp` command) |
| Receiver on synthetic packets, several grid phases and CFO | the `joint-grid-completion` and `joint-grid-multi-packet` jobs |
| Receiver on recorded IQ | `python tools/replay_iq_through_rtl.py --help` |

A change that alters receiver behaviour on hardware should also be checked on
the PER bench (`docs/per-curves-experiment.md`) and recorded with its
configuration and board state.

## Generated HDL

`fpga/generated/` holds HDL Coder output from `model/simulink/run_hdl_generation.m`.
It is regenerated, never edited by hand. After regenerating:

1. `python tools/normalize_generated_hdl.py` — replaces the generating
   machine's absolute paths in file headers and reports with
   repository-relative ones (enforced by `tests/test_generated_hdl_paths.py`);
2. run the RTL regressions above;
3. rebuild the board image and record the new timing and utilization.

## Conventions

- Field and variable names carry units (`_hz`, `_db`, `_samples`, `_q12`).
- A measured claim in the documentation names its data: file, commit or
  archive manifest, and the configuration it was taken with.
- Board scripts never write the SD card or QSPI unless that is their stated
  purpose; bench state (gains, attenuations, temperatures) is logged with every
  run.
- Keep commits small and self-describing; the commit message says what changed
  and why, including measured numbers when a change is motivated by one.

## Scope

What belongs in this repository and what is developed elsewhere is described in
[repository scope and boundary](public_private_boundary.md).

Tool locations are local configuration: set `VIVADO_PATH` to the Vivado 2021.1
launcher, or pass `VivadoPath` explicitly to MATLAB build functions. Put MATLAB
on `PATH`. Keep personal ignore rules in Git local excludes or a global ignore.
Generated HTML reports are static summaries; workstation-only scripts are removed
by the normalizer.

Historical board archives are optional evidence, not checkout dependencies.
The board-B packaging helper requires explicit `BaselineDir` and `KernelImage`
inputs and checks their published hashes; it cannot reconstruct missing vendor
boot files. Python, model and RTL regressions use the sources in this repository.
