# Changelog

## Unreleased

Первый рабочий MVP нативного аудиомаршрутизатора для macOS.

- SwiftUI: физические устройства, виртуальные микрофоны, матрица маршрутов и диагностика.
- Собственный AudioServerPlugIn: до 8 устройств, 1–16 каналов, Float32, 48 kHz.
- Swift AUHAL capture, channel mapping/mixing, SPSC ring и компенсация малого clock drift.
- Codable-конфигурация, восстановление маршрутов, menu bar и SMAppService login item.
- Установка и удаление HAL bundle через штатное administrator authorization.
- Unit tests, driver host tests, opt-in hardware и live UI tests.
- Исправления цикла HAL notifications и восстановления главного окна.
- Явное управление Microphone consent для восстановленных маршрутов.

Основной аппаратный сценарий GoXLR 3–4 → AudioPatch → Discord подтверждён пользователем.
Расширенная приёмка и ограничения описаны в Documentation/Validation.md.
