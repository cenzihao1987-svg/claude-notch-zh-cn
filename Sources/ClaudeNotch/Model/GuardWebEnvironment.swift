import Foundation

struct GuardWebFrame: Codable, Equatable, Sendable {
    let context: String
    let language: String
    let languages: [String]
    let locale: String
    let timeZone: String
}

struct GuardWebReport: Codable, Equatable, Sendable {
    let `protocol`: Int
    let session: String
    let pid: Int32
    let capturedAt: Double
    let candidateCount: Int
    let failedCount: Int
    let frames: [GuardWebFrame]
}

enum GuardWebUnavailable: Sendable {
    case notRunning, disabled, missingModule, outdatedModule, needsRelaunch, waitingForPage, unreadable, stale
}

enum GuardWebState: Sendable {
    case unavailable(GuardWebUnavailable)
    case observed(GuardWebReport)
}

enum GuardWebField: String, CaseIterable, Sendable {
    case language, region, timezone
}

struct GuardWebReading: Equatable, Sendable {
    let values: [String]
    let state: GuardCheckState
    var text: String { values.isEmpty ? "—" : values.joined(separator: " / ") }
}

extension GuardWebEvaluator {
    /// Keep every distinct observed value; one matching frame must not hide another page.
    static func reading(_ field: GuardWebField, profile: GuardProfile, state: GuardWebState) -> GuardWebReading {
        guard case .observed(let report) = state else { return .init(values: [], state: .unknown) }
        var values: [String] = []
        var differs = false
        for frame in report.frames {
            let value: String
            let matches: Bool
            switch field {
            case .language:
                value = frame.language
                matches = languageMatches(value, profile.languageCode)
                    && frame.languages.first.map { languageMatches($0, profile.languageCode) } == true
            case .region:
                value = frame.locale
                matches = localeMatches(value, profile.localeIdentifier)
            case .timezone:
                value = frame.timeZone
                matches = timezoneMatches(value, profile.timeZoneIdentifier)
            }
            if !value.isEmpty && !values.contains(value) { values.append(value) }
            differs = differs || !matches
        }
        guard profile.enabled, profile.isValid else { return .init(values: values, state: .unknown) }
        let complete = report.failedCount == 0 && !report.frames.isEmpty && report.candidateCount == report.frames.count
        return .init(values: values, state: differs ? .attention : complete ? .passed : .unknown)
    }
}

enum GuardWebEvaluator {
    static func languageMatches(_ actual: String, _ expected: String) -> Bool {
        let canonicalActual = Locale.canonicalLanguageIdentifier(from: actual.replacingOccurrences(of: "_", with: "-"))
        let canonicalExpected = Locale.canonicalLanguageIdentifier(from: expected.replacingOccurrences(of: "_", with: "-"))
        let actualLocale = Locale(identifier: canonicalActual)
        let expectedLocale = Locale(identifier: canonicalExpected)
        guard actualLocale.language.languageCode == expectedLocale.language.languageCode else { return false }
        let actualScript = Locale(identifier: actualLocale.language.maximalIdentifier).language.script
        let expectedScript = Locale(identifier: expectedLocale.language.maximalIdentifier).language.script
        guard actualScript == expectedScript else { return false }
        let expectsRegion = canonicalExpected.split(separator: "-").dropFirst().contains { $0.count == 2 || $0.count == 3 }
        return !expectsRegion || actualLocale.region == expectedLocale.region
    }

    static func localeMatches(_ actual: String, _ expected: String) -> Bool {
        let actual = Locale(identifier: actual)
        let expected = Locale(identifier: expected)
        guard actual.language.languageCode == expected.language.languageCode,
              actual.region == expected.region else { return false }
        if let script = expected.language.script { return actual.language.script == script }
        return true
    }

    static func timezoneMatches(_ actual: String, _ expected: String) -> Bool {
        guard let actualZone = NSTimeZone(name: actual), let expectedZone = NSTimeZone(name: expected) else { return false }
        return actualZone.name == expectedZone.name || actualZone.data == expectedZone.data
    }

    static func mismatches(_ frame: GuardWebFrame, profile: GuardProfile) -> [GuardText] {
        var result: [GuardText] = []
        if !languageMatches(frame.language, profile.languageCode) || frame.languages.first.map({ !languageMatches($0, profile.languageCode) }) != false {
            result.append(.init("语言", "language"))
        }
        if !localeMatches(frame.locale, profile.localeIdentifier) { result.append(.init("地区", "locale")) }
        if !timezoneMatches(frame.timeZone, profile.timeZoneIdentifier) { result.append(.init("时区", "timezone")) }
        return result
    }

    static func finding(profile: GuardProfile, state: GuardWebState, launchPending: Bool) -> GuardFinding {
        let title = GuardText("Chromium 环境", "Chromium environment")
        func unavailable(_ value: GuardText, _ detail: GuardText, check: GuardCheckState = .unknown) -> GuardFinding {
            .init(id: "chromium", title: title, value: value, detail: detail, state: check)
        }
        guard profile.enabled else {
            return unavailable(.init("未启用", "Off"), .init("专属配置已关闭，网页层核验已暂停。", "The profile is off; web environment verification is paused."), check: .information)
        }
        guard profile.isValid else {
            return unavailable(.init("待完善配置", "Set up profile"), .init("请选择有效的语言、地区和时区，再通过本工具启动 Claude。", "Choose valid settings, then launch Claude through this tool."))
        }
        switch state {
        case .unavailable(let reason):
            switch reason {
            case .notRunning: return unavailable(.init("待启动核验", "Check on launch"), .init("Claude 未运行。通过专属配置启动后自动读取网页层实际值。", "Claude is stopped. A configured launch enables actual page readings."))
            case .disabled: return unavailable(.init("未启用", "Off"), .init("网页层守护未启用。", "Web environment guard is off."), check: .information)
            case .missingModule: return unavailable(.init("采集模块未安装", "Collector not installed"), .init("当前客户端没有只读采集模块，不能用启动参数代替网页读数。", "This client has no collector; launch parameters do not substitute for page readings."))
            case .outdatedModule: return unavailable(.init("客户端需重新适配", "Client update needs adaptation"), .init("Claude 已升级或采集模块版本不匹配。原有网页读数不再有效，需要为当前客户端重新适配。", "Claude or the collector changed. Old page readings are invalid; adapt the current client first."))
            case .needsRelaunch: return unavailable(.init("需按配置重新启动", "Configured relaunch needed"), .init("当前实例没有匹配的网页采集会话。请正常退出 Claude 后经本工具按配置启动。", "This instance has no matching collection session. Quit normally and launch with the profile."))
            case .waitingForPage: return unavailable(.init("等待页面加载", "Waiting for page"), .init("采集会话已启动，尚未获得 Claude 实际页面的完整读数。", "The session is active; complete readings from the actual Claude page are not available yet."))
            case .unreadable: return unavailable(.init("读取失败", "Read failed"), .init("未能读取完整有效的网页环境数据，未将此项判为通过。", "Complete valid page data could not be read; this check has not passed."))
            case .stale: return unavailable(.init("读数已过期", "Readings expired"), .init("超过 90 秒没有新的页面读数，先前的一致结果已失效。", "No fresh readings arrived for 90 seconds; the previous match is no longer valid."))
            }
        case .observed(let report):
            let differences = Set(report.frames.flatMap { mismatches($0, profile: profile).map(\.chinese) })
            let details = report.frames.map { frame in
                "\(frame.context): \(frame.language) / \(frame.locale) / \(frame.timeZone)\nLanguages: \(frame.languages.joined(separator: ", "))"
            }.joined(separator: "\n\n")
            let target = "\(profile.languageCode) / \(profile.localeIdentifier) / \(profile.timeZoneIdentifier)"
            if !differences.isEmpty {
                return .init(id: "chromium", title: title, value: .init("网页层不一致", "Page values differ"),
                    detail: .init("已读取实际页面，与目标配置不一致：\(differences.sorted().joined(separator: "、"))。\n目标：\(target)\n\n\(details)",
                                  "Actual page values differ from the profile.\nTarget: \(target)\n\n\(details)"),
                    state: .attention, actionID: launchPending ? "launch" : "chromium")
            }
            guard report.failedCount == 0, report.frames.count == report.candidateCount, !report.frames.isEmpty else {
                return unavailable(.init("部分页面未验证", "Some pages unverified"),
                                   .init("部分页面读数不可用，未将整体判为一致。\n\n\(details)", "Some pages could not be read; overall consistency is unverified.\n\n\(details)"))
            }
            return .init(id: "chromium", title: title, value: .init("网页层已一致", "Page values match"),
                detail: .init("已读取 \(report.frames.count) 个 Claude 页面，语言、地区和时区与目标配置一致。\n目标：\(target)\n\n\(details)",
                              "Read \(report.frames.count) actual Claude pages; language, locale and timezone match.\nTarget: \(target)\n\n\(details)"), state: .passed)
        }
    }
}
