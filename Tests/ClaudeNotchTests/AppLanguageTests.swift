import Testing
@testable import ClaudeNotch

@Suite struct AppLanguageTests {
    @Test func selectsRequestedLanguage() {
        #expect(AppLanguage.chinese.text("中文", "English") == "中文")
        #expect(AppLanguage.english.text("中文", "English") == "English")
        #expect(AppLanguage(rawValue: "unsupported") == nil)
    }

    @Test func formatsDurationsInEnglish() {
        #expect(Fmt.hm(3_900, language: .english) == "1h 05m")
        #expect(Fmt.dur(3_900, language: .english) == "1h 05m")
        #expect(Fmt.dur(2_400, language: .english) == "40m")
    }

    @Test func keepsExistingChineseDurationFormat() {
        #expect(Fmt.hm(3_900, language: .chinese) == "1小时05分")
        #expect(Fmt.dur(2_400, language: .chinese) == "40分")
    }
}
