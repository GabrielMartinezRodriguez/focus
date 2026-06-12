import SwiftUI

struct ContentView: View {
    @ObservedObject var model: FocusModel
    @State private var task = ""
    @State private var minutes = 50

    private let presets = [25, 50, 90]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let session = model.session {
                activeView(session)
            } else {
                idleView
            }
            Divider()
            HStack {
                Spacer()
                Button("Salir de FocusBar") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 280)
        .padding(16)
        .fixedSize()
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nueva sesión de foco")
                .font(.headline)

            TextField("¿En qué vas a trabajar?", text: $task)
                .textFieldStyle(.roundedBorder)

            Picker("Duración", selection: $minutes) {
                ForEach(presets, id: \.self) { Text("\($0) min").tag($0) }
                Text("Sin límite").tag(0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Button {
                model.start(minutes: minutes == 0 ? nil : minutes, task: task)
                task = ""
            } label: {
                Label("Entrar en foco", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy)
        }
    }

    private func activeView(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("🧘 En foco")
                    .font(.headline)
                Spacer()
                Text(model.remainingLabel)
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if !session.task.isEmpty {
                Text(session.task)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Button(role: .destructive) {
                model.stop()
            } label: {
                Label("Terminar sesión", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.busy)
        }
    }
}
