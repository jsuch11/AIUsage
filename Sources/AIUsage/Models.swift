import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude, chatgpt, antigravity, cursor
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "ChatGPT (Codex)"
        case .antigravity: "Antigravity"
        case .cursor: "Cursor"
        }
    }
    /// Short name for messages like "Rate-limited by …".
    var serviceName: String {
        switch self {
        case .chatgpt: "ChatGPT"
        default: displayName
        }
    }
    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .chatgpt: "bubble.left.and.bubble.right.fill"
        case .antigravity: "atom"
        case .cursor: "cursorarrow.rays"
        }
    }
    /// Antigravity and Cursor read the app's own local sign-in: one account each.
    var singleAccount: Bool { self == .antigravity || self == .cursor }
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
    /// Shown under the bars, e.g. when the numbers come from a cache.
    var note: String?

    /// The constraint that limits you right now: the lowest % left across windows.
    var available: Double { windows.map(\.percentLeft).min() ?? 0 }
    var bindingWindow: UsageWindow? { windows.min { $0.percentLeft < $1.percentLeft } }
    var weekly: UsageWindow? { windows.first { $0.id == "seven_day" || $0.id == "secondary" } ?? windows.first(where: \.isWeekly) }
    /// The short rolling window ("5-hour") that sits inside the weekly one, if the plan has both.
    var session: UsageWindow? { windows.first { $0.id == "five_hour" || $0.id == "primary" } }
}

/// How much of the weekly limit one full 5-hour session uses.
/// Neither service publishes it, so it is learned: each refresh, the rise in weekly % is compared
/// with the rise in session % over the same stretch. Both readings are whole percents,
/// so the estimate needs some usage before it is shown.
struct SessionShare: Codable {
    var sessionGain = 0.0      // total session % gained across the samples counted
    var weeklyGain = 0.0       // weekly % gained over the same stretches
    var last: Sample?

    struct Sample: Codable {
        var session: Double, weekly: Double
        var sessionReset: Date?, weeklyReset: Date?
    }

    static let minimumGain = 20.0

    /// % of the week one full session uses, once there's enough data.
    var percentOfWeek: Double? {
        guard sessionGain >= Self.minimumGain, weeklyGain > 0 else { return nil }
        return weeklyGain / sessionGain * 100
    }
    /// Progress towards a first estimate, 0...1.
    var learning: Double { min(1, sessionGain / Self.minimumGain) }

    mutating func record(session s: UsageWindow, weekly w: UsageWindow) {
        let now = Sample(session: s.percentUsed, weekly: w.percentUsed, sessionReset: s.resetsAt, weeklyReset: w.resetsAt)
        defer { last = now }
        guard let prev = last, !s.hasReset, !w.hasReset,
              Self.same(prev.weeklyReset, now.weeklyReset, tolerance: 3600) else { return }
        // Only compare readings from the same session: across a session reset, the old
        // session's last stretch is unknown.
        guard Self.same(prev.sessionReset, now.sessionReset, tolerance: 120) else { return }
        let ds = now.session - prev.session
        let dw = now.weekly - prev.weekly
        guard ds > 0, dw >= 0, dw <= ds else { return }   // ignore odd jumps
        sessionGain += ds
        weeklyGain += dw
        // Favour recent behaviour (plans and limits change): keep roughly the last few sessions' worth.
        if sessionGain > 300 { sessionGain /= 2; weeklyGain /= 2 }
    }

    private static func same(_ a: Date?, _ b: Date?, tolerance: TimeInterval) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.timeIntervalSince(b)) <= tolerance
    }
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
