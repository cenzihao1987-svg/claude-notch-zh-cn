import AppKit
import UniformTypeIdentifiers

struct GuardVPNTool: Equatable, Sendable {
    let url: URL
    let name: String
    let running: Bool

    static func recognizes(name: String, bundleID: String? = nil) -> Bool {
        if GuardClashReader.bundleIDs.contains(bundleID ?? "") { return true }
        let key = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return ["clashverge", "clashvergerev", "clashx", "clashxpro", "clashnyanpasu", "flclash",
                "mihomoparty", "mihomopartyalpha", "surge", "surge5", "surge6", "stash", "shadowrocket",
                "quantumultx", "singbox", "singboxvt", "nekoray", "v2rayu", "v2rayn", "qv2ray",
                "hiddify", "loon", "tunnelblick", "wireguard", "openvpnconnect", "tailscale"].contains(key)
    }

    /// Running clients come first. Multiple clients are left for the user to choose.
    static func choices(_ tools: [Self], preferred: URL?) -> [Self] {
        let running = tools.filter(\.running)
        let candidates = running.isEmpty ? tools : running
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.url.standardizedFileURL.path).inserted }.sorted {
            if ($0.url == preferred) != ($1.url == preferred) { return $0.url == preferred }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

@MainActor
enum GuardVPNToolOpener {
    private static let preferredKey = "environmentGuard.vpnToolPath"

    static func open(language: AppLanguage) {
        let saved = UserDefaults.standard.string(forKey: preferredKey).map { URL(fileURLWithPath: $0) }
        var tools = NSWorkspace.shared.runningApplications.compactMap { app -> GuardVPNTool? in
            guard let url = app.bundleURL, url.pathExtension == "app" else { return nil }
            let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
            guard GuardVPNTool.recognizes(name: name, bundleID: app.bundleIdentifier) || url == saved else { return nil }
            return .init(url: url, name: name, running: true)
        }
        if tools.isEmpty {
            let folders = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            for folder in folders {
                let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                tools += urls.filter { $0.pathExtension == "app" && GuardVPNTool.recognizes(name: $0.deletingPathExtension().lastPathComponent) }
                    .map { .init(url: $0, name: $0.deletingPathExtension().lastPathComponent, running: false) }
            }
            if let saved, FileManager.default.fileExists(atPath: saved.path), Bundle(url: saved) != nil {
                tools.append(.init(url: saved, name: saved.deletingPathExtension().lastPathComponent, running: false))
            }
        }
        let choices = GuardVPNTool.choices(tools, preferred: saved)
        var selected: URL?
        if choices.count == 1 { selected = choices[0].url }
        else if choices.count > 1 {
            let alert = NSAlert()
            alert.messageText = language.text("打开网络工具", "Open VPN tool")
            alert.informativeText = language.text("选择你当前使用的客户端。", "Choose the client you use.")
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
            picker.addItems(withTitles: choices.map(\.name) + [language.text("选择其他应用…", "Choose another app…")])
            alert.accessoryView = picker
            alert.addButton(withTitle: language.text("打开", "Open"))
            alert.addButton(withTitle: language.text("取消", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if picker.indexOfSelectedItem < choices.count { selected = choices[picker.indexOfSelectedItem].url }
        }
        if selected == nil {
            let picker = NSOpenPanel()
            picker.title = language.text("选择你使用的网络工具", "Choose your VPN app")
            picker.allowedContentTypes = [.application]
            picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
            picker.directoryURL = URL(fileURLWithPath: "/Applications")
            guard picker.runModal() == .OK, let url = picker.url, url.pathExtension == "app" else { return }
            selected = url
        }
        guard let selected else { return }
        UserDefaults.standard.set(selected.path, forKey: preferredKey)
        NSWorkspace.shared.open(selected)
    }
}
