# ADR 001 — AudioPatch: настоящий HAL-микрофон

Дата: 2026-10-26. Статус: принято для реализации MVP, аппаратная приёмка отдельно.

## Проверенное окружение

Существующий DaevoxAudioPatch.xcodeproj сохранён. Xcode 27.1 (27A9275), Swift 6.4,
macOS SDK 27.0, DriverKit SDK 27.0; хост macOS 27.0.1 arm64.
Шаблон: deployment target 27.0, Swift 5, MainActor по умолчанию, App Sandbox.
Переводим targets на Swift 6, явно изолируем UI на MainActor. Deployment target сохраняем.
Sandbox отключаем: приложение управляет HAL-плагином и устанавливает локальный драйвер;
оставляем hardened runtime и microphone entitlement/usage description. Дистрибуция вне App Store.

## Решение

1. Собственный AudioServerPlugIn в отдельном bundle target того же Xcode-проекта.
   C++ только внутри драйвера: C ABI CFPlugIn/IUnknown, AudioObject properties,
   виртуальные Float32 interleaved streams, clock и timestamp ring.
2. Каждый виртуальный микрофон имеет input stream для Discord и output stream для
   инъекции из Swift. HAL — IPC, нет общего mmap, файлов или сетевых пакетов в RT.
   Output endpoint виден в системе; его нельзя выбирать как системные колонки.
3. Swift AUHAL захватывает все физические каналы в preallocated planar Float32.
   AUHAL преобразует аппаратный integer PCM (включая 24 bit); аппаратный формат не меняем.
   Swift делает channel mapping/mixing, SPSC ring и адаптивную fractional resampling.
   Отдельный HAL IOProc виртуального output читает ring. Два независимых clock domains.
4. MVP: физический вход 48 kHz, виртуальный 48 kHz, 1–16 каналов, до 8 устройств.
   Другие номинальные частоты явно отклоняются, а не воспроизводятся с неверной скоростью.
   Компенсация малого дрейфа — непрерывная линейная интерполяция ±2000 ppm,
   feedback по заполнению ring. Это не универсальный bandlimited SRC.
5. RT: только заранее выделенная память, bounded loops, lock-free atomics.
   Нет Task/actor/Dispatch/logging/IO/locks/allocation в callbacks. Перестройка маршрута
   выполняется через stop/dispose → новый immutable plan → start.
6. Плагин передаёт звук output → input через timestamp-tagged atomic ring.
   Несколько input clients читают одни и те же samples независимо. Потерянные/устаревшие
   frames дают нули. Driver delay 1024 frames, Swift target fill >=1024 frames.
   Это расчётная буферизация, не измеренная end-to-end задержка.
7. Custom CFPropertyList HAL property `apcf` управляет списком устройств, `apst` — статистикой.
   Конфигурация сохраняется host WriteToStorage и Swift Codable atomic JSON.
   Изменения списка/имён только при остановленных клиентах; занятый драйвер возвращает ошибку.
   Layout неизменяем для UID: другой channel count создаётся новым устройством.
   Это исключает изменение stream structure без RequestDeviceConfigurationChange.
8. Window close не завершает app; MenuBarExtra позволяет вернуть окно/завершить поток.
   SMAppService.mainApp — запуск при входе; app продолжает работать в пользовательской
   сессии. Logout завершает поток. Отдельный daemon для MVP не требуется.
   Sleep останавливает engine, wake/hotplug и смена формата приводят к пересборке по UID.

## Почему не AudioDriverKit / aggregate / tap

Apple прямо рекомендует Audio Server Driver Plug-in для virtual devices;
AudioDriverKit supports physical audio devices. SDK действительно содержит AudioDriverKit,
но это не основание обещать virtual dext. Aggregate объединяет endpoints, не публикует
произвольный стерео-микрофон из каналов 3–4. Process tap захватывает process audio,
но сам по себе не создаёт selectable input. MediaDeviceExtension registration в SDK
разрешает только один output remote-screen/streaming device, поэтому тоже не подходит.

## Установка и разрешения

Драйвер — /Library/Audio/Plug-Ins/HAL/AudioPatch.driver, root:wheel, без world-write.
App содержит готовый bundle, установка/удаление выполняются системным AppleScript
administrator authorization. Никаких kext, private API, SIP bypass или DriverKit entitlements.
После установки рекомендуем перезагрузку (как в sample Apple); принудительно coreaudiod
не перезапускаем, чтобы не обрывать чужое аудио. Для записи нужен TCC Microphone consent.
Для релиза: Developer ID signing и notarization приложения/installer, архитектуры по deployment target. При target 27.0 текущий SDK помечает x86_64 deprecated; локальная сборка — arm64.
Локальная ad-hoc сборка не доказывает принятие HAL на каждой macOS.

## Исследованные первичные источники

- Apple, Creating an Audio Server Driver Plug-in:
  https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in
- Apple, Creating an audio device driver (ограничение AudioDriverKit):
  https://developer.apple.com/documentation/audiodriverkit/creating-an-audio-device-driver
- SDK: CoreAudio.framework/Headers/AudioServerPlugIn.h, AudioHardwareBase.h,
  AudioHardware.h; AudioUnit.framework/Headers/AUComponent.h.
- BlackHole — изучен как reference, не зависимость, код не копировался:
  https://github.com/ExistentialAudio/BlackHole (GPL-3.0).
  Подтверждает практический output/input HAL loopback и установку .driver.

## Порядок реализации и границы приёмки

1. Сборка шаблона, ADR. 2. HAL discovery + UI, сборка.
3. Плагин + тестовый HAL-host harness (properties, configuration, clocks, real sample copying), сборка.
4. Swift capture/routing/drift + unit tests, сборка.
5. CRUD устройств, матрица, Codable, установка, сборка.
6. Recovery/diagnostics/tests; аппаратный протокол GoXLR → Discord.

Успех компиляции, unit tests и in-process driver host не означают, что HAL загрузил драйвер,
что TCC разрешил захват или что Discord воспроизводит звук без прерываний.
