import Foundation

/// Background checks tolerate one transient failure. Launch preflight uses its separate,
/// strict five-second probe and deliberately does not call this retry policy.
enum GuardRuntimeNetworkLookup {
    static let timeout: TimeInterval = 12

    static func observation(session: URLSession) async throws -> GuardNetworkObservation {
        try await observation(load: {
            let (data, response) = try await session.data(from: URL(string: "https://api.country.is/?fields=city,subdivision,location")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 65_536 else { throw URLError(.badServerResponse) }
            let result = try JSONDecoder().decode(GuardCountryResponse.self, from: data)
            guard Locale.Region.isoRegions.contains(where: { $0.identifier == result.country }),
                  let raw = result.ip, let ip = GuardExit.normalizedIP(raw) else { throw URLError(.cannotParseResponse) }
            let zone = result.location?.time_zone.flatMap { TimeZone(identifier: $0) == nil ? nil : $0 }
            return .init(countryCode: result.country, fetchedAt: .now, city: result.city,
                         subdivision: result.subdivision, ip: ip, timeZone: zone)
        })
    }

    static func observation(load: @Sendable () async throws -> GuardNetworkObservation,
                            wait: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(5)) }) async throws -> GuardNetworkObservation {
        do { return try await load() }
        catch {
            try Task.checkCancellation()
            if (error as? URLError)?.code == .cancelled { throw error }
            try await wait()
            try Task.checkCancellation()
            return try await load()
        }
    }
}
