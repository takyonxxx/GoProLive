import Foundation

/// Uygulama içi dil seçimi. Sistem dilinden bağımsızdır; varsayılan Türkçe.
enum AppLanguage {
    static let storageKey = "appLanguage"
    static let turkish = "tr"
    static let english = "en"

    static var current: String {
        UserDefaults.standard.string(forKey: storageKey) ?? turkish
    }
}

/// Seçili dile göre metni döndürür: `L("Bağlan", "Connect")`.
func L(_ tr: String, _ en: String) -> String {
    AppLanguage.current == AppLanguage.english ? en : tr
}
