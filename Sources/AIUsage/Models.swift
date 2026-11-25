import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude, chatgpt
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "ChatGPT (Codex)"
        }
    }
    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .chatgpt: "bubble.left.and.bubble.right.fill"
        }
    }
}

struct Account: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var provider: Provider
    /// ChatGPT only: the Codex CLI home folder holding auth.json (default ~/.codex).
    var codexHome: String?
}

/// One rate-limit window, e.g. "5-hour" or "Weekly".
struct UsageWindow: Identifiable, Hashable {
    var id: String
    var label: String
    var percentUsed: Double          // 0...100
    var resetsAt: Date?
    var length: TimeInterval?

    /// Once the reset time has passed the old reading is stale: the window has started over.
    var hasReset: Bool { resetsAt.map { $0 <= .now } ?? false }
    var percentLeft: Double { hasReset ? 100 : max(0, min(100, 100 - percentUsed)) }
    var isWeekly: Bool { (length ?? 0) >= 6 * 86400 }

    func elapsedFraction(now: Date = .now) -> Double? {
        guard let r = resetsAt, let l = length, l > 0 else { return nil }
        return min(1, max(0, 1 - r.timeIntervalSince(now) / l))
    }

    /// Compares usage with how much of the window has elapsed. Only for longer windows.
    func pace(now: Date = .now) -> Pace? {
        guard isWeekly, let e = elapsedFraction(now: now) else { return nil }
        let diff = percentUsed - e * 100
        if diff > 10 { return .ahead(diff) }
        if diff < -10 { return .spare(-diff) }
        return .onTrack
    }
}

enum Pace {
    case ahead(Double), onTrack, spare(Double)
    var text: String {
        switch self {
        case .ahead(let d): "\(Int(d))% ahead of pace — ease off"
        case .onTrack: "On pace"
        case .spare(let d): "\(Int(d))% to spare — use it"
        }
    }
}

struct UsageSnapshot {
    var plan: String?
    var windows: [UsageWindow]
    var fetchedAt: Date = .now

    /// The constraint that limits you right now: the lowest % left across windows.
    var available: Double { windows.map(\.percentLeft).min() ?? 0 }
    var bindingWindow: UsageWindow? { windows.min { $0.percentLeft < $1.percentLeft } }
    var weekly: UsageWindow? { windows.first { $0.id == "seven_day" || $0.id == "secondary" } ?? windows.first(where: \.isWeekly) }
}

enum AccountState {
    case loading
    case loaded(UsageSnapshot)
    case failed(String, needsSignIn: Bool, last: UsageSnapshot?)
    case rateLimited(until: Date, last: UsageSnapshot?)

    var snapshot: UsageSnapshot? {
        switch self {
        case .loaded(let s): s
        case .failed(_, _, let s): s
        case .rateLimited(_, let s): s
        case .loading: nil
        }
    }
}

enum UsageError: LocalizedError {
    case notSignedIn
    case unauthorized(String)
    case http(Int, String)
    case rateLimited(retryAfter: TimeInterval?)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in."
        case .unauthorized(let m): m
        case .http(let c, let body): "HTTP \(c): \(body.prefix(160))"
        case .rateLimited: "Rate-limited by the server."
        case .badResponse(let m): "Unexpected response: \(m)"
        }
    }
    var needsSignIn: Bool {
        switch self {
        case .notSignedIn, .unauthorized: true
        default: false
        }
    }
}

enum Fmt {
    static func countdown(to d: Date, now: Date = .now) -> String {
        let s = Int(d.timeIntervalSince(now))
        if s <= 0 { return "now" }
        let days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if days > 0 { return "\(days)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(m, 1))m"
    }

    static func resetMoment(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: d)
    }

    /// Parses ISO 8601 with or without (any number of) fractional digits.
    static func parseISO(_ s: String) -> Date? {
        let stripped = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: stripped)
    }
}
