import Foundation
import AppKit
import SwiftUI
import Testing
@testable import ClaudeNotch

@Suite struct GuardHistoryLogTests {
    private let date = Date(timeIntervalSince1970: 1_792_000_000)
    private func store() throws -> GuardHistoryStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("guard-log-\(UUID().uuidString)")
        let store = GuardHistoryStore(url: folder.appendingPathComponent("history.json"))
        try store.save(.init())
        return store
    }
    private func exit(_ index: Int) -> GuardExit {
        GuardExit(.init(countryCode: "TR", fetchedAt: date.addingTimeInterval(Double(index)),
            ip: "203.0.113.\((index % 250) + 1)", timeZone: "Europe/Istanbul"))!
    }
    private var risk: GuardLoggedRisk {
        .init(systemTotal: 80, configuredTotal: 80, networkPoints: 40, minimumTotal: 80, behavior: .repeated, locationUnverified: false)
    }

    @Test func immutableRiskAndPreviousExitRoundTrip() throws {
        let store = try store()
        try store.appendObservation(exit(2), kind: "exit-change", previous: exit(1), risk: risk, recordedAt: date.addingTimeInterval(100))
        let page = try store.readJournal()
        #expect(page.entries.count == 1)
        #expect(page.entries.first?.risk == risk)
        #expect(page.entries.first?.previous == exit(1))
        #expect(page.entries.first?.date == date.addingTimeInterval(100))
        #expect(page.nextOffset == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.journalURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func legacyRecordsKeepUnknownScoreAndHaveStableDistinctIDs() throws {
        let store = try store()
        struct Legacy: Encodable { let kind: String; let exit: GuardExit }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(Legacy(kind: "exit-change", exit: exit(1))); data.append(10)
        var duplicated = data; duplicated.append(data)
        try duplicated.write(to: store.journalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.journalURL.path)
        let first = try store.readJournal(), second = try store.readJournal()
        #expect(first.entries.count == 2)
        #expect(first.entries.allSatisfy { $0.risk == nil })
        #expect(Set(first.entries.map(\.id)).count == 2)
        #expect(first.entries.map(\.id) == second.entries.map(\.id))
    }

    @Test func backwardPaginationSurvivesNewAppendsWithoutSkippingOrDuplicating() throws {
        let store = try store()
        for index in 0..<180 { try store.appendObservation(exit(index), kind: "exit-change", risk: risk) }
        let first = try store.readJournal(limit: 17)
        #expect(first.entries.count == 17)
        #expect(first.entries.first?.exit == exit(179))
        try store.appendObservation(exit(181), kind: "risk-change", risk: risk)
        var collected = first.entries, cursor = first.nextOffset
        while let before = cursor {
            let page = try store.readJournal(before: before, limit: 17)
            collected.append(contentsOf: page.entries)
            #expect(page.nextOffset.map { $0 < before } ?? true)
            cursor = page.nextOffset
        }
        #expect(collected.count == 180)
        #expect(Set(collected.map(\.id)).count == 180)
        #expect(collected.map(\.exit) == (0..<180).reversed().map(exit))
        #expect(try store.readJournal().entries.first?.exit == exit(181))
    }

    @Test func damagedRowsAreReportedAndUnsafeFilesAreRejected() throws {
        let store = try store()
        try store.appendObservation(exit(1), kind: "tool-start")
        let handle = try FileHandle(forWritingTo: store.journalURL)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("damaged record\n".utf8)); try handle.close()
        let page = try store.readJournal()
        #expect(page.entries.count == 1)
        #expect(page.skippedRecords == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.journalURL.path)
        #expect(throws: (any Error).self) { try store.readJournal() }
        let linked = try self.store()
        try FileManager.default.createSymbolicLink(at: linked.journalURL, withDestinationURL: store.journalURL)
        #expect(throws: (any Error).self) { try linked.readJournal() }
        #expect(throws: (any Error).self) { try linked.appendObservation(exit(2), kind: "exit-change") }
    }

    @Test func emptyJournalIsNotAReadFailure() throws {
        let page = try store().readJournal()
        #expect(page.entries.isEmpty && page.nextOffset == nil && page.skippedRecords == 0)
    }

    @MainActor @Test func actualSamplingPipelineRecordsRiskEscalationAndPreservesOldScores() async throws {
        let store = try store()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let initial = GuardProfile(enabled: true, languageCode: "en-US", localeIdentifier: "en_US", timeZoneIdentifier: "America/Los_Angeles")
        defaults.set(try JSONEncoder().encode(initial), forKey: EnvironmentGuardService.profileKey)
        let service = EnvironmentGuardService(defaults: defaults, historyStore: store, activityProvider: { .active })
        let now = Date.now
        func observe(_ ip: String, country: String, seconds: Double, verification: GuardGeoVerification = .unchecked) -> Bool {
            service.applyNetworkObservation(.init(countryCode: country, fetchedAt: now.addingTimeInterval(seconds),
                ip: ip, timeZone: country == "US" ? "America/Los_Angeles" : "Europe/Istanbul"), verification: verification)
        }
        #expect(observe("203.0.113.1", country: "US", seconds: -120))
        #expect(observe("203.0.113.2", country: "TR", seconds: -100))
        #expect(observe("203.0.113.2", country: "TR", seconds: -95, verification: .verified))
        service.stop()
        let before = try store.readJournal()
        #expect(before.entries.first?.kind == "risk-change")
        #expect(before.entries.first?.risk?.configuredTotal == 50)
        #expect(before.entries.contains { $0.kind == "exit-change" && $0.previous?.country == "US" && $0.exit.country == "TR" })
        var profile = service.profile
        profile.selectRegion("CN"); profile.selectTimeZone("Asia/Shanghai")
        service.updateProfile(profile)
        service.stop()
        let after = try store.readJournal()
        #expect(after.entries.first?.risk?.configuredTotal == 70)
        #expect(after.entries.dropFirst().first?.risk?.configuredTotal == 50)
    }

    @MainActor @Test func nativeHistoryRowsRenderUsingOnlySyntheticEntries() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("guard-log-layout-\(UUID().uuidString)")
        let service = EnvironmentGuardService(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            historyStore: .init(url: folder.appendingPathComponent("history.json")))
        service.loadGuardDemo(.repeated)
        let entries = try await service.loadExitHistory().entries
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            ForEach(entries) { entry in NetworkHistoryRow(entry: entry, language: .chinese).padding(.horizontal, 18) }
        }.frame(width: 620).background(AppPalette.window))
        let size = host.fittingSize
        #expect(size.width == 620)
        #expect(size.height > 150 && size.height < 700)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("claude-notch-history-rows.png"))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor @Test func demoHistoryNeverReadsOrWritesRealFilesAndIgnoringKeepsTheScore() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("guard-log-demo-\(UUID().uuidString)")
        let file = folder.appendingPathComponent("history.json")
        let service = EnvironmentGuardService(defaults: UserDefaults(suiteName: UUID().uuidString)!, historyStore: .init(url: file))
        service.loadGuardDemo(.repeated)
        let before = try await service.loadExitHistory()
        #expect(before.entries.first?.risk?.configuredTotal == 80)
        service.ignoreNetworkRisk()
        let after = try await service.loadExitHistory()
        #expect(after.entries.first?.kind == "user-ignored")
        #expect(after.entries.first?.risk?.configuredTotal == 80)
        service.loadGuardDemo(.anomalous)
        #expect(try await service.loadExitHistory().entries.first?.risk?.configuredTotal == 50)
        var profile = service.profile
        profile.selectRegion("CN"); profile.selectTimeZone("Asia/Shanghai")
        service.updateProfile(profile)
        let changed = try await service.loadExitHistory()
        #expect(changed.entries.first?.kind == "risk-change")
        #expect(changed.entries.first?.risk?.configuredTotal == 80)
        #expect(changed.entries.dropFirst().first?.risk?.configuredTotal == 50)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
