import Foundation
import Speech
import Translation

/// 선택 가능한 언어 (BCP-47 코드 + 한국어 이름). 인식 엔진과 번역 프레임워크가 실제로 지원하는지는 LanguageSupport 가 실행 시점에 확인.
struct AppLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
    /// 자막 창·메뉴에 쓰는 짧은 표기 (EN, KO, ZH-HANS…)
    var short: String { code.uppercased() }

    static let all: [AppLanguage] = [
        .init(code: "en", name: "영어"), .init(code: "ko", name: "한국어"), .init(code: "ja", name: "일본어"),
        .init(code: "zh-Hans", name: "중국어 (간체)"), .init(code: "zh-Hant", name: "중국어 (번체)"),
        .init(code: "de", name: "독일어"), .init(code: "fr", name: "프랑스어"), .init(code: "es", name: "스페인어"),
        .init(code: "it", name: "이탈리아어"), .init(code: "pt", name: "포르투갈어"), .init(code: "ru", name: "러시아어"),
        .init(code: "uk", name: "우크라이나어"), .init(code: "nl", name: "네덜란드어"), .init(code: "pl", name: "폴란드어"),
        .init(code: "tr", name: "튀르키예어"), .init(code: "vi", name: "베트남어"), .init(code: "th", name: "태국어"),
        .init(code: "id", name: "인도네시아어"), .init(code: "ar", name: "아랍어"), .init(code: "hi", name: "힌디어"),
        .init(code: "sv", name: "스웨덴어"), .init(code: "da", name: "덴마크어"), .init(code: "nb", name: "노르웨이어"),
        .init(code: "fi", name: "핀란드어"), .init(code: "cs", name: "체코어"), .init(code: "hu", name: "헝가리어"),
        .init(code: "el", name: "그리스어"), .init(code: "ro", name: "루마니아어"),
    ]
    static func named(_ code: String) -> AppLanguage {
        all.first { $0.code == code } ?? AppLanguage(code: code, name: Locale.current.localizedString(forIdentifier: code) ?? code)
    }

    /// Parakeet TDT 0.6B v3(Ultra)가 자동 감지하는 25개 유럽 언어
    static let parakeetUltra: Set<String> = ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk"]
    static let parakeetV2: Set<String> = ["en"]

    /// 두 코드가 같은 언어인지 (ko == ko-KR, zh-Hans == zh-Hans-CN)
    static func matches(_ a: String, _ b: String) -> Bool {
        let la = Locale.Language(identifier: a), lb = Locale.Language(identifier: b)
        guard la.languageCode == lb.languageCode else { return false }
        if let sa = la.script, let sb = lb.script { return sa == sb }
        return true
    }
}

/// 이 맥에서 실제로 지원되는 언어 조회 (비동기, 앱 시작 시 한 번)
@MainActor
final class LanguageSupport: ObservableObject {
    @Published private(set) var translation: [String] = []         // Apple 번역이 지원하는 언어 코드
    @Published private(set) var appleSpeech: [String] = []         // Apple 인식기(SpeechAnalyzer / SFSpeechRecognizer)가 지원하는 로케일
    @Published private(set) var loaded = false
    @Published private(set) var pairStatus: [String: String] = [:] // "en>ko" → 설치됨 / 다운로드 필요 / 지원 안 함

    func load() async {
        let avail = LanguageAvailability()
        let langs = await avail.supportedLanguages
        translation = langs.map { $0.minimalIdentifier }
        if #available(macOS 26, *) {
            appleSpeech = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        } else {
            appleSpeech = SFSpeechRecognizer.supportedLocales().map { $0.identifier(.bcp47) }
        }
        loaded = true
        FileLog.write("languages: translation=\(translation.count) appleSpeech=\(appleSpeech.count)")
    }

    func translationSupports(_ code: String) -> Bool {
        !loaded || translation.contains { AppLanguage.matches($0, code) }
    }
    func appleSpeechSupports(_ code: String) -> Bool {
        !loaded || appleSpeech.contains { AppLanguage.matches($0, code) }
    }
    func engineSupports(_ engine: EngineChoice, source: String) -> Bool {
        switch engine {
        case .parakeetV2: return AppLanguage.parakeetV2.contains(AppLanguage.named(source).code)
        case .parakeetUltra: return AppLanguage.parakeetUltra.contains(Locale.Language(identifier: source).languageCode?.identifier ?? source)
        case .apple: return appleSpeechSupports(source)
        }
    }
    /// 이 언어를 들을 수 있는 엔진 (우선순위: v2 → Ultra → Apple)
    func bestEngine(for source: String, preferred: EngineChoice) -> EngineChoice {
        if engineSupports(preferred, source: source) { return preferred }
        for e in [EngineChoice.parakeetV2, .parakeetUltra, .apple] where engineSupports(e, source: source) { return e }
        return .apple
    }

    /// 번역 쌍 상태 확인 (설치됨 / 다운로드 필요 / 지원 안 함)
    func checkPair(source: String, target: String) async -> String {
        guard !AppLanguage.matches(source, target) else { return "같은 언어 (번역 안 함)" }
        let st = await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
        let text: String
        switch st {
        case .installed: text = "번역 모델 설치됨"
        case .supported: text = "번역 지원 (모델 다운로드 필요 — 첫 번역 때 다운로드 창)"
        case .unsupported: text = "이 조합은 Apple 번역이 지원하지 않음"
        @unknown default: text = "?"
        }
        pairStatus["\(source)>\(target)"] = text
        return text
    }
}
