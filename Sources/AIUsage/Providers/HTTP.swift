import Foundation

enum HTTP {
    /// Slow or flaky networks (phone hotspots, broken IPv6, VPNs) can take 5–10 s just to connect,
    /// so allow more time than URLSession's usual, and wait for a connection instead of failing at once.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        c.waitsForConnectivity = true
        c.httpCookieStorage = nil        // cookies are set per request
        c.httpShouldSetCookies = false
        return URLSession(configuration: c)
    }()

    static func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = req
        req.timeoutInterval = 30
        let (d, r): (Data, URLResponse)
        do {
            (d, r) = try await session.data(for: req)
        } catch let e as URLError where isTransient(e) {
            // One quick retry: a dropped or slow connection often works the second time.
            try await Task.sleep(for: .seconds(2))
            do { (d, r) = try await session.data(for: req) }
            catch let e as URLError { throw UsageError.network(e, host: req.url?.host) }
        } catch let e as URLError {
            throw UsageError.network(e, host: req.url?.host)
        }
        guard let h = r as? HTTPURLResponse else { throw UsageError.badResponse("no HTTP response") }
        if h.statusCode == 429 {
            let after = (h.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw UsageError.rateLimited(retryAfter: after)
        }
        return (d, h)
    }

    static func isTransient(_ e: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
         .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed].contains(e.code)
    }

    static func postJSON(_ url: URL, _ body: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    static func json(_ d: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw UsageError.badResponse(String(decoding: d.prefix(160), as: UTF8.self))
        }
        return obj
    }
}

extension Dictionary where Key == String, Value == Any {
    func double(_ k: String) -> Double? {
        if let n = self[k] as? NSNumber { return n.doubleValue }
        if let s = self[k] as? String { return Double(s) }
        return nil
    }
}
