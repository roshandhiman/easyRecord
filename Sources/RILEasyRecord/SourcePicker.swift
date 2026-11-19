import AppKit
import ScreenCaptureKit

/// The system picker grants access to a specific source without a Settings detour.
@MainActor
final class SourcePicker: NSObject, SCContentSharingPickerObserver {
    private var pending: CheckedContinuation<SCContentFilter, Error>?
    private var observing = false

    func choose(_ mode: CaptureMode) async throws -> SCContentFilter {
        guard pending == nil else { throw CancellationError() }
        let picker = SCContentSharingPicker.shared
        if !observing {
            picker.add(self)
            observing = true
        }
        var configuration = SCContentSharingPickerConfiguration()
        switch mode {
        case .screen: configuration.allowedPickerModes = .singleDisplay
        case .app: configuration.allowedPickerModes = .singleApplication
        case .window: configuration.allowedPickerModes = .singleWindow
        }
        configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "com.easyrecord.mac"]
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 2
        picker.isActive = true
        NSApp.activate(ignoringOtherApps: true)
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            switch mode {
            case .screen: picker.present(using: .display)
            case .app: picker.present(using: .application)
            case .window: picker.present(using: .window)
            }
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in self?.finish(.success(filter)) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in self?.finish(.failure(error)) }
    }

    private func finish(_ result: Result<SCContentFilter, Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}
