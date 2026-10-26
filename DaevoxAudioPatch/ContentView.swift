import SwiftUI
import CoreAudio

private enum SectionPage: String, CaseIterable, Identifiable {
    case devices = "Устройства", virtual = "Виртуальные устройства", routing = "Маршрутизация", diagnostics = "Диагностика"
    var id: Self { self }
    var symbol: String {
        switch self { case .devices: "hifispeaker"; case .virtual: "mic.badge.plus"; case .routing: "point.3.connected.trianglepath.dotted"; case .diagnostics: "waveform.path.ecg" }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AudioPatchModel
    @State private var page: SectionPage? = .devices
    @State private var selected: UUID?
    @State private var newDevice = false
    var body: some View {
        NavigationSplitView {
            List(SectionPage.allCases, selection: $page) { item in Label(item.rawValue, systemImage: item.symbol).tag(item) }
                .navigationTitle("AudioPatch")
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 320)
                .safeAreaInset(edge: .bottom) {
                    Label(model.driverLoaded ? "Драйвер загружен" : "Драйвер не загружен", systemImage: model.driverLoaded ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.caption).foregroundStyle(model.driverLoaded ? .green : .secondary).padding()
                }
        } detail: {
            Group {
                switch page ?? .devices {
                case .devices: devicesView
                case .virtual: virtualView
                case .routing: routingView
                case .diagnostics: DiagnosticsView()
                }
            }.navigationTitle((page ?? .devices).rawValue)
        }
        .frame(minWidth: 1000, minHeight: 650)
        .sheet(isPresented: $newDevice) { NewVirtualDeviceView { name, channels in model.addDevice(name: name, channels: channels) } }
        .alert("AudioPatch", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("AudioPatch", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }
    private var physical: [AudioDeviceDescription] { model.deviceManager.devices.filter(\.isPhysical) }
    private var devicesView: some View {
        List {
            if let error = model.deviceManager.error { Text(error).foregroundStyle(.red) }
            ForEach(physical) { device in
                DisclosureGroup {
                    LabeledContent("UID", value: device.uid).textSelection(.enabled)
                    LabeledContent("Буфер", value: "\(device.bufferFrames) frames")
                    LabeledContent("Доступные частоты, Hz", value: device.sampleRates.joined(separator: ", "))
                    ForEach(device.formats, id: \.self) { Text($0).font(.caption) }
                    HStack(alignment: .top, spacing: 36) {
                        channelList("Входы", device.inputChannels)
                        channelList("Выходы", device.outputChannels)
                    }.padding(.vertical, 8)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.name).font(.headline)
                            Text("\(device.transportName) · \(device.inputChannels.count) входов · \(device.outputChannels.count) выходов").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(device.sampleRate)) Hz").monospacedDigit()
                        Image(systemName: device.alive ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(device.alive ? .green : .red)
                    }.padding(.vertical, 5)
                }
            }
        }.toolbar { Button("Обновить", systemImage: "arrow.clockwise") { model.deviceManager.refresh() } }
    }
    private func channelList(_ title: String, _ channels: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.bold())
            if channels.isEmpty { Text("Нет каналов").foregroundStyle(.secondary) }
            ForEach(Array(channels.enumerated()), id: \.offset) { i, name in Text("\(i + 1) · \(name)").font(.caption) }
        }
    }
    private var virtualView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.driverLoaded { DriverSetupView().padding() }
            if model.configuration.devices.isEmpty {
                ContentUnavailableView("Создайте виртуальный микрофон", systemImage: "mic.badge.plus",
                    description: Text("Для GoXLR: 2 канала, 48 kHz. Затем соедините входы 3–4 с каналами 1–2."))
            } else {
                List(model.configuration.devices) { device in
                    VirtualDeviceRow(device: device) {
                        selected = device.id; page = .routing
                    }
                }
            }
        }.toolbar {
            Button("Создать устройство", systemImage: "plus") { newDevice = true }.disabled(model.configuration.devices.count >= 8)
        }
    }
    private var routingView: some View {
        VStack(alignment: .leading) {
            Picker("Виртуальный микрофон", selection: $selected) {
                Text("Выберите устройство").tag(nil as UUID?)
                ForEach(model.configuration.devices) { Text($0.name).tag(Optional($0.id)) }
            }.padding()
            if let device = model.configuration.devices.first(where: { $0.id == selected }) {
                RoutingEditor(configuration: device).id(device.id)
            } else {
                ContentUnavailableView("Выберите виртуальное устройство", systemImage: "square.grid.3x3",
                    description: Text("Создайте устройство в разделе «Виртуальные устройства»."))
            }
        }.onAppear { if selected == nil { selected = model.configuration.devices.first?.id } }
    }
}

private struct NewVirtualDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = "GoXLR Discord Mic"
    @State private var channels = 2
    let create: (String, Int) -> Void
    var body: some View {
        Form {
            Text("Виртуальный микрофон").font(.title2)
            TextField("Название", text: $name)
            Stepper("Каналы: \(channels)", value: $channels, in: 1...16)
            LabeledContent("Частота", value: "48 000 Hz")
            Text("Количество каналов задаётся при создании устройства. Для другой конфигурации создайте новое устройство.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Создать") { create(name, channels); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 440)
    }
}

private struct VirtualDeviceRow: View {
    @EnvironmentObject private var model: AudioPatchModel
    let device: VirtualDeviceConfiguration
    let route: () -> Void
    @State private var renaming = false
    @State private var name = ""
    @State private var deleting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(device.name, systemImage: "mic").font(.headline)
                Spacer()
                Text("\(device.channels) ch · 48 kHz").foregroundStyle(.secondary)
                Button("Матрица", action: route)
                if model.needsMicrophoneAuthorization {
                    Button("Разрешить микрофон") { Task { await model.authorizeMicrophone() } }
                }
                Button(model.routingRequested(device.id) ? "Остановить" : "Запустить") { Task { await model.toggle(device.id) } }
            }
            Text(model.statuses[device.id] ?? "Остановлено").font(.caption).foregroundStyle(model.running.contains(device.id) ? .green : .secondary)
            HStack {
                Button("Переименовать") { name = device.name; renaming = true }
                Button("Удалить", role: .destructive) { deleting = true }
            }.buttonStyle(.link)
        }.padding(.vertical, 9)
        .alert("Переименовать", isPresented: $renaming) {
            TextField("Название", text: $name)
            Button("Сохранить") { var update = device; update.name = name; model.update(update) }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Удалить \(device.name)?", isPresented: $deleting) {
            Button("Удалить устройство", role: .destructive) { model.delete(device.id) }
        } message: { Text("Маршруты этого устройства будут удалены. Закройте приложения, использующие его.") }
    }
}

private struct RoutingEditor: View {
    @EnvironmentObject private var model: AudioPatchModel
    let configuration: VirtualDeviceConfiguration
    @State private var draft: VirtualDeviceConfiguration
    init(configuration: VirtualDeviceConfiguration) { self.configuration = configuration; _draft = State(initialValue: configuration) }
    private var sources: [AudioDeviceDescription] { model.deviceManager.devices.filter { $0.isPhysical && !$0.inputChannels.isEmpty } }
    private var source: AudioDeviceDescription? { sources.first { $0.uid == draft.sourceUID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Физический вход", selection: $draft.sourceUID) {
                Text("Не выбран / отключён").tag("")
                if !draft.sourceUID.isEmpty && source == nil { Text("Отключён: \(draft.sourceUID)").tag(draft.sourceUID) }
                ForEach(sources) { Text("\($0.name) · \($0.inputChannels.count) ch").tag($0.uid) }
            }
            HStack {
                Button("GoXLR 3–4 → 1–2") {
                    draft.routes = [ChannelRoute(input: 3, output: 1), ChannelRoute(input: 4, output: 2)]
                }.disabled((source?.inputChannels.count ?? 0) < 4 || draft.channels < 2)
                Button("Очистить") { draft.routes = [] }
                Spacer()
                Button("Сохранить маршруты") { model.update(draft) }.disabled(draft == configuration)
            }
            if draft != configuration { Text("Есть несохранённые изменения. Сохраните матрицу перед запуском.").font(.caption).foregroundStyle(.orange) }
            Text("Строки — физические входы, столбцы — каналы микрофона. Несколько входов в один канал суммируются с ограничением ±1.")
                .font(.caption).foregroundStyle(.secondary)
            if let source {
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                        GridRow {
                            Text("\(source.name) →").frame(minWidth: 220, alignment: .leading)
                            ForEach(1...draft.channels, id: \.self) { Text("Mic \($0)").font(.caption.bold()).frame(width: 48) }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(Array(source.inputChannels.enumerated()), id: \.offset) { index, name in
                            GridRow {
                                Text("\(index + 1) · \(name)").font(.caption)
                                ForEach(1...draft.channels, id: \.self) { output in
                                    Toggle("Вход \(index + 1) → канал \(output)", isOn: connection(index + 1, output))
                                        .toggleStyle(.checkbox).labelsHidden().frame(width: 48)
                                }
                            }
                        }
                    }.padding(12)
                }.background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ContentUnavailableView("Физический вход отключён", systemImage: "cable.connector.slash")
            }
            HStack {
                Label(model.statuses[configuration.id] ?? "Остановлено", systemImage: model.running.contains(configuration.id) ? "waveform" : "pause.circle")
                    .font(.caption)
                Spacer()
                if model.needsMicrophoneAuthorization {
                    Button("Разрешить микрофон") { Task { await model.authorizeMicrophone() } }
                }
                Button(model.routingRequested(configuration.id) ? "Остановить" : "Запустить") { Task { await model.toggle(configuration.id) } }
                    .buttonStyle(.borderedProminent).disabled(draft != configuration)
            }
        }.padding([.horizontal, .bottom]).onChange(of: configuration) { _, next in draft = next }
    }
    private func connection(_ input: Int, _ output: Int) -> Binding<Bool> {
        Binding(get: { draft.routes.contains { $0.input == input && $0.output == output && $0.enabled } }, set: { enabled in
            draft.routes.removeAll { $0.input == input && $0.output == output }
            if enabled { draft.routes.append(ChannelRoute(input: input, output: output)) }
        })
    }
}

private struct DriverSetupView: View {
    @EnvironmentObject private var model: AudioPatchModel
    var body: some View {
        GroupBox("Системный драйвер AudioPatch") {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.driverLoaded ? "AudioPatch.driver загружен системным HAL." : model.driverInstalled ? "Bundle установлен; для загрузки в HAL перезагрузите Mac." : "Для появления микрофона установите собственный HAL-драйвер AudioPatch.")
                Text("macOS запросит пароль администратора. После установки перезагрузите Mac. Закрытие окна сохраняет аудиопоток; выход из приложения останавливает его.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.driverInstalled ? "Переустановить драйвер…" : "Установить драйвер…") { Task { await model.installDriver() } }
                    .disabled(model.administratorBusy)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
        }
    }
}

private struct DiagnosticsView: View {
    @EnvironmentObject private var model: AudioPatchModel
    @State private var uninstalling = false
    var body: some View {
        Form {
            Section("Система") {
                LabeledContent("HAL-драйвер", value: model.driverLoaded ? "Загружен" : "Не загружен")
                LabeledContent("Microphone", value: model.microphoneStatus)
                if model.needsMicrophoneAuthorization {
                    Button("Разрешить микрофон") { Task { await model.authorizeMicrophone() } }
                }
                Text(model.configurationManager.url.path).font(.caption).textSelection(.enabled)
                DriverSetupView()
                Button("Удалить драйвер…", role: .destructive) { uninstalling = true }.disabled(model.administratorBusy || !model.driverInstalled)
            }
            Section("Фоновая работа") {
                Toggle("Запускать при входе", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                Text(model.loginStatus).font(.caption)
                Toggle("Восстанавливать включённые маршруты при запуске", isOn: Binding(get: { model.configuration.restoreOnLaunch }, set: model.setRestoreOnLaunch))
                Text("Закрытие окна не завершает AudioPatch. Команда «Завершить» в строке меню останавливает маршрутизацию.").font(.caption)
            }
            ForEach(model.configuration.devices) { device in
                Section(device.name) {
                    Text(model.statuses[device.id] ?? "Остановлено")
                    LabeledContent("Виртуальный формат", value: "\(device.channels) ch · Float32 · 48 000 Hz")
                    if let source = model.deviceManager.devices.first(where: { $0.uid == device.sourceUID }) {
                        LabeledContent("Физический вход", value: source.name)
                        LabeledContent("Частота / буфер входа", value: "\(Int(source.sampleRate)) Hz / \(source.bufferFrames) frames")
                    }
                    if let outputID = model.driver.deviceID(uid: device.uid) {
                        LabeledContent("Буфер виртуального устройства", value: "\(HAL.scalar(outputID, kAudioDevicePropertyBufferFrameSize, fallback: UInt32(0))) frames")
                    }
                    if let stats = model.statistics[device.id] {
                        LabeledContent("Захвачено / передано frames", value: "\(stats.capturedFrames) / \(stats.renderedFrames)")
                        LabeledContent("Swift underrun / overrun", value: "\(stats.underruns) / \(stats.overruns)")
                        LabeledContent("Ошибки capture / format", value: "\(stats.captureErrors)")
                        LabeledContent("Ring fill", value: "\(stats.bufferedFrames) frames")
                        LabeledContent("Компенсация дрейфа", value: String(format: "%.1f ppm", stats.correctionPPM))
                        ProgressView(value: Double(stats.peak), total: 1) { Text("Пик сигнала") }
                    }
                    if let stats = model.driverStatistics[device.id] {
                        LabeledContent("Driver missing frames / written", value: "\(stats.missingFrames) / \(stats.writtenFrames)")
                        LabeledContent("IO-клиенты", value: "\(stats.clients)")
                        Text("Задержка драйвера: \(stats.delayFrames) frames. Ring добавляет целевую буферизацию от \(model.configuration.targetBufferFrames) frames. Это не измерение end-to-end задержки.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("События") { ForEach(Array(model.events.enumerated()), id: \.offset) { Text($0.element).font(.caption).textSelection(.enabled) } }
        }.formStyle(.grouped)
        .confirmationDialog("Удалить системный HAL-драйвер?", isPresented: $uninstalling) {
            Button("Удалить и остановить маршрутизацию", role: .destructive) { Task { await model.uninstallDriver() } }
        } message: { Text("macOS запросит администратора. После удаления перезагрузите Mac.") }
    }
}
