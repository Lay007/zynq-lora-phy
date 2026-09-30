# Zynq LoRa PHY и позиционирование

[English version](README.md)

Проект реализации LoRa PHY, точного определения времени прихода сигнала (ToA)
и позиционирования по разности времён прихода (TDoA) на FPGA/SDR-платформе
ZynqSDR.

Это инженерная и исследовательская платформа, а не замена маломощному серийному
LoRa-трансиверу. Её задача — сделать наблюдаемой всю цепочку PHY и обеспечить
воспроизводимый переход от эталонной MATLAB-модели с плавающей точкой через
Simulink и автоматически сгенерированный Verilog к аппаратной реализации.

Компактный учебный маршрут generic CSS и читаемый SF7 RTL baseline находятся в
сопутствующем проекте
[`zynq-sdr-course`](https://github.com/Lay007/zynq-sdr-course). Граница проектов
зафиксирована в [ADR](docs/architecture-decisions/0003-course-project-boundary.md),
поэтому сгенерированный LoRa HDL не дублируется в курсе.

> Текущее состояние: MATLAB M1 и потоковый fixed-point этап M2 завершены;
> для M3 сгенерирован Verilog, ToA прошёл точную HDL cosimulation 8/8,
> generated cores упакованы как Vivado IP, а полный CLG400 design разведён и
> загружается с SD на ZynqSDR. Аппаратный приём уже подтверждён: реальные
> эфирные пакеты Heltec V4.3/SX1262 декодируются на ZynqSDR с корректными
> explicit header и payload CRC. В последней серии M7 из 500 попыток получено
> 492 захвата, и все 492 прошли CRC без ошибок PL-сетки; остальные попытки
> включали пять сбоев на стороне передатчика и три пропуска детектора PL.
> Непрерывная шкала sample-time M6 также проверена на 47 захватах общей
> длительностью 803,7 с. Открыты калибровка задержки в кабельном тракте,
> квалификационная серия на 1000 пакетов, общая временная синхронизация
> нескольких приёмников и аппаратный multi-receiver TDoA, поэтому готовая
> синхронная система позиционирования пока не заявляется.

## Цели

- Приём и передача LoRa-совместимых пакетов на ZynqSDR.
- Прослеживаемый маршрут: MATLAB float → Simulink → Verilog → ZynqSDR.
- Оценка времени, CFO, SFO, RSSI и SNR вместе с декодированным payload.
- Формирование временных меток пакета в программируемой логике.
- Калибровка постоянных задержек трактов перед решением задачи 2D TDoA.
- Воспроизводимые эксперименты с версиями конфигураций, записей и результатов.

### Инженерное сотрудничество

Репозиторий также служит публичным подтверждением компетенций для прикладных
R&D-задач по LoRa/CSS PHY, SDR-приёму, временной синхронизации пакетов, ToA/TDoA,
маршруту MATLAB/Simulink → FPGA и измерительной верификации. Для консультаций
или проектной работы: [инженерное портфолио](https://lay007.github.io/) и
[GitHub-профиль](https://github.com/Lay007).


Текущая аппаратная квалификация намеренно ограничена BW 125 кГц и SF7:

> Стабилизируем и количественно проверяем аппаратный приёмник, закрываем
> контролируемую серию packet/PER, калибруем временной тракт одного приёмника и
> только затем переносим проверенную временную шкалу на синхронный
> multi-receiver TDoA. MATLAB, Simulink, generated HDL, raw IQ, PL metadata и
> аппаратные измерения остаются связаны общей доказательной базой.

## Что уже реализовано

- генерация upchirp/downchirp и CSS-модуляция;
- dechirp и FFT-демодуляция;
- AWGN, CFO, обнаружение исследовательской преамбулы;
- explicit header, payload CRC, whitening, FEC CR 4/5…4/8;
- диагональный interleaving и Gray/CSS mapping;
- полный бесшумный packet round-trip;
- приём эфирных пакетов SX1262: sync word, SFD и границы пакета;
- мягкое декодирование по max-log для символов, деинтерливера и Хэмминга;
- декодирование всех всплесков записи и BER/PER по логу передатчика;
- объединённый energy/chirp detector полных пакетов в непрерывном IQ;
- модель SFO, дробной задержки, multipath, I/Q/DC, clipping и ADC quantization;
- uncoded BER/SER и coded payload BER/PER;
- дробный ToA, калибровка TDoA и weighted 2D multilateration;
- детерминированные golden-векторы и MATLAB-тесты;
- вспомогательные Python-проверки CSS, ToA и TDoA.
- аппаратный OTA-приём SX1262 на ZynqSDR с валидным payload CRC;
- PL timestamp metadata и непрерывный sample-time counter;
- длительные аппаратные серии с сохранением IQ, PL trace и машинно-читаемых результатов;

## Быстрый запуск MATLAB

Используется MATLAB R2025a. Из корня репозитория:

```matlab
cd model/matlab
results = run_tests;
assertSuccess(results);
```

Построение всех графиков:

```matlab
outputs = run_visualizations;
```

Для визуального анализа записи RTL-SDR CU8 или Pluto/GNU Radio CF32 и оценки
BW, SF, смещения несущей, длительности символа, SNR и dechirp FFT запустите:

```matlab
addpath apps
app = lora_phy_inspector;
```

![LoRa PHY Inspector](docs/images/lora-phy-inspector.png)

Форматы входа, методика и ограничения описаны в
**[руководстве по LoRa PHY Inspector](docs/ru/lora-phy-inspector.md)**.

Если serial-передатчик и PlutoSDR либо RTL-SDR подключены к одному компьютеру,
скрипт [`tools/run_phy_experiment.py`](tools/run_phy_experiment.py) выполняет
всю последовательность «передать → записать → проанализировать». Начинать
следует с безопасного `--dry-run`; подробности приведены в
[русском руководстве](docs/ru/automated-phy-experiment.md).

Демодуляция нескольких CSS-символов:

![Демодуляция CSS-символов](docs/images/css-symbol-demodulation-sf7.png)

График показывает циклически сдвинутые chirp, преобразование в тон после
dechirp и выбор соответствующего FFT-bin.

![Захват CSS-кадра](docs/images/css-frame-acquisition-sf7.png)

Текущая BER-кампания сравнивает legacy single-phase/polyphase, выбранный для
Simulink FFT-correlator и независимый matched-filter reference. FFT-correlator
устранил прежний проигрыш 5–6 dB при `L=8` в AWGN:

![Текущий CSS-демодулятор и когерентный эталон](docs/images/css-ber-current-vs-ideal.png)

![Coded LoRa BER/PER с FFT-correlator](docs/images/lora-coded-ber-sf5-sf7-fft-correlator.png)

## Быстрый запуск Simulink

Модели собираются скриптом и не коммитятся, поэтому сборка — обычный способ их
получить:

```matlab
cd model/simulink
report = report_toolchain;                  % проверка продуктов и лицензий
info = build_fft_correlator_model;          % SF7, L=8, double
results = run_simulink_regression;          % toolchain, double, joint sync
```

Из командной строки регрессия возвращает ненулевой код при любом расхождении
MATLAB и Simulink:

```bash
matlab -batch "cd model/simulink; run_simulink_regression"
```

Измеренные результаты и выбранные fixed-point форматы, подтверждающие приёмку
M2, приведены в [приёмке M2](docs/ru/simulink-m2-acceptance.md).

## Быстрый запуск Python-проверок

```bash
python -m venv .venv
python -m pip install -e ".[dev]"
pytest
python examples/css_roundtrip.py
```

Python-модель является вспомогательной независимой проверкой. Авторитетной
алгоритмической моделью остаётся MATLAB.

## Структура репозитория

```text
docs/                   архитектура, методики и требования к стенду
model/matlab/           авторитетная MATLAB float-модель и тесты
model/simulink/         будущая потоковая fixed-point модель
src/zynq_lora_phy/      вспомогательная Python-модель
experiments/templates/  шаблоны PHY capture, ToA и TDoA
captures/               локальные IQ-записи, не добавляемые в Git
tools/                  утилиты записи с оборудования
fpga/                   интеграция PL/RTL и ограничения
firmware/               программное обеспечение Zynq PS
hardware/               сведения о платах, тактировании и калибровке
```

## Русская документация

- [Оглавление](docs/ru/README.md)
- [Архитектура](docs/ru/architecture.md)
- [Дорожная карта](docs/ru/roadmap.md)
- [Приёмка floating-point MATLAB M1](docs/ru/matlab-m1-acceptance.md)
- [LoRa PHY: whitening, FEC, interleaving и CRC](docs/ru/lora-phy-coding.md)
- [Методика BER/SER/PER](docs/ru/ber-methodology.md)
- [Запись SX1262 с RTL-SDR и PlutoSDR](docs/ru/iq-capture-guide.md)
- [Требования к стенду](docs/ru/test-bench.md)
- [MATLAB-модель](docs/ru/matlab-model.md)
- [Проведение экспериментов](docs/ru/experiments.md)
- [Аппаратная серия Heltec V4.3/SX1262 → ZynqSDR](docs/ru/hardware-sweep-2026-08-03-heltec-v43.md)
- [Simulink и путь к Verilog](docs/ru/simulink.md)

## Принципы измерений

1. Сначала определить и проверить алгоритм в MATLAB float.
2. Сравнивать MATLAB, Simulink, Verilog и аппаратуру одними golden-векторами.
3. Формировать точные временные метки в PL, а не по времени Linux/Ethernet.
4. Считать задержки кабелей, RF, ADC и DSP калибруемыми величинами.
5. Сохранять конфигурацию и происхождение каждого результата.

## Лицензия и вклад

Проект распространяется по лицензии Apache 2.0, текст приведён в
[LICENSE](LICENSE). Вклад принимается на условиях той же лицензии.

Новые DSP-блоки должны иметь эталонную модель, детерминированные тесты,
численные допуски и описание аппаратного отображения. Подробности приведены в
[CONTRIBUTING.ru.md](CONTRIBUTING.ru.md).
