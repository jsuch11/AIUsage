import SwiftUI
import AppKit

struct AddAccountView: View {
    @EnvironmentObject var store: AccountStore
    @Environment(\.dismiss) private var dismiss

    /// When set, signs an existing Claude account in again instead of adding one.
    var reauth: Account? = nil

    @State private var provider: Provider = .claude
    @State private var name = ""
    @State private var pkce = ClaudeAuth.makePKCE()
    @State private var code = ""
    @State private var codexHome = "~/.codex"
    @State private var busy = false
    @State private var error: String?

    private var isClaude: Bool { (reauth?.provider ?? provider) == .claude }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(reauth.map { "Sign in to \($0.name)" } ?? "Add account").font(.title2.weight(.semibold))

            if reauth == nil {
                Picker("Service", selection: $provider) {
                    ForEach(Provider.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Name (e.g. Claude Personal, Claude Team)", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            if isClaude { claudeSteps } else { codexSteps }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(reauth == nil ? "Add" : "Sign in") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (isClaude && code.isEmpty) || (reauth == nil && name.isEmpty))
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private var claudeSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1. Open the sign-in page in a browser logged in to **the claude.ai account you want to add**. For your second account, use a private window and paste the link there.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open sign-in page") { NSWorkspace.shared.open(ClaudeAuth.authorizationURL(pkce)) }
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ClaudeAuth.authorizationURL(pkce).absoluteString, forType: .string)
                }
            }
            Text("2. Approve, then paste the code it shows:").font(.callout)
            TextField("Paste code here", text: $code).textFieldStyle(.roundedBorder)
        }
    }

    private var codexSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Uses the ChatGPT login of the Codex CLI. If you haven't yet, run this in Terminal and sign in with your ChatGPT account:")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("codex login").font(.body.monospaced()).textSelection(.enabled)
                .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            TextField("Codex folder", text: $codexHome).textFieldStyle(.roundedBorder)
            Text("Shows your Codex 5-hour and weekly limits. ChatGPT doesn't expose the chat message caps.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func submit() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            if isClaude {
                let tokens = try await ClaudeAuth.exchange(pasted: code, pkce: pkce)
                if let a = reauth {
                    ClaudeProvider.saveTokens(tokens, for: a.id)
                    await store.refresh(a)
                } else {
                    let a = Account(name: name, provider: .claude)
                    ClaudeProvider.saveTokens(tokens, for: a.id)
                    store.add(a)
                }
            } else {
                _ = try await CodexProvider.fetch(codexHome: codexHome)   // validate before adding
                store.add(Account(name: name, provider: .chatgpt, codexHome: codexHome))
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
            if isClaude { pkce = ClaudeAuth.makePKCE(); code = "" }   // codes are single-use
        }
    }
}
