import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

enum RecordingStatus: Equatable {
    case idle, starting, recording, pausing, paused, stopping, saving
    var label: String {
        switch self {
        case .idle: "Start"
        case .starting: "Starting…"
        case .recording: "Recording"
        case .pausing: "Pausing…"
        case .paused: "Paused"
        case .stopping, .saving: "Saving…"
        }
    }
}

enum CaptureMode: String, CaseIterable, Identifiable {
    case screen = "Screen", app = "Apps", window = "Windows"
    var id: String { rawValue }
}

enum CaptureQuality: String, CaseIterable, Identifiable {
    case hd = "720p", fullHD = "1080p", ultraHD = "4K"
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .hd: CGSize(width: 1280, height: 720)
        case .fullHD: CGSize(width: 1920, height: 1080)
        case .ultraHD: CGSize(width: 3840, height: 2160)
        }
    }
}

struct CaptureSource: Identifiable {
    let id: String
    let name: String
    let detail: String
    let mode: CaptureMode
    let icon: NSImage?
    let displayID: CGDirectDisplayID?
    let windowID: CGWindowID?
    let applicationPID: pid_t?
}

@MainActor
final class Recorder: NSObject, ObservableObject {
    @Published var mode: CaptureMode = .screen {
        didSet {
            if !visibleSources.contains(where: { $0.id == selectedID }) {
                selectedID = visibleSources.first?.id
            }
        }
    }
    @Published var selectedID: String? {
        didSet { if oldValue != selectedID && !isChoosingSource { refreshLivePreview() } }
    }
    @Published private(set) var isChoosingSource = false
    private let sourcePicker = SourcePicker()
    private var sharedFilter: SCContentFilter?
    private var sharedSource: CaptureSource?
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewError: String?
    @Published private(set) var previewEnabled = false
    private var previewVisible = false
    private var previewStream: SCStream?
    private var previewOutput: LivePreviewOutput?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = UUID()
    @Published private(set) var sources: [CaptureSource] = []
    @Published private(set) var status: RecordingStatus = .idle
    @Published private(set) var isLoading = false
    @Published private(set) var hasScreenPermission = CGPreflightScreenCaptureAccess()
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var systemAudio = true { didSet { UserDefaults.standard.set(systemAudio, forKey: "systemAudio") } }
    @Published var microphone = false { didSet { UserDefaults.standard.set(microphone, forKey: "microphone") } }
    @Published var frameRate = 60 { didSet { UserDefaults.standard.set(frameRate, forKey: "frameRate") } }
    @Published var quality: CaptureQuality = .fullHD { didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") } }
    @Published var errorMessage: String?
    var quitAfterFinishing = false

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var outputURL: URL?
    private var sessionDirectory: URL?
    private var segments: [URL] = []
    private var sessionFilter: SCContentFilter?
    private var sessionConfiguration: SCStreamConfiguration?
    private var startedAt: TimeInterval?
    private var recordedTime: TimeInterval = 0
    private var timer: Timer?
    private var saveWhenStopped = false
    private var recordingActivity: NSObjectProtocol?

    var isBusy: Bool { status != .idle }
    var selectedSource: CaptureSource? { sources.first { $0.id == selectedID } }
    var visibleSources: [CaptureSource] { sources.filter { $0.mode == mode } }
    var canStart: Bool { !isChoosingSource && (status == .paused || (status == .idle && selectedSource != nil && !isLoading)) }
    var canSave: Bool { status == .recording || status == .paused }
    var canToggleRecording: Bool { canStart || status == .recording }
    var elapsedText: String {
        let seconds = Int(elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    override init() {
        super.init()
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["systemAudio": true, "microphone": false, "frameRate": 60])
        systemAudio = defaults.bool(forKey: "systemAudio")
        microphone = defaults.bool(forKey: "microphone")
        frameRate = defaults.integer(forKey: "frameRate") == 30 ? 30 : 60
        quality = CaptureQuality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .fullHD
        loadLocalSources()
    }

    /// Display and running-app metadata doesn't require recording permission.
    /// Enumerating window contents and starting capture still uses ScreenCaptureKit consent.
    private func loadLocalSources() {
        let displays = NSScreen.screens.enumerated().compactMap { index, screen -> CaptureSource? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            return CaptureSource(id: "screen-\(id)", name: screen.localizedName, detail: "Entire screen", mode: .screen, icon: nil, displayID: id, windowID: nil, applicationPID: nil)
        }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }.map { app in
            CaptureSource(id: "app-\(app.processIdentifier)", name: app.localizedName ?? "Application", detail: "App windows", mode: .app, icon: app.icon, displayID: nil, windowID: nil, applicationPID: app.processIdentifier)
        }
        sources = displays + apps
        if let sharedSource, !sources.contains(where: { $0.id == sharedSource.id }) { sources.append(sharedSource) }
        if !sources.contains(where: { $0.id == selectedID }) { selectedID = visibleSources.first?.id }
    }

    func loadSources() async {
        guard !isBusy, !isLoading, !isChoosingSource else { return }
        // Never call CGRequestScreenCaptureAccess. A picker selection supplies its own
        // authorized filter even when the legacy preflight API reports false.
        guard hasScreenPermission || CGPreflightScreenCaptureAccess() else {
            loadLocalSources()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            hasScreenPermission = true
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let windows = content.windows.filter {
                $0.owningApplication?.processID != ownPID && $0.windowLayer == 0 &&
                $0.frame.width > 50 && $0.frame.height > 50
            }
            let screens = content.displays.enumerated().map { index, display in
                CaptureSource(id: "screen-\(display.displayID)", name: Self.displayName(display.displayID, fallback: index + 1), detail: "Entire screen", mode: .screen, icon: nil, displayID: display.displayID, windowID: nil, applicationPID: nil)
            }
            let apps = content.applications.filter { app in
                app.processID != ownPID && windows.contains { $0.owningApplication?.processID == app.processID }
            }.sorted { $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending }.map { app in
                CaptureSource(id: "app-\(app.processID)", name: app.applicationName, detail: "All app windows", mode: .app, icon: NSRunningApplication(processIdentifier: app.processID)?.icon, displayID: nil, windowID: nil, applicationPID: app.processID)
            }
            let windowSources = windows.sorted { ($0.owningApplication?.applicationName ?? "").localizedStandardCompare($1.owningApplication?.applicationName ?? "") == .orderedAscending }.map { window in
                CaptureSource(id: "window-\(window.windowID)", name: (window.title?.isEmpty == false ? window.title : window.owningApplication?.applicationName) ?? "Window", detail: window.owningApplication?.applicationName ?? "", mode: .window, icon: window.owningApplication.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.icon }, displayID: nil, windowID: window.windowID, applicationPID: nil)
            }
            sources = screens + apps + windowSources
            if !sources.contains(where: { $0.id == selectedID }) { selectedID = screens.first?.id }
        } catch {
            hasScreenPermission = false
            loadLocalSources()
        }
    }

    func chooseSource() async {
        guard !isBusy, !isChoosingSource else { return }
        do {
            _ = try await authorizedFilter(forcePicker: true)
            if previewEnabled { refreshLivePreview() }
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
    }

    private func authorizedFilter(forcePicker: Bool = false) async throws -> SCContentFilter {
        if !forcePicker {
            if let sharedFilter, sharedSource?.id == selectedID { return sharedFilter }
            if hasScreenPermission, let source = selectedSource {
                do { return try await filter(for: source) }
                catch { hasScreenPermission = false }
            }
        }
        guard !isChoosingSource else { throw CancellationError() }
        isChoosingSource = true
        defer { isChoosingSource = false }
        let chosenMode = mode
        let filter = try await sourcePicker.choose(chosenMode)
        let source = describeSelection(filter, mode: chosenMode)
        sharedFilter = filter
        sharedSource = source
        sources.removeAll { $0.id == source.id }
        sources.append(source)
        selectedID = source.id
        return filter
    }

    private func describeSelection(_ filter: SCContentFilter, mode: CaptureMode) -> CaptureSource {
        if #available(macOS 15.2, *) {
            if mode == .window, let window = filter.includedWindows.first {
                return CaptureSource(id: "window-\(window.windowID)", name: window.title ?? "Selected window", detail: window.owningApplication?.applicationName ?? "Window", mode: .window, icon: window.owningApplication.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.icon }, displayID: nil, windowID: window.windowID, applicationPID: nil)
            }
            if mode == .app, let app = filter.includedApplications.first {
                return CaptureSource(id: "app-\(app.processID)", name: app.applicationName, detail: "App windows", mode: .app, icon: NSRunningApplication(processIdentifier: app.processID)?.icon, displayID: nil, windowID: nil, applicationPID: app.processID)
            }
            if mode == .screen, let display = filter.includedDisplays.first {
                return CaptureSource(id: "screen-\(display.displayID)", name: Self.displayName(display.displayID, fallback: 1), detail: "Entire screen", mode: .screen, icon: nil, displayID: display.displayID, windowID: nil, applicationPID: nil)
            }
        }
        return CaptureSource(id: "shared-\(mode.rawValue)", name: "Selected \(mode == .app ? "app" : mode == .window ? "window" : "screen")", detail: mode == .screen ? "Entire screen" : mode == .app ? "App windows" : "Window", mode: mode, icon: nil, displayID: nil, windowID: nil, applicationPID: nil)
    }

    func setPreviewVisible(_ visible: Bool) {
        guard previewVisible != visible else { return }
        previewVisible = visible
        refreshLivePreview()
    }

    func toggleLivePreview() async {
        guard !isChoosingSource else { return }
        previewVisible = true
        previewEnabled.toggle()
        refreshLivePreview()
    }

    func retryLivePreview() {
        guard previewEnabled, !isChoosingSource else { return }
        refreshLivePreview()
    }

    private func refreshLivePreview() {
        previewTask?.cancel()
        previewOutput?.disable()
        previewImage = nil
        previewError = nil
        let generation = UUID()
        previewGeneration = generation
        let previousStream = previewStream
        let previousOutput = previewOutput
        previewStream = nil
        previewOutput = nil
        previewTask = Task { [weak self] in
            // Keep the old output alive until ScreenCaptureKit has stopped using it.
            if let previousStream { try? await previousStream.stopCapture() }
            withExtendedLifetime(previousOutput) {}
            guard !Task.isCancelled, let self,
                  self.previewEnabled, self.previewVisible else { return }
            do {
                let filter = try await self.authorizedFilter()
                guard !Task.isCancelled else { return }
                let config = SCStreamConfiguration()
                let rect = filter.contentRect
                let fit = min(960 / max(rect.width, 1), 540 / max(rect.height, 1))
                config.width = max(2, Int(rect.width * fit) / 2 * 2)
                config.height = max(2, Int(rect.height * fit) / 2 * 2)
                config.minimumFrameInterval = CMTime(value: 1, timescale: 12)
                config.queueDepth = 3
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = true
                config.capturesAudio = false
                config.captureMicrophone = false
                let output = LivePreviewOutput { [weak self] image in
                    Task { @MainActor [weak self] in
                        guard let self, self.previewGeneration == generation,
                              self.previewEnabled, self.previewVisible else { return }
                        self.previewImage = NSImage(cgImage: image, size: .zero)
                        self.previewError = nil
                    }
                } onError: { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, self.previewGeneration == generation else { return }
                        self.previewImage = nil
                        self.previewError = error.localizedDescription
                    }
                }
                let stream = SCStream(filter: filter, configuration: config, delegate: output)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                try await stream.startCapture()
                guard !Task.isCancelled, self.previewGeneration == generation else {
                    output.disable()
                    try? await stream.stopCapture()
                    return
                }
                self.previewStream = stream
                self.previewOutput = output
            } catch is CancellationError {
                guard self.previewGeneration == generation else { return }
                self.previewEnabled = false
            } catch {
                guard !Task.isCancelled, self.previewGeneration == generation else { return }
                self.sharedFilter = nil
                self.previewError = error.localizedDescription
            }
        }
    }

    private static func displayName(_ id: CGDirectDisplayID, fallback: Int) -> String {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.localizedName ?? "Display \(fallback)"
    }

    private func filter(for source: CaptureSource) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        if let windowID = source.windowID {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw RecorderError.sourceUnavailable }
            return SCContentFilter(desktopIndependentWindow: window)
        }
        if let pid = source.applicationPID {
            guard let app = content.applications.first(where: { $0.processID == pid }),
                  let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.isOnScreen }),
                  let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) else { throw RecorderError.appNotVisible }
            // App capture includes all its windows on the display containing its first visible window.
            return SCContentFilter(display: display, including: [app], exceptingWindows: [])
        }
        guard let display = content.displays.first(where: { $0.displayID == source.displayID }) else { throw RecorderError.sourceUnavailable }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
    }

    func toggleRecording() async {
        if status == .recording { await pause() }
        else if canStart { await start() }
    }

    func start() async {
        guard canStart else { return }
        let resuming = status == .paused
        status = .starting
        saveWhenStopped = false
        do {
            if !resuming {
                let filter = try await authorizedFilter()
                if microphone {
                    guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecorderError.microphoneDenied }
                    guard AVCaptureDevice.default(for: .audio) != nil else { throw RecorderError.noMicrophone }
                }
                let config = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                let width = filter.contentRect.width * scale
                let height = filter.contentRect.height * scale
                let fit = min(1, min(quality.size.width / max(width, 1), quality.size.height / max(height, 1)))
                config.width = max(2, Int(width * fit) / 2 * 2)
                config.height = max(2, Int(height * fit) / 2 * 2)
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                config.queueDepth = 6
                config.showsCursor = true
                config.capturesAudio = systemAudio
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
                config.captureMicrophone = microphone
                if microphone { config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID }
                sessionFilter = filter
                sessionConfiguration = config
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EasyRecord-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                sessionDirectory = directory
                segments = []
                recordedTime = 0
                elapsed = 0
            }
            guard let directory = sessionDirectory, let filter = sessionFilter, let config = sessionConfiguration else { throw RecorderError.sourceUnavailable }
            let url = directory.appendingPathComponent("\(UUID().uuidString).mp4")
            let recordingConfig = SCRecordingOutputConfiguration()
            recordingConfig.outputURL = url
            recordingConfig.videoCodecType = .h264
            recordingConfig.outputFileType = .mp4
            let recordingOutput = SCRecordingOutput(configuration: recordingConfig, delegate: self)
            let captureStream = SCStream(filter: filter, configuration: config, delegate: self)
            try captureStream.addRecordingOutput(recordingOutput)
            stream = captureStream
            output = recordingOutput
            outputURL = url
            try await captureStream.startCapture()
        } catch is CancellationError {
            status = resuming ? .paused : .idle
        } catch { fail(error) }
    }

    func pause() async {
        guard status == .recording, let stream else { return }
        freezeClock()
        status = .pausing
        do { try await stream.stopCapture() }
        catch { fail(error) }
    }

    func stop() async {
        saveWhenStopped = true
        switch status {
        case .recording:
            freezeClock()
            status = .stopping
            do { try await stream?.stopCapture() }
            catch { fail(error) }
        case .paused: await save()
        case .pausing: status = .stopping
        case .starting, .stopping, .saving: break
        case .idle:
            if quitAfterFinishing { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }

    private func didStart() {
        guard status == .starting else { return }
        startedAt = ProcessInfo.processInfo.systemUptime
        status = .recording
        recordingActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording your screen")
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = self.recordedTime + ProcessInfo.processInfo.systemUptime - startedAt
            }
        }
        if saveWhenStopped { Task { await stop() } }
    }

    private func didFinish() {
        guard output != nil else { return }
        freezeClock()
        if let url = outputURL { segments.append(url) }
        stream = nil
        output = nil
        outputURL = nil
        status = .paused
        if saveWhenStopped { Task { await save() } }
    }

    private func save() async {
        guard status == .paused, !segments.isEmpty else { return }
        status = .saving
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "EasyRecord \(Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")).mp4"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else {
            status = .paused
            cancelQuit()
            return
        }
        do {
            // Export to a new temporary file, then replace the user-approved destination atomically.
            guard let directory = sessionDirectory else { throw RecorderError.sourceUnavailable }
            let result = directory.appendingPathComponent("finished-\(UUID().uuidString).mp4")
            try await RecordingAssembler.assemble(segments: segments, destination: result)
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".EasyRecord-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: result, to: staged)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else { try FileManager.default.moveItem(at: staged, to: destination) }
            try? FileManager.default.removeItem(at: directory)
            segments = []
            sessionDirectory = nil
            sessionFilter = nil
            sessionConfiguration = nil
            status = .idle
            elapsed = 0
            recordedTime = 0
            if quitAfterFinishing { NSApp.reply(toApplicationShouldTerminate: true) }
        } catch {
            status = .paused
            errorMessage = "Couldn’t save. Your recording is retained; try Save again. \(error.localizedDescription)"
            cancelQuit()
        }
    }

    private func freezeClock() {
        if let startedAt { recordedTime += ProcessInfo.processInfo.systemUptime - startedAt }
        startedAt = nil
        elapsed = recordedTime
        timer?.invalidate()
        timer = nil
        if let recordingActivity { ProcessInfo.processInfo.endActivity(recordingActivity) }
        recordingActivity = nil
    }

    private func fail(_ error: Error) {
        freezeClock()
        let failedStream = stream
        stream = nil
        output = nil
        outputURL = nil
        status = segments.isEmpty ? .idle : .paused
        errorMessage = error.localizedDescription
        if let failedStream { Task { try? await failedStream.stopCapture() } }
        cancelQuit()
    }

    private func cancelQuit() {
        if quitAfterFinishing {
            quitAfterFinishing = false
            NSApp.reply(toApplicationShouldTerminate: false)
        }
    }

}

extension Recorder: SCRecordingOutputDelegate, SCStreamDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, self.output === recordingOutput else { return }
            self.didStart()
        }
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, self.output === recordingOutput else { return }
            self.didFinish()
        }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.output === recordingOutput else { return }
            self.fail(error)
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            self.fail(error)
        }
    }
}

private enum RecorderError: LocalizedError {
    case sourceUnavailable, appNotVisible, microphoneDenied, noMicrophone
    var errorDescription: String? {
        switch self {
        case .sourceUnavailable: "This source is unavailable. Refresh and choose another."
        case .appNotVisible: "Open a window of this app on a display before recording it."
        case .microphoneDenied: "Allow EasyRecord in System Settings → Privacy & Security → Microphone, or mute the microphone."
        case .noMicrophone: "Connect a microphone or mute the microphone."
        }
    }
}
