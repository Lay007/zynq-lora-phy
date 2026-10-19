# C++ модель LoRa CSS

Каталог `cpp/` содержит переносимую C++20-модель базовых операций LoRa/CSS:

- генерацию опорного `upchirp` и `downchirp`;
- формирование информационного LoRa-символа как циклического сдвига `upchirp`;
- отдельный DDS / frequency-shift блок;
- демонстрационную программу;
- regression-тесты против общего MATLAB/FPGA golden reference.

C++ модель используется как независимый промежуточный уровень проверки между
MATLAB floating-point моделью и HDL/FPGA реализацией.

Рекомендуемая цепочка верификации:

```text
MATLAB floating point
(reference_chirp / modulate_symbol)
        ↓
C++ model (Q13)
        ↓
FPGA golden ROM (Q10)
        ↓
HDL / FPGA
```

## Текущий статус

| Возможность | Статус | Проверка |
|---|---|---|
| Reference upchirp | ✅ подтверждено | C++ ↔ FPGA/MATLAB golden ROM |
| Reference downchirp | ✅ подтверждено | комплексное сопряжение upchirp |
| Повторение chirp | ✅ подтверждено | сброс фазы между chirp |
| LoRa-символ через cyclic shift | ✅ подтверждено | символы `0, 1, 17, 63, 127` |
| Проверка диапазона symbol | ✅ подтверждено | значения вне `0..2^SF-1` отклоняются |
| DDS / frequency shift | ✅ базовые проверки | нулевая фаза, знак частоты, защита параметров |
| Dechirp | ⏳ следующий этап | ещё не реализован |
| FFT / symbol decision | ⏳ следующий этап | ещё не реализован |
| Полный packet PHY | ⏳ следующий этап | ещё не реализован |

Для проверенной конфигурации `SF7`, `BW=125 kHz`, `Fs=1 MHz`, `L=8` C++
reference chirp и сформированные информационные символы совпадают с общим
MATLAB/FPGA golden reference с допустимой погрешностью не более `1 LSB Q10`
после преобразования `Q13 -> Q10`.

Последний C++ CI для этих проверок проходит на Ubuntu/GCC и Windows/MSVC.

## Содержимое каталога

```text
cpp/
├── CMakeLists.txt              CMake-сборка
├── CMakePresets.json           готовые Debug/Release preset'ы
├── README.md                   этот документ
├── LoRa.slnx                   Visual Studio solution
├── LoRa/
│   ├── LoRa.cpp                демонстрационная программа
│   ├── chirp_modulator.*       reference chirp и LoRa symbol modulation
│   ├── frequency_shift.*       DDS / frequency shift
│   ├── cplx.h                  простой комплексный fixed-point тип
│   ├── reader_file.h           чтение бинарных данных
│   └── writer_file.h           запись бинарных данных
└── tests/
    └── test_chirp.cpp          regression C++ ↔ MATLAB/FPGA golden reference
```

## Требования

Минимальные требования:

- CMake 3.20 или новее;
- компилятор с поддержкой C++20;
- Windows, Linux или другая платформа с подходящим C++ toolchain.

Проверяемые в CI конфигурации:

- Ubuntu + GCC;
- Windows + MSVC.

Для C++ модели MATLAB, Vivado и дополнительные библиотеки не нужны. Golden
regression использует уже сохранённый в репозитории FPGA ROM.

## Быстрый старт через CMake Presets

`CMakePresets.json` находится рядом с `CMakeLists.txt`, поэтому команды preset
запускаются из каталога `cpp/`.

Release:

```bash
cd cpp
cmake --preset release
cmake --build --preset release
ctest --preset release
```

Debug:

```bash
cd cpp
cmake --preset debug
cmake --build --preset debug
ctest --preset debug
```

Preset автоматически включает `BUILD_TESTING=ON` и создаёт отдельные каталоги
сборки:

```text
build/cpp-release/
build/cpp-debug/
```

Имена `release` и `debug` одинаковы для трёх стадий:

```text
cmake --preset <имя>          configure
cmake --build --preset <имя>  build
ctest --preset <имя>          tests
```

Посмотреть доступные preset'ы:

```bash
cd cpp
cmake --list-presets=all
```

## Сборка без preset'ов

Из корня репозитория:

```bash
cmake -S cpp -B build/cpp -DCMAKE_BUILD_TYPE=Release
cmake --build build/cpp --config Release --parallel
ctest --test-dir build/cpp -C Release --output-on-failure
```

Основные CMake-цели:

- `lora_cpp_core` — библиотека с алгоритмами;
- `lora_chirp_demo` — демонстрационная программа;
- `lora_cpp_tests` — regression-тесты при `BUILD_TESTING=ON`.

Чтобы собрать только библиотеку и demo:

```bash
cmake -S cpp -B build/cpp -DBUILD_TESTING=OFF
cmake --build build/cpp --parallel
```

## Linux

Пример для Ubuntu/Debian:

```bash
sudo apt update
sudo apt install -y build-essential cmake

git clone https://github.com/Lay007/zynq-lora-phy.git
cd zynq-lora-phy
git checkout lora_cpp

cd cpp
cmake --preset release
cmake --build --preset release
ctest --preset release
```

Для GCC/Clang библиотека и тесты компилируются с:

```text
-Wall -Wextra -Wpedantic -Werror
```

Предупреждения компилятора в переносимом C++ коде рассматриваются как ошибки.

## Windows: CMake из командной строки

В Developer PowerShell for Visual Studio:

```powershell
git checkout lora_cpp
cd cpp
cmake --preset release
cmake --build --preset release
ctest --preset release
```

Для MSVC используются `/W4` и `/permissive-`.

Preset не фиксирует конкретный генератор CMake. На Windows CMake может выбрать
Visual Studio generator, а на Linux — Makefiles/Ninja в зависимости от
окружения. Поле `configuration` в build/test preset позволяет работать и с
multi-config генераторами Visual Studio.

## Windows: Visual Studio

Предпочтительный вариант — открыть CMake-проект через `Open -> Folder` и
открыть каталог `cpp/` или весь репозиторий. Visual Studio обнаружит:

```text
cpp/CMakeLists.txt
cpp/CMakePresets.json
```

и сможет выполнять configure/build непосредственно через CMake.

Для исходной Windows-разработки также сохранён:

```text
cpp/LoRa.slnx
```

Однако воспроизводимая сборка определяется именно CMake. Локальные файлы
Visual Studio (`.vs/`, `*.vcxproj.user`) исключены через `.gitignore`.

## Демонстрационная программа

После Release-сборки через preset исполняемый файл находится внутри
`build/cpp-release/` (для multi-config generator — дополнительно в каталоге
`Release`).

Linux:

```bash
./build/cpp-release/lora_chirp_demo
```

Windows / Visual Studio generator:

```powershell
.\build\cpp-release\Release\lora_chirp_demo.exe
```

Demo генерирует восемь upchirp со следующими параметрами:

```text
SF = 7
BW = 125 kHz
Fs = 500 kHz
samplesPerChip = Fs/BW = 4
samplesPerChirp = 2^SF * samplesPerChip = 512
```

Выход записывается в:

```text
chirp_sf7_bw125_fs500k_q13.pcm
```

`.pcm` является локальным производным файлом и исключён из Git.

## API: reference chirp

Базовая функция генерации опорного chirp:

```cpp
ChirpModulator modulator;

auto up = modulator.generate_chirps(
    1,          // число chirp
    true,       // true = upchirp, false = downchirp
    7,          // SF
    125000.0,   // BW, Hz
    1000000.0   // Fs, Hz
);
```

Для этого примера:

```text
N = 2^7 = 128 chips
L = Fs/BW = 8 samples/chip
samplesPerChirp = N*L = 1024
```

Возвращаемый тип:

```cpp
std::vector<CPLX<short>>
```

I/Q-компоненты представлены в Q13.

## API: формирование LoRa-символа

Информационный CSS-символ формируется методом:

```cpp
ChirpModulator modulator;

auto symbol17 = modulator.modulate_symbol(
    17,         // значение symbol
    7,          // SF
    125000.0,   // BW, Hz
    1000000.0   // Fs, Hz
);
```

Допустимый диапазон:

```text
0 <= symbol < 2^SF
```

Для `SF7` это:

```text
0..127
```

Значения вне диапазона отклоняются через `std::invalid_argument`.

### Соответствие MATLAB

MATLAB-реализация находится в:

```text
model/matlab/+lora_phy/modulate_symbol.m
```

и формирует символ следующим образом:

```matlab
shift = double(symbol) * config.samplesPerChip;
samples = circshift(lora_phy.reference_chirp(config), -shift);
```

C++ использует ту же операцию. Для:

```text
L = samplesPerChip = Fs/BW
M = 2^SF * L
shift = symbol * L
```

C++-символ определяется как циклически сдвинутый reference upchirp:

```text
symbolSamples[n] = reference[(n + shift) mod M]
```

Таким образом:

```text
symbol = 0  -> reference upchirp без сдвига
symbol = k  -> циклический сдвиг на k*L отсчётов
```

Это не отдельная аппроксимация алгоритма: C++ непосредственно повторяет
MATLAB-конвенцию `circshift(..., -symbol*samplesPerChip)`.

## Формат комплексных отсчётов

Единичная амплитуда представляется масштабом:

```text
1.0 ↔ 8192
```

То есть:

```text
I = round(real(x) * 8192)
Q = round(imag(x) * 8192)
```

Reference chirp и сформированные LoRa-символы используют один и тот же Q13
формат.

Q13 выбран для текущей C++ модели и не означает, что последующая FPGA
реализация обязана использовать именно такую разрядность.

## Формула reference chirp

`ChirpModulator::generate_chirps` использует тот же закон фазы, что и:

```text
model/matlab/+lora_phy/reference_chirp.m
```

Фаза MATLAB-модели:

```text
phaseCycles[n] = 0.5*n^2/(N*L^2) - 0.5*n/L

N = 2^SF
L = samplesPerChip = Fs/BW
```

Upchirp:

```text
x_up[n] = exp(j*2*pi*phaseCycles[n])
```

Downchirp:

```text
x_down[n] = conj(x_up[n])
```

C++ не использует дополнительный экспериментальный frequency offset для
формирования chirp и повторяет MATLAB golden model непосредственно.

## Ограничение Fs/BW

Текущая модель требует целого:

```text
L = Fs/BW
```

Это соответствует `samplesPerChip` MATLAB-модели.

Корректные примеры:

| SF | BW | Fs | L | Отсчётов/symbol |
|---:|---:|---:|---:|---:|
| 7 | 125 kHz | 500 kHz | 4 | 512 |
| 7 | 125 kHz | 1 MHz | 8 | 1024 |
| 8 | 125 kHz | 1 MHz | 8 | 2048 |
| 7 | 250 kHz | 1 MHz | 4 | 512 |

Например:

```text
Fs = 1.024 MHz
BW = 125 kHz
Fs/BW = 8.192
```

не соответствует целому числу отсчётов на chip и намеренно отклоняется.

Если такая частота дискретизации нужна реальному SDR-тракту, CSS-сигнал следует
сформировать на корректной целой chip-сетке, а затем отдельно выполнить
resampling. Это разделяет CSS-модуляцию и преобразование частоты дискретизации.

## DDS / FrequencyShift

`FrequencyShift` является отдельным блоком и не участвует в базовой формуле
reference chirp.

Назначение:

```text
сформированный IQ сигнал
        ↓
frequency shift / CFO injection / компенсация
        ↓
сдвинутый IQ сигнал
```

После `reset()` первая комплексная фаза равна нулю. Положительный frequency
shift соответствует положительному вращению комплексной фазы.

## Golden regression

Главный тест:

```text
cpp/tests/test_chirp.cpp
```

Golden ROM:

```text
fpga/rom/lora_sf7_l8_reference_q10.mem
```

ROM содержит авторитетный `SF7/L8` reference upchirp, общий для MATLAB/C++/HDL
цепочки проверки.

### Проверка reference chirp

```text
C++ Q13 chirp
      ↓
Q13 -> Q10
      ↓
sample-by-sample comparison
      ↓
FPGA/MATLAB golden Q10 ROM
```

Из-за независимого округления допускается максимум:

```text
1 LSB Q10
```

### Проверка информационных LoRa-символов

Для `SF7/L8` regression формирует C++-символы:

```text
0
1
17
63
127
```

Для каждого значения тест самостоятельно строит ожидаемый результат как тот же
циклический сдвиг golden reference:

```text
shift = symbol * 8
expected[n] = golden[(n + shift) mod 1024]
```

и выполняет sample-by-sample сравнение с C++ `modulate_symbol()`.

Таким образом, тест подтверждает не только symbol `0`, совпадающий с базовым
upchirp, но и ненулевые значения, включая крайний symbol `127` для SF7.

Также проверяется отклонение:

```text
symbol = -1
symbol = 128
```

### Что ещё проверяет regression

- длину reference chirp;
- совпадение reference chirp с golden ROM;
- `downchirp = conj(upchirp)`;
- повторяемость нескольких chirp;
- сброс начальной фазы;
- корректность LoRa symbol cyclic shift;
- диапазон значения symbol;
- отклонение нецелого `Fs/BW`;
- нулевую начальную фазу DDS;
- знак положительного frequency shift;
- защиту DDS от нулевой частоты дискретизации.

## Запуск тестов

Через preset:

```bash
cd cpp
ctest --preset release
```

Без preset:

```bash
ctest --test-dir build/cpp --output-on-failure
```

Для Visual Studio / multi-config generator:

```powershell
ctest --test-dir build/cpp -C Release --output-on-failure
```

Успешный regression заканчивается сообщением вида:

```text
C++ chirp regression PASS; max Q10 error = 1 LSB
```

## GitHub Actions

Workflow:

```text
.github/workflows/cpp-ci.yml
```

выполняет CMake configure, build и CTest на:

- `ubuntu-latest`;
- `windows-latest`.

Для текущей реализации reference chirp и LoRa symbol modulation обе платформы
проходят успешно.

CI обнаруживает:

- непереносимый Windows-only код;
- ошибки GCC/MSVC;
- проблемы CMake;
- расхождение reference chirp с golden ROM;
- ошибку направления cyclic shift при формировании LoRa-символа;
- нарушение диапазона symbol;
- регрессии базового DDS.

## Где находятся эталоны и реализации

```text
MATLAB reference chirp:
model/matlab/+lora_phy/reference_chirp.m

MATLAB symbol modulation:
model/matlab/+lora_phy/modulate_symbol.m

C++ chirp и symbol modulation:
cpp/LoRa/chirp_modulator.cpp

C++ regression:
cpp/tests/test_chirp.cpp

FPGA golden ROM:
fpga/rom/lora_sf7_l8_reference_q10.mem

HDL ROM wrapper:
fpga/wrappers/lora_reference_chirp_rom.v
```

Если математическая конвенция chirp или symbol mapping намеренно меняется,
сначала следует изменить MATLAB golden model, затем обновить производные golden
данные и только после этого принимать изменения C++/HDL.

## Что уже можно считать подтверждённым

Для проверенной конфигурации `SF7/L8` C++ модель корректно:

1. формирует reference upchirp;
2. формирует reference downchirp;
3. повторяет chirp со сбросом фазы;
4. формирует информационный LoRa-символ через cyclic shift;
5. повторяет MATLAB `modulate_symbol()` для проверенных значений symbol;
6. сохраняет соответствие общему FPGA golden reference с точностью до
   `1 LSB Q10` после пересчёта Q13 → Q10.

Это уже позволяет использовать C++ как проверяемую модель перед дальнейшей
fixed-point/HDL реализацией модулятора.

## Следующие шаги

Следующий логичный этап C++ PHY:

1. dechirp сформированного символа;
2. FFT;
3. определение максимального symbol bin;
4. проверка `modulate -> dechirp -> FFT -> decision` для нескольких символов;
5. packet preamble / sync;
6. сравнение symbol decisions с MATLAB;
7. fixed-point анализ перед переносом соответствующих блоков в HDL.

Таким образом, ближайшая цель — перейти от подтверждённого **формирования**
LoRa-символов к подтверждённому **приёму и определению** этих символов.