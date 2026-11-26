import Foundation

/// Reads Google Antigravity's per-model quota.
///
/// Live: Antigravity runs a local language server; its `GetUserStatus` call returns each model's
/// remaining fraction and reset time. It needs the CSRF token from the server's command line and
/// only answers on 127.0.0.1, so this works only while Antigravity is open.
/// Offline: Antigravity IDE caches the last status in its state.vscdb. Quota is only spent while
/// Antigravity runs, so that cache is still accurate until the reset time passes.
enum AntigravityProvider {
    static func fetch() async throws -> UsageSnapshot {
        if let live = try? await fetchLive() { return live }
        if let cached = cachedSnapshot() { return cached }
        throw UsageError.unauthorized("Antigravity isn't running. Open Antigravity (and sign in) to read its quota.")
    }

    // MARK: Live

    private struct Server { let pid: Int32; let csrf: String }

    private static func fetchLive() async throws -> UsageSnapshot {
        let servers = try await findServers()
        guard !servers.isEmpty else { throw UsageError.notSignedIn }
        for s in servers {
            for port in await listeningPorts(s.pid) {
                for scheme in ["https", "http"] {
                    if let snap = try? await getUserStatus(scheme: scheme, port: port, csrf: s.csrf) { return snap }
                }
            }
        }
        throw UsageError.badResponse("Antigravity's language server didn't answer")
    }

    private static func findServers() async throws -> [Server] {
        let out = try await run("/bin/ps", ["-axww", "-o", "pid=,args="])
        return out.split(separator: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.contains("language_server"), l.lowercased().contains("antigravity"),
                  let sp = l.firstIndex(of: " "), let pid = Int32(l[..<sp]) else { return nil }
            let args = l[sp...].split(separator: " ").map(String.init)
            guard let i = args.firstIndex(of: "--csrf_token"), i + 1 < args.count else { return nil }
            return Server(pid: pid, csrf: args[i + 1])
        }
    }

    private static func listeningPorts(_ pid: Int32) async -> [Int] {
        guard let out = try? await run("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN", "-Fn"]) else { return [] }
        // Lines look like "n127.0.0.1:50532".
        let ports = out.split(separator: "\n").compactMap { l -> Int? in
            guard l.hasPrefix("n"), let c = l.lastIndex(of: ":") else { return nil }
            return Int(l[l.index(after: c)...])
        }
        return Array(NSOrderedSet(array: ports)) as? [Int] ?? ports
    }

    private static func getUserStatus(scheme: String, port: Int, csrf: String) async throws -> UsageSnapshot {
        var req = URLRequest(url: URL(string: "\(scheme)://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetUserStatus")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 4
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue(csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        req.httpBody = Data(#"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}"#.utf8)
        let (d, r) = try await LocalhostSession.shared.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw UsageError.badResponse("status") }
        let us = (try HTTP.json(d))["userStatus"] as? [String: Any] ?? [:]
        let configs = ((us["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]]) ?? []
        let models: [(String, Double, Date?)] = configs.compactMap { c in
            guard let label = c["label"] as? String, let q = c["quotaInfo"] as? [String: Any] else { return nil }
            // proto3 JSON drops a zero value, so a missing remainingFraction means none left.
            let left = q.double("remainingFraction") ?? 0
            return (label, left, (q["resetTime"] as? String).flatMap(Fmt.parseISO))
        }
        guard !models.isEmpty else { throw UsageError.badResponse("no model quotas") }
        return snapshot(models, plan: plan(us))
    }

    private static func plan(_ us: [String: Any]) -> String? {
        if let tier = us["userTier"] as? [String: Any] {
            if (tier["id"] as? String) == "free-tier" { return "Free" }
            if let n = tier["name"] as? String { return n.replacingOccurrences(of: "Antigravity ", with: "") }
        }
        return ((us["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String
    }

    // MARK: Cache

    private static func cachedSnapshot() -> UsageSnapshot? {
        for app in ["Antigravity IDE", "Antigravity"] {
            guard let raw = LocalDB.string("antigravityUnifiedStateSync.userStatus", in: LocalDB.appSupport(app)),
                  let models = decodeCached(raw), !models.isEmpty else { continue }
            var s = snapshot(models, plan: nil)
            s.note = "Antigravity is closed — last known quota"
            return s
        }
        return nil
    }

    /// base64(proto{1: {1: "userStatusSentinelKey", 2: {1: base64(UserStatus)}}}).
    /// UserStatus.33 = model config data, whose repeated field 1 holds {1: label, 15: quota{1: float, 2: {1: seconds}}}.
    private static func decodeCached(_ b64: String) -> [(String, Double, Date?)]? {
        guard let outer = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let f1 = ProtoReader.fields(outer), let entry = ProtoReader.bytes(f1, 1).first,
              let f2 = ProtoReader.fields(entry), let wrap = ProtoReader.bytes(f2, 2).first,
              let f3 = ProtoReader.fields(wrap), let innerB64 = ProtoReader.bytes(f3, 1).first,
              let inner = Data(base64Encoded: String(decoding: innerB64, as: UTF8.self)),
              let status = ProtoReader.fields(inner), let data = ProtoReader.bytes(status, 33).first,
              let cfgs = ProtoReader.fields(data) else { return nil }
        return ProtoReader.bytes(cfgs, 1).compactMap { cfg in
            guard let c = ProtoReader.fields(cfg),
                  let label = ProtoReader.bytes(c, 1).first.map({ String(decoding: $0, as: UTF8.self) }),
                  let quota = ProtoReader.bytes(c, 15).first, let q = ProtoReader.fields(quota) else { return nil }
            var left = 0.0
            var reset: Date?
            for (n, v) in q {
                if n == 1, case .fixed32(let bits) = v { left = Double(Float(bitPattern: bits)) }
                if n == 2, case .bytes(let ts) = v, let t = ProtoReader.fields(ts),
                   case .varint(let secs)? = t.first(where: { $0.0 == 1 })?.1 {
                    reset = Date(timeIntervalSince1970: TimeInterval(secs))
                }
            }
            return (label, left, reset)
        }
    }

    // MARK: Shared

    /// Models that share a quota pool report the same numbers: show each pool once.
    private static func snapshot(_ models: [(String, Double, Date?)], plan: String?) -> UsageSnapshot {
        var groups: [(labels: [String], left: Double, reset: Date?)] = []
        for (label, left, reset) in models {
            if let i = groups.firstIndex(where: { abs($0.left - left) < 0.0001 && $0.reset == reset && sameFamily($0.labels[0], label) }) {
                groups[i].labels.append(label)
            } else {
                groups.append(([label], left, reset))
            }
        }
        let windows = groups.map { g -> UsageWindow in
            // Antigravity doesn't say how long a window is. Paid tiers refresh every 5 hours,
            // the free tier weekly: infer it from how far away the reset is.
            let untilReset = g.reset.map { $0.timeIntervalSinceNow } ?? 0
            let length: TimeInterval = untilReset > 5.5 * 3600 ? 7 * 86400 : 5 * 3600
            return UsageWindow(id: "ag-" + g.labels[0], label: groupLabel(g.labels),
                               percentUsed: (1 - g.left) * 100, resetsAt: g.reset, length: length)
        }
        return UsageSnapshot(plan: plan, windows: windows)
    }

    /// Antigravity pools quota: Gemini Pro, Gemini Flash, and the third-party models (Claude, GPT-OSS) together.
    private static func family(_ label: String) -> String {
        let words = label.split(separator: " ").map(String.init)
        guard words.first == "Gemini" else { return "third-party" }
        return words.contains("Flash") ? "Gemini Flash" : words.contains("Pro") ? "Gemini Pro" : "Gemini"
    }
    private static func sameFamily(_ a: String, _ b: String) -> Bool { family(a) == family(b) }

    private static func groupLabel(_ labels: [String]) -> String {
        guard labels.count > 1 else { return labels[0] }
        let f = family(labels[0])
        if f != "third-party" { return f }
        var names: [String] = []
        for l in labels { let w = String(l.split(separator: " ").first ?? ""); if !names.contains(w) { names.append(w) } }
        return names.joined(separator: " & ")
    }

    private static func run(_ path: String, _ args: [String]) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try p.run()
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: d, as: UTF8.self)
        }.value
    }
}

/// The language server uses a self-signed certificate. Trust it only for 127.0.0.1.
final class LocalhostSession: NSObject, URLSessionDelegate {
    static let shared: URLSession = URLSession(configuration: .ephemeral, delegate: LocalhostSession(), delegateQueue: nil)

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == "127.0.0.1", let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
