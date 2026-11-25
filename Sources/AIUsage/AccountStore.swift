import Foundation
import SwiftUI
import UserNotifications

struct Pick: Identifiable {
    var id: UUID { account.id }
    let account: Account
    let snapshot: UsageSnapshot
    var available: Double { snapshot.available }

    var reason: String {
        if available <= 0, let b = snapshot.bindingWindow, let r = b.resetsAt {
            return "All limited — back in \(Fmt.countdown(to: r))"
        }
        var parts = ["\(Int(available))% left"]
        if let w = snapshot.weekly, let r = w.resetsAt { parts.append("week resets in \(Fmt.countdown(to: r))") }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var states: [UUID: AccountState] = [:]
    @Published private(set) var lastRefresh: Date?
    @Published var refreshInterval: Double = UserDefaults.standard.object(forKey: "refreshInterval") as? Double ?? 300 {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval"); startTimer() }
    }

    private var timer: Timer?
    private var lastPercents: [String: Double] = [:]

    /// Claude's usage endpoint rate-limits aggressively: never ask more often than this per account.
    private static let claudeMinSpacing: TimeInterval = 180
    private var lastAttempt: [UUID: Date] = [:]
    /// After a 429, no requests for that account until this time.
    private(set) var backoffUntil: [UUID: Date] = [:]
    private var rateLimitStrikes: [UUID: Int] = [:]

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("accounts.json")
    }

    init() {
        load()
        startTimer()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task { await refreshAll() }
    }

    // MARK: Accounts

    func add(_ a: Account) {
        accounts.append(a)
        save()
        Task { await refresh(a) }
    }

    func remove(_ a: Account) {
        accounts.removeAll { $0.id == a.id }
        states[a.id] = nil
        if a.provider == .claude { Keychain.delete(ClaudeProvider.tokenKey(a.id)) }
        save()
    }

    func rename(_ a: Account, to name: String) {
        guard let i = accounts.firstIndex(where: { $0.id == a.id }), !name.isEmpty else { return }
        accounts[i].name = name
        save()
    }

    func move(from: IndexSet, to: Int) {
        accounts.move(fromOffsets: from, toOffset: to)
        save()
    }

    private func load() {
        guard let d = try? Data(contentsOf: fileURL),
              let a = try? JSONDecoder().decode([Account].self, from: d) else { return }
        accounts = a
    }

    private func save() {
        if let d = try? JSONEncoder().encode(accounts) { try? d.write(to: fileURL, options: .atomic) }
    }

    // MARK: Refresh

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(30, refreshInterval), repeats: true) { [weak self] _ in
            Task { await self?.refreshAll() }
        }
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { g in
            for a in accounts { g.addTask { await self.refresh(a) } }
        }
        lastRefresh = .now
    }

    func refresh(_ a: Account) async {
        let now = Date()
        if let until = backoffUntil[a.id], now < until { return }
        if a.provider == .claude, let last = lastAttempt[a.id],
           now.timeIntervalSince(last) < Self.claudeMinSpacing, states[a.id]?.snapshot != nil { return }
        lastAttempt[a.id] = now

        let previous = states[a.id]?.snapshot
        if previous == nil { states[a.id] = .loading }
        do {
            let s: UsageSnapshot
            switch a.provider {
            case .claude: s = try await ClaudeProvider.fetch(accountID: a.id)
            case .chatgpt: s = try await CodexProvider.fetch(codexHome: a.codexHome)
            }
            guard accounts.contains(where: { $0.id == a.id }) else { return }
            states[a.id] = .loaded(s)
            rateLimitStrikes[a.id] = nil
            backoffUntil[a.id] = nil
            checkAlerts(a, s)
        } catch UsageError.rateLimited(let retryAfter) {
            // Back off 2, 4, 8… minutes (max 30), or as long as the server asks.
            let strikes = (rateLimitStrikes[a.id] ?? 0) + 1
            rateLimitStrikes[a.id] = strikes
            let wait = max(retryAfter ?? 0, min(1800, 120 * pow(2, Double(strikes - 1))))
            let until = Date().addingTimeInterval(wait)
            backoffUntil[a.id] = until
            states[a.id] = .rateLimited(until: until, last: previous)
        } catch {
            let ue = error as? UsageError
            states[a.id] = .failed(error.localizedDescription, needsSignIn: ue?.needsSignIn ?? false, last: previous)
        }
    }

    // MARK: Derived

    func snapshot(_ a: Account) -> UsageSnapshot? { states[a.id]?.snapshot }

    /// Best account to use right now, optionally restricted to one provider.
    /// Most headroom wins; when two are close, prefer the one whose week resets sooner
    /// (its unused quota expires first).
    func bestPick(_ provider: Provider? = nil) -> Pick? {
        let picks = accounts
            .filter { provider == nil || $0.provider == provider }
            .compactMap { a in snapshot(a).map { Pick(account: a, snapshot: $0) } }
        return picks.max { l, r in
            if abs(l.available - r.available) > 5 { return l.available < r.available }
            let lr = l.snapshot.weekly?.resetsAt ?? .distantFuture
            let rr = r.snapshot.weekly?.resetsAt ?? .distantFuture
            return lr > rr
        }
    }

    var menuBarTitle: String {
        let values = accounts.compactMap { snapshot($0).map { "\(Int($0.available))%" } }
        return values.isEmpty ? "AI" : values.joined(separator: " · ")
    }

    // MARK: Notifications

    private func checkAlerts(_ a: Account, _ s: UsageSnapshot) {
        for w in s.windows {
            let key = "\(a.id)-\(w.id)"
            defer { lastPercents[key] = w.percentUsed }
            guard let old = lastPercents[key] else { continue }
            for t in [80.0, 95.0] where old < t && w.percentUsed >= t {
                notify("\(a.name): \(Int(w.percentUsed))% of \(w.label) used",
                       w.resetsAt.map { "Resets in \(Fmt.countdown(to: $0))" } ?? "")
            }
            if old >= 80 && w.percentUsed < 20 {
                notify("\(a.name): \(w.label) limit reset", "You have \(Int(w.percentLeft))% available again.")
            }
        }
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
