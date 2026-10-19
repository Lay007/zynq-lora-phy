# Воспроизводимые эксперименты

[English version](../../experiments/README.md)

Для каждого run копируется подходящий шаблон:

```text
experiments/templates/phy-capture.yaml
experiments/templates/toa.yaml
experiments/templates/tdoa.yaml
        ↓ копирование и заполнение
experiments/runs/2026-08-01_phy_capture_001.yaml
        ↓ выполнение
artifacts/2026-08-01_phy_capture_001/
```

`artifacts/` и непроверенные большие IQ captures не добавляются в Git. Для
значимого эксперимента коммитятся заполненная конфигурация, компактные
таблицы/графики и SHA-256 raw data. Проверенную и пригодную для публикации
эталонную запись можно перенести в `captures/reference/`: raw IQ в этом каталоге
хранится через Git LFS и обязательно сопровождается манифестом происхождения.

## Обязательное происхождение данных

- точный repository commit и clean/dirty state;
- board, RFIC, firmware, bitstream и host software revision;
- waveform/RF settings с явными единицами;
- clock/epoch topology и calibration ID;
- координаты приёмников и coordinate frame для TDoA;
- random seed симуляции;
- raw paths и SHA-256;
- критерий приёмки, выбранный до запуска.

`phy-capture.yaml` используется для RTL-SDR/PlutoSDR записи, проверяющей MATLAB
packet model до timestamp experiments.

Raw result не редактируется. Если изменился алгоритм обработки, создаётся новый
analysis output, который ссылается на тот же immutable capture.

## Моделирование ЧМ-сигналов для позиционирования

Самодостаточное floating-point сравнение ЛЧМ, НЛЧМ и оптимизированного ЧМ-закона
при одинаковых длительности, полосе и энергии запускается так:

```powershell
python tools/run_fm_positioning_experiment.py `
  --output artifacts/fm-positioning
```

Методика и зафиксированный эталонный результат приведены в документе
[«Форма ЧМ-сигнала для позиционирования»](fm-positioning-waveform-experiment.md).

## Аппаратные серии режимов

В репозитории есть одинаковые по структуре матрицы из 27 режимов:

- `experiments/sweeps/lr1121-pluto-modes.json` для LILYGO/LR1121;
- `experiments/sweeps/heltec-v43-pluto-modes.json` для Heltec V4.3/SX1262.

Нужная матрица запускается поверх проверенной локальной конфигурации стенда:

```powershell
python tools/run_phy_sweep.py `
  --sweep experiments/sweeps/lr1121-pluto-modes.json `
  --base-config experiments/configs/my-pluto.local.json `
  --execute
```

Для Heltec следует подставить `heltec-v43-pluto-modes.json`. Базовый профиль и
все варианты ограничены настройками SX1262 от −9 до −5 dBm; внешний усилитель
KCT8103L остаётся отключённым, используется transmit bypass.

`tools/analyze_phy_sweep.py` обрабатывает основной и repair-прогоны за одну
MATLAB-сессию. После просмотра отчётов `tools/curate_phy_sweep.py` повторно
проверяет размер и SHA-256 и переносит в `captures/reference/` только случаи со
статусом `complete`.

## Именование

Рекомендуемый ID:

```text
YYYY-MM-DD_<kind>_<path>_<sequence>
```

Примеры:

```text
2026-08-10_phy_capture_ota_001
2026-08-12_toa_cable_001
2026-08-20_tdoa_indoor_001
```

## Минимальный порядок выполнения

1. Зафиксировать objective и acceptance до записи.
2. Проверить repository commit и оборудование.
3. Заполнить config и назначить output directory.
4. Записать raw data без последующего изменения.
5. Посчитать SHA-256.
6. Запустить analysis из зафиксированной версии кода.
7. Сохранить метрики, графики и журнал отклонений.
8. Повторную обработку оформить новым output revision.
