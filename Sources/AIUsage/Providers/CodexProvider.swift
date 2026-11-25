import Foundation

/// Reads ChatGPT plan limits (Codex 5-hour / weekly) using the Codex CLI's login (auth.json).
/// The Codex CLI keeps that token fresh; this app only reads it.
enum CodexProvider {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static func fetch(codexHome: String?) async throws -> UsageSnapshot {
        let home = ((codexHome?.isEmpty == false ? codexHome! : "~/.codex") as NSString).expandingTildeInPath
        let authPath = home + "/auth.json"
        guard let d = FileManager.default.contents(atPath: authPath) else {
            throw UsageError.unauthorized("No Codex login found at \(authPath). Run `codex login` in Terminal.")
        }
        let auth = try HTTP.json(d)
        guard let tokens = auth["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String else {
            throw UsageError.unauthorized("Codex is logged in with an API key, not ChatGPT. Run `codex login` and choose ChatGPT.")
        }

        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let acct = tokens["account_id"] as? String {
            req.setValue(acct, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (body, r) = try await HTTP.send(req)
        if r.statusCode == 401 || r.statusCode == 403 {
            throw UsageError.unauthorized("ChatGPT session expired. Run `codex` once in Terminal to refresh it.")
        }
        guard r.statusCode == 200 else { throw UsageError.http(r.statusCode, String(decoding: body, as: UTF8.self)) }

        let j = try HTTP.json(body)
        let rl = (j["rate_limit"] as? [String: Any]) ?? [:]
        var windows: [UsageWindow] = []
        for (key, id) in [("primary_window", "primary"), ("secondary_window", "secondary")] {
            guard let w = rl[key] as? [String: Any], let used = w.double("used_percent") else { continue }
            let len = w.double("limit_window_seconds")
            var reset: Date?
            if let at = w.double("reset_at") { reset = Date(timeIntervalSince1970: at) }
            else if let after = w.double("reset_after_seconds") { reset = Date().addingTimeInterval(after) }
            windows.append(UsageWindow(id: id, label: label(len, fallback: id == "primary" ? "5-hour" : "Weekly"),
                                       percentUsed: used, resetsAt: reset, length: len))
        }
        if windows.isEmpty { throw UsageError.badResponse("no rate_limit windows in response") }
        let plan = (j["plan_type"] as? String)?.capitalized
        return UsageSnapshot(plan: plan, windows: windows)
    }

    private static func label(_ seconds: Double?, fallback: String) -> String {
        guard let s = seconds else { return fallback }
        if abs(s - 18000) < 60 { return "5-hour" }
        if abs(s - 604800) < 3600 { return "Weekly" }
        if s >= 86400 { return "\(Int(s / 86400))-day" }
        return "\(Int(s / 3600))-hour"
    }
}
