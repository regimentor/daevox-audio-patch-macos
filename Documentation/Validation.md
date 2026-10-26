# Проверки AudioPatch

Последняя аппаратная приёмка: **2026-10-26**. Этот отчёт описывает локальные проверки
и ручную приёмку; статус GitHub Actions показывается отдельно в репозитории.

## Окружение

- Xcode 27.1, Swift 6.4, macOS SDK 27.0.
- macOS 27.0.1, Apple Silicon.
- TC-Helicon GoXLR Mini: USB, 21 input / 10 output, 48 kHz, 24-bit Integer,
  аппаратный buffer 512 frames.
- Input 3/4: Chat Mic Mix L/R. Input 7/8: processed mic L/R.
- Локальная ad-hoc подпись; Developer ID и notarization не выполнялись.

## Автоматические проверки

| Проверка | Результат | Что подтверждает |
|---|---|---|
| Debug и Release Xcode build | PASS | Сборку существующего проекта и embedded driver |
| 13 XCTest unit tests | PASS | Mapping, mixing, clipping, SPSC, silence, invalid buffers, NaN, persistence |
| Clock drift ±1000 ppm | PASS | Отсутствие underrun/overrun в модели, сходимость регулятора |
| Изолированный SwiftUI smoke test | PASS | Навигацию четырёх разделов и создание окна |
| Live launch/Dock/menu regression | PASS | Два запуска с сохранённым маршрутом, клики ЛКМ/ПКМ, открытие окна через Dock |
| In-process driver host | PASS | Настоящий CFPlugIn interface, properties, PCM, multi-client reads, timestamps и lifecycle |
| Driver AddressSanitizer + UndefinedBehaviorSanitizer | PASS | Отсутствие обнаруженных ошибок памяти/UB в проверенных сценариях |
| Driver ThreadSanitizer | PASS | Отсутствие обнаруженных гонок в проверенном concurrent I/O |
| Code signature verification | PASS | Целостность локально подписанных app и driver bundles |

Drift test моделирует по 20 000 callbacks × 256 frames на каждое направление
(около 106.7 секунд виртуального времени). Это модель, а не измерение часов GoXLR.

Тестовый host вызывает настоящий interface собранного `.driver`, но не заменяет
проверку его загрузки системным HAL. Повторяемые команды находятся в [README](../README.md).

## Системный HAL и GoXLR

1. Собственный `AudioPatch.driver` установлен с administrator authorization и загружен
   системным HAL. SIP и сторонние драйверы не изменялись.
2. Через custom property `apcf` создан реальный `GoXLR Discord Mic`:
   input 2 ch + injection output 2 ch, Float32, 48 kHz.
3. Известный стереосигнал прошёл путь Swift → HAL output → driver → HAL input → AUHAL.
   Получено 142 848 frames, RMS 0.1750834, ошибка между противофазными каналами 0,
   captureErrors 0.
4. Аппаратный маршрут GoXLR 3–4 → virtual input 1–2 передал ненулевой PCM:
   captured 479 744, output 478 208, received 484 864 frames за десятисекундный тест;
   underrun/overrun/captureErrors = **0/0/0**, ring fill 1152 frames.
5. Пользователь выбрал `GoXLR Discord Mic` в Discord и подтвердил: **«Голос слышно чисто»**.
   Это ручная проверка на настоящем устройстве, отдельно от unit tests.
6. Запущенное Release-приложение продолжило маршрутизацию после завершения probe;
   read-only проверка HAL подтвердила активный IO-клиент и рост writtenFrames.

На первом тесте Chat Mic Mix был нулевым. После отключения Noise Gate **самим
пользователем** сигнал появился. AudioPatch не менял gain, gate, mute или routing
физического устройства. Записи голоса в ходе автоматической проверки не сохранялись.

## Исправление зависания запуска

Первый обычный повторный запуск выявил цикл
`reconcile → SetPropertyData → PropertiesChanged → refresh → reconcile`.
Сэмплирование процесса показало непрерывное обновление inventory на Main Thread.

Исправлены три уровня:

- Driver: неизменённый CFArray не вызывает notifications и повторный storage write.
- Swift controller: текущий `apcf` читается до записи; равные данные не записываются.
- Device manager: notifications объединяются за 150 ms; равный inventory не публикуется.

Driver regression падал на исходном binary, затем прошёл: 32 одинаковые записи и
повторная запись при активном IO не порождают notifications или storage writes.
Запуск модели перенесён в `applicationDidFinishLaunching`, независимо от окна;
главное окно уникальное и явно открывается при запуске. Live UI regression после
исправления: **1 test / 0 failures**, включая два обычных запуска и настоящий Dock.

Для TCC добавлена явная кнопка «Разрешить микрофон». После согласия пользователя
финальная Release-сборка возобновила сохранённый маршрут. Временные логи, PID,
аппаратные UID и персональные пути не входят в публикуемый отчёт.

## Оставшаяся приёмка

- Отдельная визуальная проверка Audio MIDI Setup; HAL metadata уже проверена API.
- Прослушивание/запись в Discord Web, Chrome и QuickTime.
- Длительный прогон 30–60 минут, нагрузка, CPU и энергопотребление.
- Sleep/wake, USB unplug/replug, login item после выхода/входа в систему.
- Измерение end-to-end latency отдельным импульсным/loopback тестом.
- Developer ID/notarization, установка и удаление на других компьютерах.

Полный протокол: [Hardware Acceptance](Hardware-Acceptance.md).
