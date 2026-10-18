import Darwin
import Foundation

struct GuardExit: Codable, Equatable, Sendable {
    let ip: String
    let country: String
    let city: String?
    let timeZone: String?
    let observedAt: Date
    let desktopActivity: GuardDesktopActivity?

    init?(_ observation: GuardNetworkObservation, activity: GuardDesktopActivity = .unknown) {
        guard let raw = observation.ip, let ip = Self.normalizedIP(raw) else { return nil }
        self.ip = ip
        country = observation.countryCode
        city = observation.city
        timeZone = observation.timeZone
        observedAt = observation.fetchedAt
        desktopActivity = activity
    }

    static func normalizedIP(_ value: String) -> String? {
        guard value.utf8.count <= 64 else { return nil }
        var ipv4 = in_addr(), ipv6 = in6_addr()
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            guard inet_ntop(AF_INET, &ipv4, &output, socklen_t(output.count)) != nil else { return nil }
        } else if inet_pton(AF_INET6, value, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
                return bytes.suffix(4).map(String.init).joined(separator: ".")
            }
            guard inet_ntop(AF_INET6, &ipv6, &output, socklen_t(output.count)) != nil else { return nil }
        } else { return nil }
        return String(decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func sameRoute(as other: Self) -> Bool { ip == other.ip && country == other.country }
    var maskedIP: String {
        if ip.contains(":") { return ip.split(separator: ":").prefix(3).joined(separator: ":") + ":…" }
        return ip.split(separator: ".").prefix(2).joined(separator: ".") + ".*.*"
    }
    func label(_ language: AppLanguage) -> String {
        let locale = Locale(identifier: language == .chinese ? "zh_CN" : "en_US")
        return "\(ip) · \(locale.localizedString(forRegionCode: country) ?? country)" + (city.map { " · \($0)" } ?? "")
    }
}

struct GuardExitChange: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let previous: GuardExit
    let current: GuardExit
    var countryChanged: Bool { previous.country != current.country }
}

enum GuardGeoVerification: Sendable { case unchecked, verified, conflict, unavailable }

enum GuardLocationVerifier {
    private struct Response: Decodable { let success: Bool; let ip: String?; let country_code: String? }
    static func evaluate(_ data: Data, expected: GuardExit) -> GuardGeoVerification {
        guard data.count < 8192, let result = try? JSONDecoder().decode(Response.self, from: data),
              result.success, let ip = result.ip, GuardExit.normalizedIP(ip) == expected.ip,
              let country = result.country_code, Locale.Region.isoRegions.contains(where: { $0.identifier == country }) else { return .unavailable }
        return country == expected.country ? .verified : .conflict
    }
}

/// Deliberately conservative far-apart pairs. No city precision or capital-to-capital speeds.
enum GuardGeography {
    private static let groups: [Set<String>] = [
        ["US", "CA", "MX"],
        ["GB", "IE", "FR", "DE", "ES", "PT", "IT", "NL", "BE", "CH", "AT", "DK", "NO", "SE", "FI", "IS", "PL", "CZ", "GR", "TR", "GE", "CY", "IL", "AE", "SA", "QA", "BH", "KW"],
        ["CN", "HK", "MO", "TW", "JP", "KR", "MN"],
        ["SG", "MY", "TH", "VN", "ID", "PH", "BN", "KH", "LA", "MM", "TL"],
        ["AU", "NZ"],
        ["BR", "AR", "CL", "PE", "CO", "UY", "PY", "BO", "EC", "VE"],
        ["IN", "PK", "BD", "LK", "NP", "BT"]
    ]
    static func isRemote(_ a: String, _ b: String) -> Bool {
        guard a != b, let first = groups.firstIndex(where: { $0.contains(a) }),
              let second = groups.firstIndex(where: { $0.contains(b) }), first != second else { return false }
        let pair = Set([first, second])
        // East/Southeast Asia and Oceania have nearby borders: do not infer impossible travel.
        return pair.contains(0) || pair.contains(5)
            || (pair.contains(1) && !pair.contains(6))
            || pair == Set([4, 6])
    }
}

struct GuardGeoTransition: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let previous: GuardExit
    let current: GuardExit
    let anomalous: Bool
    var exposureQualified: Bool? = nil
    var isExposureQualified: Bool { exposureQualified == true && previous.desktopActivity == .active && current.desktopActivity == .active }
    var change: GuardExitChange { .init(id: id, previous: previous, current: current) }
}

struct GuardGeoIncident: Codable, Equatable, Sendable {
    var transition: GuardGeoTransition
    var extreme: Bool
    var roundTrip: Bool
    var stableSeconds: Double
}

struct GuardNetworkBehavior: Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case countryChange, cumulative, anomalous, repeated, roundTrip, familyMismatch, unverified }
    var kind: Kind? = nil
    var points = 0
    var minimumTotal = 0
    var change: GuardExitChange? = nil
    var crossRegionCount = 0
    var regionCount = 0
    var anomalousCount = 0
    var identifier = ""
    var locationUnverified = false
    var shouldExpand: Bool { kind != nil && kind != .countryChange && kind != .cumulative }

    func title(_ language: AppLanguage) -> String {
        switch kind {
        case .countryChange: language.text("IP出口地区改变", "Exit region changed")
        case .cumulative: language.text("累计跨区较多 · 风险中等", "Repeated region changes · moderate risk")
        case .anomalous: language.text("异常跨区切换 · 风险较高", "Abnormal region switch · higher risk")
        case .repeated: language.text("多地连续跳转 · 风险极高", "Rapid multi-region switches · very high risk")
        case .roundTrip: language.text("短时跨区往返 · 风险极高", "Rapid region round trip · very high risk")
        case .familyMismatch: language.text("出口地区不一致 · 风险中等", "Exit regions differ · moderate risk")
        case .unverified: language.text("出口定位待核验", "Exit location needs verification")
        case nil: ""
        }
    }
    func description(_ language: AppLanguage) -> String {
        if kind == .unverified {
            return language.text("出口定位尚未取得一致结果，请检查线路并核验新IP出口。", "Exit location is not confirmed. Check the route and verify the new exit.")
        }
        return language.text("建议暂停使用 Claude，避免封号，请检查线路并确认新IP出口。", "Pause Claude use to reduce account risk; check the route and confirm the new exit.")
    }
}

struct GuardNetworkHistory: Codable, Equatable, Sendable {
    var lastLaunch: GuardExit?
    var confirmed: GuardExit?
    var pending: GuardExitChange?
    var lastObserved: GuardExit?
    // Read old snapshots, but never reuse the old raw-IP frequency counter for scoring.
    var transitions: [GuardExit]? = nil
    var lastByFamily: [String: GuardExit]? = nil
    var geographicTransitions: [GuardGeoTransition]? = nil
    var incident: GuardGeoIncident? = nil
    var ignoredWarning: String? = nil
    var lastExposedByFamily: [String: GuardExit]? = nil
    var exposurePolicyVersion: Int? = nil
    var connectionBaselines: [String: GuardExit]? = nil
}

/// Launch identity and last-seen sample are distinct; each address family has its own baseline.
struct GuardNetworkTracker: Sendable {
    private(set) var history: GuardNetworkHistory
    private(set) var previousLaunch: GuardExit?
    private(set) var hasLaunchSample = false
    private(set) var candidate: GuardExit?
    private(set) var alert: GuardExitChange?
    private var candidates: [String: GuardExit] = [:]
    private var rawByFamily: [String: GuardExit] = [:]
    private var pendingLocation: GuardExitChange?
    private var lastStableSample: GuardExit?

    mutating func setConnectionBaselines(_ values: [String: GuardExit]) { history.connectionBaselines = values }

    init(history: GuardNetworkHistory = .init()) {
        self.history = history
        previousLaunch = history.lastLaunch
        rawByFamily = history.lastByFamily ?? [:]
        if let last = history.lastObserved ?? history.lastLaunch, rawByFamily[Self.family(last)] == nil {
            rawByFamily[Self.family(last)] = last
        }
        self.history.exposurePolicyVersion = 1
        if let pending = history.pending, pending.countryChanged,
           history.geographicTransitions?.contains(where: { $0.id == pending.id && $0.isExposureQualified }) == true { alert = pending }
        else { self.history.pending = nil }
        // Restart is a monitoring gap, not evidence of stable routing.
        self.history.incident?.stableSeconds = 0
    }

    static func family(_ exit: GuardExit) -> String { exit.ip.contains(":") ? "ipv6" : "ipv4" }

    func candidate(for exit: GuardExit) -> GuardExit? { candidates[Self.family(exit)] }

    func previousObserved(for exit: GuardExit) -> GuardExit? {
        history.lastByFamily?[Self.family(exit)] ?? history.lastObserved ?? previousLaunch
    }

    func previous(for exit: GuardExit) -> GuardExit? {
        guard exit.desktopActivity == .active else { return previousObserved(for: exit) }
        if let sameFamily = history.lastExposedByFamily?[Self.family(exit)], sameFamily.desktopActivity == .active { return sameFamily }
        let last = history.lastExposedByFamily?.values.filter { $0.desktopActivity == .active }.max { $0.observedAt < $1.observedAt }
        if let last, exit.observedAt.timeIntervalSince(last.observedAt) >= 180 { return last }
        return nil
    }

    var hasLegacyExposureHistory: Bool {
        (history.geographicTransitions ?? []).contains { !$0.isExposureQualified }
            || history.incident.map { !$0.transition.isExposureQualified } == true
    }

    mutating func usageBoundaryChanged() {
        candidates = [:]; candidate = nil; pendingLocation = nil; rawByFamily = [:]
    }

    func requiresLocationVerification(_ exit: GuardExit) -> Bool {
        guard exit.desktopActivity == .active, let old = previous(for: exit), old.country != exit.country else { return false }
        return old.ip == exit.ip || GuardGeography.isRemote(old.country, exit.country)
    }

    func assessment(at now: Date) -> GuardNetworkBehavior {
        let events = (history.geographicTransitions ?? []).filter { $0.isExposureQualified && (0...86400).contains(now.timeIntervalSince($0.current.observedAt)) }
        let hour = events.filter { $0.anomalous && now.timeIntervalSince($0.current.observedAt) <= 3600 }
        var result = GuardNetworkBehavior(crossRegionCount: events.count,
            regionCount: Set(events.flatMap { [$0.previous.country, $0.current.country] }).count,
            anomalousCount: hour.count)
        if let last = events.last {
            result.kind = events.count >= 4 ? .cumulative : .countryChange
            result.points = events.count >= 4 ? 20 : 10
            result.change = last.change
            result.identifier = "region-" + last.id.uuidString + (events.count >= 4 ? "-cumulative" : "")
        }
        if let incident = history.incident, incident.transition.isExposureQualified {
            let extreme = incident.extreme && incident.stableSeconds < 7200
            result.kind = extreme ? (incident.roundTrip ? .roundTrip : .repeated) : .anomalous
            result.points = extreme ? 40 : 30
            result.minimumTotal = extreme ? 80 : 50
            result.change = incident.transition.change
            result.identifier = "region-" + incident.transition.id.uuidString
        }
        let fresh = rawByFamily.values.filter { $0.desktopActivity == .active && (0..<180).contains(now.timeIntervalSince($0.observedAt)) }
        if fresh.count == 2, fresh[0].country != fresh[1].country, result.minimumTotal == 0 {
            let ordered = fresh.sorted { Self.family($0) < Self.family($1) }
            result.kind = .familyMismatch
            result.points = max(result.points, 20)
            result.change = .init(id: history.pending?.id ?? UUID(), previous: ordered[0], current: ordered[1])
            result.identifier = "families-" + ordered.map { $0.ip + $0.country }.joined(separator: "-")
        }
        if let pendingLocation {
            result.locationUnverified = true
            if result.minimumTotal == 0, result.kind != .familyMismatch {
                result.kind = .unverified
                result.change = pendingLocation
                result.identifier = "unverified-" + pendingLocation.current.ip + pendingLocation.current.country
            }
        }
        return result
    }

    mutating func observe(_ exit: GuardExit, verification: GuardGeoVerification = .unchecked) {
        let family = Self.family(exit)
        if let last = rawByFamily[family], exit.observedAt <= last.observedAt { return }
        rawByFamily[family] = exit
        let old = previous(for: exit)
        if !hasLaunchSample {
            hasLaunchSample = true
            history.lastLaunch = exit
        }
        if history.lastByFamily == nil { history.lastByFamily = [:] }
        if exit.desktopActivity != .active {
            history.lastByFamily?[family] = exit
            history.lastObserved = exit
            candidates[family] = nil
            candidate = candidates.values.first
            pendingLocation = nil
            trackStability(exit, changedCountry: old.map { $0.country != exit.country } ?? false)
            return
        }
        if history.lastExposedByFamily == nil { history.lastExposedByFamily = [:] }
        guard let old else {
            history.lastExposedByFamily?[family] = exit
            history.lastByFamily?[family] = exit
            history.lastObserved = exit
            if history.confirmed == nil { history.confirmed = exit }
            trackStability(exit, changedCountry: false)
            return
        }
        if exit.sameRoute(as: old) {
            history.lastExposedByFamily?[family] = exit
            candidates[family] = nil
            candidate = candidates.values.first
            if pendingLocation.map({ Self.family($0.current) == family }) == true { pendingLocation = nil }
            history.lastByFamily?[family] = exit
            history.lastObserved = exit
            trackStability(exit, changedCountry: false)
            return
        }
        guard let first = candidates[family], first.sameRoute(as: exit) else {
            candidates[family] = exit
            candidate = exit
            if old.country == exit.country { trackStability(exit, changedCountry: false) }
            else { lastStableSample = nil; history.incident?.stableSeconds = 0 }
            return
        }
        guard exit.observedAt.timeIntervalSince(first.observedAt) >= 5 else { return }
        if old.country != exit.country, requiresLocationVerification(exit), verification != .verified {
            pendingLocation = .init(id: pendingLocation?.id ?? UUID(), previous: old, current: first)
            candidate = first
            lastStableSample = nil
            history.incident?.stableSeconds = 0
            return
        }
        // A database changing its country for an unchanged IP is a location disagreement, not travel.
        if old.ip == exit.ip, old.country != exit.country {
            pendingLocation = .init(id: pendingLocation?.id ?? UUID(), previous: old, current: first)
            candidate = first
            return
        }
        pendingLocation = nil
        candidates[family] = nil
        candidate = candidates.values.first
        if old.country != exit.country {
            let gap = first.observedAt.timeIntervalSince(old.observedAt)
            let event = GuardGeoTransition(id: UUID(), previous: old, current: first,
                anomalous: verification == .verified && gap >= 0 && gap < 7200 && GuardGeography.isRemote(old.country, exit.country), exposureQualified: true)
            var events = (history.geographicTransitions ?? []).filter { (0...86400).contains(exit.observedAt.timeIntervalSince($0.current.observedAt)) }
            let duplicateFamilyTransition = events.last.map {
                $0.isExposureQualified && $0.previous.country == old.country && $0.current.country == exit.country
                    && Self.family($0.current) != family
                    && (0...180).contains(first.observedAt.timeIntervalSince($0.current.observedAt))
            } ?? false
            if !duplicateFamilyTransition {
                events.append(event)
                history.geographicTransitions = events
                alert = event.change
                history.pending = alert
            }
            if event.anomalous && !duplicateFamilyTransition {
                let hour = events.filter { $0.isExposureQualified && $0.anomalous && (0...3600).contains(first.observedAt.timeIntervalSince($0.current.observedAt)) }
                let prior = hour.dropLast().last
                let back = prior.map { $0.previous.country == event.current.country && $0.current.country == event.previous.country } ?? false
                let extreme = hour.count >= 2 || (history.incident.map { $0.transition.isExposureQualified && $0.extreme && $0.stableSeconds < 7200 } ?? false)
                history.incident = .init(transition: event, extreme: extreme, roundTrip: back, stableSeconds: 0)
            }
        }
        history.lastByFamily?[family] = exit
        history.lastExposedByFamily?[family] = exit
        history.lastObserved = exit
        trackStability(exit, changedCountry: old.country != exit.country)
    }

    private mutating func trackStability(_ exit: GuardExit, changedCountry: Bool) {
        defer { lastStableSample = exit }
        guard history.incident?.transition.isExposureQualified == true else { return }
        let dualMismatch = rawByFamily.values.contains { other in
            Self.family(other) != Self.family(exit) && (0..<180).contains(exit.observedAt.timeIntervalSince(other.observedAt)) && other.country != exit.country
        }
        guard !changedCountry, !dualMismatch, let lastStableSample else {
            history.incident?.stableSeconds = 0
            return
        }
        let gap = exit.observedAt.timeIntervalSince(lastStableSample.observedAt)
        if gap >= 0 && gap <= 180 && lastStableSample.country == exit.country {
            history.incident?.stableSeconds += gap
        } else { history.incident?.stableSeconds = 0 }
        if (history.incident?.stableSeconds ?? 0) >= 86400 { history.incident = nil }
    }

    mutating func invalidateCandidate() {
        candidates = [:]; candidate = nil; pendingLocation = nil; lastStableSample = nil
        history.incident?.stableSeconds = 0
    }

    mutating func ignoreWarning(at now: Date) { history.ignoredWarning = assessment(at: now).identifier }

    mutating func confirm(_ exit: GuardExit) -> Bool {
        guard let alert, exit.country == alert.current.country, candidate == nil,
              history.lastByFamily?[Self.family(exit)]?.sameRoute(as: exit) == true else { return false }
        history.confirmed = exit
        history.pending = nil
        self.alert = nil
        return true
    }
}

struct GuardHistoryStore: Sendable {
    let url: URL
    static let standard = Self(url: GuardWebEnvironmentReader.directory.appendingPathComponent("network-history.json"))

    func load() throws -> GuardNetworkHistory {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        guard let data = GuardWebEnvironmentReader.privateData(at: url, maxBytes: 1_048_576) else { throw CocoaError(.fileReadNoPermission) }
        let value = try JSONDecoder().decode(GuardNetworkHistory.self, from: data)
        let events = value.geographicTransitions ?? []
        let exits = [value.lastLaunch, value.confirmed, value.pending?.previous, value.pending?.current,
                     value.lastObserved, value.incident?.transition.previous, value.incident?.transition.current].compactMap { $0 }
            + Array((value.lastByFamily ?? [:]).values) + Array((value.lastExposedByFamily ?? [:]).values) + events.flatMap { [$0.previous, $0.current] }
        for exit in exits {
            guard GuardExit.normalizedIP(exit.ip) != nil, exit.country.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
        }
        return value
    }

    var journalURL: URL { url.deletingLastPathComponent().appendingPathComponent("network-exits.jsonl") }

    func appendObservation(_ exit: GuardExit, kind: String, previous: GuardExit? = nil,
                           risk: GuardLoggedRisk? = nil, previousRisk: GuardLoggedRisk? = nil, recordedAt: Date? = nil) throws {
        let record = GuardNetworkLogEntry(recordID: UUID(), kind: kind, exit: exit,
            recordedAt: recordedAt, previous: previous, risk: risk, previousRisk: previousRisk)
        guard record.isValid else { throw CocoaError(.fileWriteInvalidFileName) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(record); data.append(10)
        guard data.count <= 16_384 else { throw CocoaError(.fileWriteUnknown) }
        let descriptor = open(journalURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              fchmod(descriptor, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard count == data.count else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Read a bounded suffix. The cursor is the byte offset of the oldest consumed line,
    /// so new appends cannot shift older pages or create duplicates while paging backwards.
    func readJournal(before: UInt64? = nil, limit: Int = 50) throws -> GuardNetworkLogPage {
        let descriptor = open(journalURL.path, O_RDONLY | O_NOFOLLOW)
        if descriptor < 0, errno == ENOENT { return .init(entries: [], nextOffset: nil) }
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let end = min(before ?? UInt64(info.st_size), UInt64(info.st_size))
        guard end > 0 else { return .init(entries: [], nextOffset: nil) }
        let count = min(100, max(1, limit))
        var start = end, data = Data()
        while start > 0 && data.count < 524_288 {
            let size = Int(min(65_536, start))
            start -= UInt64(size)
            var chunk = Data(count: size)
            let read = chunk.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, size, off_t(start)) }
            guard read == size else { throw CocoaError(.fileReadUnknown) }
            data.insert(contentsOf: chunk, at: 0)
            if data.reduce(0, { $0 + ($1 == 10 ? 1 : 0) }) >= count + 2 { break }
        }
        // Discard a partial first line when starting inside the file.
        if start > 0 {
            if let newline = data.firstIndex(of: 10) {
                let drop = data.distance(from: data.startIndex, to: newline) + 1
                data = Data(data.dropFirst(drop)); start += UInt64(drop)
            } else { return .init(entries: [], nextOffset: start > 0 ? start : nil, skippedRecords: 1) }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let bytes = Array(data)
        var lines: [(Int, Int)] = [], beginning = 0
        for index in bytes.indices where bytes[index] == 10 {
            if index > beginning { lines.append((beginning, index)) }
            beginning = index + 1
        }
        if beginning < bytes.count { lines.append((beginning, bytes.count)) }
        var entries: [GuardNetworkLogEntry] = [], skipped = 0, cursor = start
        for (first, last) in lines.reversed() {
            cursor = start + UInt64(first)
            let line = Data(bytes[first..<last])
            if line.count <= 16_384, var entry = try? decoder.decode(GuardNetworkLogEntry.self, from: line), entry.isValid {
                entry.sourceOffset = cursor
                entries.append(entry)
            } else { skipped += 1 }
            if entries.count >= count { break }
        }
        return .init(entries: entries, nextOffset: cursor > 0 ? cursor : nil, skippedRecords: skipped)
    }

    func save(_ history: GuardNetworkHistory) throws {
        let parent = url.deletingLastPathComponent(), manager = FileManager.default
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: parent.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw CocoaError(.fileWriteNoPermission) }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try JSONEncoder().encode(history).write(to: url, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
