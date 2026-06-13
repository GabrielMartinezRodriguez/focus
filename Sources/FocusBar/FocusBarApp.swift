import SwiftUI

/// Al cerrar la app, si hay una sesión activa la terminamos para restaurar el sistema
/// (Dock, barra de menú, HazeOver, apps ocultas). Así cerrar FocusBar nunca deja el Mac
/// "sellado" sin forma de deshacerlo desde la UI.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        let stateFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".focus-session.json")
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return }
        let cli = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bin/focus").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["stop", "--quiet"]
        try? p.run()
        p.waitUntilExit()   // bloquear hasta restaurar el sistema antes de salir
    }
}

@main
struct FocusBarApp: App {
    @StateObject private var model = FocusModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
