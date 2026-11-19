import Foundation
import Network

/// Kameradan gelen H.264 akışını RTSP ile yeniden yayınlar.
/// Yalnızca TCP (RTP/AVP/TCP, interleaved) taşıma desteklenir; UDP isteyen istemciye 461 döner.
/// Tüm durum `queue` üzerinde tutulur.
final class RTSPServer: @unchecked Sendable {
    private final class Client {
        let id: Int
        let connection: NWConnection
        let session: String
        let ssrc: UInt32
        var buffer = [UInt8]()
        var channel = 0
        var playing = false
        var waitingForKeyframe = true
        var seq: UInt16
        var pendingBytes = 0

        init(id: Int, connection: NWConnection) {
            self.id = id
            self.connection = connection
            session = String(format: "%08X", UInt32.random(in: 1...UInt32.max))
            ssrc = UInt32.random(in: 1...UInt32.max)
            seq = UInt16.random(in: 0...UInt16.max)
        }
    }

    private static let payloadType: UInt8 = 96
    private static let maxPayload = 1400
    /// İstemci bu kadar veriyi çekemediyse kare atla (yavaş bağlantı).
    private static let maxPendingBytes = 2_000_000

    private let queue = DispatchQueue(label: "GoProLive.rtsp")
    private var listener: NWListener?
    private var clients = [Int: Client]()
    private var nextID = 0
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var lastTimestamp: UInt32 = 0

    // MARK: - Genel API (herhangi bir thread)

    func start(port: UInt16) {
        queue.async {
            guard self.listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.allowLocalEndpointReuse = true
            do {
                let listener = try NWListener(using: parameters, on: nwPort)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.stateUpdateHandler = { state in
                    if case .failed(let error) = state {
                        print("RTSP dinleyici hatası: \(error)")
                    }
                }
                listener.start(queue: self.queue)
                self.listener = listener
            } catch {
                print("RTSP sunucusu başlatılamadı: \(error)")
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            let all = Array(self.clients.values)
            self.clients.removeAll()
            all.forEach { $0.connection.cancel() }
            self.sps = nil
            self.pps = nil
        }
    }

    /// Bir Annex-B access unit'i (90 kHz PTS ile) oynatan tüm istemcilere yollar.
    func publish(_ es: [UInt8], pts: Int64?) {
        queue.async { self.distribute(es, pts: pts) }
    }

    /// Bu cihazın yerel IPv4 adresi (GoPro ağındaki adres öncelikli).
    static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String?
        var pointer = ifaddr
        while let current = pointer {
            pointer = current.pointee.ifa_next
            let flags = Int32(current.pointee.ifa_flags)
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("10.5.5.") { return ip }
            if fallback == nil, String(cString: current.pointee.ifa_name).hasPrefix("en") {
                fallback = ip
            }
        }
        return fallback
    }

    // MARK: - Bağlantılar

    private func accept(_ connection: NWConnection) {
        nextID += 1
        let client = Client(id: nextID, connection: connection)
        clients[client.id] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self = self, let client = client else { return }
            switch state {
            case .failed, .cancelled:
                self.remove(client)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func remove(_ client: Client) {
        guard clients.removeValue(forKey: client.id) != nil else { return }
        client.connection.cancel()
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
            [weak self, weak client] data, _, isComplete, error in
            guard let self = self, let client = client else { return }
            if let data = data, !data.isEmpty {
                client.buffer.append(contentsOf: data)
                self.processBuffer(client)
            }
            if isComplete || error != nil {
                self.remove(client)
                return
            }
            if self.clients[client.id] != nil {
                self.receive(client)
            }
        }
    }

    // MARK: - RTSP istekleri

    private func processBuffer(_ client: Client) {
        while !client.buffer.isEmpty {
            // İstemciden gelen interleaved veri (RTCP): "$" kanal uzunluk(2) ... -> atla
            if client.buffer[0] == 0x24 {
                guard client.buffer.count >= 4 else { return }
                let length = Int(client.buffer[2]) << 8 | Int(client.buffer[3])
                guard client.buffer.count >= 4 + length else { return }
                client.buffer.removeFirst(4 + length)
                continue
            }

            guard let headerEnd = RTSPServer.headerEnd(client.buffer) else {
                if client.buffer.count > 16384 { remove(client) }
                return
            }
            let text = String(decoding: client.buffer[0..<headerEnd], as: UTF8.self)
            let lines = text.components(separatedBy: "\r\n")
            var headers = [String: String]()
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let bodyLength = max(0, Int(headers["content-length"] ?? "") ?? 0)
            let total = headerEnd + 4 + bodyLength
            guard client.buffer.count >= total else { return }
            client.buffer.removeFirst(total)

            let parts = lines[0].split(separator: " ")
            guard parts.count >= 2 else { continue }
            handle(method: String(parts[0]).uppercased(), url: String(parts[1]),
                   headers: headers, client: client)
        }
    }

    /// "\r\n\r\n" dizisinin başladığı indeks.
    private static func headerEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4)
        where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
            return i
        }
        return nil
    }

    private func handle(method: String, url: String, headers: [String: String], client: Client) {
        let cseq = headers["cseq"] ?? "0"
        let sessionHeader = "Session: \(client.session);timeout=60"

        switch method {
        case "OPTIONS":
            respond(client, cseq: cseq,
                    headers: ["Public: OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN, GET_PARAMETER"])

        case "DESCRIBE":
            let base = url.hasSuffix("/") ? url : url + "/"
            respond(client, cseq: cseq,
                    headers: ["Content-Base: \(base)", "Content-Type: application/sdp"],
                    body: makeSDP())

        case "SETUP":
            let transport = headers["transport"] ?? ""
            guard transport.uppercased().contains("RTP/AVP/TCP") else {
                // Yalnızca TCP: istemci (ffmpeg, VLC) TCP ile yeniden dener.
                respond(client, status: "461 Unsupported Transport", cseq: cseq)
                return
            }
            var channel = 0
            if let range = transport.range(of: "interleaved=", options: .caseInsensitive) {
                let digits = transport[range.upperBound...].prefix { $0.isNumber }
                channel = min(Int(digits) ?? 0, 254)
            }
            client.channel = channel
            let ssrc = String(format: "%08X", client.ssrc)
            respond(client, cseq: cseq, headers: [
                "Transport: RTP/AVP/TCP;unicast;interleaved=\(channel)-\(channel + 1);ssrc=\(ssrc)",
                sessionHeader,
            ])

        case "PLAY":
            client.waitingForKeyframe = true
            client.playing = true
            respond(client, cseq: cseq, headers: [sessionHeader, "Range: npt=0.000-"])

        case "PAUSE":
            client.playing = false
            respond(client, cseq: cseq, headers: [sessionHeader])

        case "GET_PARAMETER", "SET_PARAMETER":
            respond(client, cseq: cseq, headers: [sessionHeader])

        case "TEARDOWN":
            client.playing = false
            respond(client, cseq: cseq, headers: [sessionHeader], closeAfter: true)

        default:
            respond(client, status: "405 Method Not Allowed", cseq: cseq)
        }
    }

    private func respond(_ client: Client, status: String = "200 OK", cseq: String,
                         headers: [String] = [], body: String = "", closeAfter: Bool = false) {
        var lines = ["RTSP/1.0 \(status)", "CSeq: \(cseq)", "Server: GoProLive"]
        lines.append(contentsOf: headers)
        if !body.isEmpty { lines.append("Content-Length: \(body.utf8.count)") }
        let text = lines.joined(separator: "\r\n") + "\r\n\r\n" + body
        client.connection.send(content: Data(text.utf8), completion: .contentProcessed {
            [weak self, weak client] error in
            guard let self = self, let client = client else { return }
            if closeAfter || error != nil { self.remove(client) }
        })
    }

    private func makeSDP() -> String {
        var fmtp = "a=fmtp:96 packetization-mode=1"
        if let sps = sps, let pps = pps, sps.count >= 4 {
            let profile = String(format: "%02X%02X%02X", sps[1], sps[2], sps[3])
            fmtp += ";profile-level-id=\(profile)"
            fmtp += ";sprop-parameter-sets=\(Data(sps).base64EncodedString()),\(Data(pps).base64EncodedString())"
        }
        return [
            "v=0",
            "o=- 0 0 IN IP4 0.0.0.0",
            "s=GoPro Live",
            "c=IN IP4 0.0.0.0",
            "t=0 0",
            "a=control:*",
            "m=video 0 RTP/AVP 96",
            "a=rtpmap:96 H264/90000",
            fmtp,
            "a=control:trackID=0",
        ].joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - RTP (RFC 6184) paketleme

    private func distribute(_ es: [UInt8], pts: Int64?) {
        var nals = [Range<Int>]()
        var hasIDR = false
        var hasSPS = false
        var hasPPS = false
        for range in H264Renderer.nalRanges(es) where !range.isEmpty {
            switch es[range.lowerBound] & 0x1F {
            case 7:
                sps = Array(es[range]); hasSPS = true; nals.append(range)
            case 8:
                pps = Array(es[range]); hasPPS = true; nals.append(range)
            case 5:
                hasIDR = true; nals.append(range)
            case 9, 12:
                break   // AUD ve dolgu gönderilmez
            default:
                nals.append(range)
            }
        }

        let timestamp = pts.map { UInt32(truncatingIfNeeded: $0) } ?? lastTimestamp &+ 3000
        lastTimestamp = timestamp
        guard !nals.isEmpty, !clients.isEmpty else { return }

        for client in clients.values where client.playing {
            if client.pendingBytes > RTSPServer.maxPendingBytes {
                client.waitingForKeyframe = true
                continue
            }
            if client.waitingForKeyframe {
                guard hasIDR else { continue }
                client.waitingForKeyframe = false
            }

            var out = [UInt8]()
            out.reserveCapacity(es.count + (es.count / RTSPServer.maxPayload + nals.count + 2) * 18)
            if hasIDR {
                // Anahtar karede parametre setleri yoksa önbellektekileri ekle.
                if !hasSPS, let sps = sps { append(nal: sps[...], marker: false, timestamp: timestamp, client: client, to: &out) }
                if !hasPPS, let pps = pps { append(nal: pps[...], marker: false, timestamp: timestamp, client: client, to: &out) }
            }
            for (index, range) in nals.enumerated() {
                append(nal: es[range], marker: index == nals.count - 1,
                       timestamp: timestamp, client: client, to: &out)
            }

            let count = out.count
            client.pendingBytes += count
            client.connection.send(content: Data(out), completion: .contentProcessed {
                [weak self, weak client] error in
                guard let self = self, let client = client else { return }
                client.pendingBytes -= count
                if error != nil { self.remove(client) }
            })
        }
    }

    /// Bir NAL'ı tek paket ya da FU-A parçaları olarak, interleaved çerçeveleriyle ekler.
    private func append(nal: ArraySlice<UInt8>, marker: Bool, timestamp: UInt32,
                        client: Client, to out: inout [UInt8]) {
        guard !nal.isEmpty else { return }
        if nal.count <= RTSPServer.maxPayload {
            appendHeader(payloadLength: nal.count, marker: marker, timestamp: timestamp, client: client, to: &out)
            out.append(contentsOf: nal)
            return
        }

        let nalHeader = nal[nal.startIndex]
        let indicator = (nalHeader & 0xE0) | 28   // FU-A
        let type = nalHeader & 0x1F
        var offset = nal.startIndex + 1
        let end = nal.endIndex
        var first = true
        while offset < end {
            let chunk = min(RTSPServer.maxPayload - 2, end - offset)
            let last = offset + chunk == end
            var fuHeader = type
            if first { fuHeader |= 0x80 }
            if last { fuHeader |= 0x40 }
            appendHeader(payloadLength: chunk + 2, marker: marker && last,
                         timestamp: timestamp, client: client, to: &out)
            out.append(indicator)
            out.append(fuHeader)
            out.append(contentsOf: nal[offset..<(offset + chunk)])
            offset += chunk
            first = false
        }
    }

    /// "$" + kanal + uzunluk, ardından 12 baytlık RTP başlığı.
    private func appendHeader(payloadLength: Int, marker: Bool, timestamp: UInt32,
                              client: Client, to out: inout [UInt8]) {
        let length = 12 + payloadLength
        out.append(0x24)
        out.append(UInt8(client.channel))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(0x80)
        out.append((marker ? 0x80 : 0) | RTSPServer.payloadType)
        out.append(UInt8(truncatingIfNeeded: client.seq >> 8))
        out.append(UInt8(truncatingIfNeeded: client.seq))
        out.append(UInt8(truncatingIfNeeded: timestamp >> 24))
        out.append(UInt8(truncatingIfNeeded: timestamp >> 16))
        out.append(UInt8(truncatingIfNeeded: timestamp >> 8))
        out.append(UInt8(truncatingIfNeeded: timestamp))
        out.append(UInt8(truncatingIfNeeded: client.ssrc >> 24))
        out.append(UInt8(truncatingIfNeeded: client.ssrc >> 16))
        out.append(UInt8(truncatingIfNeeded: client.ssrc >> 8))
        out.append(UInt8(truncatingIfNeeded: client.ssrc))
        client.seq &+= 1
    }
}
