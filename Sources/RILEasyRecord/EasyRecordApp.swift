import SwiftUI
import AppKit

@main
struct EasyRecordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var recorder = Recorder()

    var body: some Scene {
        Window("EasyRecord", id: "easyrecord") {
            ContentView(recorder: recorder)
                .preferredColorScheme(.dark)
                .onAppear { delegate.recorder = recorder }
        }
        .defaultSize(width: 680, height: 530)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Recording") {
                Button(recorder.status == .recording ? "Pause Recording" : recorder.status == .paused ? "Resume Recording" : "Start Recording") {
                    Task { await recorder.toggleRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!recorder.canToggleRecording)
                Button("Save Recording") { Task { await recorder.stop() } }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(!recorder.canSave)
            }
        }
        MenuBarExtra {
            RecorderMenu(recorder: recorder)
        } label: {
            Image(systemName: recorder.isBusy ? "record.circle.fill" : "record.circle")
        }
    }
}

private struct RecorderMenu: View {
    @ObservedObject var recorder: Recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if recorder.isBusy {
            Text(recorder.status == .recording ? "Recording · \(recorder.elapsedText)" : recorder.status.label)
            Button(recorder.status == .paused ? "Resume" : "Pause") { Task { await recorder.toggleRecording() } }
                .disabled(!recorder.canToggleRecording)
            Button("Save") { Task { await recorder.stop() } }.disabled(!recorder.canSave)
        } else {
            Text("EasyRecord")
        }
        Button("Show Recorder") {
            openWindow(id: "easyrecord")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit EasyRecord") { NSApp.terminate(nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var recorder: Recorder?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder, recorder.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save recording and quit?"
        alert.informativeText = "Your recording will be saved before EasyRecord closes."
        alert.addButton(withTitle: "Save and Quit")
        alert.addButton(withTitle: "Keep Recording")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        recorder.quitAfterFinishing = true
        Task { await recorder.stop() }
        return .terminateLater
    }
}
