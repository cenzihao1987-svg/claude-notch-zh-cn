#if false // Legacy webpage/Chrome-cookie reader retained only for source history; no longer compiled.
import CommonCrypto
import Foundation
import LocalAuthentication
import Security
import SQLite3

/// Reads only the two WorkBuddy cookies needed by its official daily-usage page. Cookies and the
/// derived Chromium key stay in memory for this process and are never written to the app cache.
actor WorkBuddyWebSessionReader {
    private let cookiesURL: URL
    private let keychainService: String
    private var keyCache: Data?
    private var keyReadAttempted = false
    private var sessionCache: (cookies: [String: String], at: Date)?
    private var deniedThisLaunch = false
    private let sessionTTL: TimeInterval = 30 * 60

    init(
        cookiesURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Cookies"),
        keychainService: String = "Chrome Safe Storage"
    ) {
        self.cookiesURL = cookiesURL
        self.keychainService = keychainService
    }

    func cookies(force: Bool) async -> Result<[String: String], WorkBuddyUsageError> {
        if force {
            sessionCache = nil
            if deniedThisLaunch {
                keyReadAttempted = false
                keyCache = nil
                deniedThisLaunch = false
            }
        }
        if let sessionCache, Date().timeIntervalSince(sessionCache.at) < sessionTTL {
            return .success(sessionCache.cookies)
        }
        if deniedThisLaunch { return .failure(.webSessionAccessDenied) }

        let contextResult = await authenticationContextIfNeeded()
        let context: LAContext?
        switch contextResult {
        case .notNeeded: context = nil
        case let .authorized(value): context = value
        case .denied:
            deniedThisLaunch = true
            return .failure(.webSessionAccessDenied)
        }
        guard let cookies = readCookies(authenticationContext: context), cookies["session"]?.isEmpty == false else {
            return .failure(.webSessionMissing)
        }
        sessionCache = (cookies, Date())
        return .success(cookies)
    }

    func invalidate() {
        sessionCache = nil
    }

    private enum AuthenticationResult {
        case notNeeded
        case authorized(LAContext)
        case denied
    }

    private func authenticationContextIfNeeded() async -> AuthenticationResult {
        guard requiresInteractiveKeychainAccess() else { return .notNeeded }
        let context = LAContext()
        context.localizedFallbackTitle = "使用密码"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return .denied }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "使用 Touch ID 读取 WorkBuddy 网页用量"
            )
            return ok ? .authorized(context) : .denied
        } catch {
            return .denied
        }
    }

    private func requiresInteractiveKeychainAccess() -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecInteractionNotAllowed
    }

    private func readCookies(authenticationContext: LAContext?) -> [String: String]? {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("workbuddy-chrome-\(getpid()).sqlite")
        let suffixes = ["", "-wal", "-shm"]
        var copiedMain = false
        for suffix in suffixes {
            let source = URL(fileURLWithPath: cookiesURL.path + suffix)
            let target = URL(fileURLWithPath: base.path + suffix)
            try? fm.removeItem(at: target)
            if (try? fm.copyItem(at: source, to: target)) != nil {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                if suffix.isEmpty { copiedMain = true }
            }
        }
        guard copiedMain else { return nil }
        defer { for suffix in suffixes { try? fm.removeItem(at: URL(fileURLWithPath: base.path + suffix)) } }

        var openedDatabase: OpaquePointer?
        guard sqlite3_open(base.path, &openedDatabase) == SQLITE_OK, let db = openedDatabase else {
            if let openedDatabase { sqlite3_close(openedDatabase) }
            return nil
        }
        defer { sqlite3_close(db) }
        guard let key = safeStorageKey(authenticationContext: authenticationContext) else { return nil }
        var statement: OpaquePointer?
        let sql = "SELECT name, encrypted_value FROM cookies WHERE host_key IN ('www.workbuddy.cn', '.workbuddy.cn') AND name IN ('session', 'tgw_l7_route')"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var cookies: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let nameValue = sqlite3_column_text(statement, 0), let encrypted = sqlite3_column_blob(statement, 1) else { continue }
            let name = String(cString: nameValue)
            let value = Data(bytes: encrypted, count: Int(sqlite3_column_bytes(statement, 1)))
            if let decrypted = decrypt(value, key: key) { cookies[name] = decrypted }
        }
        return cookies.isEmpty ? nil : cookies
    }

    private func safeStorageKey(authenticationContext: LAContext?) -> Data? {
        if keyReadAttempted { return keyCache }
        keyReadAttempted = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let authenticationContext { query[kSecUseAuthenticationContext as String] = authenticationContext }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let password = item as? Data else {
            return nil
        }
        var key = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
                    salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    keyBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), 16)
            }
        }
        guard status == kCCSuccess else { return nil }
        keyCache = key
        return key
    }

    private func decrypt(_ encrypted: Data, key: Data) -> String? {
        guard encrypted.count > 3, encrypted.prefix(3) == Data("v10".utf8) else {
            return String(data: encrypted, encoding: .utf8)
        }
        let ciphertext = encrypted.dropFirst(3)
        let iv = Data(repeating: 0x20, count: 16)
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { cipherBytes in key.withUnsafeBytes { keyBytes in iv.withUnsafeBytes { ivBytes in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, 16, ivBytes.baseAddress,
                        cipherBytes.baseAddress, ciphertext.count,
                        outputBytes.baseAddress, outputBytes.count, &moved)
            }}}
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(moved..<output.count)
        if let value = String(data: output, encoding: .utf8) { return value }
        if output.count > 32 { return String(data: output.dropFirst(32), encoding: .utf8) }
        return nil
    }
}
#endif
