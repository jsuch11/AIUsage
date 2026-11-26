import SwiftUI

struct AccountCard: View {
    @EnvironmentObject var store: AccountStore
    let account: Account
    var compact = false
    var onSignIn: (Account) -> Void = { _ in }

    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            header
            content
        }
        .padding(compact ? 0 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !compact { RoundedRectangle(cornerRadius: 12).fill(.background.secondary) }
        }
        .contextMenu {
            Button("Refresh") { Task { await store.refresh(account) } }
            Button("Rename…") { newName = account.name; renaming = true }
            if account.provider == .claude { Button("Sign in again…") { onSignIn(account) } }
            Divider()
            Button("Remove", role: .destructive) { store.remove(account) }
        }
        .alert("Rename account", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { store.rename(account, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ProviderBadge(provider: account.provider)
            Text(account.name).font(compact ? .callout.weight(.semibold) : .headline)
            if let plan = store.snapshot(account)?.plan {
                Text(plan).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
            Spacer()
            if case .loading = store.states[account.id] { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private var content: some View {
        switch store.states[account.id] {
        case .loaded(let s):
            windows(s)
        case .failed(let msg, let needsSignIn, let last):
            if let last { windows(last).opacity(0.5) }
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                if needsSignIn && account.provider == .claude {
                    Button("Sign in") { onSignIn(account) }.controlSize(.small)
                }
            }
        case .rateLimited(let until, let last):
            if let last { windows(last).opacity(0.7) }
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    Text("Rate-limited by \(account.provider.serviceName) — retrying in \(Fmt.countdown(to: until, now: ctx.date))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .loading, .none:
            Text("Loading…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func windows(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 9) {
            // The menu shows only the main 5-hour + weekly windows.
            ForEach(compact ? Array(s.windows.prefix(2)) : s.windows) { w in
                UsageBar(window: w, compact: compact)
            }
            if s.session != nil, s.weekly != nil {
                SessionShareLine(snapshot: s, share: store.sessionShares[account.id], compact: compact)
            }
            if let note = s.note {
                Label(note, systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
