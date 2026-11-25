import SwiftUI

func usageColor(_ left: Double) -> Color {
    left > 50 ? .green : left > 20 ? .orange : .red
}

/// Bar showing how much of a window is LEFT.
struct UsageBar: View {
    let window: UsageWindow
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(window.label).font(compact ? .caption : .callout).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(window.percentLeft))% left")
                        .font((compact ? Font.caption : .callout).monospacedDigit().weight(.semibold))
                        .foregroundStyle(usageColor(window.percentLeft))
                }
                bar(elapsed: window.elapsedFraction(now: ctx.date))
                HStack {
                    if let r = window.resetsAt {
                        Text("Resets in \(Fmt.countdown(to: r, now: ctx.date)) · \(Fmt.resetMoment(r))")
                    }
                    Spacer()
                    if !compact, let p = window.pace(now: ctx.date) { Text(p.text) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func bar(elapsed: Double?) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(usageColor(window.percentLeft).gradient)
                    .frame(width: g.size.width * window.percentLeft / 100)
                // Tick = where you'd be if you used the window evenly.
                if let e = elapsed, window.isWeekly {
                    Rectangle().fill(.primary.opacity(0.6))
                        .frame(width: 2)
                        .offset(x: g.size.width * (1 - e) - 1)
                }
            }
        }
        .frame(height: compact ? 6 : 9)
        .help(window.isWeekly ? "The tick marks even pace through the week" : "")
    }
}

struct ProviderBadge: View {
    let provider: Provider
    var body: some View {
        Image(systemName: provider.symbol)
            .foregroundStyle(provider == .claude ? Color.orange : Color.teal)
    }
}

/// "Use now" banner: best account overall, plus best per provider.
struct RecommendationView: View {
    @EnvironmentObject var store: AccountStore
    var compact = false

    var body: some View {
        if let best = store.bestPick() {
            VStack(alignment: .leading, spacing: 6) {
                Label("Use now", systemImage: "arrow.right.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                row(best, primary: true)
                if !compact {
                    ForEach(Provider.allCases) { p in
                        if let pick = store.bestPick(p), pick.id != best.id,
                           store.accounts.contains(where: { $0.provider == p }) {
                            row(pick, primary: false)
                        }
                    }
                }
            }
            .padding(compact ? 10 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(usageColor(best.available).opacity(0.12)))
        }
    }

    private func row(_ p: Pick, primary: Bool) -> some View {
        HStack(spacing: 8) {
            ProviderBadge(provider: p.account.provider)
            Text(primary ? p.account.name : "Best \(p.account.provider.displayName): \(p.account.name)")
                .font(primary ? .headline : .callout)
            Spacer()
            Text(p.reason).font(.caption).foregroundStyle(.secondary)
        }
    }
}
