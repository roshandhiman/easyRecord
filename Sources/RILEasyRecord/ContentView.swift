import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var recorder: Recorder
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""

    private var filteredSources: [CaptureSource] {
        recorder.visibleSources.filter { search.isEmpty || "\($0.name) \($0.detail)".localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $search).textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 14).frame(height: 36)
                .background(.white.opacity(0.075), in: Capsule())
                iconButton(recorder.previewEnabled ? "eye" : "eye.slash", label: recorder.previewEnabled ? "Hide live preview" : "Show live preview", enabled: !recorder.isChoosingSource, active: recorder.previewEnabled) {
                    Task { await recorder.toggleLivePreview() }
                }
                iconButton("arrow.clockwise", label: "Refresh sources", enabled: !recorder.isBusy && !recorder.isLoading) {
                    Task { await recorder.loadSources(); recorder.retryLivePreview() }
                }
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 15)

            HStack(spacing: 5) {
                ForEach(CaptureMode.allCases) { mode in
                    Button { recorder.mode = mode; search = "" } label: {
                        Text(mode.rawValue).font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(recorder.mode == mode ? Color.white.opacity(0.13) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(recorder.mode == mode ? .isSelected : [])
                }
            }
            .padding(4).background(.black.opacity(0.13), in: Capsule())
            .padding(.horizontal, 22).padding(.bottom, 14)
            .disabled(recorder.isBusy || recorder.isChoosingSource)

            if recorder.previewEnabled {
                livePreview
                    .padding(.horizontal, 22)
                    .padding(.bottom, 14)
            }

            if !recorder.hasScreenPermission && recorder.mode == .window && filteredSources.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "display").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                    Button("Choose Window") { Task { await recorder.chooseSource() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSources.isEmpty {
                VStack(spacing: 12) {
                    if recorder.isLoading { ProgressView().controlSize(.small) }
                    else {
                        Image(systemName: "macwindow").font(.system(size: 28, weight: .light))
                        Text(search.isEmpty ? "No available sources" : "No results").font(.system(size: 12))
                    }
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredSources) { source in sourceRow(source) }
                    }.padding(.horizontal, 22).padding(.bottom, 16)
                }
                .disabled(recorder.isBusy || recorder.isChoosingSource)
            }
            controlBar
        }
        .foregroundStyle(Color(white: 0.91))
        .background {
            ZStack {
                WindowGlass()
                Color.black.opacity(0.28)
            }.ignoresSafeArea()
        }
        .background(WindowSetup())
        .frame(minWidth: 600, minHeight: recorder.previewEnabled ? 560 : 420)
        .onAppear { recorder.setPreviewVisible(true) }
        .onDisappear { recorder.setPreviewVisible(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in recorder.setPreviewVisible(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in recorder.setPreviewVisible(true) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { notification in
            if (notification.object as? NSWindow)?.identifier?.rawValue == "easyrecord" { recorder.setPreviewVisible(false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { notification in
            if (notification.object as? NSWindow)?.identifier?.rawValue == "easyrecord" { recorder.setPreviewVisible(true) }
        }
        .task { await recorder.loadSources() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await recorder.loadSources() } }
        }
        .alert("EasyRecord", isPresented: Binding(get: { recorder.errorMessage != nil }, set: { if !$0 { recorder.errorMessage = nil } })) {
            Button("OK", role: .cancel) { recorder.errorMessage = nil }
        } message: { Text(recorder.errorMessage ?? "") }
    }

    private var livePreview: some View {
        ZStack {
            Color.black.opacity(0.5)
            if let image = recorder.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let error = recorder.previewError {
                Button { recorder.retryLivePreview() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 22, weight: .light))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Retry preview: \(error)")
                .accessibilityLabel("Retry preview: \(error)")
            } else if recorder.selectedSource != nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "display").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.10)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live preview of \(recorder.selectedSource?.name ?? "selected source")")
    }

    private func sourceRow(_ source: CaptureSource) -> some View {
        let selected = recorder.selectedID == source.id
        return Button { recorder.selectedID = source.id } label: {
            HStack(spacing: 14) {
                Group {
                    if let icon = source.icon { Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit) }
                    else { Image(systemName: "display").font(.system(size: 26, weight: .light)).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(source.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(selected ? Color(white: 0.92) : Color.white.opacity(0.22))
            }
            .padding(.horizontal, 17).padding(.vertical, 15)
            .background(.white.opacity(selected ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 23))
            .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(.white.opacity(selected ? 0.27 : 0.12), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 23))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(source.name), \(source.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var controlBar: some View {
        HStack(spacing: 7) {
            iconButton(recorder.systemAudio ? "speaker.wave.2" : "speaker.slash", label: recorder.systemAudio ? "Mute system audio" : "Unmute system audio", enabled: !recorder.isBusy, active: recorder.systemAudio) {
                recorder.systemAudio.toggle()
            }
            iconButton(recorder.microphone ? "mic" : "mic.slash", label: recorder.microphone ? "Mute microphone" : "Unmute microphone", enabled: !recorder.isBusy, active: recorder.microphone) {
                recorder.microphone.toggle()
            }
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 20).padding(.horizontal, 5)
            Menu {
                Picker("Quality", selection: $recorder.quality) {
                    ForEach(CaptureQuality.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: { menuLabel(recorder.quality.rawValue) }
            .menuStyle(.borderlessButton).fixedSize().disabled(recorder.isBusy)
            .help("Recording quality").accessibilityLabel("Recording quality")
            Menu {
                Picker("Frame rate", selection: $recorder.frameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
            } label: { menuLabel("\(recorder.frameRate) fps") }
            .menuStyle(.borderlessButton).fixedSize().disabled(recorder.isBusy)
            .help("Frame rate").accessibilityLabel("Frame rate")
            Spacer(minLength: 8)
            if recorder.isBusy {
                Text(recorder.elapsedText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Duration \(recorder.elapsedText)")
            }
            if [.starting, .pausing, .stopping, .saving].contains(recorder.status) {
                ProgressView().controlSize(.small).frame(width: 38, height: 36)
                    .help(recorder.status.label)
            } else {
                iconButton(recorder.status == .recording ? "pause.fill" : recorder.status == .paused ? "play.fill" : "record.circle.fill", label: recorder.status == .recording ? "Pause" : recorder.status == .paused ? "Resume" : "Start recording", enabled: recorder.canToggleRecording, active: true, record: recorder.status == .idle) {
                    Task { await recorder.toggleRecording() }
                }
            }
            iconButton("square.and.arrow.down", label: "Save recording", enabled: recorder.canSave) {
                Task { await recorder.stop() }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 15)
        .background(.black.opacity(0.12))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
    }

    private func menuLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).padding(.leading, 8).padding(.vertical, 8)
    }

    private func iconButton(_ symbol: String, label: String, enabled: Bool = true, active: Bool = true, record: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: record ? 22 : 16, weight: .regular))
                .foregroundStyle(record ? Color(red: 0.96, green: 0.38, blue: 0.38) : active ? Color(white: 0.91) : Color(white: 0.5))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.065), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.3)
        .help(label).accessibilityLabel(label)
    }
}

private struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct WindowSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }
    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
    }
}
