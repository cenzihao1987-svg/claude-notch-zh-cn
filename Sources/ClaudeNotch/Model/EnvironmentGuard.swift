import Foundation

struct GuardText: Equatable, Sendable {
    let chinese: String
    let english: String

    init(_ chinese: String, _ english: String) {
        self.chinese = chinese
        self.english = english
    }

    func text(_ language: AppLanguage) -> String { language.text(chinese, english) }
}

struct GuardProfile: Codable, Equatable, Sendable {
    var enabled = false
    var languageCode = "en-US"
    var localeIdentifier = ""
    var timeZoneIdentifier = ""
    var timeZoneOverrides: [String: String]? = nil

    static let languages = ["en-US", "en-GB", "en-CA", "en-AU", "zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES"]

    var countryCode: String? {
        guard !localeIdentifier.isEmpty else { return nil }
        return Locale(identifier: localeIdentifier).region?.identifier
    }

    // Older saved profiles had no override metadata. Preserve their explicit timezone.
    mutating func selectRegion(_ code: String) {
        if timeZoneOverrides == nil {
            timeZoneOverrides = [:]
            if let current = countryCode, !timeZoneIdentifier.isEmpty {
                timeZoneOverrides?[current] = timeZoneIdentifier
            }
        }
        let base = Locale(identifier: languageCode).language.languageCode?.identifier ?? "en"
        localeIdentifier = "\(base)_\(code)"
        timeZoneIdentifier = timeZoneOverrides?[code] ?? Self.defaultTimeZones[code] ?? ""
    }

    mutating func selectTimeZone(_ identifier: String) {
        if timeZoneOverrides == nil { timeZoneOverrides = [:] }
        timeZoneIdentifier = identifier
        if let countryCode { timeZoneOverrides?[countryCode] = identifier }
    }

    static let defaultTimeZones: [String: String] = {
        var zones: [String: String] = [:]
        if let table = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) {
            for line in table.split(separator: "\n") where !line.hasPrefix("#") {
                let fields = line.split(separator: "\t")
                guard fields.count >= 3 else { continue }
                for country in fields[0].split(separator: ",") where zones[String(country)] == nil {
                    zones[String(country)] = String(fields[2])
                }
            }
        }
        zones["US"] = "America/Los_Angeles"
        let known = Set(TimeZone.knownTimeZoneIdentifiers)
        return zones.filter { known.contains($0.value) }
    }()

    var isValid: Bool {
        Self.languages.contains(languageCode)
            && countryCode.map { code in Locale.Region.isoRegions.contains { $0.identifier == code } } == true
            && TimeZone.knownTimeZoneIdentifiers.contains(timeZoneIdentifier)
    }

    var arguments: [String] {
        ["--lang=\(languageCode)", "-AppleLanguages", "(\(languageCode))", "-AppleLocale", localeIdentifier]
    }

    var environment: [String: String] { ["TZ": timeZoneIdentifier] }
}

/// System defaults only. These values are never substituted for Claude's runtime readings.
struct GuardSystemEnvironment: Equatable, Sendable {
    var languageCode: String
    var localeIdentifier: String
    var timeZoneIdentifier: String

    static func read() -> Self {
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        return .init(languageCode: (system?["AppleLanguages"] as? [String])?.first ?? Locale.preferredLanguages.first ?? "",
                     localeIdentifier: system?["AppleLocale"] as? String ?? Locale.autoupdatingCurrent.identifier,
                     timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier)
    }
}

struct GuardRiskAssessment: Equatable, Sendable {
    let local: Int?
    let network: Int?
    let client: Int?
    var minimumTotal = 0

    var total: Int? {
        if minimumTotal > 0 { return min(100, max(minimumTotal, (local ?? 0) + (network ?? 0) + (client ?? 0))) }
        guard let local, let network, let client else { return nil }
        return min(100, max(minimumTotal, local + network + client))
    }

    func level(_ language: AppLanguage) -> String {
        guard let total else { return language.text("待检测", "Not checked") }
        switch total {
        case 0..<20: return language.text("风险较低", "Lower risk")
        case 20..<50: return language.text("风险中等", "Moderate risk")
        case 50..<80: return language.text("风险较高", "Higher risk")
        default: return language.text("风险很高", "Very high risk")
        }
    }
}

enum GuardRiskEvaluator {
    // A single local group prevents correlated region/timezone signals being counted twice.
    static let mainlandTimeZones: Set<String> = [
        "Asia/Shanghai", "Asia/Urumqi", "Asia/Kashgar", "Asia/Chongqing", "Asia/Chungking", "Asia/Harbin", "PRC"
    ]

    static func assess(environment: GuardSystemEnvironment?, snapshot: GuardSnapshot,
                       networkEnabled: Bool, now: Date = .now, estimating: Bool = false) -> GuardRiskAssessment {
        let local: Int?
        if let environment, !environment.localeIdentifier.isEmpty,
           let region = Locale(identifier: environment.localeIdentifier).region?.identifier,
           Locale.Region.isoRegions.contains(where: { $0.identifier == region }),
           TimeZone(identifier: environment.timeZoneIdentifier) != nil {
            var points = region == "CN" || mainlandTimeZones.contains(environment.timeZoneIdentifier) ? 40 : 0
            if snapshot.networkIsFresh(at: now), let route = snapshot.network {
                if route.countryCode != region { points = max(points, 20) }
                if let zone = route.timeZone, TimeZone(identifier: zone) != nil,
                   !GuardWebEvaluator.timezoneMatches(environment.timeZoneIdentifier, zone) { points = max(points, 20) }
            }
            if !estimating, case .observed(let report) = snapshot.webEnvironment,
               report.frames.contains(where: { !GuardWebEvaluator.localeMatches($0.locale, environment.localeIdentifier)
                    || !GuardWebEvaluator.languageMatches($0.language, environment.languageCode)
                    || !GuardWebEvaluator.timezoneMatches($0.timeZone, environment.timeZoneIdentifier) }) { points = max(points, 20) }
            local = points
        } else { local = nil }
        let network: Int?
        if networkEnabled, snapshot.networkIsFresh(at: now), let country = snapshot.network?.countryCode,
           Locale.Region.isoRegions.contains(where: { $0.identifier == country }) {
            network = snapshot.networkBehavior.locationUnverified ? nil : min(40,
                max(GuardSupportedRegions.codes.contains(country) ? 0 : 40, snapshot.networkBehavior.points)
                    + snapshot.proxyCheck.points + (snapshot.historyUnavailable ? 10 : 0))
        } else { network = nil }
        let client: Int?
        switch snapshot.client?.signature {
        case .valid?: client = 0
        case .local?: client = 10
        case .invalid?: client = 20
        default: client = nil
        }
        return .init(local: local, network: network, client: client.map { min(20, $0 + snapshot.runtimeCheck.points) },
                     minimumTotal: snapshot.networkBehavior.minimumTotal)
    }
}

struct LaunchReceipt: Codable, Equatable, Sendable {
    let pid: Int32
    let launchedAt: Date
    let appPath: String
    let profile: GuardProfile
    var webSession: String? = nil

    func matches(_ client: GuardClient) -> Bool {
        guard let date = client.launchedAt else { return false }
        return pid == client.pid && appPath == client.path && abs(date.timeIntervalSince(launchedAt)) < 1
    }
}

struct GuardProcessConfiguration: Equatable, Sendable {
    var language: String?
    var appleLanguages: String?
    var locale: String?
    var timeZone: String?

    func matches(_ profile: GuardProfile) -> Bool {
        language == profile.languageCode && appleLanguages == "(\(profile.languageCode))"
            && locale == profile.localeIdentifier && timeZone == profile.timeZoneIdentifier
    }
}

enum GuardSignature: Equatable, Sendable {
    case valid(publisher: String)
    case local
    case invalid(code: Int32)
    case unavailable
}

struct GuardClient: Equatable, Sendable {
    let path: String
    let version: String
    let pid: Int32?
    let launchedAt: Date?
    var signature: GuardSignature = .unavailable
    var process: GuardProcessConfiguration?
    var runningInstanceCount = 0
}

struct GuardNetworkObservation: Equatable, Sendable {
    let countryCode: String
    let fetchedAt: Date
    var city: String? = nil
    var subdivision: String? = nil
    var ip: String? = nil
    var timeZone: String? = nil
}

/// Explicitly authorized local exit history; no coordinates or account fields are decoded.
struct GuardCountryResponse: Decodable, Sendable {
    let ip: String?
    let location: Location?
    struct Location: Decodable, Sendable { let time_zone: String? }
    let country: String
    let city: String?
    let subdivision: String?
}

struct GuardSnapshot: Sendable {
    var client: GuardClient?
    var checkedAt: Date?
    var network: GuardNetworkObservation?
    var networkInvalidated = true
    var networkError: GuardText?
    var webEnvironment: GuardWebState = .unavailable(.notRunning)
    var proxyCheck = GuardProxyCheck()
    var runtimeCheck = GuardRuntimeCheck()
    var exitChange: GuardExitChange?
    var networkBehavior = GuardNetworkBehavior()
    var desktopActivity = GuardDesktopActivity.unknown
    var historyUnavailable = false

    func networkIsFresh(at date: Date) -> Bool {
        guard !networkInvalidated, let network else { return false }
        return (0..<180).contains(date.timeIntervalSince(network.fetchedAt))
    }
}

enum GuardCheckState: Sendable {
    case passed, information, pending, unknown, attention
}

struct GuardFinding: Identifiable, Sendable {
    let id: String
    let title: GuardText
    let value: GuardText
    let detail: GuardText
    let state: GuardCheckState
    /// Rows may share a cause, e.g. pending locale and timezone are one pending launch.
    var actionID: String?
}

enum GuardSummary: Equatable, Sendable {
    case checking, attention(Int), unverified, clear

    init(findings: [GuardFinding], checked: Bool) {
        let causes = Set(findings.compactMap(\.actionID))
        if !causes.isEmpty { self = .attention(causes.count) }
        else if !checked { self = .checking }
        else if findings.contains(where: { $0.state == .unknown || $0.state == .pending }) { self = .unverified }
        else { self = .clear }
    }

    func text(_ language: AppLanguage) -> String {
        switch self {
        case .checking: language.text("检测中", "Checking")
        case .attention(let count): language.text("需处理 \(count) 项", "\(count) items need attention")
        case .unverified: language.text("待验证", "Unverified")
        case .clear: language.text("未见已知异常", "No known issues found")
        }
    }
}

enum GuardEvaluator {
    static func findings(profile: GuardProfile, snapshot: GuardSnapshot,
                         networkEnabled: Bool, now: Date = .now) -> [GuardFinding] {
        var result: [GuardFinding] = []
        guard let client = snapshot.client else {
            return [.init(id: "installation", title: .init("Claude Desktop", "Claude Desktop"),
                          value: .init("未找到", "Not found"),
                          detail: .init("未找到支持的 Claude 应用。可在窗口中选择安装位置。", "Select your installed Claude app in this window."),
                          state: snapshot.checkedAt == nil ? .unknown : .attention,
                          actionID: snapshot.checkedAt == nil ? nil : "installation")]
        }
        let signatureValue: GuardText
        let signatureDetail: GuardText
        let signatureState: GuardCheckState
        switch client.signature {
        case .valid(let publisher):
            signatureValue = .init("签名有效", "Valid signature")
            signatureDetail = .init("签名及资源校验通过。签名身份：\(publisher)。这不代表账号风险已经验证。", "Signature and resource checks passed. Signing identity: \(publisher). Account risk is not assessed.")
            signatureState = .passed
        case .local:
            signatureValue = .init("来源待核验", "Verify source")
            signatureDetail = .init("检测到本地重签名，发行者身份未验证。可核对安装来源；本工具不会替换应用。此项与封号的关联未知。", "A local ad hoc signature was found; publisher identity is unverified. Check the installation source. Its relation to account restrictions is unknown.")
            signatureState = .attention
        case .invalid(let code):
            signatureValue = .init("校验未通过", "Validation failed")
            signatureDetail = .init("客户端签名或资源校验未通过（\(code)）。请核对安装来源。", "Signature or resource validation failed (\(code)). Check the installation source.")
            signatureState = .attention
        case .unavailable:
            signatureValue = .init("未验证", "Unverified")
            signatureDetail = .init("无法读取签名信息，不能确认客户端完整性。", "Signature information is unavailable; integrity cannot be confirmed.")
            signatureState = .unknown
        }
        result.append(.init(id: "signature", title: .init("客户端来源", "Client source"), value: signatureValue,
                            detail: signatureDetail, state: signatureState,
                            actionID: signatureState == .attention ? "signature" : nil))

        let matches = profile.enabled && profile.isValid && client.process?.matches(profile) == true
        let launchValue: GuardText
        let launchDetail: GuardText
        let launchState: GuardCheckState
        var launchAction: String?
        if !profile.enabled {
            launchValue = .init("未启用", "Off")
            launchDetail = .init("可保存独立的语言、地区和时区，再启用专属启动配置。", "Save a language, region and timezone, then enable configured launches.")
            launchState = .information
        } else if !profile.isValid {
            launchValue = .init("待设置", "Set up")
            launchDetail = .init("请先选择地区和时区。", "Choose a region and timezone first.")
            launchState = .pending
            launchAction = "launch"
        } else if client.runningInstanceCount > 1 {
            launchValue = .init("多个实例", "Multiple instances")
            launchDetail = .init("检测到多个 Claude 实例。正常退出后再按配置启动，避免配置混用。", "Multiple Claude instances are running. Quit them normally before a configured launch.")
            launchState = .attention
            launchAction = "launch"
        } else if client.pid == nil {
            launchValue = .init("待应用", "Pending")
            launchDetail = .init("下次启动将使用专属语言、地区和时区。", "The next configured launch will use your language, region and timezone.")
            launchState = .pending
            launchAction = "launch"
        } else if matches {
            launchValue = .init("启动参数匹配", "Launch settings match")
            launchDetail = .init("已观察到主进程启动参数及 TZ 与配置一致。应用内部和子进程的实际值仍未验证。", "The main process arguments and TZ match the profile. Internal runtime and child-process values remain unverified.")
            launchState = .passed
        } else if client.process == nil {
            launchValue = .init("未验证", "Unverified")
            launchDetail = .init("无法读取此进程的启动配置。配置提交成功也不能视为内部已生效。", "This process's launch settings could not be read. A successful launch does not verify internal behavior.")
            launchState = .unknown
        } else {
            launchValue = .init("待重新启动", "Relaunch needed")
            launchDetail = .init("当前实例未匹配专属配置。请正常退出 Claude，再按配置启动。", "This instance does not match the profile. Quit Claude normally, then launch it with the profile.")
            launchState = .pending
            launchAction = "launch"
        }
        result.append(.init(id: "launch", title: .init("启动配置", "Launch configuration"), value: launchValue,
                            detail: launchDetail, state: launchState, actionID: launchAction))
        result.append(.init(id: "locale", title: .init("语言与地区", "Language and region"),
                            value: matches ? .init("参数匹配", "Arguments match") : .init(profile.isValid ? "配置已保存" : "待设置", profile.isValid ? "Profile saved" : "Not configured"),
                            detail: .init("目标：\(profile.languageCode) / \(profile.localeIdentifier.isEmpty ? "未设置" : profile.localeIdentifier)。读取的是启动参数，不是 Claude 内部 API 的返回值。系统中文不单独计为异常。", "Target: \(profile.languageCode) / \(profile.localeIdentifier). These are launch settings, not values returned by Claude's runtime APIs. A Chinese system language alone is not an issue."),
                            state: matches ? .passed : .information))
        result.append(.init(id: "timezone", title: .init("进程时区", "Process timezone"),
                            value: matches ? .init("TZ 参数匹配", "TZ matches") : .init(profile.enabled ? "待应用" : "未启用", profile.enabled ? "Pending" : "Off"),
                            detail: .init("目标：\(profile.timeZoneIdentifier.isEmpty ? "未设置" : profile.timeZoneIdentifier)。TZ 不能证明 Chromium、原生模块及子进程采用相同时区。", "Target: \(profile.timeZoneIdentifier). TZ does not prove that Chromium, native modules or child processes use the same timezone."),
                            state: matches ? .passed : .information))
        result.append(GuardWebEvaluator.finding(profile: profile, state: snapshot.webEnvironment, launchPending: launchAction != nil))

        let networkFresh = snapshot.networkIsFresh(at: now)
        let country = snapshot.network?.countryCode
        let unsupported = country.map { !GuardSupportedRegions.codes.contains($0) } ?? false
        let mismatch = country != nil && profile.enabled && profile.isValid && country != profile.countryCode
        let networkIssue = networkEnabled && networkFresh && (unsupported || mismatch)
        let networkValue: GuardText
        if !networkEnabled { networkValue = .init("已关闭", "Off") }
        else if let country {
            let name = Locale(identifier: "zh_CN").localizedString(forRegionCode: country) ?? country
            networkValue = .init("\(name) · \(networkFresh ? "仅供参考" : "已过期")", "\(country) · \(networkFresh ? "reference only" : "stale")")
        } else { networkValue = .init("未验证", "Unverified") }
        var detail = GuardText("仅代表本工具请求的出口，Claude 的实际出口未确认。VPN 分流可能使两者不同。", "This is only this tool's request route. Claude's actual route is unverified and may differ with VPN routing.")
        if networkIssue {
            detail = .init((unsupported ? "探测国家未列入已核对的 Claude 支持地区。" : "探测国家与保存的地区配置不同。") + detail.chinese,
                           (unsupported ? "The probe country is not on the checked Claude supported-regions list. " : "The probe country differs from the saved profile. ") + detail.english)
        }
        if let error = snapshot.networkError, networkEnabled {
            detail = .init(error.chinese + " " + detail.chinese, error.english + " " + detail.english)
        }
        result.append(.init(id: "network", title: .init("网络出口参照", "Network reference"), value: networkValue,
                            detail: detail, state: !networkEnabled ? .information : networkIssue ? .attention : networkFresh ? .information : .unknown,
                            actionID: networkIssue ? "network" : nil))
        return result
    }
}

enum GuardSupportedRegions {
    static let source = URL(string: "https://support.claude.com/en/articles/8461763-where-can-i-access-claude")!
    static let verifiedOn = "2026-10-14"
    // Snapshot of the Claude consumer availability list, not the separate API list.
    static let codes = Set("AL DZ AD AO AG AR AM AU AT AZ BS BH BD BB BE BZ BJ BT BO BA BW BR BN BG BF BI KH CM CA CV TD CL CO KM CG CR HR CZ DK DJ DM DO TL EC EG SV GQ EE SZ FJ FI FR GA GM GE DE GH GR GD GT GN GW GY HT HN HU IS IN ID IQ IE IL IT CI JM JP JO KZ KE KI KW KG LA LV LB LS LR LI LT LU MG MW MY MV MT MP MH MR MU MX FM MD MC MN ME MA MZ NA NR NP NL NZ NE NG MK NO OM PK PW PS PA PG PY PE PH PL PT QA CY RO RW KN LC VC WS SM ST SA SN RS SC SL SG SK SI SB ZA KR ES LK SR SE CH TW TJ TZ TH TG TO TT TN TR TM TV UG UA AE GB US UY UZ VU VA VN ZM ZW".split(separator: " ").map(String.init))
}
