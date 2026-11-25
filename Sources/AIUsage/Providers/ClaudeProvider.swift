import Foundation
import CryptoKit
import Security

struct ClaudeTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

/// Signs in to a Claude account with the same OAuth flow Claude Code uses
/// (open a page, approve, paste the code back), so each account gets its own tokens.
enum ClaudeAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scopes = "org:create_api_key user:profile user:inference"

    struct PKCE { let verifier: String; let challenge: String; let state: String }

    static func makePKCE() -> PKCE {
        let verifier = base64url(random(32))
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        return PKCE(verifier: verifier, challenge: challenge, state: base64url(random(32)))
    }

    static func authorizationURL(_ p: PKCE) -> URL {
        var c = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: p.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: p.state),
        ]
        return c.url!
    }

    /// `pasted` is what the callback page shows, usually "code#state".
    static func exchange(pasted: String, pkce: PKCE) async throws -> ClaudeTokens {
        let parts = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "#", maxSplits: 1).map(String.init)
        guard let code = parts.first, !code.isEmpty else { throw UsageError.badResponse("empty code") }
        let (d, r) = try await HTTP.postJSON(tokenURL, [
            "grant_type": "authorization_code",
            "code": code,
            "state": parts.count > 1 ? parts[1] : pkce.state,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": pkce.verifier,
        ])
        guard r.statusCode == 200 else {
            throw UsageError.http(r.statusCode, String(decoding: d, as: UTF8.self))
        }
        return try parseTokens(d, previousRefresh: nil)
    }

    static func refresh(_ t: ClaudeTokens) async throws -> ClaudeTokens {
        let (d, r) = try await HTTP.postJSON(tokenURL, [
            "grant_type": "refresh_token",
            "refresh_token": t.refreshToken,
            "client_id": clientID,
        ])
        if r.statusCode == 400 || r.statusCode == 401 {
            throw UsageError.unauthorized("Session expired — sign in again.")
        }
        guard r.statusCode == 200 else {
            throw UsageError.http(r.statusCode, String(decoding: d, as: UTF8.self))
        }
        return try parseTokens(d, previousRefresh: t.refreshToken)
    }

    private static func parseTokens(_ d: Data, previousRefresh: String?) throws -> ClaudeTokens {
        let j = try HTTP.json(d)
        guard let access = j["access_token"] as? String else { throw UsageError.badResponse("no access_token") }
        let refresh = (j["refresh_token"] as? String) ?? previousRefresh ?? ""
        let expiresIn = j.double("expires_in") ?? 3600
        return ClaudeTokens(accessToken: access, refreshToken: refresh,
                            expiresAt: Date().addingTimeInterval(expiresIn))
    }

    private static func random(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b)
    }

    private static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum ClaudeProvider {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func tokenKey(_ id: UUID) -> String { "claude.\(id.uuidString)" }
    static func saveTokens(_ t: ClaudeTokens, for id: UUID) { Keychain.setCodable(t, for: tokenKey(id)) }

    static func fetch(accountID id: UUID) async throws -> UsageSnapshot {
        guard var t = Keychain.getCodable(ClaudeTokens.self, for: tokenKey(id)) else {
            throw UsageError.notSignedIn
        }
        if t.expiresAt < Date().addingTimeInterval(120) {
            t = try await ClaudeAuth.refresh(t)
            saveTokens(t, for: id)
        }
        do {
            return try await usage(token: t.accessToken)
        } catch UsageError.unauthorized(_) {
            t = try await ClaudeAuth.refresh(t)
            saveTokens(t, for: id)
            return try await usage(token: t.accessToken)
        }
    }

    private static func usage(token: String) async throws -> UsageSnapshot {
        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (d, r) = try await HTTP.send(req)
        if r.statusCode == 401 || r.statusCode == 403 { throw UsageError.unauthorized("Session expired — sign in again.") }
        guard r.statusCode == 200 else { throw UsageError.http(r.statusCode, String(decoding: d, as: UTF8.self)) }

        let j = try HTTP.json(d)
        var windows: [UsageWindow] = []
        for (key, value) in j {
            // extra_usage is the paid overage budget, not a plan limit: counting it would skew "% left".
            guard key != "extra_usage",
                  let w = value as? [String: Any], let util = w.double("utilization") else { continue }
            windows.append(UsageWindow(
                id: key,
                label: label(for: key),
                percentUsed: util,
                resetsAt: (w["resets_at"] as? String).flatMap(Fmt.parseISO),
                length: key.hasPrefix("five_hour") ? 5 * 3600 : key.hasPrefix("seven_day") ? 7 * 86400 : nil
            ))
        }
        let order = ["five_hour", "seven_day"]
        windows.sort {
            (order.firstIndex(of: $0.id) ?? 99, $0.id) < (order.firstIndex(of: $1.id) ?? 99, $1.id)
        }
        if windows.isEmpty { throw UsageError.badResponse("no usage windows in response") }
        return UsageSnapshot(plan: nil, windows: windows)
    }

    private static func label(for key: String) -> String {
        switch key {
        case "five_hour": "5-hour"
        case "seven_day": "Weekly"
        case "seven_day_opus": "Weekly · Opus"
        case "seven_day_sonnet": "Weekly · Sonnet"
        case "seven_day_omelette": "Weekly · Design"
        default:
            key.replacingOccurrences(of: "seven_day_", with: "Weekly · ")
                .replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
