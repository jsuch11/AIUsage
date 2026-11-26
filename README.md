# AI Usage

A small macOS menu-bar app plus an overview window showing how much of each AI plan
limit is left, when it resets, and which account to use right now.

- **Claude** (Pro / Max / Team): 5-hour and weekly limits (plus per-model weekly limits when your plan has them).
  Each account signs in separately, inside the app.
- **ChatGPT** (Plus / Pro): Codex 5-hour and weekly limits, read from the Codex CLI login (`codex login`).
  ChatGPT doesn't expose its chat message caps anywhere, so those aren't shown.
- **Antigravity**: per-model quota (models that share a pool are shown once), read from the Antigravity app's
  local language server while it runs. When it's closed, the last quota Antigravity IDE saved is shown.
- **Cursor**: this billing month's included usage, using the Cursor app's sign-in on this Mac.

All of these use undocumented endpoints (the ones Claude Code, the Codex CLI, Antigravity and cursor.com use).
They may change without notice.

## Build

Requires macOS 14+ and Xcode (or the Command Line Tools).

    ./scripts/build-app.sh --install

This builds `build/AI Usage.app`, copies it to /Applications and launches it.

Run `./scripts/setup-signing.sh` once first. It creates a local self-signed code-signing certificate,
so every build has the same signature and keeps its Keychain access (otherwise macOS asks again after each build).

The app icon is drawn by `LogoMark` in `Sources/AIUsage/Views/Logo.swift`. After changing it, run
`./scripts/make-icon.sh` to regenerate `Resources/AppIcon.icns`.

## Use

- Menu-bar icon: % left for each account. Click it for the compact view.
- Overview window (⌘-Tab to it): one card per account. ⌘N adds an account, ⌘R refreshes.
- "Use now" picks the account with the most room. When two are close, it picks the one whose
  week resets sooner, because its unused quota expires first.
- "A full 5-hour session ≈ X% of your week": learned from how your weekly % rises as you use a session
  (Claude and ChatGPT). It appears after you've used about 20% of a session with the app running,
  and also says how much the rest of the current session would cost and how many full sessions the week has left.
- Weekly bars have a tick for even pace. Left of the tick means you're using it faster than the week allows.
- Notifications fire at 80% and 95% used, and when a nearly used-up limit resets.

Tokens are stored in your login Keychain. The account list is in `~/Library/Application Support/AIUsage/`.
