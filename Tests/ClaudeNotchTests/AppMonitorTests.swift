import Testing
@testable import ClaudeNotch

@Suite struct AppMonitorTests {
    @Test(arguments: ["com.tencent.workbuddy.mac", "com.workbuddy.workbuddy"])
    func workBuddyCurrentAndLegacyIdentitiesAreRecognized(_ bundleID: String) {
        #expect(AppMonitor.provider(forBundleID: bundleID) == .workbuddy)
    }

    @Test func existingClaudeAndCodexIdentitiesRemainRecognized() {
        #expect(AppMonitor.provider(forBundleID: "com.anthropic.claudefordesktop") == .claude)
        #expect(AppMonitor.provider(forBundleID: "com.anthropic.claude") == .claude)
        #expect(AppMonitor.provider(forBundleID: "com.openai.codex") == .codex)
    }

    @Test(arguments: ["com.tencent.workbuddy.mac.helper", "com.workbuddy.workbuddy.fake", "com.tencent.workbuddy", "com.google.Chrome", "WorkBuddy", ""])
    func unrelatedAndSimilarIdentifiersDoNotChangeProvider(_ bundleID: String) {
        #expect(AppMonitor.provider(forBundleID: bundleID) == nil)
    }

    @Test func missingIdentityIsIgnored() {
        #expect(AppMonitor.provider(forBundleID: nil) == nil)
    }
}
