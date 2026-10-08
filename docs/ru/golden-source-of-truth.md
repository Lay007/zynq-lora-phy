# Golden source of truth проекта LoRa PHY

Этот документ фиксирует, **какая реализация считается эталонной** для разных уровней `zynq-lora-phy` и как должны сравниваться MATLAB, Python, Simulink, HDL, Inspector и реальные RF-записи.

Цель правила — исключить ситуацию, когда несколько реализаций расходятся, но непонятно, какая из них правильная.

## 1. Термины

### Golden model

**Golden model** — авторитетная математическая модель алгоритма. Для основной математики LoRa PHY в этом проекте таким эталоном является **floating-point MATLAB model**.

Если C++, Python, Simulink или HDL расходятся с floating-point MATLAB при одинаковых параметрах и входных данных, расхождение должно быть объяснено и проверено. Сам факт того, что другая реализация «работает», не делает её новым эталоном.

### Golden vector

**Golden vector** — зафиксированный набор чисел, полученный из эталонной модели и используемый для автоматического regression-теста.

Примеры:

- IQ-отсчёты одного chirp;
- последовательность CSS-symbol indices;
- промежуточные nibble/codeword/interleaver vectors;
- машинно-читаемый `model/matlab/golden/lora-phy-sf7-cr1.json`;
- stage vectors для FFT-correlator.

Golden vector удобен тем, что DUT можно проверить без повторной реализации всей эталонной математики внутри testbench.

### Reference capture

**Reference capture** — сохранённая реальная IQ-запись от известного передатчика и с известными настройками.

В этом проекте записи SX1262/LR1121 используются как **hardware reference evidence**, но не заменяют математический golden model. Реальная запись содержит CFO, шум, RF-фильтрацию, clock error, AGC, multipath и другие аппаратные эффекты.

Итого:

```text
Golden model     = математический эталон
Golden vector    = конкретные эталонные числа
Reference capture = эталонное аппаратное свидетельство
```

## 2. Иерархия доверия

Для алгоритмов PHY используется следующая логика:

```text
Semtech-compatible PHY specification
              ↓
MATLAB floating-point golden model
              ↓
MATLAB golden vectors / regression tests
              ↓
Python / Simulink / fixed-point implementations
              ↓
VHDL / Verilog DUT
              ↓
GHDL / Icarus / XSim simulation evidence
              ↓
FPGA + RFIC
              ↓
real OTA/cable IQ captures
              ↓
LoRa PHY Inspector / packet decoder
```

Это не означает, что MATLAB не может содержать ошибку. Если MATLAB расходится с официальной документацией Semtech или с воспроизводимым поведением нескольких реальных Semtech RFIC, сначала расследуется первопричина, после чего **эталон и все dependent vectors меняются осознанно одним согласованным изменением**.

## 3. Соответствие частей LoRa PHY файлам проекта

| Часть PHY | Авторитетный источник / golden | Реализации и DUT | Проверка |
|---|---|---|---|
| CSS reference chirp | `model/matlab/+lora_phy/reference_chirp.m` | `hdl/srcs/formiration_chirp.vhd`, `hdl/srcs/phase_to_sample.vhd` | `hdl/tb/test_formiration_chirp_golden.vhd`, MATLAB IQ comparison |
| CSS symbol modulation | `model/matlab/+lora_phy/modulate_symbol.m` | HDL chirp generator | all-symbol SF7 regression, 2048 samples/symbol |
| Базовая research CSS frame | `model/matlab/+lora_phy/build_css_frame.m`, `preamble_waveform.m` | соответствующие acquisition experiments | MATLAB tests; **не путать со стандартным LoRa packet framing** |
| Standard LoRa packet waveform | `model/matlab/+lora_phy/build_lora_packet.m` и связанные MATLAB PHY functions | packet TX/RX chain; HDL packet TX пока неполный | MATLAB packet tests + реальные SX1262 captures |
| Preamble / sync / SFD | MATLAB standard packet/on-air receiver model | detector / receiver logic; HDL packet generator пока частично | standard on-air receiver tests, OTA captures |
| Explicit PHDR | MATLAB packet coding model | `src/zynq_lora_phy/lora_packet.py` | PHDR checksum regression, real packet decode |
| Whitening | MATLAB packet coding model | `src/zynq_lora_phy/lora_packet.py` | known whitening prefix + round-trip tests |
| FEC 4/5…4/8 | MATLAB packet coding model | Python decoder; later HDL/fixed-point DUT | codebook and round-trip regression |
| Diagonal interleaving | MATLAB packet coding model | Python decoder; later HDL/fixed-point DUT | interleave/deinterleave regression |
| Gray/CSS label mapping | MATLAB packet coding model | Python decoder, HDL symbol mapping where applicable | golden symbol vectors |
| Payload CRC | MATLAB packet coding model | `src/zynq_lora_phy/lora_packet.py` | fixed vectors + real packet CRC validation |
| Hard packet decode | MATLAB receiver model | `src/zynq_lora_phy/lora_packet.py` | MATLAB/Python agreement + OTA captures |
| IQ quality metrics | MATLAB golden waveform | `model/matlab/+lora_phy/compare_iq_to_golden.m` | EVM, normalized correlation, phase error |
| HDL package waveform | MATLAB chirp/symbol convention + explicit test sequence | `hdl/srcs/formiration_package.vhd` | `hdl/tb/test_formiration_package_golden.vhd` |
| Inspector parameter estimates | known synthetic parameters + capture manifest | `model/matlab/apps/lora_phy_inspector.m` | synthetic tests + SX1262/LR1121 reference capture CI |
| Hardware compatibility | known RFIC settings / manifest | SX1262, LR1121, Zynq/AD936x chain | reference captures and reproducible hardware experiments |

## 4. Главный golden для chirp и символа

Для chirp/symbol math authoritative source — floating-point MATLAB.

Проверяемая цепочка выглядит так:

```text
reference_chirp.m
      ↓
modulate_symbol.m
      ↓
expected complex IQ
      ↓
quantization / implementation
      ↓
VHDL output
      ↓
CI16 PCM
      ↓
compare_iq_to_golden.m
```

Для текущей проверенной HDL-конфигурации:

```text
SF = 7
BW = 125 kHz
Fs = 2 MHz
L = Fs/BW = 16 samples/chip
Ns = 2^SF * L = 2048 complex samples/symbol
```

GHDL regression проверяет все `h = 0...127` и оба направления chirp. HDL не становится golden только потому, что regression зелёный: зелёный regression означает, что DUT соответствует зафиксированной MATLAB-конвенции в проверенной конфигурации.

## 5. Golden для packet coding

Для bit-level packet coding главным executable reference остаётся MATLAB packet model и его regression vectors.

Особенно это относится к деталям, которые легко реализовать «почти правильно»:

- порядок nibble;
- систематические и parity bits FEC;
- reduced-rate first block;
- diagonal interleaving;
- Gray mapping;
- `+1` CSS-bin convention;
- PHDR checksum;
- LoRa-specific payload CRC convention;
- whitening sequence.

Машинно-читаемый regression vector:

```text
model/matlab/golden/lora-phy-sf7-cr1.json
```

Python `src/zynq_lora_phy/lora_packet.py` является **независимой проверяемой реализацией**, а не отдельным конкурирующим источником истины. Его ценность именно в том, что он может обнаружить ошибку или неоднозначность MATLAB-модели при независимом совпадении с реальным RFIC.

## 6. Статус Simulink и fixed-point

Simulink/fixed-point модели являются DUT следующего уровня.

Требование:

```text
MATLAB floating point
        ↓
fixed-point / Simulink
        ↓
quantified error
```

Расхождение допустимо только в пределах заранее определённых численных эффектов:

- quantization;
- rounding;
- saturation;
- finite accumulator width;
- pipeline latency.

Для таких различий необходимо измерять, а не просто визуально сравнивать:

- EVM;
- RMS/max sample error;
- phase error;
- symbol-decision equivalence;
- BER/PER при одинаковом impairment set.

## 7. Статус HDL

VHDL/Verilog — **DUT, а не golden**.

Для HDL используются два уровня проверки:

1. **математическая regression** — соответствует ли waveform MATLAB golden;
2. **implementation regression** — корректны ли handshake, FIFO, boundaries, sample count, pipeline latency и интерфейсы.

Текущие ключевые тесты:

```text
hdl/tb/test_formiration_chirp_golden.vhd
hdl/tb/test_formiration_package_golden.vhd
```

В GHDL proprietary Xilinx DDS заменяется behavioral model. Поэтому GHDL доказывает корректность VHDL-логики и принятой математической конвенции, но **не доказывает bit-exact поведение настоящего Xilinx DDS Compiler**.

Следующий уровень evidence для этого места — Vivado/XSim с настоящим IP, затем FPGA measurement.

## 8. Статус LoRa PHY Inspector

Inspector также не является golden source. Это **verification/measurement layer**.

Он должен отвечать на вопрос:

> Насколько анализируемый IQ соответствует известной или оцененной LoRa PHY модели?

Для искусственно сгенерированного HDL PCM Inspector может сравнивать запись непосредственно с MATLAB golden и выдавать:

- EVM;
- normalized correlation;
- RMS/max phase error;
- peak sample error;
- SF/BW;
- carrier offset/CFO.

End-to-end regression имеет смысл именно в таком направлении:

```text
MATLAB golden
      ↓
VHDL DUT
      ↓
GHDL-generated CI16 PCM
      ↓
Inspector
      ↓
PASS / FAIL
```

Inspector не должен сам определять, что его собственная оценка «истинна», без synthetic golden tests или известного capture manifest.

## 9. Статус реальных SX1262/LR1121 записей

Реальные OTA IQ-файлы являются **reference captures**.

Они отвечают на другой вопрос, чем synthetic golden:

> Совместима ли наша модель и наш receiver с реальным Semtech-class transmitter?

Reference capture должен по возможности иметь provenance:

- RFIC и плата;
- firmware/commit;
- frequency;
- SF/BW/CR;
- preamble length;
- sync word;
- explicit/implicit mode;
- CRC setting;
- TX power;
- RX center frequency и Fs;
- IQ format;
- дата/условия стенда.

Если Inspector/decoder правильно работает на synthetic golden, но не работает на известной SX1262 записи, это не повод «подправить golden под запись». Сначала следует локализовать отличие: RF filtering, CFO/SFO, framing, polarity, sync word, sample timing, quantization или ошибка модели.

## 10. Правило изменения эталона

Golden нельзя менять только ради того, чтобы упавший тест снова стал зелёным.

Изменение authoritative behavior должно сопровождаться:

1. объяснением причины;
2. ссылкой на Semtech documentation, воспроизводимый RF experiment или найденную ошибку модели;
3. обновлением MATLAB golden model;
4. регенерацией зависимых golden vectors;
5. проверкой Python/Simulink/HDL;
6. повторной проверкой reference captures;
7. обновлением документации.

Иначе regression теряет смысл.

## 11. Практическая схема при разработке нового блока

Для нового PHY-блока рекомендуемый порядок:

```text
1. Формула / PHY requirement
          ↓
2. MATLAB floating-point implementation
          ↓
3. Unit tests + golden vectors
          ↓
4. Independent Python/C++ check, если полезно
          ↓
5. Fixed-point / Simulink
          ↓
6. HDL DUT
          ↓
7. GHDL/Icarus regression
          ↓
8. Vivado/XSim/IP verification
          ↓
9. FPGA + RF capture
          ↓
10. Inspector / packet decode / measured metrics
```

Такой порядок позволяет точно ответить, **на каком уровне впервые появилось расхождение**.

## 12. Evidence boundary

Следует различать утверждения:

- `MATLAB PASS` — алгоритм прошёл модельные тесты;
- `Python agrees with MATLAB` — независимая software implementation совпала;
- `GHDL PASS` — HDL DUT совпал с regression в behavioral simulation;
- `XSim PASS` — vendor-specific simulation прошла;
- `implementation PASS` — synthesis/place-and-route удовлетворяют требованиям;
- `reference capture PASS` — receiver/Inspector совместимы с конкретной реальной записью;
- `hardware PASS` — результат подтверждён на физическом Zynq/RFIC стенде.

Нельзя автоматически заменять одно утверждение другим. Например, `GHDL PASS` не доказывает timing closure или RF performance, а успешная OTA запись не доказывает bit-exact корректность всех внутренних HDL samples.

## 13. Короткое правило проекта

Если требуется выбрать один ответ на вопрос «что считать правильным?», используется следующий порядок:

```text
Semtech-compatible specification / reproducible RF evidence
                     ↓
         MATLAB floating-point golden
                     ↓
            golden regression vectors
                     ↓
       independent software implementations
                     ↓
              Simulink/fixed-point
                     ↓
                  HDL DUT
                     ↓
              hardware evidence
```

При этом реальные RF measurements используются для **валидации самой модели**, а не для молчаливого обхода regression.

Связанные документы:

- [LoRa PHY: структура сигнала и формат кадра](lora-phy-protocol.md)
- [Whitening, FEC, interleaving, CRC и отображение символов](lora-phy-coding.md)
- [LoRa PHY Inspector](lora-phy-inspector.md)
- [Архитектура системы](architecture.md)
- [Методика BER/SER/PER](ber-methodology.md)
