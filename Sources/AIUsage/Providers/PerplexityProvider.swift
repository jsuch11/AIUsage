import Foundation

/// Reads Perplexity's remaining Pro Search, Research and Labs queries.
///
/// perplexity.ai/rest/rate-limit/all is what the website uses; it's undocumented. It needs the
/// web session cookie (`__Secure-next-auth.session-token`), which the user copies from a browser
/// signed in to perplexity.ai. It only returns how many queries are LEFT, never the total or when
/// they refill, so the total is the highest count seen so far.
enum PerplexityProvider {
    static let cookieName = "__Secure-next-auth.session-token"
    static let limitsURL = URL(string: "https://www.perplexity.ai/rest/rate-limit/all")!
    static let sessionURL = URL(string: "https://www.perplexity.ai/api/auth/session")!

    static func tokenKey(_ id: UUID) -> String { "perplexity.\(id.uuidString)" }
    static func saveToken(_ t: String, for id: UUID) { Keychain.set(Data(t.utf8), for: tokenKey(id)) }

    /// Accepts the cookie value on its own, or a whole pasted Cookie header.
    static func cleanToken(_ pasted: String) -> String {
        var t = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: cookieName + "=") {
            t = String(t[r.upperBound...])
            if let end = t.firstIndex(of: ";") { t = String(t[..<end]) }
        }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
    }

    static func fetch(accountID id: UUID) async throws -> UsageSnapshot {
        guard let d = Keychain.get(tokenKey(id)), let token = String(data: d, encoding: .utf8), !token.isEmpty else {
            throw UsageError.notSignedIn
        }
        return try await fetch(token: token, accountID: id)
    }

    /// Also used to check a pasted cookie before the account is added.
    static func fetch(token: String, accountID id: UUID) async throws -> UsageSnapshot {
        // The limits endpoint answers signed-out visitors too (all zeros), so check the session first.
        let (sd, sr) = try await HTTP.send(request(sessionURL, token))
        guard sr.statusCode == 200, let user = (try? HTTP.json(sd))?["user"] as? [String: Any], !user.isEmpty else {
            if sr.statusCode == 403, String(decoding: sd.prefix(400), as: UTF8.self).contains("<html") {
                throw UsageError.badResponse("Perplexity's bot protection blocked the request. Try again later.")
            }
            throw UsageError.unauthorized("Perplexity sign-in expired. Copy a fresh session cookie.")
        }

        let (d, r) = try await HTTP.send(request(limitsURL, token))
        guard r.statusCode == 200 else { throw UsageError.http(r.statusCode, String(decoding: d.prefix(200), as: UTF8.self)) }
        let j = try HTTP.json(d)

        let kinds: [(key: String, label: String)] = [
            ("remaining_pro", "Pro Search"),
            ("remaining_research", "Research"),
            ("remaining_labs", "Labs"),
            ("remaining_agentic_research", "Deep Research"),
        ]
        var windows: [UsageWindow] = []
        for k in kinds {
            guard let left = j.double(k.key) else { continue }
            let total = highest(left, key: "\(id.uuidString).\(k.key)")
            guard total > 0 else { continue }       // not on this plan
            windows.append(UsageWindow(id: "pplx_" + k.key, label: k.label,
                                       percentUsed: (1 - left / total) * 100,
                                       detail: "\(Int(left)) left"))
        }
        if windows.isEmpty {
            // Free plan, or everything used up since the app first looked.
            windows.append(UsageWindow(id: "pplx_remaining_pro", label: "Pro Search", percentUsed: 100, detail: "0 left"))
        }
        return UsageSnapshot(plan: nil, windows: windows,
                             note: "Perplexity doesn't say when queries refill. Totals are the most seen so far.")
    }

    private static func request(_ url: URL, _ token: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("\(cookieName)=\(token)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://www.perplexity.ai/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        return req
    }

    /// Remembers the largest "remaining" count seen for each kind: the best guess at the total.
    private static func highest(_ value: Double, key: String) -> Double {
        let k = "perplexityMax." + key
        let best = max(value, UserDefaults.standard.double(forKey: k))
        UserDefaults.standard.set(best, forKey: k)
        return best
    }

    static func forget(_ id: UUID) {
        Keychain.delete(tokenKey(id))
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix("perplexityMax.\(id.uuidString)") {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }
}
