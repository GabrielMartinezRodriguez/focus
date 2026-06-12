import SwiftUI

@main
struct FocusBarApp: App {
    @StateObject private var model = FocusModel()

    init() {
        // App de barra de menú: sin icono en el Dock
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            if model.session != nil {
                Text("🧘 \(model.remainingLabel)")
            } else {
                Image(systemName: "scope")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
