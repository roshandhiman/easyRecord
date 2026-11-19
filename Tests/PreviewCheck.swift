import AppKit
import ScreenCaptureKit

@main
struct PreviewCheck {
    static func sample(_ color: UInt32, status: SCFrameStatus = .complete) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer) == kCVReturnSuccess)
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!
        for y in 0..<16 {
            let row = base.advanced(by: y * bytes).assumingMemoryBound(to: UInt32.self)
            for x in 0..<16 { row[x] = color }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var description: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &description) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 12), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: true)!
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        dictionary[SCStreamFrameInfo.status] = status.rawValue
        return sample!
    }

    static func main() throws {
        var frames: [CGImage] = []
        let output = LivePreviewOutput(onFrame: { frames.append($0) }, onError: { fatalError($0.localizedDescription) })
        output.consume(try sample(0xffff0000))
        output.consume(try sample(0xff0000ff))
        precondition(frames.count == 2, "Preview didn't deliver successive frames")
        precondition(frames.allSatisfy { $0.width == 16 && $0.height == 16 })
        let first = frames[0].dataProvider!.data! as Data
        let second = frames[1].dataProvider!.data! as Data
        precondition(first != second, "Preview frame stayed stale")
        output.consume(try sample(0xff00ff00, status: .idle))
        precondition(frames.count == 2, "Incomplete frame was displayed")
        output.disable()
        output.consume(try sample(0xff00ff00))
        precondition(frames.count == 2, "Disabled preview still rendered")
        print("PASS: changing live frames, output size, incomplete-frame rejection, and disabled-preview cleanup")
    }
}
