# Проверка HDL-сигнала LoRa: IQ-записи и 5 контрольных точек TX

Этот каталог предназначен для проверки цифрового тракта формирования LoRa/CSS-сигнала по промежуточным IQ-записям.

Основной инструмент анализа — MATLAB-приложение **LoRa PHY Inspector**. Его задача — не просто показать спектр, а ответить на инженерный вопрос:

> **Совпадает ли сигнал в выбранной контрольной точке с эталонной MATLAB-моделью и, если нет, где именно возникло расхождение?**

Проверяемый тракт:

```text
[1] Формирователь chirp
        │ Fs = 2.000 MS/s
        ▼
[2] Формирователь package stream
        │ Fs = 2.000 MS/s
        ▼
[3] КИХ / rational resampler 24/25
        │ Fs = 1.920 MS/s
        ▼
[4] CIC interpolator ×32
        │ Fs = 61.440 MS/s
        ▼
[5] Частотный перенос / NCO
          Fs = 61.440 MS/s
```

Идея такой схемы проста: если точки 1 и 2 проходят проверку, а точка 3 — нет, искать ошибку нужно уже не в LoRa-формирователе, а в ресемплере. Аналогично для последующих ступеней.

---

## 1. Быстрый старт

Для текущей HDL-модели наиболее полно проверены **точки 1 и 2**.

### Проверка одного chirp

Файл должен называться, например:

```text
hdl_sf7_bw125k_fs2000k_chirp-h0-up.pcm
```

Запуск из MATLAB:

```matlab
cd hdl/signal
open_in_inspector("captures/hdl_sf7_bw125k_fs2000k_chirp-h0-up.pcm", Language="ru")
```

После открытия нажать **«Анализ»**.

Для корректного сигнала сверху должен появиться итог:

```text
ИТОГ: PASS — STAGE 1
```

### Проверка package stream

Файл:

```text
hdl_sf7_bw125k_fs2000k_package.pcm
```

Запуск:

```matlab
open_in_inspector("captures/hdl_sf7_bw125k_fs2000k_package.pcm", Language="ru")
```

Ожидаемый итог:

```text
ИТОГ: PASS — STAGE 2
```

При `WARN`, `FAIL` или `NOT VERIFIED` см. раздел **«Как искать ошибку»** ниже.

---

## 2. Что означает совокупный результат

Главный параметр Inspector — не отдельная корреляция и не EVM, а **совокупный статус**:

```text
PASS | WARN | FAIL | NOT VERIFIED
```

### PASS

Контрольная точка соответствует определённому для неё golden reference и выполняет все обязательные структурные и численные проверки.

Для точек 1 и 2 waveform-проверка использует следующие пороги:

```text
EVM                 <= 1 %
normalized corr.    >= 0.999
RMS phase error     <= 1°
```

Кроме этих метрик проверяется структура записи: количество отсчётов, число символов и ожидаемая последовательность.

### WARN

Структура сигнала распознана, но одна или несколько строгих waveform-метрик не прошли заданный порог.

Пример:

```text
EVM          = 5.67 %       -> выше 1 %
Correlation  = 0.99839      -> ниже 0.999
RMS phase    = 3.25°        -> выше 1°

ИТОГ: WARN
```

Высокая корреляция сама по себе не означает, что сигнал удовлетворяет требованиям.

### FAIL

Обнаружена структурная ошибка, из-за которой сигнал нельзя считать корректным результатом данного этапа.

Примеры:

- неверное количество complex samples;
- неправильная частота дискретизации для выбранной точки;
- недопустимый номер символа `h`;
- не совпадает ожидаемая последовательность package;
- файл недостаточной длины;
- metadata имени противоречат содержимому/настройкам.

### NOT VERIFIED

Контрольная точка распознана, но в проекте пока **нет точной исполняемой эталонной модели production-блока**, с которой можно честно выполнить sample-to-sample проверку.

Сейчас это относится к точкам 3–5.

`NOT VERIFIED` — не ошибка сигнала и не `PASS`. Это означает:

> **данная ступень ещё не обеспечена достаточной golden-верификацией.**

---

## 3. Сводная таблица контрольных точек

| Точка | Выход блока | Fs | Что проверяется сейчас | Статус golden |
|---|---|---:|---|---|
| 1 | отдельный LoRa/CSS chirp | 2.000 MS/s | sample count, EVM, correlation, phase error | полностью реализован |
| 2 | текущий `formiration_package` stream | 2.000 MS/s | весь поток, все символы, переходы, aggregate EVM | полностью реализован |
| 3 | FIR / resampler 24/25 | 1.920 MS/s | metadata, Fs, общий DSP-анализ | `NOT VERIFIED` до фиксации production FIR |
| 4 | CIC ×32 | 61.440 MS/s | metadata, Fs, общий DSP-анализ | `NOT VERIFIED` до фиксации CIC |
| 5 | mixer / NCO | 61.440 MS/s | metadata, Fs, общий DSP-анализ | `NOT VERIFIED` до фиксации NCO/mixer |

---

# 4. Контрольная точка 1 — отдельный chirp

На этой точке проверяется **один конкретный CSS-символ**, сформированный HDL-блоком chirp generator.

Для текущей проверенной конфигурации:

```text
SF = 7
BW = 125 kHz
Fs = 2.000 MS/s
L = Fs / BW = 16 samples/chip
```

Число chips в символе:

```text
N = 2^SF = 128
```

Число complex samples:

```text
Ns = 2^SF × L
   = 128 × 16
   = 2048
```

Формат CI16 занимает 4 байта на один комплексный отсчёт, поэтому размер файла должен быть:

```text
2048 × 4 = 8192 bytes
```

## Что проверяет Inspector

Для Stage 1 проверяются:

- номер LoRa/CSS-символа `h`;
- направление chirp: `up` или `down`;
- точное число complex samples;
- соответствие MATLAB floating-point waveform;
- EVM;
- normalized correlation;
- RMS phase error;
- maximum phase error;
- peak normalized sample error;
- complex gain/phase;
- временное выравнивание относительно golden reference.

Golden waveform строится MATLAB-функциями:

```text
model/matlab/+lora_phy/reference_chirp.m
model/matlab/+lora_phy/modulate_symbol.m
```

## Имена файлов

```text
hdl_sf7_bw125k_fs2000k_chirp-h0-up.pcm
hdl_sf7_bw125k_fs2000k_chirp-h17-up.pcm
hdl_sf7_bw125k_fs2000k_chirp-h64-down.pcm
hdl_sf7_bw125k_fs2000k_chirp-h127-up.pcm
```

Имя:

```text
hdl_sf7_bw125k_fs2000k_chirp.pcm
```

не допускается: из него неизвестно, какой `h` сформирован и какое направление chirp используется.

---

# 5. Контрольная точка 2 — package stream

Stage 2 проверяет не один символ, а **весь текущий выход `formiration_package`**.

Это важное уточнение: термин `package` здесь означает внутренний HDL package-stream contract проекта, а **не полный стандартный LoRa PHY packet**.

Текущая последовательность:

```text
symbol 0 : h=0   up
symbol 1 : h=0   up
symbol 2 : h=0   up
symbol 3 : h=0   up
symbol 4 : h=0   up
symbol 5 : h=0   up
symbol 6 : h=5   up
symbol 7 : h=17  up
symbol 8 : h=64  down
symbol 9 : h=127 up
```

То есть:

```text
6 × h=0 upchirp
+ h=5 up
+ h=17 up
+ h=64 down
+ h=127 up
```

Всего:

```text
10 symbols
10 × 2048 = 20480 complex samples
20480 × 4 = 81920 bytes
```

## Что проверяется

Inspector/verification layer контролирует:

- ровно `20480/20480` complex samples;
- ровно `10/10` ожидаемых символов;
- значение `h` каждого символа;
- направление каждого chirp;
- каждый символ против собственного MATLAB golden;
- EVM каждого символа;
- correlation каждого символа;
- RMS phase error каждого символа;
- mean EVM по всему потоку;
- worst EVM;
- worst correlation;
- worst RMS phase error;
- общую waveform-проверку всего 10-symbol потока;
- тем самым — непрерывность всех девяти межсимвольных переходов.

Это позволяет обнаружить ошибки, которые не видны при тестировании отдельного chirp, например:

```text
последний sample symbol N
         ↓
ошибка FSM / FIFO / valid-ready
         ↓
первый sample symbol N+1
```

## Что Stage 2 пока НЕ доказывает

Текущий `formiration_package` ещё не является полной реализацией стандартного LoRa PHY framing.

Поэтому Stage 2 сам по себе не доказывает наличие корректных:

- LoRa Sync Word;
- полного SFD 2.25 downchirp;
- PHDR;
- payload coding;
- whitening;
- FEC;
- interleaving;
- payload CRC.

Для этого в будущем нужна отдельная контрольная сущность уровня **полного LoRa PHY frame**.

---

# 6. Контрольная точка 3 — ресемплер 24/25

После Stage 2 частота дискретизации должна быть уменьшена:

```text
2.000 MS/s × 24/25 = 1.920 MS/s
```

То есть коэффициент преобразования:

```text
R = 0.96
```

Предполагаемое имя записи:

```text
hdl_sf7_bw125k_fs1920k_resampler.pcm
```

## Почему нельзя сравнивать этот поток с Stage 2 напрямую sample-to-sample

После изменения sample rate временная сетка другая:

```text
Stage 2                  Stage 3
2.000 MS/s               1.920 MS/s
sample n                 sample m
     │                        │
     └── не соответствует ────┘
```

Поэтому golden reference должен повторять то же преобразование:

```text
MATLAB LoRa golden @ 2.000 MS/s
           ↓
reference FIR / rational resampler 24/25
           ↓
MATLAB golden @ 1.920 MS/s
```

## Что требуется зафиксировать для полноценного PASS

Для production FIR/resampler должны быть известны:

- коэффициенты фильтра;
- структура polyphase/FIR;
- interpolation factor = 24;
- decimation factor = 25;
- group delay;
- начальная фаза полифазного фильтра;
- word lengths;
- коэффициенты масштабирования;
- правила округления/усечения;
- поведение на начале и конце пакета.

Пока эти параметры не представлены в репозитории как executable reference, Inspector намеренно показывает:

```text
NOT VERIFIED
```

---

# 7. Контрольная точка 4 — CIC-интерполяция ×32

После ресемплера:

```text
Fs3 = 1.920 MS/s
```

После CIC:

```text
Fs4 = 1.920 × 32
    = 61.440 MS/s
```

Имя:

```text
hdl_sf7_bw125k_fs61440k_cic.pcm
```

Для полноценной проверки CIC необходимо знать:

- `R` — коэффициент интерполяции;
- `N` — число каскадов интегратор-гребёнка;
- `M` — differential delay;
- внутренний gain;
- bit growth;
- разрядности каскадов;
- места truncation/rounding;
- выходное масштабирование;
- latency;
- ожидаемый passband droop.

Golden-путь должен быть:

```text
Stage 3 MATLAB golden @ 1.920 MS/s
             ↓
reference CIC ×32
             ↓
Stage 4 MATLAB golden @ 61.440 MS/s
```

На этом этапе кроме EVM важно контролировать спектральные характеристики:

- droop в рабочей полосе LoRa;
- interpolation images;
- уровень паразитных составляющих;
- изменение амплитуды;
- точное количество выходных отсчётов.

До появления точного production CIC contract Stage 4 имеет статус `NOT VERIFIED`.

---

# 8. Контрольная точка 5 — частотный перенос

Последняя точка — сигнал после NCO/mixer.

Частота дискретизации остаётся:

```text
Fs5 = 61.440 MS/s
```

Имя:

```text
hdl_sf7_bw125k_fs61440k_mixer.pcm
```

На этой точке LoRa waveform уже находится не около DC, а на заданном frequency offset внутри полосы 61.44 MHz.

Полная проверка должна выполняться в два этапа:

```text
записанный Stage 5 signal
          ↓
оценка / известное значение frequency shift
          ↓
обратный перенос в baseband
          ↓
сравнение с Stage 4 golden
```

Будущие критерии Stage 5:

- ошибка фактической частоты переноса;
- остаточный frequency offset после обратного переноса;
- EVM;
- correlation;
- RMS phase error;
- spectral purity;
- наличие нежелательного image;
- sample count;
- continuity на границах package.

Для полноценной проверки должны быть известны:

- tuning word NCO;
- phase accumulator width;
- LUT/DDS convention;
- sign convention mixer;
- стартовая фаза;
- latency;
- округление/усечение I/Q.

До этого Stage 5 имеет статус `NOT VERIFIED`.

---

# 9. Формат IQ-файла CI16

Все HDL PCM для Inspector используют raw binary без заголовка:

```text
signed int16, little-endian
I0, Q0, I1, Q1, I2, Q2, ...
```

Один complex sample занимает 4 байта:

```text
byte 0..1 : I0
byte 2..3 : Q0
byte 4..5 : I1
byte 6..7 : Q1
...
```

HDL-слово:

```text
31                         16 15                          0
+----------------------------+----------------------------+
|        I / real int16      |        Q / imag int16      |
+----------------------------+----------------------------+
```

То есть:

```text
data_out[31:16] = I = real
data_out[15:0]  = Q = imag
```

Writer:

```text
hdl/tb/ci16_file_io_pkg.vhd
```

явно записывает байты в порядке:

```text
I_lo, I_hi, Q_lo, Q_hi
```

MATLAB читает поток как little-endian `int16` и нормирует его на `32768`.

При текущей Q14-подобной амплитуде HDL типичный модуль комплексного сигнала после загрузки оказывается около:

```text
|x| ≈ 0.5
```

Это ожидаемо и не означает потерю амплитуды.

---

# 10. Правила именования файлов

Общий шаблон:

```text
hdl_sf<SF>_bw<BW_KHZ>k_fs<FS_KHZ>k_<TAG>.pcm
```

Поддерживаемые варианты:

```text
Stage 1:
hdl_sf<SF>_bw<BW>k_fs<FS>k_chirp-h<SYMBOL>-up.pcm
hdl_sf<SF>_bw<BW>k_fs<FS>k_chirp-h<SYMBOL>-down.pcm

Stage 2:
hdl_sf<SF>_bw<BW>k_fs<FS>k_package.pcm

Stage 3:
hdl_sf<SF>_bw<BW>k_fs<FS>k_resampler.pcm

Stage 4:
hdl_sf<SF>_bw<BW>k_fs<FS>k_cic.pcm

Stage 5:
hdl_sf<SF>_bw<BW>k_fs<FS>k_mixer.pcm
```

Для текущего тракта:

```text
Stage 1 : Fs = 2000 kHz
Stage 2 : Fs = 2000 kHz
Stage 3 : Fs = 1920 kHz
Stage 4 : Fs = 61440 kHz
Stage 5 : Fs = 61440 kHz
```

Raw PCM сам по себе не содержит SF/BW/Fs/тип контрольной точки, поэтому корректное имя файла является частью интерфейсного контракта.

---

# 11. Автоматический и ручной выбор контрольной точки

В Inspector имеется поле:

```text
Контрольная точка TX
```

Режимы:

```text
Auto from filename
1 — Chirp 2.000 MS/s
2 — Package 2.000 MS/s
3 — Resampler 1.920 MS/s
4 — CIC 61.440 MS/s
5 — Shift 61.440 MS/s
```

Рекомендуется использовать **Auto from filename**.

Ручной выбор полезен только для диагностики. Он не должен использоваться для маскировки неправильно названной записи.

Для HDL PCM параметры SF/BW/Fs берутся из имени файла. Это особенно важно для отдельного chirp: blind estimation SF/BW по одному chirp может быть неоднозначной и не должна переопределять известные metadata.

---

# 12. Как понимать основные метрики

## EVM

EVM показывает нормированное RMS-расстояние между принятым комплексным сигналом и эталоном после компенсации единого complex gain/phase.

Чем меньше — тем лучше.

Для текущего чистого цифрового regression:

```text
PASS threshold: EVM <= 1 %
```

На практике для GHDL/MATLAB без реального аналогового тракта ожидается значение значительно лучше 1 %.

## Correlation

Normalized correlation показывает сходство формы сигнала с golden waveform.

```text
1.0      — практически идеальное совпадение
0.999+   — текущий regression threshold
```

Но correlation нельзя использовать как единственный критерий: небольшая систематическая фазовая ошибка может сохранять высокую корреляцию и одновременно существенно ухудшать EVM.

## RMS phase error

Показывает среднеквадратическое расхождение фазы после удаления общего complex gain/phase.

Текущий порог:

```text
<= 1°
```

Нарастающая от начала к концу chirp phase error часто указывает на ошибку закона изменения частоты/фазы, а постоянная ошибка — на стартовую фазу или alignment.

## Peak sample error

Максимальное отклонение одного нормированного complex sample.

Полезно для поиска локальных дефектов:

- одного неверного sample;
- off-by-one на границе;
- выброса FIFO;
- ошибки при переходе между символами.

---

# 13. Golden source of truth

Для проверки цифрового TX используется следующая иерархия:

```text
LoRa PHY / математический контракт
             ↓
MATLAB floating-point golden
             ↓
golden vectors / executable verification
             ↓
HDL DUT
             ↓
CI16 recording
             ↓
LoRa PHY Inspector
```

HDL **не считается источником истины для собственной проверки**.

Основной golden для chirp/symbol waveform:

```text
model/matlab/+lora_phy/reference_chirp.m
model/matlab/+lora_phy/modulate_symbol.m
```

Проверка контрольных точек:

```text
model/matlab/+lora_phy/verify_tx_checkpoint.m
```

Независимое аппаратное подтверждение в будущем:

```text
Vivado/XSim
      ↓
Zynq + AD936x
      ↓
RF/cable/OTA capture
      ↓
Inspector
```

---

# 14. История старого `output_hdl.pcm`

Ранее существовал файл:

```text
hdl/signal/output_hdl.pcm
```

Позже тот же Git blob оказался добавлен под именем:

```text
hdl_sf7_bw125k_fs2000k_chirp.pcm
```

Побайтовая проверка показала важное уточнение: конкретный XSim-файл действительно можно интерпретировать как корректный little-endian CI16 `I,Q`. Поэтому сам способ сериализации нельзя считать доказанной причиной ошибки.

Но содержимое файла не соответствует текущему контракту:

```text
size = 90132 bytes
complex samples = 90132 / 4 = 22533
```

Для одного SF7/BW125/Fs2M chirp ожидается:

```text
2048 samples
8192 bytes
```

Для текущего Stage 2 package:

```text
20480 samples
81920 bytes
```

Старая запись:

```text
22533 = 11 × 2048 + 5 samples
```

Следовательно, она не является ни одним текущим chirp, ни текущим package-stream regression.

Кроме того, запись была получена старой реализацией chirp/phase logic, которая впоследствии была исправлена относительно MATLAB golden.

Поэтому правильная формулировка:

```text
byte layout старого output_hdl.pcm — похож на корректный CI16
waveform/transaction history       — устаревшие
current golden reference           — не соответствует
```

---

# 15. Почему PCM не хранятся в Git

`*.pcm` — это **генерируемые артефакты симуляции**.

Их source of truth:

```text
HDL source
+ testbench
+ golden model
```

а не бинарный PCM.

Хранение PCM в Git опасно, потому что можно:

- закоммитить устаревшую запись;
- переименовать старый blob и принять его за новый результат;
- получить несоответствие имени и реального содержимого;
- анализировать локальный PCM, тогда как CI проверяет другой fresh-generated файл;
- невозможно нормально просмотреть binary diff на code review.

Поэтому CI содержит защиту от tracked PCM в `hdl/signal`.

---

# 16. Автоматическая end-to-end проверка

Workflow:

```text
.github/workflows/hdl-signal-ci.yml
```

проверяет цепочку:

```text
production VHDL
      ↓
GHDL
      ↓
behavioral DDS/FIFO
      ↓
self-checking testbench
      ↓
CI16 writer
      ↓
fresh *.pcm
      ↓
MATLAB loader
      ↓
TX checkpoint verification
      ↓
LoRa PHY Inspector / report
      ↓
MATLAB golden
```

Для Stage 2 self-checking testbench:

```text
hdl/tb/test_formiration_package_golden.vhd
```

ожидает ровно:

```text
20480 complex samples
```

и дополнительно проверяет каждый I/Q sample до записи PCM.

Это означает, что CI проверяет не заранее подготовленный бинарник, а **результат актуального HDL-кода**.

---

# 17. Как искать ошибку

Рекомендуемый порядок диагностики — всегда слева направо по контрольным точкам.

```text
Stage 1 PASS?
   │
   ├─ нет → chirp generator / phase / DDS / I/Q / sample count
   │
   ▼
Stage 2 PASS?
   │
   ├─ нет → package FSM / FIFO / valid-ready / symbol transitions
   │
   ▼
Stage 3 PASS?
   │
   ├─ нет → FIR / rational resampler
   │
   ▼
Stage 4 PASS?
   │
   ├─ нет → CIC / scaling / bit growth
   │
   ▼
Stage 5 PASS?
   │
   └─ нет → NCO / mixer / frequency shift
```

### Если EVM высокая, а correlation почти 1

Проверить:

- накопление фазовой ошибки;
- небольшую ошибку частоты;
- стартовый sample;
- sample alignment;
- scaling/rounding.

### Если ошибка только в начале chirp

Проверить:

- стартовую фазу;
- порядок `phase increment` / `DDS sample`;
- latency DDS;
- первый `valid_out`.

### Если ошибка растёт к концу chirp

Проверить:

- phase increment;
- finite-difference закона chirp;
- wrap phase/frequency;
- фиксированную точку и округление.

### Если отдельные chirp PASS, а package FAIL

Проверить:

- `formiration_package` FSM;
- FIFO;
- `valid/ready` handshake;
- duplicate/missing symbol;
- off-by-one на границах;
- сохранение состояния между символами.

### Если Stage 2 PASS, а Stage 3 не проходит

LoRa-формирователь уже можно считать локализованно исправным. Проверку нужно переносить на ресемплер.

---

# 18. Что считается доказанным сейчас

Для **SF7 / BW125 / L=16 / Fs=2.000 MS/s** regression подтверждает:

- все `h=0...127` для upchirp;
- все `h=0...127` для downchirp;
- ровно 2048 samples/chirp;
- отсутствие лишнего 2049-го sample;
- корректный порядок I/Q;
- CI16 little-endian file contract;
- текущий 10-symbol `formiration_package` waveform;
- переходы между символами в текущем package-stream;
- загрузку freshly-generated PCM в MATLAB;
- golden EVM/correlation/phase verification.

---

# 19. Что пока НЕ считается доказанным

Текущие тесты пока не доказывают:

- полный standard LoRa PHY TX frame в HDL;
- полноценные Sync/SFD/PHDR/payload/FEC/interleaving/CRC в TX HDL;
- все SF/BW/Fs;
- bit-exact совпадение с proprietary Xilinx DDS Compiler в Vivado/XSim;
- production FIR/resampler Stage 3;
- production CIC Stage 4;
- production NCO/mixer Stage 5;
- synthesis/implementation/STA;
- аппаратный sample-rate contract;
- передачу через AD936x;
- RF/cable/OTA качество всего HDL TX.

---

# 20. Практический чек-лист новой записи

Перед анализом PCM проверить:

- [ ] запись сформирована актуальным testbench;
- [ ] размер файла кратен 4 байтам;
- [ ] формат — signed CI16 little-endian;
- [ ] порядок — `I,Q,I,Q,...`;
- [ ] имя однозначно содержит SF/BW/Fs/контрольную точку;
- [ ] Stage 1 дополнительно содержит `h` и `up/down`;
- [ ] частота дискретизации соответствует выбранной точке;
- [ ] количество samples соответствует ожидаемой длительности;
- [ ] Inspector автоматически выбрал правильный Stage;
- [ ] для Stage 1/2 получен `PASS` либо изучена причина `WARN/FAIL`;
- [ ] Stage 3/4/5 не трактуются как проверенные, пока для них нет executable golden;
- [ ] после изменений HDL пройден CI.

---

# 21. Связанные файлы

### HDL

```text
hdl/srcs/formiration_chirp.vhd
hdl/srcs/phase_to_sample.vhd
hdl/srcs/formiration_package.vhd
```

### Testbench

```text
hdl/tb/test_formiration_chirp_golden.vhd
hdl/tb/test_formiration_package_golden.vhd
hdl/tb/test_formiration_package.vhd
hdl/tb/ci16_file_io_pkg.vhd
```

### MATLAB golden и Inspector

```text
model/matlab/+lora_phy/reference_chirp.m
model/matlab/+lora_phy/modulate_symbol.m
model/matlab/+lora_phy/compare_iq_to_golden.m
model/matlab/+lora_phy/verify_tx_checkpoint.m
model/matlab/+lora_phy/parse_hdl_recording_name.m
model/matlab/+lora_phy/load_iq_capture.m
model/matlab/+lora_phy/inspect_iq_capture.m
model/matlab/apps/lora_phy_inspector.m
```

### Запуск Inspector

```text
hdl/signal/open_in_inspector.m
```

### CI

```text
.github/workflows/hdl-signal-ci.yml
.github/workflows/inspector-reference-ci.yml
```

---

## Главное правило

При разработке следующего блока не нужно пытаться определить «весь тракт работает или нет» по одному конечному графику.

Используется последовательная локализация:

```text
1 PASS → доверяем chirp generator
2 PASS → доверяем package generator
3 PASS → доверяем resampler
4 PASS → доверяем CIC
5 PASS → доверяем frequency shifter
```

Так каждая следующая контрольная точка проверяет **только новое преобразование**, а предыдущая успешно проверенная точка становится входным подтверждённым базисом для следующего этапа.
