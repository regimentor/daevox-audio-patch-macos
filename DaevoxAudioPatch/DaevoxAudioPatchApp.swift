import SwiftUI
import AppKit

@MainActor
final class AudioPatchAppDelegate: NSObject, NSApplicationDelegate {
    // The app owns routing even when no main window exists.
    let model = AudioPatchModel()
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { model.startReadOnlyForUITests() }
        else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { model.start() }
        #else
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { model.start() }
        #endif
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
}

@main
struct DaevoxAudioPatchApp: App {
    @NSApplicationDelegateAdaptor(AudioPatchAppDelegate.self) private var delegate
    var body: some Scene {
        Window("AudioPatch", id: "main") {
            ContentView().environmentObject(delegate.model)
        }
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        MenuBarExtra {
            MenuBarContent().environmentObject(delegate.model)
        } label: {
            MenuBarLabel().environmentObject(delegate.model)
        }
    }
}

private struct MenuBarLabel: View {
    @EnvironmentObject private var model: AudioPatchModel
    @Environment(\.openWindow) private var openWindow
    @State private var presentedInitialWindow = false
    var body: some View {
        Label("AudioPatch", systemImage: model.hasRunningRoutes ? "waveform.circle.fill" : "waveform.circle")
            .task {
                // A restored menu-bar scene can suppress the default main-window scene.
                // Explicitly present the unique main window once per process, not on updates.
                guard !presentedInitialWindow else { return }
                presentedInitialWindow = true
                await Task.yield()
                openWindow(id: "main")
            }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var model: AudioPatchModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.hasRunningRoutes ? "Активных маршрутов: \(model.running.count)" : "Маршрутизация остановлена")
        Button("Открыть AudioPatch") { openWindow(id: "main"); NSApplication.shared.activate() }
        Divider()
        Button("Завершить AudioPatch") { model.shutdown(); NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}
