import Foundation

enum HTTP {
    static func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = req
        req.timeoutInterval = 20
        let (d, r) = try await URLSession.shared.data(for: req)
        guard let h = r as? HTTPURLResponse else { throw UsageError.badResponse("no HTTP response") }
        if h.statusCode == 429 {
            let after = (h.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw UsageError.rateLimited(retryAfter: after)
        }
        return (d, h)
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
