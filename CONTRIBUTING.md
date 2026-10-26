# Участие в разработке

Основной проект — `DaevoxAudioPatch.xcodeproj`, shared scheme — `DaevoxAudioPatch`.
Для приложения нужны Xcode 27.1 и macOS SDK 27.0; deployment target — macOS 27.0.
Swift Package Manager, CocoaPods и сторонние аудиодрайверы не требуются.

## Подготовка изменений

1. Создайте ветку от `main`.
2. Соберите проект по команде из [README](README.md).
3. Запустите проверки, относящиеся к изменённому компоненту.
4. В PR опишите проблему, итоговое поведение и проверку. Отдельно укажите то,
   что ещё не проверено на оборудовании.

## Архитектурные ограничения

- Swift — для UI, конфигурации, HAL discovery и маршрутизации. C++ — только для
  минимального HAL plug-in. UI остаётся SwiftUI.
- Audio callbacks: preallocated memory, bounded work, lock-free atomics.
  Не добавляйте locks, allocations, logging, dispatch, actor/Task или filesystem I/O.
- Разные устройства имеют разные clock domains. Сохраняйте компенсацию дрейфа
  и корректные underrun/overrun policies.
- Изменения metadata должны быть идемпотентными: одинаковая конфигурация не должна
  порождать HAL notifications или перезапускать поток.
- Не меняйте аппаратные mic gain, gate, mute или USB routing без отдельного действия
  пользователя. Не обходите TCC, administrator authorization или SIP.
- Не коммитьте signing keys, персональный Team ID, `.xcuserstate`, `xcuserdata`,
  конфигурации маршрутов, аудиозаписи, build products или локальные отчёты.

## Проверки

Unit tests и in-process driver host не требуют установки плагина. Команды есть
в [README](README.md). CI проверяет C++ driver host, а не весь аудиосценарий.

`Scripts/test-hardware.sh` и live UI regression запускаются только явно: они
используют настоящее устройство, могут запросить Microphone consent и изменить
сохранённый профиль тестового микрофона. Перед тестом остановите собственные
маршруты и закройте клиентов виртуального микрофона. Probe подаёт тестовый тон.

Критерии ручной проверки: [Hardware Acceptance](Documentation/Hardware-Acceptance.md).
Результаты с известными границами: [Validation](Documentation/Validation.md).
