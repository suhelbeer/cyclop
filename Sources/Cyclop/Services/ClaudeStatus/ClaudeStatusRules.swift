import Foundation

/// The labels Cyclop looks for inside a Claude window, and what each means.
///
/// Kept as data, not code: a Claude update that renames "Stop" should cost a
/// line in `~/Library/Application Support/Cyclop/claude-status-rules.json`,
/// not a rebuild. The file is optional; any key left out keeps the default.
///
/// Label patterns match a whole label, ignoring case, with `*` standing for
/// any run of characters. Count patterns are regular expressions whose first
/// group is the number.
///
/// The defaults are what Claude 4.23118 shows (read 2026-11-07, see
/// `claude-ax-findings-2026-11-07.md`): thread cards read
/// "<title> — Working" or "<title> — Needs attention", the open thread's
/// composer swaps "Send" for "Stop", a project window's toolbar has
/// "Threads 6 threads waiting on you", and the main window "Tasks, 2 need
/// input".
struct ClaudeStatusRules: Codable, Equatable, Sendable {
    /// Labels that exist only while a thread is running.
    var working: [String]
    /// Labels that carry Claude's own count of threads waiting on you.
    var waitingCount: [String]
    /// Labels that prove the window is a Claude page the rules understand.
    /// Without one of them a quiet window is "unknown", not idle.
    var layout: [String]

    static let defaults = ClaudeStatusRules(
        working: ["Stop", "* — Working", "* — Working — *", "Claude is working"],
        waitingCount: [#"^Threads\s+(\d+)\s+threads?\s+waiting on you"#, #"^Tasks,\s*(\d+)\s+needs?\s+input"#],
        layout: ["Threads*", "Tasks*", "Send", "Send *", "Stop"]
    )

    init(working: [String], waitingCount: [String], layout: [String]) {
        self.working = working
        self.waitingCount = waitingCount
        self.layout = layout
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults
        working = try c.decodeIfPresent([String].self, forKey: .working) ?? d.working
        waitingCount = try c.decodeIfPresent([String].self, forKey: .waitingCount) ?? d.waitingCount
        layout = try c.decodeIfPresent([String].self, forKey: .layout) ?? d.layout
    }

    /// `claude-status-rules.json` in the support folder.
    static var file: URL { Support.file("claude-status-rules.json") }

    /// The file's rules, or the defaults when there is no file or it does not
    /// parse. A broken file is reported, never written over.
    static func load() -> (rules: ClaudeStatusRules, broken: Bool) {
        guard let data = try? Data(contentsOf: file) else { return (defaults, false) }
        do {
            return (try JSONDecoder().decode(ClaudeStatusRules.self, from: data), false)
        } catch {
            return (defaults, true)
        }
    }

    // MARK: - Matching

    /// Whole-label match, ignoring case, `*` for anything, as a regex.
    static func labelRegex(_ pattern: String) -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        let parts = pattern.components(separatedBy: "*").map(NSRegularExpression.escapedPattern(for:))
        return try? NSRegularExpression(pattern: "^" + parts.joined(separator: ".*") + "$", options: [.caseInsensitive])
    }

    static func matches(_ label: String, _ pattern: String) -> Bool {
        guard let regex = labelRegex(pattern) else { return false }
        return regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil
    }

    /// The rules turned into regular expressions once, rather than once per
    /// label per read: a page has a few hundred labels and is read every
    /// couple of seconds.
    func compiled() -> Compiled {
        Compiled(
            working: working.compactMap(Self.labelRegex),
            waitingCount: waitingCount.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) },
            layout: layout.compactMap(Self.labelRegex)
        )
    }

    struct Compiled: @unchecked Sendable {
        let working: [NSRegularExpression]
        let waitingCount: [NSRegularExpression]
        let layout: [NSRegularExpression]

        private static func hit(_ regexes: [NSRegularExpression], _ label: String) -> Bool {
            let range = NSRange(label.startIndex..., in: label)
            return regexes.contains { $0.firstMatch(in: label, range: range) != nil }
        }

        private static func count(_ regexes: [NSRegularExpression], _ label: String) -> Int? {
            let range = NSRange(label.startIndex..., in: label)
            for regex in regexes {
                guard let match = regex.firstMatch(in: label, range: range), match.numberOfRanges > 1,
                      let found = Range(match.range(at: 1), in: label), let n = Int(label[found])
                else { continue }
                return n
            }
            return nil
        }

        /// Reads one window from the labels on its page. Returns the reading
        /// and the label that decided it, for Settings.
        func classify(_ labels: [String]) -> (reading: ClaudeReading, matched: String?) {
            var reading = ClaudeReading(readable: true, recognised: false, working: false, waiting: nil)
            var matched: String?
            for raw in labels {
                let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { continue }
                if reading.waiting == nil, let n = Self.count(waitingCount, label) {
                    reading.waiting = n
                    reading.recognised = true
                    matched = matched ?? label
                }
                if !reading.working, Self.hit(working, label) {
                    reading.working = true
                    reading.recognised = true
                    matched = label
                }
                if !reading.recognised, Self.hit(layout, label) {
                    reading.recognised = true
                    matched = matched ?? label
                }
            }
            return (reading, matched)
        }
    }

    func classify(_ labels: [String]) -> (reading: ClaudeReading, matched: String?) {
        compiled().classify(labels)
    }
}
