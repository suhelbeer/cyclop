import Foundation

/// Puts Cyclop's hook into Claude Code's settings and takes it out again.
///
/// Claude Code runs a command on each hook event and hands it a JSON object on
/// stdin. The command installed here is a small shell script that writes that
/// object, plus the terminal it came from, to one file per session in
/// `Application Support/Cyclop/ClaudeSessions`. `ClaudeSessionStore` watches
/// that folder. Nothing leaves the Mac.
///
/// The settings file belongs to the user, so this edits it as little as it
/// can: the first install keeps a copy next to it, only entries whose command
/// points at our script are ever added or removed, and a file that does not
/// parse is left alone rather than replaced.
enum ClaudeHooks {
    /// Events the script listens to. `PostToolUse` is there to flip a session
    /// back to "working" once a permission prompt has been answered.
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Notification", "Stop", "SessionEnd",
    ]
    /// Events that take a tool matcher.
    private static let matched: Set<String> = ["PreToolUse", "PostToolUse"]

    /// How an entry is recognised as ours, on install and on removal.
    static let marker = "Cyclop/claude-hook.sh"

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static var backupURL: URL {
        settingsURL.appendingPathExtension("cyclop-backup")
    }

    static var scriptURL: URL { Support.file("claude-hook.sh") }

    static var sessionsFolder: URL { Support.directory("ClaudeSessions") }

    enum Failure: LocalizedError {
        case unreadableSettings
        var errorDescription: String? {
            localized("~/.claude/settings.json is not valid JSON, so Cyclop left it alone.")
        }
    }

    /// True when every event has our entry in it.
    static var isInstalled: Bool {
        guard let hooks = (try? readSettings())?["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains(where: isOurs)
        }
    }

    static func install() throws {
        try writeScript()
        var settings = try readSettings() ?? [:]
        let fm = FileManager.default
        if fm.fileExists(atPath: settingsURL.path), !fm.fileExists(atPath: backupURL.path) {
            try fm.copyItem(at: settingsURL, to: backupURL)
        }
        var hooks = removingOurs(from: settings["hooks"] as? [String: Any] ?? [:])
        let command = "\"\(scriptURL.path)\""
        for event in events {
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": command, "timeout": 5]],
            ]
            if matched.contains(event) { group["matcher"] = "*" }
            hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [group]
        }
        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    static func uninstall() throws {
        if var settings = try readSettings(), let hooks = settings["hooks"] as? [String: Any] {
            let cleaned = removingOurs(from: hooks)
            if cleaned.isEmpty {
                settings.removeValue(forKey: "hooks")
            } else {
                settings["hooks"] = cleaned
            }
            try writeSettings(settings)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: scriptURL)
        try? fm.removeItem(at: sessionsFolder)
    }

    // MARK: - Settings file

    /// nil when there is no file yet. Throws when there is one and it is not
    /// a JSON object: overwriting it would lose the user's settings.
    private static func readSettings() throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x09 || $0 == 0x0D }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadableSettings
        }
        return object
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains {
            ($0["command"] as? String)?.contains(marker) == true
        }
    }

    /// Drops our commands, then any group or event left empty by that.
    static func removingOurs(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let others = entries.filter { ($0["command"] as? String)?.contains(marker) != true }
                if others.isEmpty { return nil }
                var copy = group
                copy["hooks"] = others
                return copy
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    // MARK: - Script

    private static func writeScript() throws {
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// Plain `sh` and tools every Mac has: no jq, no Python. `plutil` reads
    /// JSON, which is enough to pull two fields out of the hook's input.
    ///
    /// The process walk finds the `claude` process itself, so the app can tell
    /// a session whose terminal was closed (no `SessionEnd` arrives then) from
    /// one that is just quiet. `__CFBundleIdentifier` is set by macOS for
    /// anything started from an app and inherited by its children, so it names
    /// the terminal app the session runs in.
    static let script = #"""
    #!/bin/sh
    # Written by Cyclop. Records where each Claude Code session stands so the
    # notch can show it. Local only: writes one small file per session.
    dir="$HOME/Library/Application Support/Cyclop/ClaudeSessions"
    input=$(cat)
    field() { printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }
    sid=$(field session_id)
    case "$sid" in ''|*/*|.*) exit 0 ;; esac
    if [ "$(field hook_event_name)" = "SessionEnd" ]; then
      rm -f "$dir/$sid.json"
      exit 0
    fi
    mkdir -p "$dir" || exit 0
    tty=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
    cpid=0; p=$PPID; i=0
    while [ "${p:-0}" -gt 1 ] && [ $i -lt 6 ]; do
      c=$(ps -o command= -p "$p" 2>/dev/null)
      case "$c" in *claude-hook*) ;; *claude*) cpid=$p; break ;; esac
      p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); i=$((i+1))
    done
    clean() { printf '%s' "$1" | tr -d '"\\\n'; }
    tmp="$dir/.$sid.$$"
    printf '{"at":%s,"tty":"%s","pid":%s,"app":"%s","hook":%s}\n' \
      "$(date +%s)" "$(clean "$tty")" "$cpid" "$(clean "$__CFBundleIdentifier")" "$input" \
      > "$tmp" && mv -f "$tmp" "$dir/$sid.json"
    exit 0
    """#
}
