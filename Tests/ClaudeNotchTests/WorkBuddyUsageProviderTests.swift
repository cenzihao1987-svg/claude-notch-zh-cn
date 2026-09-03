import Foundation
import SQLite3
import Testing
@testable import ClaudeNotch

@Suite struct WorkBuddyUsageProviderTests {
    @Test func credentialsUseOnlyCurrentAccessTokenAndAccountID() throws {
        let credentials = try WorkBuddyUsageProvider.credentials(from: Data("""
        {
          "account": {"uid": "fixture-user", "enterpriseId": "enterprise-1"},
          "auth": {"accessToken": "fixture-token", "domain": "workbuddy", "expiresAt": 4102444800000}
        }
        """.utf8))

        #expect(credentials.userID == "fixture-user")
        #expect(credentials.enterpriseID == "enterprise-1")
        #expect(credentials.expiresAt != nil)
        let request = WorkBuddyUsageProvider.enterpriseUsageRequest(credentials: credentials)
        #expect(request.url == WorkBuddyUsageProvider.enterpriseUsageURL)
        #expect(request.url?.scheme == "https")
        #expect(request.url?.host == "copilot.tencent.com")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
    }

    @Test func rejectsMissingOrMalformedCredentials() {
        #expect(throws: WorkBuddyUsageError.credentialsInvalid) {
            try WorkBuddyUsageProvider.credentials(from: Data("not json".utf8))
        }
        #expect(throws: WorkBuddyUsageError.credentialsInvalid) {
            try WorkBuddyUsageProvider.credentials(from: Data("""
            {"account":{"uid":""},"auth":{"accessToken":""}}
            """.utf8))
        }
    }

    @MainActor @Test func mapsPersonalPackagesWithoutInventingUsage() throws {
        let usage = try WorkBuddyUsageProvider.usage(from: Data("""
        {"data":{"Response":{"Data":{"Accounts":[
          {"PackageName":"Pro","CycleCapacitySizePrecise":"1000","CycleCapacityRemainPrecise":"600","CycleEndTime":4102444800000},
          {"PackageName":"Bonus","CycleCapacitySizePrecise":50,"CycleCapacityRemainPrecise":20}
        ]}}}}
        """.utf8), enterprise: false)

        #expect(usage.usageTotal == 1050)
        #expect(usage.usageLeft == 620)
        #expect(usage.usageUsed == 430)
        #expect(usage.planName == "Pro")
        let snapshot = WorkBuddyUsageProvider.snapshot(usage: usage, fetchedAt: Date(), sessions: [])
        #expect(snapshot.primaryUsage == Double(430) / 1050)
        #expect(snapshot.stats.count == 4)
        #expect(IslandView.singlePageStats(for: snapshot).count == 4)
    }

    @Test func mapsEnterpriseUnlimitedUsage() throws {
        let usage = try WorkBuddyUsageProvider.usage(from: Data("""
        {"data":{"limitNum":-1,"credit":12,"cycleResetTime":4102444800000}}
        """.utf8), enterprise: true)

        #expect(usage.isUnlimited)
        let snapshot = WorkBuddyUsageProvider.snapshot(usage: usage, fetchedAt: Date(), sessions: [])
        #expect(snapshot.headlineValue == "∞")
        #expect(snapshot.primaryUsage == nil)
    }

    @Test func mapsLocalRequestCreditsToSevenCalendarDays() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 2)))
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workbuddy-local-usage-\(UUID().uuidString)", isDirectory: true)
        let projectsURL = directory.appendingPathComponent("projects", isDirectory: true)
        let projectURL = projectsURL.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("workbuddy.db")
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        func execute(_ sql: String) {
            #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        }
        execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, updated_at INTEGER)")
        execute("CREATE TABLE session_usage (session_id TEXT PRIMARY KEY, credit_json TEXT)")
        execute("INSERT INTO sessions VALUES ('session-1', \(Int64(now.timeIntervalSince1970 * 1_000)))")
        execute("INSERT INTO session_usage VALUES ('session-1', '{\"req-a\":1.25,\"req-b\":3.5,\"req-old\":9,\"req-sub\":2}')")
        sqlite3_close(database)
        database = nil

        func timestamp(_ year: Int, _ month: Int, _ day: Int) throws -> Int64 {
            let date = try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
            return Int64(date.timeIntervalSince1970 * 1_000)
        }
        let mainLines = [
            "{\"timestamp\":\(try timestamp(2026, 8, 20)),\"providerData\":{\"conversationRequestId\":\"req-old\"}}",
            "{\"timestamp\":\(try timestamp(2026, 8, 29)),\"providerData\":{\"conversationRequestId\":\"req-a\"}}",
            "{\"timestamp\":\(try timestamp(2026, 8, 29)),\"providerData\":{\"conversationRequestId\":\"req-a\"}}",
            "{\"timestamp\":\(try timestamp(2026, 9, 1)),\"providerData\":{\"conversationRequestId\":\"req-b\"}}",
        ].joined(separator: "\n")
        try Data(mainLines.utf8).write(to: projectURL.appendingPathComponent("session-1.jsonl"))
        let subagentsURL = projectURL.appendingPathComponent("session-1/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentsURL, withIntermediateDirectories: true)
        let subagentLine = "{\"timestamp\":\(try timestamp(2026, 9, 2)),\"providerData\":{\"conversationRequestId\":\"req-sub\"}}"
        try Data(subagentLine.utf8).write(to: subagentsURL.appendingPathComponent("agent-1.jsonl"))

        let reader = WorkBuddyLocalUsageReader(databaseURL: databaseURL, projectsURL: projectsURL)
        let read = try await reader.read(force: true, now: now, calendar: calendar).get()
        #expect(read.matchedRequests == 4)
        #expect(read.totalRequests == 4)
        #expect(read.dailyUsage.map(\.credits) == [0, 0, 1.25, 0, 0, 3.5, 2])
        let snapshot = WorkBuddyUsageProvider.snapshot(
            usage: .init(usageLeft: 8, usageTotal: 10, usageUsed: 2, planName: "Pro",
                         editionType: nil, refreshAt: nil, expireAt: nil, isUnlimited: false),
            fetchedAt: now,
            sessions: [],
            dailyUsage: read.dailyUsage
        )
        #expect(snapshot.dailySeries.allSatisfy { $0.credits != nil && $0.tokens == 0 })
        #expect(snapshot.chartTitle == "last 7 days · local credits")
    }

    @Test func readsOnlyThreeMostRecentNonDeletedTasks() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workbuddy-db-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("workbuddy.db")
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer {
            if let database { sqlite3_close(database) }
        }

        func execute(_ sql: String) {
            #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        }
        execute("CREATE TABLE sessions (id TEXT, title TEXT, custom_title TEXT, updated_at REAL, deleted_at REAL, cwd TEXT)")
        execute("CREATE TABLE session_usage (session_id TEXT, used INTEGER)")
        execute("INSERT INTO sessions VALUES ('old','Old','',1000,NULL,''),('one','One','',4000,NULL,''),('two','Two','',3000,NULL,''),('three','Three','',2000,NULL,''),('gone','Gone','',5000,1,'')")
        execute("INSERT INTO session_usage VALUES ('one',11),('two',22),('three',33),('gone',99)")
        sqlite3_close(database)
        database = nil

        let tasks = try WorkBuddyUsageProvider.recentTasks(from: databaseURL).get()
        #expect(tasks.map(\.name) == ["One", "Two", "Three"])
        #expect(tasks.map(\.tokens) == [11, 22, 33])
    }

    @Test func workBuddyTasksExposeHandoffOnlyWithLocalTranscriptAndDirectory() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workbuddy-handoff-\(UUID().uuidString)", isDirectory: true)
        let projectsURL = directory.appendingPathComponent("projects", isDirectory: true)
        let projectURL = projectsURL.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("workbuddy.db")
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        #expect(sqlite3_exec(database, "CREATE TABLE sessions (id TEXT, title TEXT, custom_title TEXT, updated_at REAL, deleted_at REAL, cwd TEXT)", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "CREATE TABLE session_usage (session_id TEXT, used INTEGER)", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "INSERT INTO sessions VALUES ('with-log','Task','',4000,NULL,'/tmp/project'),('without-log','Old','',3000,NULL,'/tmp/project')", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(database, "INSERT INTO session_usage VALUES ('with-log',11),('without-log',22)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        database = nil
        try Data("{\"type\":\"message\",\"role\":\"user\"}\n".utf8)
            .write(to: projectURL.appendingPathComponent("with-log.jsonl"))

        let tasks = try WorkBuddyUsageProvider.recentTasks(
            from: databaseURL,
            projectsURL: projectsURL
        ).get()

        let handoffTask = try #require(tasks.first(where: { $0.id == "with-log" }))
        #expect(handoffTask.taskReference?.provider == .workbuddy)
        #expect(handoffTask.taskReference?.cwd == "/tmp/project")
        #expect(handoffTask.taskReference?.handoffDestinations == [.claudeDesktop, .codex])
        #expect(tasks.first(where: { $0.id == "without-log" })?.taskReference == nil)
    }

    @Test func liveWorkBuddyDataWhenExplicitlyRequested() async {
        guard ProcessInfo.processInfo.environment["CODEX_NOTCH_RUN_WORKBUDDY_INTEGRATION_TEST"] == "1" else {
            return
        }
        let snapshot = await WorkBuddyUsageProvider().fetch()
        #expect(snapshot.provider == .workbuddy)
        #expect(snapshot.sessions.count <= 3)
        if !snapshot.sessions.isEmpty {
            #expect(snapshot.sessions.contains { $0.taskReference != nil })
        }
        if let message = snapshot.statusMessage {
            Issue.record("WorkBuddy integration failed: \(message)")
        }
    }

    @Test func liveLocalWorkBuddyCreditsWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_NOTCH_RUN_WORKBUDDY_INTEGRATION_TEST"] == "1" else {
            return
        }
        let read = try await WorkBuddyLocalUsageReader().read(force: true).get()
        #expect(read.dailyUsage.count == 7)
        #expect(read.totalRequests > 0)
        #expect(read.matchedRequests > 0)
    }
}
