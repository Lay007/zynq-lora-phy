# Contributing

## Development workflow

1. Open an issue or describe the measurable outcome of the change.
2. Add or update the authoritative MATLAB floating-point behavior.
3. Add deterministic MATLAB tests, including a boundary or impairment case.
4. Update the Simulink implementation only after the MATLAB behavior is stable.
5. Compare generated Verilog against versioned MATLAB/Simulink golden vectors.
6. Update the relevant architecture, experiment, or calibration notes.

The [development guide](docs/development.md) lists the regressions per area
and the steps after regenerating HDL; the
[scope and boundary](docs/public_private_boundary.md) document says what
belongs in this repository and has the pre-publication checklist.

Run the local checks before committing:

```bash
python -m pip install -e ".[dev]"
pytest
```

For the authoritative model, run in MATLAB:

```matlab
cd model/matlab
results = run_tests;
assertSuccess(results);
```

## Commit policy

Keep commits small and outcome-oriented. The subject should answer **what was done
and why**, not describe an intention or a future task. Use English in public GitHub
issues, pull requests, code comments and commit messages. Keep English as the
primary documentation language and update existing Russian translations when
applicable.
Prefer technical summaries such as:

```text
Fix packet timestamp alignment after SFD detection
Validate CDC metadata across DMA buffer boundaries
Document the golden-vector regression procedure
```

Avoid generic descriptions, unverified performance claims and AI co-author
trailers. Credit the people who actually contributed to the implementation and
review. Avoid combining unrelated RTL, model, documentation, and infrastructure
changes in one commit when they can be reviewed independently.

External contributors should work on a topic branch or fork and open a pull
request against `main`, linking an issue or defining explicit acceptance
criteria. Maintainer-directed changes may go directly to `main`. Historical
or experimental branches, including `lora_cpp`, must not be used as an implicit
target for new changes, rebases, merges, or cleanup.

## Evidence vocabulary

Use the narrowest claim supported by the evidence:

- MATLAB/Python test pass = model/reference evidence;
- Icarus/XSim pass = RTL simulation evidence;
- synthesis report = synthesis evidence only;
- routed timing report = implementation evidence only;
- bitstream/XSA generation = build evidence, not hardware acceptance;
- boot or DMA smoke = board connectivity evidence;
- RF/packet/ToA claim requires the corresponding measured hardware evidence.

Do not turn a green simulation or implementation job into a board-level claim in commit
messages, README text, issues, or reports.

## Engineering conventions

- Store SI units in field names where ambiguity is possible (`sample_rate_hz`,
  `toa_s`, `position_m`).
- Record random seeds for generated signals and noise.
- Keep generated runs under ignored `artifacts/`. Promote only reviewed,
  redistributable IQ evidence to `captures/reference/`; raw `.cf32`, `.cu8`,
  and `.cfile` data there must use Git LFS and include provenance plus SHA-256.
- Never overwrite raw experiment data. Derived results belong in a new output
  directory with their configuration and software revision.
- Document fixed-point scaling and rounding for every PL interface.
- Do not edit HDL Coder output manually; change the Simulink source or its HDL
  configuration and regenerate Verilog.
