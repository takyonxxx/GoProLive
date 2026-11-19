import Foundation

/// Minimal MPEG-TS ayrıştırıcı: video (H.264) PES paketlerini çıkarır.
/// Yalnızca alım thread'inden kullanılmalıdır.
final class TSDemuxer {
    /// (bir PES paketinin elementary stream baytları, 90 kHz PTS)
    var onVideoPES: (([UInt8], Int64?) -> Void)?

    private static let packetSize = 188

    private var videoPID = -1
    private var pes = [UInt8]()
    private var pesStarted = false
    private var corrupted = false
    private var lastCC = -1

    func reset() {
        videoPID = -1
        pes.removeAll(keepingCapacity: true)
        pesStarted = false
        corrupted = false
        lastCC = -1
    }

    func feed(_ raw: UnsafeRawBufferPointer) {
        let size = TSDemuxer.packetSize
        let n = raw.count
        guard n >= size else { return }
        let p = raw.bindMemory(to: UInt8.self)

        // Sync baytını (0x47) bul; olası bir ön başlığı (ör. RTP) atlar.
        var offset = -1
        var o = 0
        let maxStart = min(n - size, size - 1)
        while o <= maxStart {
            if p[o] == 0x47 && (o + size >= n || p[o + size] == 0x47) {
                offset = o
                break
            }
            o += 1
        }
        guard offset >= 0 else { return }

        while offset + size <= n {
            if p[offset] == 0x47 { parsePacket(p, offset) }
            offset += size
        }
    }

    private func parsePacket(_ p: UnsafeBufferPointer<UInt8>, _ o: Int) {
        let b1 = p[o + 1], b2 = p[o + 2], b3 = p[o + 3]
        if b1 & 0x80 != 0 { return }                       // transport error
        let pusi = (b1 & 0x40) != 0
        let pid = (Int(b1 & 0x1F) << 8) | Int(b2)
        let afc = (b3 >> 4) & 0x3
        let cc = Int(b3 & 0x0F)
        guard afc & 0x1 != 0 else { return }               // payload yok
        if pid == 0 || pid == 0x1FFF { return }

        var start = o + 4
        if afc & 0x2 != 0 { start += 1 + Int(p[o + 4]) }   // adaptation field
        let end = o + TSDemuxer.packetSize
        guard start < end else { return }

        if videoPID < 0 {
            // Video PES başlangıcı (00 00 01 E0..EF) gördüğümüz ilk PID'e kilitlen.
            guard pusi, end - start >= 4,
                  p[start] == 0, p[start + 1] == 0, p[start + 2] == 1,
                  (p[start + 3] & 0xF0) == 0xE0 else { return }
            videoPID = pid
            lastCC = -1
        }
        guard pid == videoPID else { return }

        if lastCC >= 0 && cc != ((lastCC + 1) & 0x0F) { corrupted = true }
        lastCC = cc

        if pusi {
            flush()
            pesStarted = true
            corrupted = false
        }
        if pesStarted {
            pes.append(contentsOf: UnsafeBufferPointer(rebasing: p[start..<end]))
        }
    }

    private func flush() {
        defer { pes.removeAll(keepingCapacity: true) }
        guard pesStarted, !corrupted, pes.count > 14,
              pes[0] == 0, pes[1] == 0, pes[2] == 1 else { return }

        let flags = pes[7]
        let headerLength = Int(pes[8])
        let dataStart = 9 + headerLength
        guard dataStart < pes.count else { return }

        var pts: Int64?
        if flags & 0x80 != 0 && headerLength >= 5 {
            pts = (Int64(pes[9] & 0x0E) << 29)
                | (Int64(pes[10]) << 22)
                | (Int64(pes[11] & 0xFE) << 14)
                | (Int64(pes[12]) << 7)
                | (Int64(pes[13]) >> 1)
        }
        onVideoPES?(Array(pes[dataStart...]), pts)
    }
}
