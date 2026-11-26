import Foundation

/// Reads Cursor's monthly plan usage with the Cursor app's own sign-in (from its state.vscdb).
/// cursor.com/api/usage-summary is what the dashboard calls; it wants the session cookie,
/// which is "<user id>::<access token>". Undocumented, so parsing is defensive.
enum CursorProvider {
    static let summaryURL = URL(string: "https://cursor.com/api/usage-summary")!

    static func fetch() async throws -> UsageSnapshot {
        let db = LocalDB.appSupport("Cursor")
        guard let token = LocalDB.string("cursorAuth/accessToken", in: db)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n")), !token.isEmpty else {
            throw UsageError.unauthorized("Not signed in to Cursor. Open the Cursor app and sign in.")
        }
        guard let user = userID(fromJWT: token) else {
            throw UsageError.unauthorized("Couldn't read Cursor's sign-in. Sign in to Cursor again.")
        }

        var req = URLRequest(url: summaryURL)
        req.setValue("WorkosCursorSessionToken=\(user)%3A%3A\(token)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (body, r) = try await HTTP.send(req)
        if r.statusCode == 401 || r.statusCode == 403 {
            throw UsageError.unauthorized("Cursor session expired. Open Cursor once to refresh it.")
        }
        guard r.statusCode == 200 else { throw UsageError.http(r.statusCode, String(decoding: body, as: UTF8.self)) }

        let j = try HTTP.json(body)
        let start = (j["billingCycleStart"] as? String).flatMap(Fmt.parseISO)
        let end = (j["billingCycleEnd"] as? String).flatMap(Fmt.parseISO)
        let length = zip2(start, end).map { $1.timeIntervalSince($0) }
        let usage = (j["individualUsage"] as? [String: Any]) ?? (j["teamUsage"] as? [String: Any]) ?? [:]
        let plan = (usage["plan"] as? [String: Any]) ?? [:]

        var windows: [UsageWindow] = []
        let total: Double? = {
            if let used = plan.double("used"), let limit = plan.double("limit"), limit > 0 { return used / limit * 100 }
            return plan.double("totalPercentUsed")
        }()
        if (j["isUnlimited"] as? Bool) != true, let total {
            windows.append(UsageWindow(id: "cursor_plan", label: "Monthly", percentUsed: total, resetsAt: end, length: length))
        }
        for (key, label) in [("autoPercentUsed", "Auto"), ("apiPercentUsed", "Named models")] {
            if let p = plan.double(key) {
                windows.append(UsageWindow(id: "cursor_" + key, label: label, percentUsed: p, resetsAt: end, length: length))
            }
        }
        if windows.isEmpty { throw UsageError.badResponse("no plan usage in response") }
        let membership = (j["membershipType"] as? String)
            ?? LocalDB.string("cursorAuth/stripeMembershipType", in: db)
        return UsageSnapshot(plan: membership?.capitalized, windows: windows)
    }

    /// The JWT's `sub` is like "auth0|user_01ABC…"; the cookie wants the part after "|".
    private static func userID(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b), let j = try? HTTP.json(d), let sub = j["sub"] as? String else { return nil }
        return sub.split(separator: "|").last.map(String.init)
    }

    private static func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
        guard let a, let b else { return nil }
        return (a, b)
    }
}
