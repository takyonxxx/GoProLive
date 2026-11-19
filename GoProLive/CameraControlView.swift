import SwiftUI

/// Kameraya komut ve ayar gönderen düğmelerin bulunduğu sayfa.
/// Ayar numaraları kameranın API'sine göre seçilir: gpControl (HERO5-8) ya da Open GoPro (HERO9+).
struct CameraControlView: View {
    @ObservedObject var gopro: GoProClient
    @Environment(\.dismiss) private var dismiss
    @State private var confirmPowerOff = false
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.turkish

    /// HERO9 ve sonrası (Open GoPro)
    private var isModern: Bool { gopro.api == .openGoPro }

    private struct Option: Identifiable {
        let label: String
        let value: Int
        var id: Int { value }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusSection

                    Group {
                        recordingSection
                        modeSection

                        settingSection(L("Çözünürlük", "Resolution"), id: 2, options: resolutionOptions)
                        settingSection(L("Kare hızı", "Frame rate"), id: 3, options: [
                            Option(label: "24", value: 10),
                            Option(label: "30", value: 8),
                            Option(label: "60", value: 5),
                            Option(label: "120", value: 1),
                            Option(label: "240", value: 0),
                        ])
                        // Yeni modellerde: 121 = dijital lens, 135 = HyperSmooth
                        settingSection(L("Görüş açısı", "Field of view"), id: isModern ? 121 : 4, options: fieldOfViewOptions)
                        settingSection(L("Sabitleme", "Stabilization"), id: isModern ? 135 : 78, options: stabilizationOptions)
                        settingSection(L("Oto kapanma", "Auto off"), id: 59, options: [
                            Option(label: L("Asla", "Never"), value: 0),
                            Option(label: L("5 dk", "5 min"), value: 4),
                            Option(label: L("15 dk", "15 min"), value: 6),
                            Option(label: L("30 dk", "30 min"), value: 7),
                        ])
                        if !isModern {
                            settingSection(L("Bip sesi", "Beep volume"), id: 87, options: [
                                Option(label: L("Kapalı", "Off"), value: 0),
                                Option(label: L("Düşük", "Low"), value: 40),
                                Option(label: L("Orta", "Medium"), value: 70),
                                Option(label: L("Yüksek", "High"), value: 100),
                            ])
                        }

                        cameraSection
                    }
                    .disabled(!gopro.isCameraReachable)
                }
                .padding()
                .id(language)   // dil değişince metinleri yeniden kur
            }
            .navigationTitle(L("Kamera Kontrol", "Camera Control"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Kapat", "Close")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 600)
        #endif
        .preferredColorScheme(.dark)
        .task { await gopro.refreshStatus() }
        .confirmationDialog(L("Kamera kapatılsın mı?", "Power off the camera?"), isPresented: $confirmPowerOff, titleVisibility: .visible) {
            Button(L("Kamerayı Kapat", "Power Off Camera"), role: .destructive) {
                Task {
                    await gopro.powerOff()
                    dismiss()
                }
            }
            Button(L("Vazgeç", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("Kamera kapanınca Wi-Fi bağlantısı da kesilir; yeniden açmak için kameradaki düğmeye basmanız gerekir.", "Powering off also drops the Wi-Fi connection; you'll need to press the button on the camera to turn it back on."))
        }
    }

    // MARK: - Modele göre seçenekler

    private var resolutionOptions: [Option] {
        if isModern {
            return [
            Option(label: "5.3K", value: 100),
            Option(label: "4K", value: 1),
            Option(label: "2.7K", value: 4),
            Option(label: "1080p", value: 9),
            ]
        }
        return [
            Option(label: "4K", value: 1),
            Option(label: "2.7K", value: 4),
            Option(label: "1080p", value: 9),
            Option(label: "720p", value: 12),
        ]
    }

    private var fieldOfViewOptions: [Option] {
        if isModern {
            return [
            Option(label: L("Geniş", "Wide"), value: 0),
            Option(label: "SuperView", value: 3),
            Option(label: L("Doğrusal", "Linear"), value: 4),
            Option(label: L("Dar", "Narrow"), value: 2),
            ]
        }
        return [
            Option(label: L("Geniş", "Wide"), value: 0),
            Option(label: "SuperView", value: 3),
            Option(label: L("Doğrusal", "Linear"), value: 4),
        ]
    }

    private var stabilizationOptions: [Option] {
        if isModern {
            return [
            Option(label: L("Kapalı", "Off"), value: 0),
            Option(label: L("Açık", "On"), value: 1),
            Option(label: "Boost", value: 3),
            Option(label: L("Oto", "Auto"), value: 4),
            ]
        }
        return [
            Option(label: L("Kapalı", "Off"), value: 0),
            Option(label: L("Açık", "On"), value: 1),
        ]
    }

    // MARK: - Bölümler

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Label(modeName, systemImage: "camera")
                if gopro.isRecording {
                    Label(L("Kayıtta", "Recording"), systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                }
                if let percent = gopro.batteryPercent {
                    Label("%\(percent)", systemImage: gopro.batteryCharging ? "battery.100percent.bolt" : "battery.75percent")
                }
                if let seconds = gopro.remainingVideoSeconds {
                    Label(remainingText(seconds), systemImage: "sdcard")
                }
            }
            .font(.footnote)

            if !gopro.commandMessage.isEmpty {
                Text(gopro.commandMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !gopro.isCameraReachable {
                Text(L("Kamera bağlı değil.", "Camera not connected."))
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var recordingSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if gopro.isRecording {
                    actionButton(L("Kaydı Durdur", "Stop Recording"), systemImage: "stop.fill", tint: .red) {
                        await gopro.setShutter(false)
                    }
                } else {
                    actionButton(gopro.cameraMode == 0 || gopro.cameraMode == nil ? L("Kaydı Başlat", "Start Recording") : L("Deklanşör", "Shutter"),
                                 systemImage: "record.circle", tint: .red) {
                        await gopro.setShutter(true)
                    }
                }
                actionButton("HiLight", systemImage: "tag.fill") {
                    await gopro.addHilight()
                }
            }
        }
    }

    private var modeSection: some View {
        row(L("Mod", "Mode")) {
            optionGrid([
                Option(label: "Video", value: 0),
                Option(label: L("Fotoğraf", "Photo"), value: 1),
                Option(label: isModern ? "Timelapse" : L("Çoklu", "Multi"), value: 2),
            ], selected: gopro.cameraMode) { option in
                await gopro.setMode(option.value, label: L("Mod", "Mode") + " \(option.label)")
            }
        }
    }

    private var cameraSection: some View {
        VStack(spacing: 10) {
            if gopro.supportsLocateAndPowerOff {
                HStack(spacing: 8) {
                    actionButton(L("Bul (bip)", "Locate (beep)"), systemImage: "speaker.wave.2.fill") {
                        await gopro.locate(true)
                    }
                    actionButton(L("Bip'i Durdur", "Stop Beep"), systemImage: "speaker.slash.fill") {
                        await gopro.locate(false)
                    }
                }
            }
            HStack(spacing: 8) {
                actionButton(L("Saati Eşitle", "Sync Clock"), systemImage: "clock.arrow.2.circlepath") {
                    await gopro.syncClock()
                }
                actionButton(L("Yenile", "Refresh"), systemImage: "arrow.clockwise") {
                    await gopro.refreshStatus()
                }
                if gopro.supportsLocateAndPowerOff {
                Button(role: .destructive) {
                    confirmPowerOff = true
                } label: {
                    Label(L("Kapat", "Power Off"), systemImage: "power")
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 8))
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Yardımcılar

    private func settingSection(_ title: String, id: Int, options: [Option]) -> some View {
        row(title) {
            optionGrid(options, selected: gopro.cameraSettings[id]) { option in
                await gopro.setSetting(id, option.value, label: "\(title): \(option.label)")
            }
        }
    }

    /// Seçenek düğmeleri; kameranın bildirdiği geçerli değer vurgulanır.
    private func optionGrid(_ options: [Option], selected: Int?,
                            action: @escaping (Option) async -> Void) -> some View {
        // Tek satır, eşit genişlik: seçenekler alt satıra taşmaz.
        HStack(spacing: 6) {
            ForEach(options) { option in
                Button {
                    Task { await action(option) }
                } label: {
                    Text(option.label)
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, minHeight: 24)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 8))
                .tint(selected == option.value ? Color.blue : Color.gray.opacity(0.4))
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, tint: Color = .blue,
                              action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 8))
        .tint(tint)
    }

    /// Başlık solda, seçenekler sağda: her ayar tek satır yer kaplar.
    private func row<Content: View>(_ title: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 88, alignment: .leading)
            content()
        }
    }

    private var modeName: String {
        switch gopro.cameraMode {
        case 0: return "Video"
        case 1: return L("Fotoğraf", "Photo")
        case 2: return isModern ? "Timelapse" : L("Çoklu çekim", "Multi-shot")
        default: return L("Mod bilinmiyor", "Mode unknown")
        }
    }

    private func remainingText(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours) \(L("sa", "h")) \(minutes) \(L("dk", "min"))" : "\(minutes) \(L("dk", "min"))"
    }
}
