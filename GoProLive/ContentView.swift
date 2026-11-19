import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @StateObject private var gopro = GoProClient()
    @Environment(\.scenePhase) private var scenePhase
    @State private var isFullscreen = false
    @State private var showCameraControls = false
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.turkish

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isFullscreen {
                fullscreenVideo
            } else {
                VStack(spacing: 12) {
                    header

                    video
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    Text(gopro.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    if let url = gopro.rtspURL {
                        Text(url)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    controls
                }
                .padding()
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #else
        .statusBarHidden(isFullscreen)
        #endif
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showCameraControls) {
            CameraControlView(gopro: gopro)
        }
        .task { await gopro.connect() }
        .onChange(of: scenePhase) { _, newPhase in
            gopro.scenePhaseChanged(newPhase)
        }
    }

    /// Video + durum katmanları; dokununca tam ekran açılır/kapanır.
    private var video: some View {
        VideoLayerView(videoLayer: gopro.displayLayer)
            .overlay {
                if gopro.state != .streaming {
                    Image(systemName: "video.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.gray)
                }
            }
            .overlay(alignment: .topLeading) {
                if gopro.state == .streaming {
                    Text("\(gopro.isRecording ? L("● KAYIT  ", "● REC  ") : "")\(gopro.videoSize)  \(gopro.fps) fps  \(gopro.bitrateKbps) kbps")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(gopro.isRecording ? Color.red : Color.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(isFullscreen ? 20 : 8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let percent = gopro.batteryPercent {
                    batteryBadge(percent)
                        .padding(isFullscreen ? 20 : 8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleFullscreen() }
    }

    private func batteryBadge(_ percent: Int) -> some View {
        HStack(spacing: 4) {
            if gopro.batteryCharging {
                Image(systemName: "bolt.fill")
            }
            Image(systemName: batterySymbol(percent))
            Text("%\(percent)")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(percent <= 20 && !gopro.batteryCharging ? Color.red : Color.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Tüm ekranı kaplar; telefon dikey tutuluyorsa görüntüyü 90° çevirip yatay gösterir.
    private var fullscreenVideo: some View {
        GeometryReader { geo in
            let portrait = geo.size.height > geo.size.width
            video
                .frame(width: portrait ? geo.size.height : geo.size.width,
                       height: portrait ? geo.size.width : geo.size.height)
                .rotationEffect(.degrees(portrait ? 90 : 0))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .ignoresSafeArea()
    }

    private func toggleFullscreen() {
        isFullscreen.toggle()
        #if os(macOS)
        // Mac'te pencereyi de gerçek tam ekrana al / geri çıkar.
        if let window = NSApp.keyWindow,
           window.styleMask.contains(.fullScreen) != isFullscreen {
            window.toggleFullScreen(nil)
        }
        #endif
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(gopro.cameraName.isEmpty ? "GoPro Live" : gopro.cameraName)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            // Dil: TR <-> EN
            Button(language == AppLanguage.english ? "EN" : "TR") {
                language = language == AppLanguage.english ? AppLanguage.turkish : AppLanguage.english
            }
            .buttonStyle(.bordered)
            Button {
                showCameraControls = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .disabled(!gopro.isCameraReachable)
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 12) {
            switch gopro.state {
            case .disconnected:
                Button(L("Bağlan", "Connect")) { Task { await gopro.connect() } }
                    .buttonStyle(.borderedProminent)
            case .connecting, .starting:
                ProgressView()
            case .connected:
                Button(L("Yayını Başlat", "Start Stream")) { Task { await gopro.startStream() } }
                    .buttonStyle(.borderedProminent)
                Button(L("Bağlantıyı Kes", "Disconnect")) { Task { await gopro.disconnect() } }
                    .buttonStyle(.bordered)
            case .streaming:
                Button(L("Yayını Durdur", "Stop Stream")) { Task { await gopro.stopStream() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .controlSize(.large)
        .frame(minHeight: 50)
    }

    private var statusColor: Color {
        switch gopro.state {
        case .disconnected: return .gray
        case .connecting, .starting: return .yellow
        case .connected: return .blue
        case .streaming: return .green
        }
    }
}

#Preview {
    ContentView()
}
