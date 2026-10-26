# Daevox AudioPatch for macOS

[![HAL driver tests](https://github.com/regimentor/daevox-audio-patch-macos/actions/workflows/driver-tests.yml/badge.svg)](https://github.com/regimentor/daevox-audio-patch-macos/actions/workflows/driver-tests.yml)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![macOS 27+](https://img.shields.io/badge/macOS-27%2B-000000?logo=apple&logoColor=white)](#требования)
[![MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Открытый аудиомаршрутизатор: выбранные каналы физического устройства → виртуальный микрофон.**

Нативный SwiftUI-маршрутизатор для macOS. Собственный CoreAudio HAL-плагин публикует
виртуальные микрофоны; Swift AUHAL захватывает физические каналы и передаёт их через
адаптивный ring buffer в output stream выбранного виртуального устройства.
Discord/Chrome/QuickTime читают его input stream.

Основной сценарий: **GoXLRMini inputs 3–4 → GoXLR Discord Mic channels 1–2**.
2026-10-26 проверен на реальном GoXLR Mini; пользователь подтвердил чистый голос в Discord.
Подробные условия и границы проверки — в [Validation](Documentation/Validation.md).
Loopback/BlackHole и внешние библиотеки не нужны. SIP не отключается.

## Статус

Рабочий MVP. Основной путь GoXLR Mini → Discord проверен на реальном оборудовании;
это не заявление о полной функциональности Loopback или о production-приёмке всех сценариев.
Готовых notarized `.dmg`/`.pkg` пока нет: приложение и драйвер собираются из исходников.

## Требования

- Apple Silicon Mac с macOS 27.0 или новее.
- Xcode 27.1 с macOS SDK 27.0 для сборки приложения.
- Физический вход 48 kHz; другие номинальные частоты пока не поддерживаются.
- Administrator authorization для установки драйвера и Microphone consent для захвата.

## Сборка из исходников

```sh
git clone git@github.com:regimentor/daevox-audio-patch-macos.git
cd daevox-audio-patch-macos
```


Откройте `DaevoxAudioPatch.xcodeproj`, схема `DaevoxAudioPatch`. Xcode 27.1, Swift 6,
macOS 27.0+ (deployment target исходного проекта сохранён).
Target `AudioPatchDriver` — зависимость приложения; готовый bundle находится внутри
`DaevoxAudioPatch.app/Contents/Resources/Driver/AudioPatch.driver`.

Для локальной сборки с ad-hoc подписью:

```sh
xcodebuild -project DaevoxAudioPatch.xcodeproj -scheme DaevoxAudioPatch \
  -configuration Release -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
open build/DerivedData/Build/Products/Release/DaevoxAudioPatch.app
```

Персональный Development Team в репозитории не задан. В Xcode можно выбрать свой Team. Для распространения отдельно
настройте Developer ID signing приложения **и** driver target, notarization и installer.
Локальная подпись не является notarization. Driver target по умолчанию подписывается ad-hoc.

## Установка и первый маршрут

Приложение является обычным `.app` bundle. Завершите уже запущенный экземпляр через
его меню, затем скопируйте сборку в «Программы»:

```sh
ditto build/DerivedData/Build/Products/Release/DaevoxAudioPatch.app /Applications/AudioPatch.app
open /Applications/AudioPatch.app
```

1. Откройте `/Applications/AudioPatch.app`. Xcode для дальнейшего запуска не нужен.
2. «Виртуальные устройства» → «Установить драйвер…». macOS запросит администратора.
   Bundle устанавливается в `/Library/Audio/Plug-Ins/HAL/AudioPatch.driver`.
3. Перезагрузите Mac. Приложение не перезапускает coreaudiod принудительно.
4. Откройте AudioPatch. Убедитесь, что внизу окна написано «Драйвер загружен».
5. Создайте `GoXLR Discord Mic`, 2 канала, 48 kHz.
6. «Маршрутизация»: выберите GoXLRMini, нажмите «GoXLR 3–4 → 1–2», сохраните матрицу.
7. Нажмите «Запустить» и разрешите доступ к микрофону. Если включённый маршрут
   восстановлен без разрешения, используйте «Разрешить микрофон» в «Диагностика»
   или строке виртуального устройства.
8. В Audio MIDI Setup проверьте input `GoXLR Discord Mic`: 2 ch, Float32, 48 kHz.
9. В Discord выберите этот input. В Chrome также разрешите сайту доступ к микрофону;
   если список устройств был открыт до создания микрофона, обновите страницу/перезапустите Discord.
10. Проведите [аппаратную приёмку](Documentation/Hardware-Acceptance.md).

Альтернатива установке через UI:

```sh
Scripts/install-driver.sh build/DerivedData/Build/Products/Release/AudioPatch.driver
```

Для работы не нужны root-права приложения. Администратор нужен только для установки
и удаления системного bundle. TCC Microphone consent обязателен для физического захвата.

## Возможности и границы текущей реализации

- HAL discovery с UID, именами каналов, форматами, частотами, hotplug notifications.
- До 8 виртуальных устройств, каждое 1–16 каналов, **48 kHz**.
- Произвольная матрица соединений, несколько входов на канал, суммирование и hard clipping ±1.
  Gain сохраняется в модели; отдельный UI управления gain пока не добавлен.
- AUHAL преобразует аппаратный PCM (в том числе GoXLR 24-bit Integer) в planar Float32.
- SPSC ring, prefill, underrun/overrun, плавная drift correction ±2000 ppm.
  Линейная интерполяция предназначена для малого clock drift при 48→48 kHz;
  номинальные 44.1/96 kHz не поддерживаются и явно отклоняются.
- Виртуальный input и injection output видны в macOS. Не используйте injection output
  как системный playback: другой процесс тоже может отправлять туда звук.
- Channel count неизменяем после создания UID. Для другой конфигурации создайте новое
  устройство. Перед добавлением/переименованием/удалением закройте использующие виртуальные
  устройства приложения: драйвер отклоняет изменение, пока есть активные IO-клиенты.
- Приложение остаётся в строке меню при закрытии окна. Выход останавливает звук.
  Автозапуск через SMAppService.mainApp, восстановление по UID после sleep/USB reconnect.
  Это пользовательский процесс, не системный daemon до входа в учётную запись.
- Codable JSON: `~/Library/Application Support/AudioPatch/configuration.json`.
  Повреждённый/неподдерживаемый файл не перезаписывается автоматически.
- Диагностика показывает реальные счётчики. Driver missing frames учитывают каждое
  чтение клиента и стартовую тишину; это не отдельный счётчик аппаратных xruns.
- 1024 frames задержки HAL loopback плюс Swift prefill (для GoXLR buffer 512 — target 1152).
  Это описанная буферизация, **не измеренная end-to-end задержка**.

## Тесты

```sh
xcodebuild -project DaevoxAudioPatch.xcodeproj -scheme DaevoxAudioPatch \
  -destination 'platform=macOS' -derivedDataPath /tmp/AudioPatchDerived \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:DaevoxAudioPatchTests test
Scripts/test-driver.sh /tmp/AudioPatchDerived/Build/Products/Debug/AudioPatch.driver/Contents/MacOS/AudioPatch
```

GitHub Actions компилирует **C++ HAL plug-in для in-process host tests** на macOS runner.
Этот job не устанавливает драйвер и не проверяет SwiftUI, GoXLR или Discord. Для полной
сборки приложения и XCTest используйте указанное выше окружение Xcode/macOS 27.

Unit tests проверяют реальные Swift mapping/mixing/ring/drift/persistence. Driver host
загружает собранный .driver через dlopen и вызывает его настоящий interface: properties,
конфигурацию, timestamps и PCM I/O, включая concurrent clients и stale-frame silence.
Это изолированная проверка компонента, не доказательство его загрузки системным HAL.
Реальный тест установленного HAL (по явному запуску, создаёт/сохраняет GoXLR Discord Mic):
`Scripts/test-hardware.sh`. Перед ним остановите маршруты AudioPatch и закройте клиенты
виртуального микрофона, поскольку тест вводит синтетический тон. Нужен GoXLR и разрешение Microphone; после трёхсекундного
проверочного тона говорите 10 секунд. `--meter` измеряет все physical inputs без записи,
`--status-only` читает HAL counters без изменения профиля/захвата, `--create-only --enable`
включает сохранённый маршрут для следующего запуска приложения.
Нулевой Chat Mic Mix будет отмечен как отсутствие сигнала, а не успешная голосовая приёмка.

UI smoke test запускается через `-only-testing:DaevoxAudioPatchUITests`; debug flag
`--ui-testing` отключает восстановление сохранённых аппаратных маршрутов и запись в драйвер.

Проверка обычного запуска с восстановлением реального сохранённого маршрута, кликов
M1/M2 по меню и повторного открытия через Dock запускается отдельно (она перезапускает app):

```sh
env TEST_RUNNER_AUDIOPATCH_LIVE_UI=1 xcodebuild \
  -project DaevoxAudioPatch.xcodeproj -scheme DaevoxAudioPatch \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/AudioPatchStartupTestDerived ENABLE_TESTABILITY=YES \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -only-testing:DaevoxAudioPatchUITests/DaevoxAudioPatchUITests/testLiveRestoredLaunchDockAndStatusMenu test
```

Архитектура: [ADR](Documentation/ADR-001-audio-architecture.md).
Проверенные результаты и оставшиеся проверки: [Validation](Documentation/Validation.md).

## Удаление

Остановите маршруты, закройте Discord/QuickTime. В «Диагностика» нажмите «Удалить драйвер…»
или выполните `Scripts/uninstall-driver.sh`, затем перезагрузите Mac. Удаляется только
`/Library/Audio/Plug-Ins/HAL/AudioPatch.driver`. JSON и чужие драйверы сохраняются.
Автозапуск выключается отдельно в приложении/системных настройках. Приложение можно удалить
обычным способом. При удалении драйвера звук прекращается, автоматического fallback на
физический микрофон нет.

## Структура проекта

| Путь | Назначение |
|---|---|
| `DaevoxAudioPatch/Audio` | HAL discovery, AUHAL capture, Swift routing/ring/drift |
| `DaevoxAudioPatch/Services` | Конфигурация, driver control, lifecycle и состояние UI |
| `DaevoxAudioPatch/Models` | Codable-модели устройств и маршрутов |
| `VirtualAudioDriver` | Минимальный C++ AudioServerPlugIn |
| `DaevoxAudioPatchTests` / `DaevoxAudioPatchUITests` | Unit и UI tests |
| `DriverTests` / `HardwareTests` | Driver host и opt-in реальные проверки |
| `Scripts` / `Documentation` | Установка, удаление, проверки и ADR |

## Участие

[Как внести изменения](CONTRIBUTING.md) · [Сообщить об ошибке](https://github.com/regimentor/daevox-audio-patch-macos/issues/new/choose) · [Changelog](CHANGELOG.md)

## Лицензия

MIT, см. [LICENSE](LICENSE). Код драйвера написан самостоятельно.
BlackHole изучался как открытый reference; его код не включён и он не является зависимостью.
