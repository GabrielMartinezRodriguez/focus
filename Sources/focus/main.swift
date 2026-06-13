import Foundation

// MARK: - Configuración

/// Apps de distracción que se cierran del todo al entrar en foco (y se reabren al salir).
///
/// IMPORTANTE: aquí NO van las apps de mensajería que vigila el centinela
/// (Slack/WhatsApp/Telegram). Esas deben seguir corriendo para que sigan registrando
/// notificaciones en macOS — cerrarlas dejaría al centinela ciego.
let appsToClose: [String] = []

/// Apps de mensajería: se OCULTAN (no se cierran) al entrar en foco. Siguen corriendo y
/// registrando notificaciones —el centinela las tría— pero sus ventanas desaparecen de la
/// vista y No Molestar las silencia. Se vuelven a mostrar al salir.
let appsToHide = ["Slack", "Telegram", "WhatsApp", "Mail"]

/// Fichero donde se guarda el estado de la sesión activa.
let stateFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".focus-session.json")

/// Reglas personales del centinela. Se leen de ~/.focusrc (privado, fuera del repo).
/// Si no existe, se usan reglas genéricas de ejemplo.
let rulesFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".focusrc")

let defaultRules = """
    INTERRUMPE: emergencias de salud o seguridad; producción caída o errores graves
    que afecten a clientes y no se auto-resuelvan; alguien bloqueado esperando tu respuesta
    para poder trabajar; un cliente con un problema urgente.
    RETÉN: saludos, humor, stickers, reacciones; conversación general de canales;
    alertas auto-resueltas o informativas; bots y newsletters; cualquier cosa que pueda
    esperar una hora sin consecuencias reales.
    """

func sentinelRules() -> String {
    (try? String(contentsOf: rulesFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultRules
}

// MARK: - Utilidades

@discardableResult
func shell(_ command: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func osascript(_ script: String) {
    shell("osascript -e '\(script)'")
}

func isRunning(_ app: String) -> Bool {
    shell("pgrep -xq \"\(app)\" && echo yes") == "yes"
}

/// HazeOver (https://hazeover.com) es opcional: si no está instalado, su paso se omite.
let hazeOverInstalled = !shell("mdfind \"kMDItemCFBundleIdentifier == 'com.pointum.hazeover'\" 2>/dev/null").isEmpty
    || FileManager.default.fileExists(atPath: "/Applications/HazeOver.app")

// MARK: - Limpieza de workspace con IA

/// Apps que jamás se proponen cerrar, diga lo que diga el LLM.
let neverClose = ["Finder", "FocusBar", "ghostty", "Terminal", "iTerm2", "Claude"]

let claudeCLI = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/bin/claude").path

func runProcess(_ launchPath: String, _ arguments: [String], stdin: String? = nil) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = Pipe()
    if let stdin {
        let inPipe = Pipe()
        process.standardInput = inPipe
        inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
        inPipe.fileHandleForWriting.closeFile()
    }
    try? process.run()
    process.waitUntilExit()
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// Lista las apps visibles y los títulos de sus ventanas.
func openWindowsSummary() -> String {
    let script = """
    set out to ""
    tell application "System Events"
        repeat with p in (every process whose background only is false)
            set appName to name of p
            set winText to ""
            try
                repeat with t in (name of every window of p)
                    if (t as text) is not "" then set winText to winText & " | " & (t as text)
                end repeat
            end try
            set out to out & appName & winText & linefeed
        end repeat
    end tell
    return out
    """
    return runProcess("/usr/bin/osascript", ["-"], stdin: script)
}

struct AppToClose: Codable {
    let app: String
    let reason: String
}

/// Pregunta a Claude qué apps abiertas no tienen relación con la tarea.
func unrelatedApps(task: String, windows: String) -> [AppToClose] {
    let prompt = """
    Estoy empezando una sesión de trabajo enfocado. Mi tarea: "\(task)".

    Apps abiertas (nombre | títulos de ventanas):
    \(windows)

    Devuelve SOLO un JSON válido, sin nada más, con este formato:
    {"close":[{"app":"NombreApp","reason":"motivo breve"}]}

    Reglas: incluye solo apps claramente NO relacionadas con la tarea.
    NUNCA incluyas: \(neverClose.joined(separator: ", ")), terminales,
    ni la app donde probablemente estoy trabajando.
    Música de fondo para concentrarse cuenta como relacionada.
    En caso de duda, NO la incluyas.
    """
    let output = runProcess(claudeCLI, ["--model", "sonnet", "-p", prompt])
    guard let start = output.firstIndex(of: "{"),
          let end = output.lastIndex(of: "}") else { return [] }
    let json = String(output[start...end])
    struct Response: Codable { let close: [AppToClose] }
    let decoded = try? JSONDecoder().decode(Response.self, from: json.data(using: .utf8)!)
    return (decoded?.close ?? []).filter { !neverClose.contains($0.app) }
}

/// Diálogo nativo de confirmación. Devuelve true si el usuario acepta cerrar.
func confirmDialog(_ apps: [AppToClose]) -> Bool {
    let list = apps.map { "• \($0.app) — \($0.reason)" }.joined(separator: "\n")
    let script = """
    display dialog "Estas apps no parecen relacionadas con tu tarea:\n\n\(list)" \
        with title "Focus" buttons {"Dejarlas", "Cerrarlas"} \
        default button "Cerrarlas" with icon caution
    return button returned of result
    """
    return runProcess("/usr/bin/osascript", ["-"], stdin: script) == "Cerrarlas"
}

/// Analiza el workspace y (con confirmación) cierra lo no relacionado.
/// Devuelve las apps cerradas para poder reabrirlas al salir.
func cleanWorkspace(task: String, dryRun: Bool = false) -> [String] {
    print("   🤖 Analizando tus \(dryRun ? "ventanas" : "ventanas abiertas") con IA...")
    let windows = openWindowsSummary()
    let candidates = unrelatedApps(task: task, windows: windows)
    guard !candidates.isEmpty else {
        print("   ✓ Todo lo abierto parece relacionado con la tarea")
        return []
    }
    if dryRun {
        print("   Propondría cerrar:")
        for c in candidates { print("     • \(c.app) — \(c.reason)") }
        return []
    }
    guard confirmDialog(candidates) else {
        print("   ↩︎ Has decidido dejarlas abiertas")
        return []
    }
    var closed: [String] = []
    for c in candidates where isRunning(c.app) {
        osascript("tell application \"\(c.app)\" to quit")
        closed.append(c.app)
        print("   ✕ \(c.app) cerrada (\(c.reason))")
    }
    return closed
}

// MARK: - Estado de sesión

struct Session: Codable {
    var task: String
    var startedAt: Date
    var minutes: Int?      // nil = sin temporizador
    var closedApps: [String]
    var hiddenApps: [String]
    var timerPid: Int32?
    var watchPid: Int32?
    var dockWasHidden: Bool
    var menuBarWasHidden: Bool
    var dockDelayBefore: String?   // autohide-delay previo ("" si no estaba definido)
}

func loadSession() -> Session? {
    guard let data = try? Data(contentsOf: stateFile) else { return nil }
    return try? JSONDecoder().decode(Session.self, from: data)
}

func saveSession(_ session: Session) {
    if let data = try? JSONEncoder().encode(session) {
        try? data.write(to: stateFile)
    }
}

func clearSession() {
    try? FileManager.default.removeItem(at: stateFile)
}

// MARK: - Centinela de notificaciones

let notifDB = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db").path
let digestFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".focus-digest.log")

/// Canales que vigila el centinela (identificadores de bundle en la BD de notificaciones).
let watchedChannels = ["whatsapp": "WhatsApp", "tinyspeck": "Slack",
                       "telegram": "Telegram", "com.apple.mail": "Mail"]

/// Lock para que solo un centinela procese a la vez (evita alertas duplicadas).
let watchLockFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".focus-watch.lock")

func pidAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

func acquireWatchLock() -> Bool {
    if let txt = try? String(contentsOf: watchLockFile, encoding: .utf8),
       let pid = Int32(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
       pid != ProcessInfo.processInfo.processIdentifier, pidAlive(pid) {
        return false // otro centinela vivo lo tiene
    }
    try? "\(ProcessInfo.processInfo.processIdentifier)".write(to: watchLockFile, atomically: true, encoding: .utf8)
    return true
}

func releaseWatchLock() {
    if let txt = try? String(contentsOf: watchLockFile, encoding: .utf8),
       Int32(txt.trimmingCharacters(in: .whitespacesAndNewlines)) == ProcessInfo.processInfo.processIdentifier {
        try? FileManager.default.removeItem(at: watchLockFile)
    }
}

/// ¿Puede este proceso leer realmente la BD? (TCC puede denegar aunque el fichero exista)
func canReadNotifDB() -> Bool {
    Int(runProcess("/usr/bin/sqlite3", [notifDB, "SELECT COUNT(*) FROM record;"])) != nil
}

/// Pidfile del demonio watchd (vigilante residente).
let daemonPidFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".focus-watchd.pid")

func daemonAlive() -> Bool {
    guard let txt = try? String(contentsOf: daemonPidFile, encoding: .utf8),
          let pid = Int32(txt.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    return pidAlive(pid)
}

struct Notif {
    let recId: Int64
    let date: String
    let channel: String
    let title: String      // remitente / canal
    let subtitle: String
    let body: String       // texto del mensaje

    var oneLine: String { "[\(channel)] \(title)\(subtitle.isEmpty ? "" : " (\(subtitle))"): \(body)" }
}

func sqlite(_ sql: String) -> [String] {
    let out = runProcess("/usr/bin/sqlite3", ["-separator", "\u{1F}", notifDB, sql])
    return out.isEmpty ? [] : out.components(separatedBy: "\n")
}

func watchedAppIds() -> [Int64: String] {
    // Canales extra opcionales (~/.focus-extra-channels, líneas "substring:Nombre")
    var channels = watchedChannels
    let extraFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".focus-extra-channels")
    if let extra = try? String(contentsOf: extraFile, encoding: .utf8) {
        for line in extra.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: ":")
            if parts.count == 2, !parts[0].isEmpty { channels[parts[0].lowercased()] = parts[1] }
        }
    }
    var map: [Int64: String] = [:]
    for row in sqlite("SELECT app_id, identifier FROM app;") {
        let cols = row.components(separatedBy: "\u{1F}")
        guard cols.count == 2, let id = Int64(cols[0]) else { continue }
        for (key, name) in channels where cols[1].lowercased().contains(key) {
            map[id] = name
        }
    }
    return map
}

func fetchNotifications(after recId: Int64, apps: [Int64: String]) -> [Notif] {
    guard !apps.isEmpty else { return [] }
    let ids = apps.keys.map(String.init).joined(separator: ",")
    var result: [Notif] = []
    for row in sqlite("SELECT rec_id, app_id, datetime(delivered_date + 978307200, 'unixepoch', 'localtime'), hex(data) FROM record WHERE app_id IN (\(ids)) AND rec_id > \(recId) ORDER BY rec_id;") {
        let cols = row.components(separatedBy: "\u{1F}")
        guard cols.count == 4, let rid = Int64(cols[0]), let appId = Int64(cols[1]) else { continue }
        // decodificar el plist binario de la notificación
        var data = Data(); var idx = cols[3].startIndex
        while idx < cols[3].endIndex, let next = cols[3].index(idx, offsetBy: 2, limitedBy: cols[3].endIndex) {
            if let byte = UInt8(cols[3][idx..<next], radix: 16) { data.append(byte) }
            idx = next
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let req = plist["req"] as? [String: Any] else { continue }
        result.append(Notif(
            recId: rid, date: cols[2], channel: apps[appId] ?? "?",
            title: (req["titl"] as? String ?? "").trimmingCharacters(in: .whitespaces),
            subtitle: (req["subt"] as? String ?? "").trimmingCharacters(in: .whitespaces),
            body: (req["body"] as? String ?? "").trimmingCharacters(in: .whitespaces)))
    }
    return result
}

func maxRecId() -> Int64 {
    Int64(sqlite("SELECT COALESCE(MAX(rec_id),0) FROM record;").first ?? "0") ?? 0
}

func appendDigest(_ line: String) {
    let entry = line + "\n"
    if let handle = try? FileHandle(forWritingTo: digestFile) {
        handle.seekToEndOfFile()
        handle.write(entry.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? entry.write(to: digestFile, atomically: true, encoding: .utf8)
    }
}

/// Alerta crítica: diálogo nativo que atraviesa cualquier No Molestar.
func criticalAlert(summary: String, reason: String) {
    let esc = { (s: String) in s.replacingOccurrences(of: "\"", with: "'") }
    let script = """
    display alert "🚨 \(esc(summary))" message "\(esc(reason))" as critical buttons {"Visto"} default button "Visto" giving up after 120
    """
    _ = runProcess("/usr/bin/osascript", ["-"], stdin: script)
}

/// El prompt del centinela: decide qué justifica romper el foco del usuario.
func sentinelVerdict(task: String, notifs: [Notif]) -> [(index: Int, summary: String, reason: String)] {
    let list = notifs.enumerated()
        .map { "\($0.offset). \($0.element.oneLine)" }
        .joined(separator: "\n")
    let prompt = """
    Eres el centinela de foco del usuario, un programador en sesión de trabajo profundo.
    Su tarea actual: "\(task.isEmpty ? "trabajo enfocado" : task)".
    Tu único trabajo: decidir si alguna de estas notificaciones justifica INTERRUMPIR su concentración AHORA MISMO.

    Notificaciones nuevas:
    \(list)

    Reglas del usuario:
    \(sentinelRules())

    REGLA DE ORO: en caso de duda, RETÉN. Romper el foco cuesta 20 minutos de re-concentración;
    leer un mensaje 45 minutos tarde casi nunca cuesta nada.
    ÚNICA EXCEPCIÓN: si huele a emergencia de salud, seguridad o producción, interrumpe aunque dudes.

    Responde SOLO con JSON válido, sin nada más:
    {"alerts":[{"index":N,"summary":"qué pasa, en una línea, para mostrárselo al usuario","reason":"por qué no puede esperar"}]}
    Si ninguna justifica interrumpir: {"alerts":[]}
    """
    let output = runProcess(claudeCLI, ["--model", "sonnet", "-p", prompt])
    guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") else { return [] }
    struct Alert: Codable { let index: Int; let summary: String; let reason: String }
    struct Response: Codable { let alerts: [Alert] }
    let decoded = try? JSONDecoder().decode(Response.self, from: String(output[start...end]).data(using: .utf8)!)
    return (decoded?.alerts ?? []).map { ($0.index, $0.summary, $0.reason) }
}

/// Bucle del centinela: corre mientras exista la sesión.
func runSentinel() {
    let now = { ISO8601DateFormatter().string(from: Date()) }
    // La lectura puede fallar por TCC aunque el fichero "exista": probamos una consulta real.
    guard canReadNotifDB() else {
        // Si hay un demonio watchd vivo, él se encargará — salir en silencio.
        if daemonAlive() { return }
        appendDigest("⚠️ [\(now())] Centinela sin acceso a la BD de notificaciones (falta Acceso total al disco para el proceso que lanzó la sesión, y no hay demonio watchd)")
        return
    }
    guard acquireWatchLock() else { return } // otro centinela ya vigila esta sesión
    defer { releaseWatchLock() }
    appendDigest("👁 [\(now())] Centinela activo (pid \(ProcessInfo.processInfo.processIdentifier))")
    let apps = watchedAppIds()
    var lastRec = maxRecId()
    var pendingIncidents: [(notif: Notif, since: Date)] = []

    while let session = loadSession() {
        Thread.sleep(forTimeInterval: 15)
        var fresh = fetchNotifications(after: lastRec, apps: apps)
        lastRec = max(lastRec, fresh.map(\.recId).max() ?? lastRec)

        // Capa 1: reglas fijas
        fresh = fresh.filter { n in
            let text = n.oneLine.lowercased()
            if text.contains("download completed") { return false }
            if text.contains("automatically resolved") {
                // cancela el incidente pendiente correspondiente
                pendingIncidents.removeAll { $0.notif.subtitle == n.subtitle }
                appendDigest("✅ \(n.date) \(n.oneLine) (auto-resuelto, retenido)")
                return false
            }
            if text.contains("new incident") {
                // Capa 2: espera 3 min antes de avisar, por si se auto-resuelve
                pendingIncidents.append((n, Date()))
                return false
            }
            return true
        }

        // Capa 2: incidentes que llevan >3 min sin resolverse → alerta
        for pending in pendingIncidents where Date().timeIntervalSince(pending.since) > 180 {
            criticalAlert(summary: "Incidente sin auto-resolver (3+ min)", reason: pending.notif.oneLine)
            appendDigest("🚨 \(pending.notif.date) \(pending.notif.oneLine) → INTERRUMPIDO")
        }
        pendingIncidents.removeAll { Date().timeIntervalSince($0.since) > 180 }

        // Capa 3: juicio con IA para el resto
        guard !fresh.isEmpty else { continue }
        let alerts = sentinelVerdict(task: session.task, notifs: fresh)
        for (i, n) in fresh.enumerated() {
            if let alert = alerts.first(where: { $0.index == i }) {
                criticalAlert(summary: alert.summary, reason: alert.reason)
                appendDigest("🚨 \(n.date) \(n.oneLine) → INTERRUMPIDO: \(alert.reason)")
            } else {
                appendDigest("· \(n.date) \(n.oneLine)")
            }
        }
    }
}

/// Resumen de fin de sesión a partir del digest acumulado.
func showDigest() {
    guard let content = try? String(contentsOf: digestFile, encoding: .utf8),
          !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        print("   📭 No llegó nada durante la sesión")
        return
    }
    let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
    print("   📬 Retenido durante la sesión (\(lines.count)):")
    for line in lines.suffix(15) { print("      \(line)") }
    let esc = content.replacingOccurrences(of: "\"", with: "'").prefix(1500)
    let script = """
    display dialog "Mientras estabas en foco:\n\n\(esc)" with title "Focus — resumen de sesión" buttons {"OK"} default button "OK" giving up after 600
    """
    _ = runProcess("/usr/bin/osascript", ["-"], stdin: script)
}

// MARK: - Acciones

func enterFocus(minutes: Int?, task: String) {
    if loadSession() != nil {
        print("⚠️  Ya hay una sesión activa. Usa `focus stop` primero.")
        return
    }

    print("🧘 Entrando en modo foco" + (task.isEmpty ? "" : ": \(task)"))

    // Digest limpio para esta sesión (evita arrastrar avisos de sesiones anteriores)
    try? "".write(to: digestFile, atomically: true, encoding: .utf8)

    // 1. Cerrar apps de distracción (recordando cuáles estaban abiertas para reabrirlas)
    var closed: [String] = []
    for app in appsToClose where isRunning(app) {
        osascript("tell application \"\(app)\" to quit")
        closed.append(app)
        print("   ✕ \(app) cerrada")
    }

    // 1a. Ocultar apps de mensajería: siguen corriendo (el centinela las vigila) pero
    //     sus ventanas desaparecen de la vista.
    var hidden: [String] = []
    for app in appsToHide where isRunning(app) {
        osascript("tell application \"System Events\" to set visible of process \"\(app)\" to false")
        hidden.append(app)
    }
    if !hidden.isEmpty {
        print("   ◌ \(hidden.joined(separator: ", ")) ocultas (siguen vigiladas)")
    }

    // 1b. Con tarea declarada: limpieza inteligente del resto del workspace.
    // Estas NO se reabren al salir (a diferencia de las de mensajería).
    if !task.isEmpty, FileManager.default.isExecutableFile(atPath: claudeCLI) {
        _ = cleanWorkspace(task: task)
    }

    // 2. Ocultar Dock y barra de menú (recordando su estado previo)
    let dockWasHidden = shell("defaults read com.apple.dock autohide 2>/dev/null") == "1"
    let menuBarWasHidden = shell("osascript -e 'tell application \"System Events\" to get autohide menu bar of dock preferences'") == "true"
    if !dockWasHidden {
        shell("defaults write com.apple.dock autohide -bool true")
    }
    // Retardo enorme: el Dock no aparece ni rozando el borde con el ratón
    let dockDelayBefore = shell("defaults read com.apple.dock autohide-delay 2>/dev/null")
    shell("defaults write com.apple.dock autohide-delay -float 1000 && killall Dock")
    if !menuBarWasHidden {
        osascript("tell application \"System Events\" to set autohide menu bar of dock preferences to true")
    }
    print("   ✕ Dock sellado y barra de menú oculta")

    // 3. Encender HazeOver (si está instalado)
    if hazeOverInstalled {
        osascript("tell application \"HazeOver\" to set enabled to true")
        print("   ✓ HazeOver encendido")
    }

    // 3b. Activar No Molestar (si existe el atajo "Focus On")
    if shell("shortcuts list 2>/dev/null | grep -cx 'Focus On'") == "1" {
        shell("shortcuts run \"Focus On\"")
        print("   ✓ No Molestar activado")
    }

    // 4. Temporizador: programa `focus stop` al acabar
    var timerPid: Int32? = nil
    if let minutes {
        let binary = CommandLine.arguments[0]
        let pid = shell("nohup bash -c 'sleep \(minutes * 60) && \"\(binary)\" stop' >/dev/null 2>&1 & echo $!")
        timerPid = Int32(pid)
        print("   ⏱  Sesión de \(minutes) min — todo se restaurará solo al acabar")
    }

    saveSession(Session(task: task, startedAt: Date(), minutes: minutes,
                        closedApps: closed, hiddenApps: hidden, timerPid: timerPid, watchPid: nil,
                        dockWasHidden: dockWasHidden, menuBarWasHidden: menuBarWasHidden,
                        dockDelayBefore: dockDelayBefore))

    // 5. Centinela: vigila Slack/WhatsApp/Telegram y solo interrumpe por lo crítico
    let binary = CommandLine.arguments[0]
    let watchPid = shell("nohup \"\(binary)\" watch >/dev/null 2>&1 & echo $!")
    if var s = loadSession() {
        s.watchPid = Int32(watchPid)
        saveSession(s)
    }
    print("   👁  Centinela vigilando Slack, WhatsApp y Telegram")
    print("✅ Foco activo. `focus stop` para terminar antes.")
}

func exitFocus(showDigestDialog: Bool = true) {
    guard let session = loadSession() else {
        print("No hay ninguna sesión activa.")
        return
    }

    print("🌤  Saliendo del modo foco...")

    // Cancelar el temporizador si se para a mano
    if let pid = session.timerPid {
        shell("pkill -P \(pid) 2>/dev/null; kill \(pid) 2>/dev/null")
    }

    // Restaurar Dock y barra de menú a como estaban antes de la sesión
    if !session.dockWasHidden {
        shell("defaults write com.apple.dock autohide -bool false")
    }
    if let delay = session.dockDelayBefore, !delay.isEmpty {
        shell("defaults write com.apple.dock autohide-delay -float \(delay)")
    } else {
        shell("defaults delete com.apple.dock autohide-delay 2>/dev/null")
    }
    shell("killall Dock")
    if !session.menuBarWasHidden {
        osascript("tell application \"System Events\" to set autohide menu bar of dock preferences to false")
    }
    print("   ✓ Dock y barra de menú restaurados")

    // Apagar HazeOver (si está instalado)
    if hazeOverInstalled {
        osascript("tell application \"HazeOver\" to set enabled to false")
        print("   ✓ HazeOver apagado")
    }

    // Desactivar No Molestar
    if shell("shortcuts list 2>/dev/null | grep -cx 'Focus Off'") == "1" {
        shell("shortcuts run \"Focus Off\"")
        print("   ✓ No Molestar desactivado")
    }

    // Reabrir las apps que se cerraron
    for app in session.closedApps {
        shell("open -gja \"\(app)\"")
        print("   ↩︎ \(app) reabierta")
    }

    // Volver a mostrar las apps de mensajería que se ocultaron
    for app in session.hiddenApps where isRunning(app) {
        osascript("tell application \"System Events\" to set visible of process \"\(app)\" to true")
    }
    if !session.hiddenApps.isEmpty {
        print("   ↩︎ \(session.hiddenApps.joined(separator: ", ")) visibles de nuevo")
    }

    clearSession()

    // Parar el centinela y mostrar lo retenido
    if let pid = session.watchPid { shell("kill \(pid) 2>/dev/null") }
    if showDigestDialog { showDigest() }

    let elapsed = Int(Date().timeIntervalSince(session.startedAt) / 60)
    print("✅ Sesión terminada (\(elapsed) min de foco).")
}

func showStatus() {
    guard let session = loadSession() else {
        print("Sin sesión activa.")
        return
    }
    let elapsed = Int(Date().timeIntervalSince(session.startedAt) / 60)
    var line = "🧘 En foco desde hace \(elapsed) min"
    if let total = session.minutes { line += " (quedan \(max(0, total - elapsed)) min)" }
    if !session.task.isEmpty { line += " — tarea: \(session.task)" }
    print(line)
}

// MARK: - CLI

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "start":
    let minutes = args.count > 1 ? Int(args[1]) : nil
    let task = args.dropFirst(minutes != nil ? 2 : 1).joined(separator: " ")
    enterFocus(minutes: minutes, task: task)
case "stop":
    // --quiet omite el diálogo de digest (lo usa FocusBar al cerrarse, para no
    // bloquear la terminación de la app con un modal).
    exitFocus(showDigestDialog: !args.contains("--quiet"))
case "status":
    showStatus()
case "watch":
    runSentinel()
case "watchd":
    // Demonio residente: vigila para siempre; cuando hay sesión, hace de centinela.
    // Lánzalo desde un proceso con Acceso total al disco (p. ej. tu terminal):
    //   nohup focus watchd >/dev/null 2>&1 &
    guard canReadNotifDB() else {
        print("✗ watchd sin Acceso total al disco — lánzalo desde una terminal que lo tenga")
        exit(1)
    }
    try? "\(ProcessInfo.processInfo.processIdentifier)".write(to: daemonPidFile, atomically: true, encoding: .utf8)
    print("👁 watchd vigilando (pid \(ProcessInfo.processInfo.processIdentifier))")
    while true {
        if loadSession() != nil { runSentinel() }
        Thread.sleep(forTimeInterval: 5)
    }
case "scan":
    let task = args.dropFirst().joined(separator: " ")
    if task.isEmpty {
        print("Uso: focus scan <tarea>  (analiza sin cerrar nada)")
    } else {
        _ = cleanWorkspace(task: task, dryRun: true)
    }
default:
    print("""
    focus — modo foco para tu Mac

    Uso:
      focus start [minutos] [tarea...]   Entra en foco (con temporizador opcional)
      focus stop                         Sale del foco y restaura todo
      focus status                       Estado de la sesión actual

    Ejemplos:
      focus start 50 terminar el endpoint de pagos
      focus start
      focus stop
    """)
}
