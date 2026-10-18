import Foundation

struct GuardProxyCheck: Equatable, Sendable {
    var definitions: [String] = []
    var activeVariables: [String] = []
    var endpointCount = 0
    var conflict = false
    var inspected = false
    var incomplete = false
    var points: Int { !inspected ? 0 : conflict ? 15 : definitions.isEmpty && activeVariables.isEmpty && !incomplete ? 0 : 5 }
    var summary: GuardText {
        if !inspected { return .init("待核验", "Unverified") }
        if conflict { return .init("存在多套代理端点", "Multiple proxy endpoints need review") }
        if incomplete { return .init("部分代理配置未读取", "Some proxy settings could not be read") }
        if points > 0 { return .init("发现代理定义，需核验", "Proxy definitions need review") }
        return .init("未发现旧代理迹象", "No old proxy indications")
    }
    var state: GuardCheckState { !inspected || incomplete ? .unknown : points > 0 ? .attention : .passed }

}

struct GuardRuntimeProcess: Equatable, Sendable {
    let pid: Int32
    let parent: Int32
    let path: String
}

struct GuardRuntimeCheck: Equatable, Sendable {
    var inspected = false
    var desktopRunning = false
    var execution: [String] = []
    var browsers: [String] = []
    var environmentSamples: [String] = []
    var virtualMachine = false
    var backgroundMismatch = false
    var points: Int { !inspected || !desktopRunning ? 0 : backgroundMismatch ? 10 : 5 }
    // Process evidence confirms local processes, never the account request route or cloud location.
    var location: GuardText {
        if !desktopRunning { return .init("Claude 未运行", "Claude is not running") }
        if backgroundMismatch { return .init("后台进程时区与配置不同", "Background process timezone differs") }
        if virtualMachine { return .init("本机隔离运行组件；任务内部环境与出口未核验", "Local isolation component; task environment and route unverified") }
        if !execution.isEmpty { return .init("本机执行进程；后台环境与出口未核验", "Local execution; background environment and route unverified") }
        return .init("未确认执行位置（可能空闲或云端）", "Execution location unverified (idle or cloud possible)")
    }
}

enum GuardExecutionInspector {
    static let proxyKeys: Set<String> = ["http_proxy", "https_proxy", "all_proxy", "no_proxy"]

    /// Only variable names and source line locations survive inspection, never passwords or values.
    static func proxyCheck(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           shellProcesses: [GuardRuntimeProcess] = []) -> GuardProxyCheck {
        var result = GuardProxyCheck(inspected: true)
        var endpoints = Set<String>()
        for (key, value) in environment where proxyKeys.contains(key.lowercased()) && !value.isEmpty {
            result.activeVariables.append(key)
            if key.lowercased() != "no_proxy", let endpoint = endpointIdentity(value) { endpoints.insert(endpoint) }
        }
        for shell in shellProcesses where ["/bin/zsh", "/bin/bash", "/bin/sh", "/opt/homebrew/bin/fish"].contains(shell.path) {
            guard let variables = GuardProcessReader.proxyEnvironment(pid: shell.pid) else { result.incomplete = true; continue }
            for (key, value) in variables where !value.isEmpty {
                result.activeVariables.append("PID \(shell.pid) · \(key)")
                if key.lowercased() != "no_proxy", let endpoint = endpointIdentity(value) { endpoints.insert(endpoint) }
            }
        }
        for file in [".zshenv", ".zprofile", ".zshrc", ".profile", ".bash_profile", ".bashrc"] {
            let url = home.appendingPathComponent(file)
            guard let data = GuardWebEnvironmentReader.privateData(at: url, maxBytes: 262_144, requirePrivateOwner: false),
                  let text = String(data: data, encoding: .utf8) else {
                if FileManager.default.fileExists(atPath: url.path) { result.incomplete = true }
                continue
            }
            result.definitions += definitions(in: text, source: file)
        }
        let settings = home.appendingPathComponent(".claude/settings.json")
        if let data = GuardWebEnvironmentReader.privateData(at: settings, maxBytes: 262_144, requirePrivateOwner: false),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let env = object["env"] as? [String: Any] {
            for (key, raw) in env where proxyKeys.contains(key.lowercased()) {
                result.definitions.append("~/.claude/settings.json · \(key)")
                if key.lowercased() != "no_proxy", let value = raw as? String,
                   let endpoint = endpointIdentity(value) { endpoints.insert(endpoint) }
            }
        }
        result.endpointCount = endpoints.count
        result.conflict = endpoints.count > 1
        result.activeVariables.sort()
        return result
    }

    static func definitions(in text: String, source: String) -> [String] {
        let pattern = #"(?i)(?:^|[;\s])(?:export\s+)?(https?_proxy|all_proxy|no_proxy)\s*="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { return nil }
            return "\(source):\(index + 1) · \(line[range])"
        }
    }

    static func endpointIdentity(_ value: String) -> String? {
        guard value.count <= 4096,
              let url = URLComponents(string: value.contains("://") ? value : "http://" + value),
              let host = url.host, !host.isEmpty else { return nil }
        return host.lowercased() + ":" + String(url.port ?? (url.scheme == "https" ? 443 : 80))
    }

    static func processes() -> [GuardRuntimeProcess] { checkedProcesses() ?? [] }

    static func checkedProcesses() -> [GuardRuntimeProcess]? {
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-xo", "pid=,ppid=,comm="]
        task.standardOutput = output; task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, data.count < 2_097_152 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 3, let pid = Int32(parts[0]), let parent = Int32(parts[1]) else { return nil }
            return .init(pid: pid, parent: parent, path: String(parts[2]))
        }
    }

    static func runtimeCheck(client: GuardClient?, processes: [GuardRuntimeProcess], home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             expectedProfile: GuardProfile? = nil) -> GuardRuntimeCheck {
        var result = GuardRuntimeCheck(inspected: true, desktopRunning: client?.pid != nil)
        guard let client, let desktopPID = client.pid else { return result }
        let map = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        func descends(_ pid: Int32, from ancestor: Int32) -> Bool {
            var current = pid, seen = Set<Int32>()
            while seen.insert(current).inserted, let process = map[current] {
                if current == ancestor { return true }
                current = process.parent
            }
            return false
        }
        let appPrefix = client.path + "/"
        let runtimePrefix = home.appendingPathComponent("Library/Application Support/Claude/").path + "/"
        for process in processes {
            let name = URL(fileURLWithPath: process.path).lastPathComponent
            let trusted = process.path.hasPrefix(appPrefix) || process.path.hasPrefix(runtimePrefix)
            if trusted && process.pid != desktopPID && descends(process.pid, from: desktopPID) {
                if ["claude", "claude-code", "vm", "vmm", "cowork"].contains(name.lowercased()) || name.lowercased().contains("virtualmachine")
                    || process.path.contains("/claude-code-vm/") {
                    result.execution.append("\(process.path.replacingOccurrences(of: home.path, with: "~")) · PID \(process.pid)")
                    if let expectedProfile, expectedProfile.isValid, let zone = GuardProcessReader.read(pid: process.pid)?.timeZone,
                       TimeZone(identifier: zone) != nil {
                        result.environmentSamples.append("PID \(process.pid) · TZ=\(zone)")
                        if !GuardWebEvaluator.timezoneMatches(zone, expectedProfile.timeZoneIdentifier) { result.backgroundMismatch = true }
                    }
                    result.virtualMachine = result.virtualMachine || process.path.contains("/claude-code-vm/") || process.path.contains("/vm_bundles/")
                }
                if name.localizedCaseInsensitiveContains("browser") || name == "chrome-native-host" || name.contains("Renderer") {
                    result.browsers.append("\(process.path) · PID \(process.pid)（页面进程，任务关联未核验）")
                }
            }
            if process.path.hasPrefix(appPrefix), name == "chrome-native-host", let browser = map[process.parent],
               browser.path.hasPrefix("/Applications/Google Chrome.app/") || browser.path.hasPrefix("/Applications/Microsoft Edge.app/") {
                result.browsers.append("\(browser.path) · PID \(browser.pid)（桥接存在，任务使用未确认）")
            }
        }
        result.execution.sort(); result.browsers = Array(Set(result.browsers)).sorted()
        return result
    }
}
