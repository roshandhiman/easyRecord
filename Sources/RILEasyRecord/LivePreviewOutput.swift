import ScreenCaptureKit
import CoreImage

/// Preview samples never enter a file writer or capture audio.
final class LivePreviewOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "com.easyrecord.preview", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var enabled = true
    private let onFrame: (CGImage) -> Void
    private let onError: (Error) -> Void

    init(onFrame: @escaping (CGImage) -> Void, onError: @escaping (Error) -> Void) {
        self.onFrame = onFrame
        self.onError = onError
    }

    func disable() {
        lock.lock()
        enabled = false
        lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        consume(sampleBuffer)
    }

    func consume(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let shouldRender = enabled
        lock.unlock()
        guard shouldRender, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: buffer)
            if let frame = context.createCGImage(image, from: image.extent) { onFrame(frame) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onError(error) }
}
