import Foundation
import Testing
@testable import ClaudeNotch

@Suite struct GuardVPNToolTests {
    private func tool(_ name: String, running: Bool) -> GuardVPNTool {
        .init(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, running: running)
    }

    @Test func commonClientsAreRecognizedWithoutMatchingBrowsersOrHelpers() {
        for name in ["Clash Verge", "ClashX Pro", "Surge", "Stash", "FlClash", "Mihomo Party", "sing-box", "V2rayU", "Hiddify", "WireGuard"] {
            #expect(GuardVPNTool.recognizes(name: name))
        }
        #expect(!GuardVPNTool.recognizes(name: "Google Chrome"))
        #expect(!GuardVPNTool.recognizes(name: "Clash Verge Helper"))
        #expect(GuardVPNTool.recognizes(name: "自定义显示名", bundleID: "io.github.clash-verge-rev.clash-verge-rev"))
    }

    @Test func runningNonClashClientWinsOverInstalledOrPreferredClash() {
        let clash = tool("Clash Verge", running: false), surge = tool("Surge", running: true)
        #expect(GuardVPNTool.choices([clash, surge], preferred: clash.url) == [surge])
    }

    @Test func multipleRunningClientsRemainSelectableAndPreferenceSortsFirst() {
        let clash = tool("Clash Verge", running: true), surge = tool("Surge", running: true)
        #expect(GuardVPNTool.choices([clash, surge], preferred: surge.url) == [surge, clash])
    }

    @Test func installedChoicesAreDeduplicatedWithoutRunningClients() {
        let a = tool("Surge", running: false), b = tool("WireGuard", running: false)
        #expect(GuardVPNTool.choices([a, b, a], preferred: nil) == [a, b])
    }
}
