import Foundation

struct DeepSeekSpendHistory: Codable, Equatable, Sendable {
    let sourcePath: String
    let currency: String
    let dailySpend: [String: Double]
    let updatedAt: Date

    func lastSevenDays(now: Date = Date(), calendar: Calendar = .current) -> [DailyUsagePoint] {
        let formatter = Self.dayFormatter
        return (0..<7).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { return nil }
            let start = calendar.startOfDay(for: day)
            return DailyUsagePoint(
                date: start,
                tokens: 0,
                cost: dailySpend[formatter.string(from: start)] ?? 0
            )
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

enum DeepSeekSpendImportError: Error, Equatable, Sendable {
    case unreadableFile
    case invalidCSV
    case missingDateColumn
    case missingAmountColumn
    case noUsageRows
    case multipleCurrencies
    case usageCSVNotFound

    var message: String {
        switch self {
        case .unreadableFile: "无法读取 DeepSeek 用量 CSV"
        case .invalidCSV: "DeepSeek 用量 CSV 格式无效"
        case .missingDateColumn: "DeepSeek 用量 CSV 缺少日期列"
        case .missingAmountColumn: "DeepSeek 用量 CSV 缺少金额列"
        case .noUsageRows: "DeepSeek 用量 CSV 没有可用消费记录"
        case .multipleCurrencies: "DeepSeek 用量 CSV 包含多种币种"
        case .usageCSVNotFound: "未在导出目录中找到 cost CSV"
        }
    }
}

/// Keeps only the daily totals and the user-selected source path. The raw CSV, API key and
/// request records are never copied into the app's support directory.
actor DeepSeekSpendHistoryStore {
    private let storageURL: URL
    private let downloadsURL: URL

    init(storageURL: URL? = nil, downloadsURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL
        self.downloadsURL = downloadsURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    func load() -> DeepSeekSpendHistory? {
        guard let data = try? Data(contentsOf: storageURL) else { return nil }
        return try? JSONDecoder().decode(DeepSeekSpendHistory.self, from: data)
    }

    func importCSV(at sourceURL: URL, now: Date = Date()) throws -> DeepSeekSpendHistory {
        let history = try Self.history(from: Self.resolveUsageCSV(at: sourceURL), now: now)
        try save(history)
        return history
    }

    /// Finds the newest official export in Downloads on every scheduled/manual refresh. A
    /// missing or malformed replacement never deletes the last successful daily totals.
    func refreshLatestExport(now: Date = Date()) throws -> DeepSeekSpendHistory {
        let history = try Self.history(from: Self.latestUsageCSV(in: downloadsURL), now: now)
        try save(history)
        return history
    }

    static func history(from sourceURL: URL, now: Date = Date(), calendar: Calendar = .current) throws -> DeepSeekSpendHistory {
        guard let text = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            throw DeepSeekSpendImportError.unreadableFile
        }
        return try parse(text, sourcePath: sourceURL.path, now: now, calendar: calendar)
    }

    /// DeepSeek exports a folder containing `cost-*.csv` and `amount-*.csv`. The bar chart uses
    /// the former because it has the billed amount and currency for each request.
    static func resolveUsageCSV(at url: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw DeepSeekSpendImportError.unreadableFile
        }
        guard isDirectory.boolValue else { return url }
        let files = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        guard let costCSV = files.first(where: {
            $0.pathExtension.lowercased() == "csv" && $0.lastPathComponent.lowercased().hasPrefix("cost-")
        }) else {
            throw DeepSeekSpendImportError.usageCSVNotFound
        }
        return costCSV
    }

    /// Scans only `~/Downloads/cost-*.csv` and one level of official `usage_data_*` folders;
    /// unrelated Downloads content is never opened.
    static func latestUsageCSV(in downloadsURL: URL) throws -> URL {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: downloadsURL,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw DeepSeekSpendImportError.usageCSVNotFound
        }

        var candidates = entries.filter(isCostCSV)
        for directory in entries where directory.lastPathComponent.hasPrefix("usage_data_") {
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            candidates.append(contentsOf: (files ?? []).filter(isCostCSV))
        }

        guard let latest = candidates.max(by: { modificationDate($0) < modificationDate($1) }) else {
            throw DeepSeekSpendImportError.usageCSVNotFound
        }
        return latest
    }

    static func parse(
        _ text: String,
        sourcePath: String = "/tmp/deepseek-usage.csv",
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> DeepSeekSpendHistory {
        let rows = CSVRows.parse(text)
        guard let headers = rows.first, !headers.isEmpty else { throw DeepSeekSpendImportError.invalidCSV }
        let normalized = headers.map(normalizeHeader)
        guard let dateIndex = index(in: normalized, matching: isDateHeader) else {
            throw DeepSeekSpendImportError.missingDateColumn
        }
        guard let amountIndex = index(in: normalized, matching: isAmountHeader) else {
            throw DeepSeekSpendImportError.missingAmountColumn
        }
        let currencyIndex = index(in: normalized, matching: isCurrencyHeader)
        let categoryIndex = index(in: normalized, matching: isCategoryHeader)
        let dateFormatter = dayFormatter
        var totals: [String: Double] = [:]
        var currencies = Set<String>()

        for row in rows.dropFirst() {
            guard row.indices.contains(dateIndex), row.indices.contains(amountIndex) else { continue }
            if let categoryIndex, row.indices.contains(categoryIndex), isNonUsageCategory(row[categoryIndex]) {
                continue
            }
            guard let date = parseDate(row[dateIndex]), let amount = parseAmount(row[amountIndex]) else { continue }
            let currency = currencyIndex.flatMap { row.indices.contains($0) ? parseCurrency(row[$0]) : nil }
                ?? inferredCurrency(from: row[amountIndex])
                ?? "CNY"
            currencies.insert(currency)
            let key = dateFormatter.string(from: calendar.startOfDay(for: date))
            totals[key, default: 0] += abs(amount)
        }

        guard !totals.isEmpty else { throw DeepSeekSpendImportError.noUsageRows }
        guard currencies.count == 1, let currency = currencies.first else {
            throw DeepSeekSpendImportError.multipleCurrencies
        }
        return DeepSeekSpendHistory(sourcePath: sourcePath, currency: currency, dailySpend: totals, updatedAt: now)
    }

    private func save(_ history: DeepSeekSpendHistory) throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(history)
        try data.write(to: storageURL, options: .atomic)
    }

    private static let defaultStorageURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude Notch/DeepSeek/usage-history.json")

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func index(in headers: [String], matching predicate: (String) -> Bool) -> Int? {
        headers.firstIndex(where: predicate)
    }

    private static func normalizeHeader(_ value: String) -> String {
        value.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private static func isDateHeader(_ value: String) -> Bool {
        ["date", "日期", "时间", "time", "createdat", "createdtime", "starttime", "starttimeiso", "endtime", "endtimeiso", "账单日期", "消费日期"].contains(value)
    }

    private static func isAmountHeader(_ value: String) -> Bool {
        ["amount", "cost", "fee", "totalcost", "totalamount", "消费金额", "金额", "费用", "花费", "账单金额"].contains(value)
    }

    private static func isCurrencyHeader(_ value: String) -> Bool {
        ["currency", "币种", "货币"].contains(value)
    }

    private static func isCategoryHeader(_ value: String) -> Bool {
        ["type", "transactiontype", "category", "类别", "类型", "说明", "description"].contains(value)
    }

    private static func isNonUsageCategory(_ value: String) -> Bool {
        let lower = value.lowercased()
        return ["充值", "赠金", "退款", "recharge", "topup", "top up", "grant", "refund"]
            .contains { lower.contains($0) }
    }

    private static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed), seconds > 1_000_000_000 {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
        }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: trimmed) { return date }
        for pattern in ["yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss", "yyyy-MM-dd", "yyyy/MM/dd"] {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    private static func parseAmount(_ value: String) -> Double? {
        let clean = value
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(clean)
    }

    private static func parseCurrency(_ value: String) -> String? {
        let currency = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ["CNY", "USD"].contains(currency) ? currency : nil
    }

    private static func inferredCurrency(from amount: String) -> String? {
        amount.contains("¥") ? "CNY" : (amount.contains("$") ? "USD" : nil)
    }

    private static func isCostCSV(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "csv" && url.lastPathComponent.lowercased().hasPrefix("cost-")
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

private enum CSVRows {
    static func parse(_ text: String) -> [[String]] {
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let delimiter: Character = normalizedText.first(where: { $0 == "," || $0 == "\t" }) == "\t" ? "\t" : ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = normalizedText.makeIterator()
        while let character = iterator.next() {
            if character == "\"" {
                if quoted, let next = iterator.next() {
                    if next == "\"" { field.append("\"") } else {
                        quoted = false
                        if next == delimiter { row.append(field); field = "" }
                        else if next == "\n" || next == "\r" {
                            row.append(field); field = ""; rows.append(row); row = []
                        } else { field.append(next) }
                    }
                } else {
                    quoted.toggle()
                }
            } else if character == delimiter, !quoted {
                row.append(field); field = ""
            } else if character == "\n", !quoted {
                row.append(field); field = ""; rows.append(row); row = []
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    }
}
