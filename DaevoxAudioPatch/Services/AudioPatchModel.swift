import AppKit
import AVFoundation
import Combine
import CoreAudio
import ServiceManagement
import SwiftUI

@MainActor
private final class RoutingSession {
    let source: AudioDeviceDescription
    let outputID: AudioObjectID
    let router: AudioRoutingEngine
    let capture = AudioCaptureEngine()
    let output = VirtualOutputEngine()
    var lastCapturedFrames: UInt64 = 0
    var lastRenderedFrames: UInt64 = 0
    var stalledTicks = 0
    init(source: AudioDeviceDescription, outputID: AudioObjectID, configuration: VirtualDeviceConfiguration, target: Int) throws {
        self.source = source; self.outputID = outputID
        let fill = max(target, Int(source.bufferFrames) * 2 + 128)
        router = try AudioRoutingEngine(sourceChannels: source.inputChannels.count, channels: configuration.channels,
            mapping: configuration.routes, target: fill)
        do {
            try output.start(device: outputID, router: router)
            try capture.start(device: source.id, router: router)
        } catch { stop(); throw error }
    }
    func stop() { capture.stop(); output.stop() }
}

@MainActor
final class AudioPatchModel: ObservableObject {
    let deviceManager = AudioDeviceManager()
    let driver = VirtualDriverController()
    let configurationManager = ConfigurationManager()
    @Published private(set) var configuration = PatchConfiguration()
    @Published private(set) var statuses: [UUID: String] = [:]
    @Published private(set) var statistics: [UUID: RoutingStatistics] = [:]
    @Published private(set) var driverStatistics: [UUID: DriverStatistics] = [:]
    @Published private(set) var running: Set<UUID> = []
    @Published private(set) var driverLoaded = false
    @Published private(set) var driverInstalled = false
    @Published private(set) var events: [String] = []
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var administratorBusy = false
    @Published private(set) var loginStatus = ""
    private var sessions: [UUID: RoutingSession] = [:]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var deviceSubscription: AnyCancellable?
    private var sleeping = false
    private var configurationHealthy = true
    private var reconciling = false
    private var refreshCounter = 0
    private var started = false
    private var lastAutomaticError: String?
    private var retryAfter: [UUID: Date] = [:]
    var microphoneStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "Доступ разрешён"
        case .notDetermined: "Доступ ещё не запрошен"
        case .denied: "Доступ запрещён в Системных настройках"
        case .restricted: "Доступ ограничен системой"
        @unknown default: "Неизвестно"
        }
    }
    var needsMicrophoneAuthorization: Bool { AVCaptureDevice.authorizationStatus(for: .audio) != .authorized }
    var hasRunningRoutes: Bool { !running.isEmpty }
    func routingRequested(_ id: UUID) -> Bool {
        configuration.devices.contains { $0.id == id && $0.enabled } && !restoreSuppressed.contains(id)
    }
    #if DEBUG
    func startReadOnlyForUITests() {
        driverLoaded = driver.pluginID != nil; driverInstalled = driver.isInstalled
        loginStatus = Self.describeLoginStatus()
    }
    #endif

    func start() {
        guard !started else { return }; started = true
        do { configuration = try configurationManager.load() }
        catch { configurationHealthy = false; report(error) }
        deviceSubscription = deviceManager.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
        deviceManager.onChange = { [weak self] in self?.reconcile() }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sleeping = true; self?.stopAll(); self?.record("Сон: аудиопотоки остановлены.") }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sleeping = false; self?.deviceManager.refresh(); self?.reconcile()
                self?.record("Пробуждение: восстановление по UID.")
            }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        loginStatus = Self.describeLoginStatus()
        reconcile(allowLaunchRestore: configuration.restoreOnLaunch)
    }
    private var restoreSuppressed: Set<UUID> = []
    private func tick() {
        driverLoaded = driver.pluginID != nil; driverInstalled = driver.isInstalled
        for (id, session) in Array(sessions) {
            let stats = session.router.statistics()
            statistics[id] = stats
            if stats.capturedFrames == session.lastCapturedFrames || stats.renderedFrames == session.lastRenderedFrames {
                session.stalledTicks += 1
            } else { session.stalledTicks = 0 }
            session.lastCapturedFrames = stats.capturedFrames; session.lastRenderedFrames = stats.renderedFrames
            if session.stalledTicks >= 6 {
                stop(id); retryAfter[id] = .now.addingTimeInterval(5)
                statuses[id] = "Поток не продвигается; повторный запуск через 5 секунд"
                record("HAL watchdog: поток остановлен для восстановления.")
            }
            driverStatistics[id] = driver.statistics(device: session.outputID)
        }
        refreshCounter += 1
        if refreshCounter % 4 == 0 { reconcile() }
    }
    func reconcile(allowLaunchRestore: Bool = true) {
        guard !reconciling, configurationHealthy else { return }
        reconciling = true; defer { reconciling = false }
        driverLoaded = driver.pluginID != nil; driverInstalled = driver.isInstalled
        if !allowLaunchRestore { restoreSuppressed = Set(configuration.devices.map(\.id)) }
        guard !sleeping else { return }
        if driverLoaded {
            do { try driver.synchronize(configuration.devices) }
            catch { reportOnce(error); return }
        }
        for config in configuration.devices {
            guard config.enabled, !restoreSuppressed.contains(config.id) else { stop(config.id); statuses[config.id] = "Остановлено"; continue }
            guard driverLoaded else { stop(config.id); statuses[config.id] = "Ожидание установки драйвера и перезагрузки"; continue }
            guard let source = deviceManager.devices.first(where: { $0.uid == config.sourceUID && $0.alive && $0.isPhysical }) else {
                stop(config.id); statuses[config.id] = "Ожидание подключения физического входа"; continue
            }
            guard let output = driver.deviceID(uid: config.uid) else { stop(config.id); statuses[config.id] = "HAL публикует виртуальное устройство…"; continue }
            if let session = sessions[config.id] {
                if session.source.id == source.id && session.source.sampleRate == source.sampleRate &&
                   session.source.bufferFrames == source.bufferFrames && session.source.inputChannels == source.inputChannels && session.outputID == output { continue }
                stop(config.id)
            }
            if let retry = retryAfter[config.id], retry > .now { continue }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                statuses[config.id] = "Нужен доступ: нажмите «Разрешить микрофон»"; continue
            }
            do {
                sessions[config.id] = try RoutingSession(source: source, outputID: output, configuration: config, target: configuration.targetBufferFrames)
                running.insert(config.id); statuses[config.id] = "Маршрутизация работает"; retryAfter[config.id] = nil
                record("Запущен \(config.name): \(source.name), 48 kHz.")
            } catch { statuses[config.id] = error.localizedDescription; retryAfter[config.id] = .now.addingTimeInterval(5); reportOnce(error) }
        }
    }
    func addDevice(name: String, channels: Int) {
        var next = configuration
        let source = deviceManager.devices.first { $0.isPhysical && $0.name.localizedCaseInsensitiveContains("goxlr") } ??
            deviceManager.devices.first { $0.isPhysical && !$0.inputChannels.isEmpty }
        var device = VirtualDeviceConfiguration(name: name, channels: channels)
        device.sourceUID = source?.uid ?? ""
        device.routes = (1...channels).map { ChannelRoute(input: (source?.inputChannels.count ?? 0) >= channels + 2 ? $0 + 2 : $0, output: $0) }
        next.devices.append(device)
        commit(next)
    }
    func update(_ device: VirtualDeviceConfiguration) {
        var next = configuration
        guard let index = next.devices.firstIndex(where: { $0.id == device.id }) else { return }
        next.devices[index] = device
        commit(next)
    }
    func delete(_ id: UUID) {
        var next = configuration; next.devices.removeAll { $0.id == id }; commit(next)
    }
    private func commit(_ next: PatchConfiguration) {
        guard configurationHealthy else { error = "Сначала исправьте конфигурацию: \(configurationManager.url.path)"; return }
        do {
            let validated = try next.validated()
            let previous = configuration
            stopAll()
            if driver.pluginID != nil { try driver.synchronize(validated.devices) }
            do { try configurationManager.save(validated) }
            catch {
                // Restore the driver control plane when disk persistence fails.
                if driver.pluginID != nil { try? driver.synchronize(previous.devices) }
                throw error
            }
            configuration = validated
            record("Конфигурация сохранена.")
            reconcile()
        } catch { report(error); reconcile() }
    }
    func authorizeMicrophone() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        var allowed = status == .authorized
        if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .audio) }
        guard allowed else {
            error = "Разрешите AudioPatch доступ в Системные настройки → Конфиденциальность и безопасность → Микрофон."
            return
        }
        record("Доступ к микрофону разрешён.")
        reconcile()
    }
    func toggle(_ id: UUID) async {
        guard var device = configuration.devices.first(where: { $0.id == id }) else { return }
        if running.contains(id) || (device.enabled && !restoreSuppressed.contains(id)) {
            device.enabled = false; update(device); return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        var allowed = status == .authorized
        if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .audio) }
        guard allowed else { error = "Разрешите AudioPatch доступ к микрофону в Системные настройки → Конфиденциальность и безопасность → Микрофон."; return }
        restoreSuppressed.remove(id); retryAfter[id] = nil; device.enabled = true; update(device)
    }
    func stop(_ id: UUID) {
        sessions.removeValue(forKey: id)?.stop(); running.remove(id)
    }
    func stopAll() { for id in Array(sessions.keys) { stop(id) } }
    func shutdown() {
        timer?.invalidate(); timer = nil; stopAll()
        deviceManager.onChange = nil; deviceManager.stopMonitoring(); deviceSubscription?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
    func installDriver() async {
        administratorBusy = true; defer { administratorBusy = false }
        do { try await driver.install(); driverInstalled = true; notice = "Драйвер установлен. Перезагрузите Mac, затем откройте AudioPatch."; record("Драйвер установлен; ожидается перезагрузка.") }
        catch { report(error) }
    }
    func uninstallDriver() async {
        administratorBusy = true; defer { administratorBusy = false }; stopAll()
        restoreSuppressed = Set(configuration.devices.map(\.id))
        do { try await driver.uninstall(); driverInstalled = false; notice = "Драйвер удалён. Для выгрузки из HAL перезагрузите Mac. Конфигурация сохранена." }
        catch { report(error) }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginStatus = Self.describeLoginStatus()
        } catch { report(error) }
    }
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval }
    func setRestoreOnLaunch(_ enabled: Bool) { var next = configuration; next.restoreOnLaunch = enabled; commit(next) }
    private static func describeLoginStatus() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: "Автозапуск включён"
        case .requiresApproval: "Подтвердите автозапуск в Системных настройках"
        case .notRegistered: "Автозапуск выключен"
        case .notFound: "Для автозапуска поместите приложение в Applications"
        @unknown default: "Статус автозапуска неизвестен"
        }
    }
    private func record(_ message: String) {
        events.insert("\(Date.now.formatted(date: .omitted, time: .standard)) · \(message)", at: 0)
        if events.count > 100 { events.removeLast() }
    }
    private func report(_ error: Error) { self.error = error.localizedDescription; record(error.localizedDescription) }
    private func reportOnce(_ error: Error) {
        if lastAutomaticError != error.localizedDescription { lastAutomaticError = error.localizedDescription; report(error) }
    }
}
