import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Keep running in the menu bar after the overview window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AccountStore()

    var body: some Scene {
        Window("AI Usage", id: "overview") {
            OverviewView()
                .environmentObject(store)
        }
        .defaultSize(width: 780, height: 520)

        MenuBarExtra {
            MenuView()
                .environmentObject(store)
        } label: {
            Label(store.menuBarTitle, systemImage: "gauge.with.dots.needle.50percent")
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
