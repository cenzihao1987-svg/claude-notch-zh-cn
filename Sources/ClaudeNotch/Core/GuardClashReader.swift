import AppKit
import Foundation

enum GuardClashReader {
    private final class LocalOnlySession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static let bundleIDs = ["io.github.clash-verge-rev.clash-verge-rev", "io.github.zyrouge.clash-verge"]
    struct Endpoint: Equatable, Sendable {
        var socket: String?
        var controller: URL?
        var secret: String?
    }

    /// Only top-level endpoint keys are retained. Configuration's mode is deliberately ignored.
    static func endpoint(_ data: Data) -> Endpoint? {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            guard ["external-controller-unix", "external-controller", "secret"].contains(key) else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                value = (try? JSONDecoder().decode(String.self, from: Data(value.utf8))) ?? ""
            } else if value.hasPrefix("'") && value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            } else if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
            values[key] = value
        }
        let socket = values["external-controller-unix"].flatMap { $0.hasPrefix("/") && $0.utf8.count < 1024 ? $0 : nil }
        var address = values["external-controller"] ?? ""
        if address.hasPrefix(":") { address = "127.0.0.1" + address }
        var components = URLComponents(string: "http://" + address)
        if components?.host == "0.0.0.0" { components?.host = "127.0.0.1" }
        let local = ["127.0.0.1", "localhost", "[::1]", "::1"].contains(components?.host ?? "")
        let controller = local && components?.port != nil && components?.user == nil && components?.password == nil
            ? components?.url : nil
        guard socket != nil || controller != nil else { return nil }
        return Endpoint(socket: socket, controller: controller, secret: values["secret"])
    }

    static func decode(_ data: Data, status: Int = 200) -> GuardClashState {
        guard status == 200, data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mode = object["mode"] as? String,
              let state = GuardClashState(rawValue: mode.lowercased()), [.global, .rule, .direct].contains(state) else { return .unknown }
        return state
    }

    @MainActor static func read() async -> GuardClashState {
        let running = NSWorkspace.shared.runningApplications.contains { bundleIDs.contains($0.bundleIdentifier ?? "") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let endpoints = await Task.detached(priority: .utility) {
            ["io.github.clash-verge-rev.clash-verge-rev", "io.github.zyrouge.clash-verge"].compactMap { directory -> Endpoint? in
                let url = home.appendingPathComponent("Library/Application Support/\(directory)/clash-verge.yaml")
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
                      let data = try? Data(contentsOf: url) else { return nil }
                return endpoint(data)
            }
        }.value
        for endpoint in endpoints {
            if let socket = endpoint.socket {
                let data = await Task.detached(priority: .utility) { readSocket(socket) }.value
                if let data, decode(data) != .unknown { return decode(data) }
            }
            if let controller = endpoint.controller {
                var request = URLRequest(url: controller.appendingPathComponent("configs"))
                request.timeoutInterval = 2
                if let secret = endpoint.secret, !secret.isEmpty { request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization") }
                let config = URLSessionConfiguration.ephemeral
                config.connectionProxyDictionary = [:]
                config.httpCookieStorage = nil; config.urlCredentialStorage = nil
                config.timeoutIntervalForResource = 2
                let session = URLSession(configuration: config, delegate: LocalOnlySession(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                if let (data, response) = try? await session.data(for: request) {
                    let state = decode(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
                    if state != .unknown { return state }
                }
            }
        }
        return running ? .unknown : .notRunning
    }

    private static func readSocket(_ path: String) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeSocket,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return nil }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["--silent", "--fail", "--noproxy", "*", "--max-time", "2", "--max-filesize", "65536", "--unix-socket", path, "http://localhost/configs"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Drain while curl runs, including chunked responses; curl's own deadline bounds the read.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= 65_536 else { return nil }
        return data
    }

    /// Returns false when Clash Verge is not installed.
    @discardableResult
    @MainActor static func open() -> Bool {
        guard let url = bundleIDs.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}

enum GuardLaunchNetworkProbe {
    private struct Response: Decodable { let ip: String; let country: String }
    static func exit() async -> GuardExit? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 5
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(from: URL(string: "https://api.country.is/")!),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65_536,
              let result = try? JSONDecoder().decode(Response.self, from: data),
              Locale.Region.isoRegions.contains(where: { $0.identifier == result.country }) else { return nil }
        return GuardExit(.init(countryCode: result.country, fetchedAt: .now, ip: result.ip))
    }
    @MainActor static func sample() async -> GuardLaunchNetworkSample {
        async let exit = exit()
        let clash = await GuardClashReader.read()
        return await .init(exit: exit, clash: clash)
    }
}
