import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AccountStore

    var body: some View {
        Form {
            Picker("Refresh every", selection: $store.refreshInterval) {
                Text("1 minute").tag(60.0)
                Text("2 minutes").tag(120.0)
                Text("5 minutes").tag(300.0)
                Text("15 minutes").tag(900.0)
            }
            Section("Accounts") {
                List {
                    ForEach(store.accounts) { a in
                        HStack { ProviderBadge(provider: a.provider); Text(a.name) }
                    }
                    .onMove { store.move(from: $0, to: $1) }
                }
                .frame(minHeight: 120)
                Text("Drag to reorder. Right-click a card in the overview to rename or remove it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 340)
    }
}
