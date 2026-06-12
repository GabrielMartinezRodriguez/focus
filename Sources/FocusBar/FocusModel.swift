import Foundation
import Combine

/// Espejo del estado que escribe el CLI en ~/.focus-session.json
struct Session: Codable {
    var task: String
    var startedAt: Date
    var minutes: Int?
    var closedApps: [String]
    var timerPid: Int32?
    var dockWasHidden: Bool
    var menuBarWasHidden: Bool
}

@MainActor
final class FocusModel: ObservableObject {
    @Published var session: Session?
    @Published var busy = false

    private let stateFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".focus-session.json")
    private let cli = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("bin/focus").path
    private var timer: AnyCancellable?

    init() {
        reload()
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.reload() }
    }

    func reload() {
        guard let data = try? Data(contentsOf: stateFile),
              let s = try? JSONDecoder().decode(Session.self, from: data) else {
            session = nil
            return
        }
        session = s
    }

    var remainingLabel: String {
        guard let s = session else { return "" }
        let elapsed = Date().timeIntervalSince(s.startedAt)
        guard let total = s.minutes else {
            return "\(Int(elapsed / 60))m"
        }
        let remaining = max(0, Double(total * 60) - elapsed)
        let m = Int(remaining) / 60, sec = Int(remaining) % 60
        return String(format: "%d:%02d", m, sec)
    }

    func start(minutes: Int?, task: String) {
        var args = ["start"]
        if let minutes { args.append(String(minutes)) }
        if !task.isEmpty { args.append(task) }
        run(args)
    }

    func stop() { run(["stop"]) }

    private func run(_ args: [String]) {
        busy = true
        let cli = self.cli
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = args
            try? p.run()
            p.waitUntilExit()
            await MainActor.run {
                self.busy = false
                self.reload()
            }
        }
    }
}
