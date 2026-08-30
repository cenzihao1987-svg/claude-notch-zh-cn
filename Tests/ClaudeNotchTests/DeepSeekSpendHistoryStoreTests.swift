import Foundation
import Testing
@testable import ClaudeNotch

@Suite struct DeepSeekSpendHistoryStoreTests {
    @Test func groupsExpenseRowsByDayAndSkipsRecharge() throws {
        let calendar = Calendar(identifier: .gregorian)
        let history = try DeepSeekSpendHistoryStore.parse(
            """
            日期,消费金额,币种,类型
            2026-08-24 09:30:00,1.20,CNY,API 调用
            2026-08-24 12:00:00,-0.30,CNY,API 调用
            2026-08-25 10:00:00,100.00,CNY,充值
            2026-08-26,2.50,CNY,API 调用
            """,
            sourcePath: "/tmp/usage.csv",
            now: Date(timeIntervalSince1970: 1),
            calendar: calendar
        )

        #expect(history.currency == "CNY")
        #expect(history.dailySpend == ["2026-08-24": 1.5, "2026-08-26": 2.5])
        #expect(history.sourcePath == "/tmp/usage.csv")
    }

    @Test func supportsEnglishQuotedCSVAndDollarAmounts() throws {
        let history = try DeepSeekSpendHistoryStore.parse(
            """
            created_at,cost,currency,description
            2026-08-29T12:00:00Z,"$0.24",USD,API usage
            2026-08-30T12:00:00Z,"$1.10",USD,API usage
            """
        )

        #expect(history.currency == "USD")
        #expect(history.dailySpend.values.reduce(0, +) == 1.34)
    }

    @Test func supportsOfficialDeepSeekCostExportHeaders() throws {
        let history = try DeepSeekSpendHistoryStore.parse(
            """
            user_id,start_time_iso,end_time_iso,model,wallet_type,cost,currency
            anonymous,2026-08-29T12:00:00Z,2026-08-29T12:00:05Z,deepseek-v4-flash,topped_up,0.24,CNY
            anonymous,2026-08-30T12:00:00Z,2026-08-30T12:00:05Z,deepseek-v4-flash,topped_up,1.10,CNY
            """
        )

        #expect(history.currency == "CNY")
        #expect(abs(history.dailySpend.values.reduce(0, +) - 1.34) < 0.0001)
    }

    @Test func automaticallyFindsCostCSVInsideOfficialDownloadFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepseek-export-test-\(UUID().uuidString)", isDirectory: true)
        let export = root.appendingPathComponent("usage_data_2026-08-01_2026-08-30", isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let amount = export.appendingPathComponent("amount-2026-08-01_2026-08-30.csv")
        let cost = export.appendingPathComponent("cost-2026-08-01_2026-08-30.csv")
        try Data("amount".utf8).write(to: amount)
        try Data("cost".utf8).write(to: cost)

        #expect(try DeepSeekSpendHistoryStore.latestUsageCSV(in: root).standardizedFileURL.path
            == cost.standardizedFileURL.path)
    }

    @Test func rejectsMissingColumnsAndMixedCurrencies() {
        #expect(throws: DeepSeekSpendImportError.missingDateColumn) {
            try DeepSeekSpendHistoryStore.parse("amount\n1.00")
        }
        #expect(throws: DeepSeekSpendImportError.missingAmountColumn) {
            try DeepSeekSpendHistoryStore.parse("date\n2026-08-30")
        }
        #expect(throws: DeepSeekSpendImportError.multipleCurrencies) {
            try DeepSeekSpendHistoryStore.parse("date,amount,currency\n2026-08-30,1,CNY\n2026-08-29,1,USD")
        }
    }

    @MainActor @Test func makesExactlyOneMorningAndEveningPassiveSlot() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let morning = formatter.date(from: "2026-08-30 09:10")!
        let evening = formatter.date(from: "2026-08-30 21:10")!
        let early = formatter.date(from: "2026-08-30 01:00")!

        #expect(AppModel.deepSeekPassiveSlot(for: early, calendar: calendar) == nil)
        #expect(AppModel.deepSeekPassiveSlot(for: morning, calendar: calendar) == "2026-08-30-morning")
        #expect(AppModel.deepSeekPassiveSlot(for: evening, calendar: calendar) == "2026-08-30-evening")
    }

    @Test func liveDownloadedExportWhenExplicitlyRequested() throws {
        guard ProcessInfo.processInfo.environment["CODEX_NOTCH_RUN_DEEPSEEK_EXPORT_TEST"] == "1" else {
            return
        }
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        let url = try DeepSeekSpendHistoryStore.latestUsageCSV(in: downloads)
        let history = try DeepSeekSpendHistoryStore.history(from: url)
        #expect(!history.dailySpend.isEmpty)
        #expect(["CNY", "USD"].contains(history.currency))
    }
}
