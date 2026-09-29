# Русская документация

[English documentation](../README.md) · [Главная страница проекта](../../README.ru.md)

## Начать отсюда

- [Архитектура системы](architecture.md)
- [Дорожная карта и критерии готовности](roadmap.md)
- [Аппаратный timestamping и синхронизация приёмников](hardware-timestamping.md)
- [Завершённая приёмка floating-point MATLAB M1](matlab-m1-acceptance.md)
- [MATLAB-модель](matlab-model.md)
- [Simulink и генерация Verilog](simulink.md)
- [Основания M2: инструментарий, интерфейсы и stage-векторы](simulink-m2-interfaces.md)
- [Приёмка M2: измерения Simulink](simulink-m2-acceptance.md)
- [ADR-0001: когерентный FFT-correlator и fallback](architecture-decisions/0001-coherent-css-demodulator.md)

## PHY и измерения

- [LoRa PHY: структура сигнала и формат кадра](lora-phy-protocol.md)
- [Golden source of truth: эталоны MATLAB, HDL и RF evidence](golden-source-of-truth.md)
- [Whitening, FEC, interleaving, CRC и отображение символов](lora-phy-coding.md)
- [Методика BER/SER/PER](ber-methodology.md)
- [Послойная differential regression приёмного тракта](stage-differential.md)
- [Методика дробного ToA и будущей аппаратной калибровки](toa-methodology.md)
- [End-to-end приёмка MATLAB M1: PHY, ToA и TDoA](matlab-m1-acceptance.md)
- [Запись пакетов SX1262 с RTL-SDR и PlutoSDR](iq-capture-guide.md)
- [LoRa PHY Inspector: визуальный анализ и оценка параметров](lora-phy-inspector.md)
- [Передача, запись и анализ с одного компьютера](automated-phy-experiment.md)

## Оборудование и эксперименты

- [Требования к стенду](test-bench.md)
- [Воспроизводимые эксперименты](experiments.md)
- [Аппаратная серия Heltec V4.3/SX1262 → ZynqSDR от 3 августа 2026 года](hardware-sweep-2026-08-03-heltec-v43.md)
- [Целевой прогон Heltec V4.3: SF5/SF6, BW500 и ToA от 7 августа 2026 года](hardware-targeted-2026-08-07.md)
- [Аппаратная серия LR1121 → ZynqSDR от 2 августа 2026 года](hardware-sweep-2026-08-02.md)
- [Кривые помехоустойчивости LoRa: схемы стенда и эксперимент](per-curves-experiment.md)
- [Как вносить изменения](../../CONTRIBUTING.ru.md)

Английские документы остаются первичными при расхождении версий. Русский набор
должен обновляться в том же коммите, если изменение затрагивает методику,
интерфейс или критерий приёмки.
