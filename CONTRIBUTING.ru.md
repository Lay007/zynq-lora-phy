# Участие в разработке

[English version](CONTRIBUTING.md)

## Рабочий процесс

1. Описать измеримый результат изменения.
2. Добавить или обновить авторитетное поведение MATLAB float.
3. Добавить детерминированные MATLAB-тесты, включая boundary/impairment case.
4. Изменять Simulink только после стабилизации MATLAB-поведения.
5. Сравнивать Verilog с версионными MATLAB/Simulink golden-векторами.
6. Обновлять архитектуру, методику эксперимента и калибровочные заметки.

[Руководство разработчика](docs/ru/development.md) описывает проверки по областям
и порядок регенерации HDL; [граница репозитория](docs/ru/public_private_boundary.md)
определяет публичную область проекта и проверку перед публикацией.

Python-проверки:

```bash
python -m pip install -e ".[dev]"
pytest
```

Авторитетные MATLAB-тесты:

```matlab
cd model/matlab
results = run_tests;
assertSuccess(results);
```

## Инженерные соглашения

- В неоднозначных полях указывать SI units: `sample_rate_hz`, `toa_s`,
  `position_m`.
- Сохранять random seed для генерируемых сигналов и шума.
- Не добавлять большие raw captures в Git; хранить компактный fixture либо
  checksum и инструкцию получения.
- Не перезаписывать raw experiment data. Derived result помещается в новый
  output directory вместе с config и software revision.
- Документировать fixed-point scaling и rounding каждого PL interface.
- Не редактировать HDL Coder output вручную; менять Simulink source/config и
  повторно генерировать Verilog.
- Изменение английской методики или интерфейса должно обновлять соответствующую
  русскую страницу в том же коммите.
