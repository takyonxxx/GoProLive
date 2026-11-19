import AVFoundation
import CoreMedia

/// Annex-B H.264 access unit'lerini AVSampleBufferDisplayLayer'a (donanımsal çözücü) besler.
/// handleAccessUnit yalnızca alım thread'inden çağrılmalıdır.
final class H264Renderer {
    let displayLayer: AVSampleBufferDisplayLayer

    var onFrame: (() -> Void)?
    var onFormat: ((Int32, Int32) -> Void)?

    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var waitingForKeyframe = true
    private var resetRequested = false
    private let lock = NSLock()

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    /// Herhangi bir thread'den çağrılabilir.
    func requestReset() {
        lock.lock()
        resetRequested = true
        lock.unlock()
    }

    func handleAccessUnit(_ es: [UInt8], pts: Int64?) {
        let renderer = displayLayer.sampleBufferRenderer

        lock.lock()
        let doReset = resetRequested
        resetRequested = false
        lock.unlock()
        if doReset {
            sps = nil
            pps = nil
            format = nil
            waitingForKeyframe = true
            renderer.flush()
        }

        var avcc = [UInt8]()
        avcc.reserveCapacity(es.count + 64)
        var hasIDR = false
        var parameterSetsChanged = false

        for range in H264Renderer.nalRanges(es) where !range.isEmpty {
            let type = es[range.lowerBound] & 0x1F
            switch type {
            case 7:
                let nal = Array(es[range])
                if sps == nil || sps! != nal { sps = nal; parameterSetsChanged = true }
            case 8:
                let nal = Array(es[range])
                if pps == nil || pps! != nal { pps = nal; parameterSetsChanged = true }
            case 1, 5:
                if type == 5 { hasIDR = true }
                let length = UInt32(range.count)
                avcc.append(UInt8(truncatingIfNeeded: length >> 24))
                avcc.append(UInt8(truncatingIfNeeded: length >> 16))
                avcc.append(UInt8(truncatingIfNeeded: length >> 8))
                avcc.append(UInt8(truncatingIfNeeded: length))
                avcc.append(contentsOf: es[range])
            default:
                break   // AUD, SEI vb.
            }
        }

        if (parameterSetsChanged || format == nil), let sps = sps, let pps = pps {
            if let newFormat = H264Renderer.makeFormat(sps: sps, pps: pps) {
                format = newFormat
                waitingForKeyframe = true
                let dims = CMVideoFormatDescriptionGetDimensions(newFormat)
                onFormat?(dims.width, dims.height)
            }
        }

        guard let format = format, !avcc.isEmpty else { return }

        if renderer.status == .failed {
            renderer.flush()
            waitingForKeyframe = true
        }
        if waitingForKeyframe {
            guard hasIDR else { return }
            waitingForKeyframe = false
        }

        guard let sample = H264Renderer.makeSampleBuffer(avcc: avcc, format: format, pts: pts) else { return }
        renderer.enqueue(sample)
        onFrame?()
    }

    // MARK: - Yardımcılar

    /// Annex-B akışındaki NAL birimlerinin (start code hariç) aralıkları.
    static func nalRanges(_ bytes: [UInt8]) -> [Range<Int>] {
        var ranges = [Range<Int>]()
        bytes.withUnsafeBufferPointer { b in
            let n = b.count
            var i = 0
            var start = -1
            while i + 3 <= n {
                if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
                    if start >= 0 {
                        var end = i
                        while end > start && b[end - 1] == 0 { end -= 1 }
                        ranges.append(start..<end)
                    }
                    start = i + 3
                    i += 3
                } else {
                    i += 1
                }
            }
            if start >= 0 && start < n { ranges.append(start..<n) }
        }
        return ranges
    }

    private static func makeFormat(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBufferPointer { spsPtr in
            pps.withUnsafeBufferPointer { ppsPtr in
                guard let spsBase = spsPtr.baseAddress, let ppsBase = ppsPtr.baseAddress else {
                    return OSStatus(-1)
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [spsPtr.count, ppsPtr.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    private static func makeSampleBuffer(avcc: [UInt8],
                                         format: CMVideoFormatDescription,
                                         pts: Int64?) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        status = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!,
                                          blockBuffer: block,
                                          offsetIntoDestination: 0,
                                          dataLength: avcc.count)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts.map { CMTime(value: $0, timescale: 90_000) } ?? .invalid,
            decodeTimeStamp: .invalid)
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sample = sampleBuffer else { return nil }

        // Düşük gecikme: zaman damgasını bekleme, hemen göster.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
