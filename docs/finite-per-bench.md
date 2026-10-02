# Finite PER and timestamp collection

`tools/finite_per_measure.py` is the finite PL bench alternative to the historical
continuous `per_measure.py` series. It currently supports SF7/BW125 at 1 MS/s,
CR4/5 through CR4/8, manual RX gain, and gaps of at least 0.15 s. A point sends
1–500 unique, numbered templates exactly once. The receiver is armed before TX.

Compile the two programs with the provenance builder and an ARM hard-float
cross-compiler. The collector checks that the build manifest matches its sources
and binaries. Install the `hardware`
dependencies and supply a verified SSH known-hosts file. Example:

```sh
python tools/build_per_tools.py --cc arm-linux-gnueabihf-gcc --out board/per
python tools/finite_per_measure.py --known-hosts artifacts/known_hosts \
  --bin-dir board/per --packets 300 --snr 20 -9 -8 -7 -6 \
  --rx-gain 37 --tx-atten 10 --restore-profile --out artifacts/finite-series.json
python tools/analyze_finite_toa.py artifacts/finite-series.json \
  --out artifacts/finite-series-toa.json
```

Use a cable path with the intended external attenuation. The script records the
SD bitstream hash and bridge signature; these do not separately hash the running
PL. It refuses an active `iio_readdev`: on this board RX DMA changes the DAC
stream rate/zero stuffing, as described in `per-curves-experiment.md`.

## Accounting and completion

- PER is `(planned_transmissions - received_unique) / planned_transmissions`.
  Leading, trailing and long runs of losses are included; sequence IDs do not
  wrap within a point. The same IDs may be reused in separate SNR points.
- `outcomes` records every planned ID and its CRC/ToA observation. A missing
  CRC-valid ID has no uniquely attributed detector/CRC failure reason. Aggregate
  packet records, CRC failures, timeouts and invalid reads are separate counts.
- The board trace collector treats `timeout_ms` as an inactivity timeout:
  becoming active or capturing another symbol restarts it. A fixed deadline
  from rearm could otherwise clear a partly captured first packet when the
  one-second TX lead-in happens to finish near that deadline. Idle and stalled
  captures still expire; `duration_ms` remains an absolute collection limit.
- The generator writes a one-second noise lead, all packets and their gaps, a
  two-second noise tail, then padding to a whole 262144-sample IIO buffer. This
  avoids silently dropping a partial final buffer in libiio 0.25's
  [iio_writedev](https://github.com/analogdevicesinc/libiio/blob/v0.25/tests/iio_writedev.c).
  The collector checks both pipeline exit codes, final generator counters,
  clipping, expected sample count and a minimum streaming duration. It keeps
  observing for two seconds after the writer exits.
- The count means completed finite templates submitted through the checked IIO
  pipeline. It is not a hardware RF event timestamp. Confirm first/last packet
  IDs and intervals at high SNR before using this protocol near sensitivity.
- Failed/incomplete transmission or collection, malformed/changed snapshots, or
  unexpected CRC-valid IDs make `measurement_valid=false` and `per=null`.
  `per_observed` is retained only as a diagnostic, not a qualified PER.
- `lora_tx_noise` without the optional limit remains continuous. In finite mode
  its optional arguments after seed/sample rate are packet limit, lead samples
  and tail samples. Finite limits require enough distinct templates. Final
  counters are emitted on completion, signal termination or output failure.

## Timestamp integrity and persistence

Every PKT retains capture/metadata sequence, 64-bit coarse count, signed Q12
fraction, log peak, status/debug, joint status, sample-drop counts, freshness,
snapshot-change flag and raw trace. ToA eligibility rejects stale/changed
metadata, mailbox overflow, missing/rejected joint correction and sample drops
within the attempt. CRC validity and ToA eligibility are separate decisions.
Timeouts retain acquisition/joint status and drop counters even when no packet
trace completes. Sticky trigger bits count affected attempts, not every trigger
or statistically independent FFT window.
The joint page's correction/up-offset/origin/phase diagnostics are also retained.
They remain frozen from a previous success on an abort: use
`joint_diagnostics_valid`, freshness and status before attributing them to a packet.
Each run archives the exact collector/generator sources with hashes and retains
the compiler manifest, so later edits do not erase its build provenance.
For known-delay/CFO studies, `--templates path.c64` accepts a prebuilt stream
with a matching profile/count/sequence/dimensions sidecar. Optional `trials`
entries describe each sequence's `start_offset_samples` and `cfo_hz`; the
analyzer includes those known offsets in its interval model. The stimulus
generator and its assumptions must be retained separately with the experiment.

Raw lines are flushed to a sidecar and parsed records checkpointed atomically
after each observation. Transient Windows destination locks are retried without
removing the previous JSON. Interrupted runs retain their records and error
instead of masquerading as complete series. TX cleanup covers initial RF setup
and failures; a run-scoped UUID limits temporary-file cleanup.

`analyze_finite_toa.py` subtracts the integer epoch before converting to floating
point, then fits epoch and clock scale against known packet intervals. It reports
the residual distribution on unique CRC-valid, eligible ToA records, together
with the planned/usable denominators. These are conditional relative
repeatability statistics. The fit removes offset and linear drift: it cannot
measure RF input bias, absolute ToA accuracy or inter-receiver synchronization.
Retain those distinctions in plots and publications.
For injected CFO trials it additionally fits only the zero-CFO control records
and evaluates other CFO groups against that fit, so a joint fit does not hide
CFO-dependent bias. This control fit uses the median pairwise slope and median
intercept so a rare whole-symbol error does not move every group's reference.
All records, including control outliers, remain in the reported residuals.
Sample-drop counter changes anywhere among the packet reads
invalidate continuity of the point's relative timebase, even if a particular
packet's own before/after counts match.
