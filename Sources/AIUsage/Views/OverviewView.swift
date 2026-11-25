import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var store: AccountStore
    @State private var sheet: SheetMode?

    enum SheetMode: Identifiable {
        case add, signIn(Account)
        var id: String {
            switch self { case .add: "add"; case .signIn(let a): a.id.uuidString }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !store.accounts.isEmpty { BrandHeader() }
                if store.accounts.isEmpty {
                    emptyState
                } else {
                    RecommendationView()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                        ForEach(store.accounts) { a in
                            AccountCard(account: a) { sheet = .signIn($0) }
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 380, minHeight: 300)
        .toolbar {
            ToolbarItem {
                if let t = store.lastRefresh {
                    Text("Updated \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ToolbarItem {
                Button { Task { await store.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .help("Refresh (⌘R)")
            }
            ToolbarItem {
                Button { sheet = .add } label: { Image(systemName: "plus") }
                    .keyboardShortcut("n")
                    .help("Add account (⌘N)")
            }
        }
        .sheet(item: $sheet) { mode in
            switch mode {
            case .add: AddAccountView()
            case .signIn(let a): AddAccountView(reauth: a)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            LogoMark(size: 72)
            Text("No accounts yet").font(.title2.weight(.semibold))
            Text("Add your Claude and ChatGPT accounts to see all your limits in one place.")
                .foregroundStyle(.secondary)
            Button("Add account") { sheet = .add }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
