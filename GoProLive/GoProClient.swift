import AVFoundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Alım thread'i ile arayüz arasında paylaşılan sayaçlar.
final class StreamCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var frames = 0
    private var lastData = Date.distantPast

    func addBytes(_ n: Int) {
        lock.lock(); bytes += n; lastData = Date(); lock.unlock()
    }
    func addFrame() {
        lock.lock(); frames += 1; lock.unlock()
    }
    func touch() {
        lock.lock(); lastData = Date(); lock.unlock()
    }
    /// Sayaçları okur ve sıfırlar.
    func take() -> (bytes: Int, frames: Int, lastData: Date) {
        lock.lock(); defer { lock.unlock() }
        let result = (bytes, frames, lastData)
        bytes = 0
        frames = 0
        return result
    }
}

@MainActor
final class GoProClient: ObservableObject {
    enum State: Equatable {
        case disconnected, connecting, connected, starting, streaming
    }

    // HERO7 Wi-Fi erişim noktası sabitleri
    private let host = "10.5.5.9"
    private let streamPort: UInt16 = 8554
    /// Yeniden yayın için RTSP (TCP) portu; kameradan alım UDP olduğu için aynı numara çakışmaz.
    private let rtspPort: UInt16 = 8554
    private let keepAlive = Array("_GPHD_:0:0:2:0.000000\n".utf8)

    @Published private(set) var state: State = .disconnected
    @Published private(set) var cameraName = ""
    @Published private(set) var message = L("GoPro Wi-Fi ağına bağlanın, sonra Bağlan'a dokunun.", "Join the GoPro Wi-Fi network, then tap Connect.")
    @Published private(set) var bitrateKbps = 0
    @Published private(set) var fps = 0
    @Published private(set) var videoSize = ""
    /// Kamera pil yüzdesi (henüz okunamadıysa nil).
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var batteryCharging = false
    /// Kameranın bildirdiği ayarlar (ayar no -> değer); kontrol sayfası seçili olanı buradan gösterir.
    @Published private(set) var cameraSettings = [Int: Int]()
    @Published private(set) var isRecording = false
    /// 0 = video, 1 = fotoğraf, 2 = çoklu çekim
    @Published private(set) var cameraMode: Int?
    @Published private(set) var remainingVideoSeconds: Int?
    /// Son gönderilen komutun sonucu.
    @Published private(set) var commandMessage = ""
    /// Yayın sürerken diğer cihazların bağlanabileceği RTSP adresi.
    @Published private(set) var rtspURL: String?

    let displayLayer = AVSampleBufferDisplayLayer()

    private let session: URLSession
    private let udp = UDPReceiver()
    private let demuxer = TSDemuxer()
    private let renderer: H264Renderer
    private let rtsp = RTSPServer()
    private let counters = StreamCounters()
    private var loopTask: Task<Void, Never>?
    private var lastRestart = Date.distantPast
    private var resumeOnActive = false
    #if os(macOS)
    private var awakeActivity: NSObjectProtocol?
    #endif

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        config.allowsCellularAccess = false
        session = URLSession(configuration: config)

        displayLayer.videoGravity = .resizeAspect
        renderer = H264Renderer(displayLayer: displayLayer)

        // Boru hattı: UDP -> MPEG-TS -> H.264 -> ekran (hepsi alım thread'inde)
        let counters = self.counters
        let demuxer = self.demuxer
        let renderer = self.renderer
        let rtsp = self.rtsp
        udp.onDatagram = { buffer in
            counters.addBytes(buffer.count)
            demuxer.feed(buffer)
        }
        demuxer.onVideoPES = { es, pts in
            renderer.handleAccessUnit(es, pts: pts)
            rtsp.publish(es, pts: pts)
        }
        renderer.onFrame = {
            counters.addFrame()
        }
        renderer.onFormat = { [weak self] width, height in
            Task { @MainActor in
                self?.videoSize = "\(width)×\(height)"
            }
        }
    }

    // MARK: - Genel API

    func connect() async {
        guard state == .disconnected else { return }
        state = .connecting
        message = L("Kamera aranıyor…", "Searching for camera…")
        do {
            let data = try await get("/gp/gpControl/info")
            var name = "GoPro"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let info = json["info"] as? [String: Any] {
                let model = info["model_name"] as? String ?? "GoPro"
                let firmware = info["firmware_version"] as? String ?? ""
                name = firmware.isEmpty ? model : "\(model) (\(firmware))"
            }
            cameraName = name
            state = .connected
            message = L("Bağlandı.", "Connected.")
            await refreshBattery()
        } catch {
            state = .disconnected
            message = L("Kameraya ulaşılamadı. Cihazın GoPro Wi-Fi ağına bağlı olduğunu ve Yerel Ağ iznini verdiğinizi kontrol edin.", "Can't reach the camera. Check that this device is on the GoPro Wi-Fi network and that Local Network access is allowed.") + "\n(\(error.localizedDescription))"
        }
    }

    func startStream() async {
        if state == .disconnected { await connect() }
        guard state == .connected else { return }
        state = .starting
        message = L("Yayın başlatılıyor…", "Starting stream…")
        do {
            demuxer.reset()            // alım thread'i henüz çalışmıyor
            renderer.requestReset()
            try udp.start(port: streamPort)
            rtsp.start(port: rtspPort)
            rtspURL = RTSPServer.localIPv4().map { "rtsp://\($0):\(rtspPort)/live" }

            await ensureWidescreen()

            // Önizleme için 720p iste; HERO7 bunu yok sayıp 848×480 veriyor, zararı yok.
            _ = try? await get("/gp/gpControl/setting/64/7")
            try await sendRestart()

            counters.touch()
            _ = counters.take()
            state = .streaming
            message = L("Canlı yayın", "Live")
            setKeepAwake(true)
            startLoop()
        } catch {
            udp.stop()
            rtsp.stop()
            rtspURL = nil
            state = .connected
            message = L("Yayın başlatılamadı: ", "Couldn't start the stream: ") + error.localizedDescription
        }
    }

    func stopStream(notifyCamera: Bool = true) async {
        guard state == .streaming || state == .starting else { return }
        loopTask?.cancel()
        loopTask = nil
        udp.stop()
        rtsp.stop()
        rtspURL = nil
        setKeepAwake(false)
        bitrateKbps = 0
        fps = 0
        state = .connected
        message = L("Yayın durduruldu.", "Stream stopped.")
        if notifyCamera {
            _ = try? await get("/gp/gpControl/execute?p1=gpStream&a1=proto_v2&c1=stop")
        }
    }

    func disconnect() async {
        await stopStream()
        state = .disconnected
        cameraName = ""
        videoSize = ""
        batteryPercent = nil
        batteryCharging = false
        cameraSettings = [:]
        isRecording = false
        cameraMode = nil
        remainingVideoSeconds = nil
        commandMessage = ""
        message = L("Bağlantı kesildi.", "Disconnected.")
    }

    /// Uygulama arka plana geçince yayını bırak, geri gelince sürdür.
    func scenePhaseChanged(_ phase: ScenePhase) {
        #if os(macOS)
        // Mac'te uygulama arka planda da çalışır; yayına dokunma.
        #else
        switch phase {
        case .background:
            if state == .streaming {
                resumeOnActive = true
                Task { await stopStream(notifyCamera: false) }
            }
        case .active:
            if resumeOnActive {
                resumeOnActive = false
                Task { await startStream() }
            }
        default:
            break
        }
        #endif
    }

    // MARK: - Kamera komutları (kontrol sayfası)

    var isCameraReachable: Bool { state == .connected || state == .streaming }

    /// `/gp/gpControl/` altındaki bir komutu yollar, sonucu `commandMessage`'a yazar ve durumu tazeler.
    @discardableResult
    func sendCommand(_ path: String, label: String) async -> Bool {
        guard isCameraReachable else {
            commandMessage = L("Kamera bağlı değil.", "Camera not connected.")
            return false
        }
        do {
            _ = try await get("/gp/gpControl/" + path)
            commandMessage = "\(label): " + L("gönderildi", "sent")
            try? await Task.sleep(nanoseconds: 400_000_000)
            await refreshBattery()
            return true
        } catch {
            commandMessage = "\(label): " + L("başarısız", "failed") + " (\(error.localizedDescription))"
            return false
        }
    }

    func setSetting(_ id: Int, _ value: Int, label: String) async {
        await sendCommand("setting/\(id)/\(value)", label: label)
    }

    func refreshStatus() async {
        await refreshBattery()
    }

    /// Kameranın saatini bu cihazın saatine eşitler (p = %YY%AA%GG%SS%DD%ss, onaltılık).
    func syncClock() async {
        let c = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let values = [(c.year ?? 2000) % 100, c.month ?? 1, c.day ?? 1,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0]
        let p = values.map { String(format: "%%%02x", $0) }.joined()
        await sendCommand("command/setup/date_time?p=\(p)", label: L("Saat eşitleme", "Clock sync"))
    }

    /// Kamerayı kapatır; Wi-Fi de kapanacağı için bağlantıyı keser.
    func powerOff() async {
        guard isCameraReachable else { return }
        await stopStream()
        _ = try? await get("/gp/gpControl/command/system/sleep")
        await disconnect()
        message = L("Kamera kapatıldı.", "Camera powered off.")
    }

    // MARK: - İç işleyiş

    private func sendRestart() async throws {
        lastRestart = Date()
        _ = try await get("/gp/gpControl/execute?p1=gpStream&a1=proto_v2&c1=restart")
    }

    /// Saniyede bir: istatistik + keep-alive (2 sn'de bir) + veri kesilirse yeniden başlatma.
    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self = self else { return }
                await self.loopTick(tick)
                tick += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func loopTick(_ tick: Int) async {
        guard state == .streaming else { return }

        if tick % 2 == 0 {
            udp.send(keepAlive, host: host, port: streamPort)
        }

        // Pil: 10 sn'de bir, keep-alive döngüsünü bekletmeden.
        if tick % 10 == 0 {
            Task { [weak self] in await self?.refreshBattery() }
        }

        let stats = counters.take()
        if tick > 0 {
            bitrateKbps = stats.bytes * 8 / 1000
            fps = stats.frames
        }

        let silence = Date().timeIntervalSince(stats.lastData)
        if silence > 4, Date().timeIntervalSince(lastRestart) > 5 {
            message = L("Veri gelmiyor, yayın yeniden isteniyor…", "No data, requesting the stream again…")
            do {
                try await sendRestart()
            } catch {
                if state == .streaming {
                    message = L("Kamera yanıt vermiyor: ", "Camera not responding: ") + error.localizedDescription
                }
            }
        } else if silence <= 4, state == .streaming {
            message = L("Canlı yayın", "Live")
        }
    }

    /// Önizleme, çekim modunun en-boy oranını izler; 16:9 gelmesi için kamerayı video moduna alır
    /// ve video çözünürlüğü 4:3 ise 1080p'ye çevirir. Hatalar yok sayılır (yayın yine başlar).
    private func ensureWidescreen() async {
        // Video modu (fotoğraf/çoklu çekim modlarında önizleme 4:3 gelir)
        _ = try? await get("/gp/gpControl/command/mode?p=0")

        // Ayar 2 = video çözünürlüğü. 4:3 olanlar: 6 (2.7K 4:3), 7 (1440p), 10 (960p), 18 (4K 4:3)
        guard let data = try? await get("/gp/gpControl/status"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = json["settings"] as? [String: Any],
              let resolution = (settings["2"] as? NSNumber)?.intValue,
              [6, 7, 10, 18].contains(resolution) else { return }
        _ = try? await get("/gp/gpControl/setting/2/9")   // 1080p
        try? await Task.sleep(nanoseconds: 500_000_000)   // kameranın moda geçmesini bekle
    }

    /// `/gp/gpControl/status`: "70" = pil yüzdesi, "2" = pil çubukları (0-3, 4 = şarj oluyor).
    private func refreshBattery() async {
        guard state != .disconnected, state != .connecting,
              let data = try? await get("/gp/gpControl/status"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? [String: Any] else { return }
        let bars = (status["2"] as? NSNumber)?.intValue
        isRecording = (status["10"] as? NSNumber)?.intValue == 1        // 10 = kayıt sürüyor
        cameraMode = (status["43"] as? NSNumber)?.intValue              // 43 = geçerli mod
        remainingVideoSeconds = (status["35"] as? NSNumber)?.intValue   // 35 = kalan video süresi
        if let raw = json["settings"] as? [String: Any] {
            var parsed = [Int: Int]()
            for (key, value) in raw {
                if let id = Int(key), let number = (value as? NSNumber)?.intValue { parsed[id] = number }
            }
            cameraSettings = parsed
        }
        batteryCharging = bars == 4
        if let percent = (status["70"] as? NSNumber)?.intValue {
            batteryPercent = min(max(percent, 0), 100)
        } else if let bars, (0...3).contains(bars) {
            // Yüzde vermeyen firmware: çubuklardan yaklaşık değer.
            batteryPercent = [10, 40, 70, 100][bars]
        }
    }

    /// Yayın sırasında ekranın kapanmasını engeller.
    private func setKeepAwake(_ on: Bool) {
        #if os(macOS)
        if on {
            if awakeActivity == nil {
                awakeActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleDisplaySleepDisabled],
                    reason: "GoPro canlı yayın")
            }
        } else if let activity = awakeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            awakeActivity = nil
        }
        #else
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }

    private func get(_ path: String) async throws -> Data {
        guard let url = URL(string: "http://\(host)\(path)") else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
