# ToA/TDoA qualification gates / Критерии квалификации

Snapshot: 2026-09-24. Tracks [#28](https://github.com/Lay007/zynq-lora-phy-positioning/issues/28)
and [#29](https://github.com/Lay007/zynq-lora-phy-positioning/issues/29); both remain open.
First drafted in PR #30 at the M6 step; rewritten here against the evidence since.

**Naming.** The roadmap's milestones (M4 symbol receiver, M5 single-receiver
ToA, M6 synchronized TDoA) are not the numbered steps of the
[experiment log](clg400-joint-grid-experiment.md) (M4 sticky diagnostics, M5
sub-sample interpolation, M6 `trace_rearm`, M7 straddle detection, M8 miss
diagnostics). All of the log's steps so far belong to roadmap M4/M5.

## Evidence boundary / Граница доказательств

Board: one CLG400 receiver, Heltec V4/SX1262 transmitter about 1 m over the
air, SF7/BW125/L=8, manual gain 25 dB. On the current image (M7 with the
silence guard, `eac45bda...`):

| | count |
|---|---|
| attempts | 806 |
| captured (IQ and PL trace) | 793 |
| transmitter-side failures (profile readback, `send` timeout) | 8 |
| detection misses (packet in the recording, detector never fired) | 5 of 798 recordings with a packet, 0.63% (Wilson 95% about 0.27-1.46%) |
| CRC valid among captures | 787 of 793; the 6 failures are 1-sample grid errors, all in the first ~35 minutes after a cold boot |
| accepted only through the straddle path | 46, all decode |

Before the step-M7 detector fix: 12 of 196 misses (6.1%). One absolute sample
timebase over a whole series is confirmed on hardware (803.7 s, step M6). What
none of this is: a PER measurement over a controlled channel, a ToA accuracy
figure, a calibration, or anything about two receivers. CRC success and zero
grid error say the symbol grid is right, not that the final ToA is accurate.

The raw recordings of these series are archived with a SHA-256 manifest per
run in a separate artifacts repository that is not public yet; until it is,
this is not independently reproducible hardware evidence.

На текущем образе: 806 попыток, 793 захвата, 8 сбоев на стороне передатчика,
5 пропусков детекции из 798 записей с пакетом (0,63%), 787 из 793 CRC (все 6
отказов — ошибки сетки в 1 отсчёт в первые ~35 минут после холодной загрузки),
46 пакетов straddle-пути декодируются все. До исправления детектора было 12
пропусков из 196. Непрерывная шкала отсчётов подтверждена на плате. Это не PER
на контролируемом канале, не точность ToA, не калибровка и не два приёмника.
Сырые записи заархивированы с манифестами SHA-256 в отдельном, пока закрытом
репозитории.

## Open questions before any ToA claim / Открытые вопросы

- **Detection misses.** None of the five reproduces when its recording is
  replayed through the RTL at any arrival phase. The recording comes from the
  vendor DMA branch, the receiver from `lora_async_sample_fifo`; the crossing
  is known to have dropped samples at least once since the last boot (sticky
  flag), when is unknown. The step-M8 image adds an exact drop count and a
  ring of every detector decision frozen at the end of each recording; built,
  not deployed.
- **Grid errors after a cold boot.** Six 1-sample errors, all while the model
  CFO displacement was below -3.38 samples. Tested offline: neither the float
  model nor the RTL shows any CFO dependence of the rounding in the range the
  board visited. Time since boot remains; not separated.
- **Final ToA versus grid correction.** The fractional metadata comes from
  the upchirp peak, the grid correction from the joint up/down estimate.
  Whether the final ToA keeps a CFO dependence (#28 section 1) has not been
  measured; the offline test above covered the grid correction only.

## Ordered next steps / Порядок следующих шагов

| Gate | Done | Safe offline work | Required bench evidence |
|---|---|---|---|
| Timestamp contract (#28, #29) | 64-bit counter continuous across a series; re-arm without reset | State first confirmed preamble event, profile, signed fraction/carry, rollover; distinguish DMA anchor from packet ToA | RF reference and first-IQ-sample to PL epoch mapping; detect DMA and crossing gaps (crossing count: step M8) |
| Detection (#28) | Phase sweep 0-1023 incl. input without a packet; blind band closed; false detections on silence found and guarded | Compare board decision history with RTL replay for each miss (`tools/compare_history_to_replay.py`) | Deploy the M8 image; a series long enough to catch several misses with their history |
| ToA qualification (#28) | Every attempt recorded, failures included (`summarize_capture_run.py --planned-attempts`) | Independent delay/CFO/SFO sweeps of the **final** metadata, both CFO signs, symbol boundaries; predeclare bias/p95/p99/outlier/miss limits | Every attempt with TX/metadata/capture IDs, flags, IQ hash, build and RF configuration; no success-only denominator; 1000 planned transmissions |
| Calibration (#28, #29) | - | Define measurement plane and uncertainty table with unknown values left blank | Fixed-gain cable delay increments, RF ground truth, calibration residual, repeat after reset/configuration changes |
| Synchronization (#29) | - | Audit CLG400 clock/epoch pins and CDC; use ADR 0005 | Two receivers on one split RF input, common clock **and** epoch, residual offset/drift after cold boot |
| Positioning (#29) | - | Propagate full ToA covariance through pairwise subtraction and solver Jacobian; study geometry and ambiguity | Three calibrated receivers, surveyed points, timing residuals and position-error distributions with counts |

Each row stays open until its evidence exists. A host send timestamp is not RF
ground truth; Q12 resolution is not timestamp accuracy. For a reference
receiver 0, `Cov(t_i-t_0, t_j-t_0)` includes the shared reference error: even
independent receiver errors yield correlated TDoA observations, so do not add
RMS components without recording the independence/correlation assumptions.

For a saved capture campaign:

```bash
python tools/summarize_capture_run.py experiments/runs/RUN --planned-attempts 1000
```

Missing or unclassifiable records make the exit status non-zero. Capture
failures stay separate from CRC failures and from detection misses.

Каждый этап закрывается по артефактам. Изменение gain/FIR/частоты требует
проверки применимости калибровки.

The offline MATLAB estimator ID is `matched-filter-log-magnitude-v1`: guarded
three-point interpolation on the log magnitude, bounded to +/-0.5 sample.
Record the code commit and parameters with every result. Historical
measurement JSON is immutable.
