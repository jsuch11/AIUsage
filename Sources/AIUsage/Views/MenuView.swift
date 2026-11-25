import SwiftUI

struct MenuView: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecommendationView(compact: true)

            if store.accounts.isEmpty {
                Text("No accounts yet — open the overview to add one.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(store.accounts) { a in
                AccountCard(account: a, compact: true) { _ in openOverview() }
                if a.id != store.accounts.last?.id { Divider() }
            }

            Divider()
            HStack {
                Button("Open Overview") { openOverview() }
                Spacer()
                Button { Task { await store.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
    }

    private func openOverview() {
        openWindow(id: "overview")
        NSApp.activate()
    }
}
