import AppKit
import Combine

/// One Claude Code session, as last reported by its hook.
struct ClaudeSession: Identifiable, Equatable {
    enum Status: Int, Comparable {
        /// Waiting on a permission prompt or a question. Sorted first.
        case needsYou
        case working
        /// Finished its turn, waiting for the next prompt.
        case done
        /// Says "working" but nothing has moved for a while: most often a turn
        /// interrupted with Esc, which fires no hook.
        case quiet
        /// Started, no prompt yet.
        case idle

        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    let id: String
    let cwd: String
    var status: Status
    /// Last hook event or transcript write, whichever is later.
    var updated: Date
    /// `/dev/ttys004`, when the session runs in a terminal.
    let tty: String?
    let pid: pid_t?
    /// Bundle id of the app the session runs in (Terminal, iTerm2, an editor).
    let appBundleID: String?
    let transcript: URL?
    /// Claude Code's own wording of what it is waiting for.
    let notice: String?
    /// The last thing Claude said, or the tool it is running.
    var preview: String?

    var project: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

/// Watches the files the hook script writes and turns them into sessions.
///
/// The folder is watched for as long as the tool is on, so the header count
/// stays right with the panel closed. The clock that ages "working" into
/// "quiet" and drops sessions whose process is gone runs only while the panel
/// is open: nobody reads those labels otherwise.
@MainActor
final class ClaudeSessionStore: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var hooksInstalled = ClaudeHooks.isInstalled
    @Published var lastError: String?

    /// A "working" session with no hook event and no transcript write for this
    /// long is shown as quiet. Long enough for a slow build to keep its label.
    static let quietAfter: TimeInterval = 5 * 60
    /// Sessions whose process could not be found are dropped after this.
    static let forgetAfter: TimeInterval = 12 * 60 * 60

    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    /// Previews keyed by transcript path, kept while the file's size holds.
    private var previewCache: [String: (size: UInt64, text: String?)] = [:]

    var needsYouCount: Int { sessions.filter { $0.status == .needsYou }.count }

    func start() {
        stop()
        let folder = ClaudeHooks.sessionsFolder
        let fd = open(folder.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: .write, queue: .main
            )
            // Main queue on purpose: the handler inherits this type's main-actor
            // isolation (see ScreenshotFolderWatcher for the same note).
            source.setEventHandler { [weak self] in self?.reload() }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
        reload()
    }

    func stop() {
        source?.cancel()
        source = nil
        setPanelActive(false)
    }

    func setPanelActive(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        guard active else { return }
        hooksInstalled = ClaudeHooks.isInstalled
        reload()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func installHooks() {
        do {
            try ClaudeHooks.install()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        hooksInstalled = ClaudeHooks.isInstalled
        start()
    }

    func removeHooks() {
        do {
            try ClaudeHooks.uninstall()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        hooksInstalled = ClaudeHooks.isInstalled
        sessions = []
    }

    func focus(_ session: ClaudeSession) {
        TerminalFocus.focus(session)
    }

    // MARK: - Reading

    func reload() {
        let fm = FileManager.default
        let folder = ClaudeHooks.sessionsFolder
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let now = Date()
        var found: [ClaudeSession] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  var session = Self.parse(data)
            else { continue }

            if !Self.isAlive(session, now: now) {
                try? fm.removeItem(at: url)
                continue
            }
            if let transcript = session.transcript {
                let attributes = try? fm.attributesOfItem(atPath: transcript.path)
                if let modified = attributes?[.modificationDate] as? Date, modified > session.updated {
                    session.updated = modified
                }
                let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
                session.preview = preview(for: transcript, size: size)
            }
            if session.status == .working, now.timeIntervalSince(session.updated) > Self.quietAfter {
                session.status = .quiet
            }
            found.append(session)
        }
        found.sort { ($0.status, $1.updated) < ($1.status, $0.updated) }
        if found != sessions { sessions = found }
    }

    private func preview(for transcript: URL, size: UInt64) -> String? {
        if let cached = previewCache[transcript.path], cached.size == size { return cached.text }
        let text = Self.lastActivity(in: Self.tail(of: transcript, bytes: 256 * 1024))
        previewCache[transcript.path] = (size, text)
        return text
    }

    private static func isAlive(_ session: ClaudeSession, now: Date) -> Bool {
        if let pid = session.pid {
            return kill(pid, 0) == 0 || errno == EPERM
        }
        return now.timeIntervalSince(session.updated) < forgetAfter
    }

    // MARK: - Parsing (pure, tested)

    /// One file written by the hook script.
    nonisolated static func parse(_ data: Data) -> ClaudeSession? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hook = root["hook"] as? [String: Any],
              let id = hook["session_id"] as? String,
              let event = hook["hook_event_name"] as? String
        else { return nil }

        let notice = hook["message"] as? String
        let tty = (root["tty"] as? String).flatMap { value -> String? in
            guard value.range(of: #"^ttys?[0-9]+$"#, options: .regularExpression) != nil else { return nil }
            return "/dev/" + value
        }
        let pid = (root["pid"] as? NSNumber).map { pid_t(truncating: $0) }.flatMap { $0 > 1 ? $0 : nil }
        let app = (root["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let at = (root["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        let transcript = (hook["transcript_path"] as? String).map { URL(fileURLWithPath: $0) }
        let status = status(
            event: event,
            notificationType: hook["notification_type"] as? String,
            message: notice
        )
        return ClaudeSession(
            id: id,
            cwd: hook["cwd"] as? String ?? "",
            status: status,
            updated: at,
            tty: tty,
            pid: pid,
            appBundleID: app,
            transcript: transcript,
            notice: status == .needsYou ? notice : nil,
            preview: nil
        )
    }

    nonisolated static func status(event: String, notificationType: String?, message: String?) -> ClaudeSession.Status {
        switch event {
        case "SessionStart":
            return .idle
        case "Stop":
            return .done
        case "Notification":
            // "Claude is waiting for your input" comes a minute after a turn
            // ends; it is not a question, the turn is simply done.
            if notificationType == "idle_prompt" { return .done }
            if notificationType == nil, message?.localizedCaseInsensitiveContains("waiting for your input") == true {
                return .done
            }
            return .needsYou
        default:
            return .working
        }
    }

    nonisolated static func tail(of url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The newest assistant entry in a transcript, as one short line: its
    /// last tool call, or else its text.
    nonisolated static func lastActivity(in transcriptTail: String) -> String? {
        for line in transcriptTail.split(separator: "\n").reversed() {
            guard line.contains("\"assistant\""),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }
            for block in content.reversed() {
                switch block["type"] as? String {
                case "tool_use":
                    return describeTool(block["name"] as? String ?? "", block["input"] as? [String: Any] ?? [:])
                case "text":
                    if let text = block["text"] as? String, let line = oneLine(text) { return line }
                default:
                    continue
                }
            }
        }
        return nil
    }

    nonisolated static func describeTool(_ name: String, _ input: [String: Any]) -> String {
        func file(_ key: String) -> String? {
            (input[key] as? String).map { ($0 as NSString).lastPathComponent }
        }
        let detail: String?
        switch name {
        case "Bash":
            detail = (input["description"] as? String) ?? (input["command"] as? String)
        case "Read", "Edit", "MultiEdit", "Write", "NotebookEdit":
            detail = file("file_path") ?? file("notebook_path")
        case "Grep", "Glob":
            detail = input["pattern"] as? String
        case "Task", "Agent":
            detail = input["description"] as? String
        case "WebFetch":
            detail = input["url"] as? String
        case "WebSearch":
            detail = input["query"] as? String
        default:
            detail = nil
        }
        guard let detail = detail.flatMap(oneLine) else { return name }
        return "\(name): \(detail)"
    }

    /// Whitespace squashed, cut to what fits two lines of the pane.
    nonisolated static func oneLine(_ text: String) -> String? {
        let squashed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !squashed.isEmpty else { return nil }
        return squashed.count > 160 ? String(squashed.prefix(159)) + "…" : squashed
    }
}
