# Repository scope and boundary

This repository is a self-contained engineering baseline: a LoRa / LoRa-like
PHY, SDR acquisition on Zynq-7020 + AD9361/AD9363, synchronization, packet
timestamping and ToA/TDoA positioning, with the measurement tooling needed to
reproduce every published result. Related research that is not yet published
(new waveform designs and their optimization) is developed separately and
builds on this repository, never the other way round.

## What belongs here

Standard LoRa / LoRa-like PHY, SDR, synchronization and positioning
infrastructure:

- chirp modulation, dechirp + FFT demodulation, packet/activity detection,
  preamble synchronization, sync word and SFD handling;
- whitening, interleaving, Hamming/FEC, header and CRC;
- synthetic IQ generation, CFO/SFO/noise impairment injection, estimation and
  compensation;
- PL timestamp extraction, standard ToA/TDoA processing and multilateration;
- the Zynq/AD9361 board route: RTL, generated HDL snapshots, constraints, boot
  set packaging, register maps;
- SX1262/LR1121 transmitter and receiver firmware used as bench references;
- infrastructure for multiple synchronized receivers;
- automated experiments and measurements (BER/PER/EVM/CFO/SFO, the packet
  campaigns, the PER bench), with small curated or synthetic datasets;
- tests, CI and documentation.

Rule of thumb: if a component can serve as a generic LoRa/SDR/positioning
baseline without knowledge of a new, unpublished research idea, it belongs
here.

## What is kept out

- new or modified chirp waveforms and their synthesis;
- waveform optimization, channel-adaptive waveform design, new objective
  functions (including CRLB/Fisher-information based design used as part of a
  new method);
- experiments of the form "standard chirp vs modified/optimized chirp" and
  their unpublished results;
- full raw measurement datasets that are not needed to reproduce a published
  figure;
- draft papers and thesis material.

Such work may move here once the method is published, an open-source version is
prepared, or it is deliberately released. When it moves it gets a generic API,
tests, documentation and a reproducible example, and research-only details are
dropped.

## Dependency direction

Research code may use this repository as a pinned dependency (a fixed commit or
tag). This repository must not depend on, import from, or reference anything
outside itself: CI, tests and examples run on a clean clone.

## Pre-publication checklist

Before pushing to this repository:

- [ ] no unpublished waveform algorithms or research results;
- [ ] no restricted or unreleased datasets; large captures stay in Git LFS
      or out of the repository;
- [ ] no secrets, tokens, or credentials beyond documented factory defaults of
      bench equipment;
- [ ] no absolute local paths or internal host names (generated HDL:
      `python tools/normalize_generated_hdl.py`, checked by
      `tests/test_generated_hdl_paths.py`);
- [ ] no development-tool session files, prompts, or local tool state
      (see `.gitignore`);
- [ ] CI and examples pass on a clean clone of this repository alone.
