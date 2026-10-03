import Carbon
import Foundation

/// Translates the Mac's time zone and keyboard layouts into the identifiers a
/// Windows answer file expects, so Windows comes up with the same settings.
enum WindowsLocale {
    private typealias WindowsZoneFunction = @convention(c) (
        UnsafePointer<UInt16>, Int32, UnsafeMutablePointer<UInt16>, Int32, UnsafeMutablePointer<Int32>
    ) -> Int32

    /// Windows time zone ID (e.g. "Pacific Standard Time") for the Mac's zone,
    /// using ICU's CLDR mapping from libicucore.
    static func currentTimeZoneID() -> String {
        windowsTimeZoneID(for: TimeZone.current.identifier) ?? "UTC"
    }

    static func windowsTimeZoneID(for ianaZone: String) -> String? {
        guard let library = dlopen("/usr/lib/libicucore.dylib", RTLD_NOW),
              let symbol = dlsym(library, "ucal_getWindowsTimeZoneID") else { return nil }
        let function = unsafeBitCast(symbol, to: WindowsZoneFunction.self)
        let input = Array(ianaZone.utf16)
        var output = [UInt16](repeating: 0, count: 128)
        var status: Int32 = 0
        let length = function(input, Int32(input.count), &output, Int32(output.count), &status)
        guard status <= 0, length > 0 else { return nil }
        return String(utf16CodeUnits: output, count: Int(length))
    }

    /// Mac keyboard layout ID → Windows "LANGID:KLID" input locale.
    private static let layoutMap: [String: String] = [
        "com.apple.keylayout.ABC": "0409:00000409",
        "com.apple.keylayout.US": "0409:00000409",
        "com.apple.keylayout.USExtended": "0409:00000409",
        "com.apple.keylayout.USInternational-PC": "0409:00020409",
        "com.apple.keylayout.ArabicPC": "0401:00000401",
        "com.apple.keylayout.Arabic-PC": "0401:00000401",
        "com.apple.keylayout.Arabic": "0401:00000401",
        "com.apple.keylayout.Arabic-QWERTY": "0401:00000401",
        "com.apple.keylayout.British": "0809:00000809",
        "com.apple.keylayout.British-PC": "0809:00000809",
        "com.apple.keylayout.Canadian": "1009:00001009",
        "com.apple.keylayout.Australian": "0c09:00000409",
        "com.apple.keylayout.Irish": "1809:00001809",
        "com.apple.keylayout.German": "0407:00000407",
        "com.apple.keylayout.Austrian": "0c07:00000407",
        "com.apple.keylayout.SwissGerman": "0807:00000807",
        "com.apple.keylayout.French": "040c:0000040c",
        "com.apple.keylayout.French-PC": "040c:0000040c",
        "com.apple.keylayout.Belgian": "080c:0000080c",
        "com.apple.keylayout.SwissFrench": "100c:0000100c",
        "com.apple.keylayout.Spanish": "0c0a:0000040a",
        "com.apple.keylayout.Spanish-ISO": "0c0a:0000040a",
        "com.apple.keylayout.Italian": "0410:00000410",
        "com.apple.keylayout.Italian-Pro": "0410:00000410",
        "com.apple.keylayout.Portuguese": "0816:00000816",
        "com.apple.keylayout.Brazilian": "0416:00000416",
        "com.apple.keylayout.Brazilian-ABNT2": "0416:00000416",
        "com.apple.keylayout.Dutch": "0413:00020409",
        "com.apple.keylayout.Danish": "0406:00000406",
        "com.apple.keylayout.Swedish": "041d:0000041d",
        "com.apple.keylayout.Swedish-Pro": "041d:0000041d",
        "com.apple.keylayout.Norwegian": "0414:00000414",
        "com.apple.keylayout.Finnish": "040b:0000040b",
        "com.apple.keylayout.Polish": "0415:00000415",
        "com.apple.keylayout.PolishPro": "0415:00000415",
        "com.apple.keylayout.Czech": "0405:00000405",
        "com.apple.keylayout.Hungarian": "040e:0000040e",
        "com.apple.keylayout.Turkish": "041f:0000041f",
        "com.apple.keylayout.Turkish-QWERTY-PC": "041f:0000041f",
        "com.apple.keylayout.Greek": "0408:00000408",
        "com.apple.keylayout.Russian": "0419:00000419",
        "com.apple.keylayout.Russian-Phonetic": "0419:00000419",
        "com.apple.keylayout.RussianWin": "0419:00000419",
        "com.apple.keylayout.Ukrainian": "0422:00000422",
        "com.apple.keylayout.Ukrainian-PC": "0422:00000422",
        "com.apple.keylayout.Hebrew": "040d:0000040d",
        "com.apple.keylayout.Hebrew-PC": "040d:0000040d",
        "com.apple.keylayout.Persian": "0429:00000429",
        "com.apple.keylayout.Persian-ISIRI2901": "0429:00000429",
        "com.apple.keylayout.Urdu": "0420:00000420",
        "com.apple.keylayout.Hindi": "0439:00010439",
        "com.apple.keylayout.Thai": "041e:0000041e",
        "com.apple.keylayout.Vietnamese": "042a:0000042a",
    ]

    /// Default Windows layout per language, for Mac layouts missing above.
    private static let languageMap: [String: String] = [
        "en": "0409:00000409", "ar": "0401:00000401", "fr": "040c:0000040c", "de": "0407:00000407",
        "es": "0c0a:0000040a", "it": "0410:00000410", "pt": "0816:00000816", "nl": "0413:00020409",
        "ru": "0419:00000419", "uk": "0422:00000422", "he": "040d:0000040d", "tr": "041f:0000041f",
        "el": "0408:00000408", "pl": "0415:00000415", "cs": "0405:00000405", "hu": "040e:0000040e",
        "sv": "041d:0000041d", "da": "0406:00000406", "nb": "0414:00000414", "fi": "040b:0000040b",
        "fa": "0429:00000429", "ur": "0420:00000420", "hi": "0439:00010439", "th": "041e:0000041e",
        "vi": "042a:0000042a",
    ]

    /// Human-readable names for the input locales above.
    private static let localeNames: [String: String] = [
        "0409:00000409": "US", "0409:00020409": "US International", "0401:00000401": "Arabic (101)",
        "0809:00000809": "UK", "1009:00001009": "Canadian French", "0c09:00000409": "Australian (US)",
        "1809:00001809": "Irish", "0407:00000407": "German", "0c07:00000407": "German (Austria)",
        "0807:00000807": "Swiss German", "040c:0000040c": "French", "080c:0000080c": "Belgian French",
        "100c:0000100c": "Swiss French", "0c0a:0000040a": "Spanish", "0410:00000410": "Italian",
        "0816:00000816": "Portuguese", "0416:00000416": "Portuguese (Brazil ABNT)", "0413:00020409": "Dutch (US Intl)",
        "0406:00000406": "Danish", "041d:0000041d": "Swedish", "0414:00000414": "Norwegian",
        "040b:0000040b": "Finnish", "0415:00000415": "Polish", "0405:00000405": "Czech",
        "040e:0000040e": "Hungarian", "041f:0000041f": "Turkish Q", "0408:00000408": "Greek",
        "0419:00000419": "Russian", "0422:00000422": "Ukrainian", "040d:0000040d": "Hebrew",
        "0429:00000429": "Persian", "0420:00000420": "Urdu", "0439:00010439": "Hindi Traditional",
        "041e:0000041e": "Thai", "042a:0000042a": "Vietnamese",
    ]

    /// Input locales for every keyboard layout enabled on the Mac, US English first.
    static func currentInputLocales() -> String {
        var locales = ["0409:00000409"]
        for source in enabledKeyboardLayouts() {
            let locale = layoutMap[source.id] ?? source.languages.first.flatMap { languageMap[$0] }
            if let locale, !locales.contains(locale) {
                locales.append(locale)
            }
        }
        return locales.joined(separator: ";")
    }

    /// "0409:00000409;0401:00000401" → "US, Arabic (101)".
    static func describeInputLocales(_ value: String) -> String {
        value.split(separator: ";").map { localeNames[String($0).lowercased()] ?? String($0) }.joined(separator: ", ")
    }

    static func enabledKeyboardLayouts() -> [(id: String, languages: [String])] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.compactMap { source in
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
            let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            var languages: [String] = []
            if let rawLanguages = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
                languages = Unmanaged<CFArray>.fromOpaque(rawLanguages).takeUnretainedValue() as? [String] ?? []
            }
            return (id, languages)
        }
    }
}
