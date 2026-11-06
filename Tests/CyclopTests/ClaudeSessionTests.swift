import Foundation
import Testing
@testable import Cyclop

/// The file format the hook script writes and the transcript tail it reads
/// are the two places a Claude Code update could quietly break this tool.
struct ClaudeSessionTests {
    private func record(_ hook: String, tty: String = "ttys004", pid: Int = 0, app: String = "com.apple.Terminal") -> Data {
        Data(#"{"at":1700000000,"tty":"\#(tty)","pid":\#(pid),"app":"\#(app)","hook":\#(hook)}"#.utf8)
    }

    @Test func parsesStopRecord() throws {
        let session = try #require(ClaudeSessionStore.parse(record(
            #"{"session_id":"abc","hook_event_name":"Stop","cwd":"/Users/z/code/notch","transcript_path":"/tmp/t.jsonl"}"#
        )))
        #expect(session.id == "abc")
        #expect(session.project == "notch")
        #expect(session.status == .done)
        #expect(session.tty == "/dev/ttys004")
        #expect(session.pid == nil)
        #expect(session.appBundleID == "com.apple.Terminal")
        #expect(session.transcript?.path == "/tmp/t.jsonl")
    }

    /// The tty goes into an AppleScript literal, so anything odd is dropped.
    @Test func rejectsStrangeTTY() throws {
        for bad in ["??", "", "ttys004\\\" & do shell script", "pts/3"] {
            let escaped = bad.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let session = try #require(ClaudeSessionStore.parse(record(
                #"{"session_id":"a","hook_event_name":"Stop"}"#, tty: escaped
            )))
            #expect(session.tty == nil)
        }
    }

    @Test func permissionNoticeNeedsYou() throws {
        let session = try #require(ClaudeSessionStore.parse(record(
            #"{"session_id":"a","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}"#
        )))
        #expect(session.status == .needsYou)
        #expect(session.notice == "Claude needs your permission to use Bash")
    }

    @Test func idleNoticeIsDone() {
        #expect(ClaudeSessionStore.status(event: "Notification", notificationType: "idle_prompt", message: nil) == .done)
        #expect(ClaudeSessionStore.status(event: "Notification", notificationType: nil,
                                          message: "Claude is waiting for your input") == .done)
        #expect(ClaudeSessionStore.status(event: "PreToolUse", notificationType: nil, message: nil) == .working)
        #expect(ClaudeSessionStore.status(event: "UserPromptSubmit", notificationType: nil, message: nil) == .working)
        #expect(ClaudeSessionStore.status(event: "SessionStart", notificationType: nil, message: nil) == .idle)
    }

    @Test func malformedRecordIsSkipped() {
        #expect(ClaudeSessionStore.parse(Data("{\"at\":1,\"hook\":".utf8)) == nil)
        #expect(ClaudeSessionStore.parse(record(#"{"hook_event_name":"Stop"}"#)) == nil)
    }

    @Test func previewPrefersLatestToolCall() {
        let tail = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"Old answer"}]}}
        {"type":"user","message":{"content":"next"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Let me check."},{"type":"tool_use","name":"Bash","input":{"command":"swift build","description":"Build the app"}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}
        """
        #expect(ClaudeSessionStore.lastActivity(in: tail) == "Bash: Build the app")
    }

    @Test func previewSurvivesCutFirstLine() {
        let tail = """
        sage":{"content":[{"type":"text"
        {"type":"assistant","message":{"content":[{"type":"text","text":"  All tests\\n pass.  "}]}}
        """
        #expect(ClaudeSessionStore.lastActivity(in: tail) == "All tests pass.")
    }

    @Test func describesFileTools() {
        #expect(ClaudeSessionStore.describeTool("Edit", ["file_path": "/a/b/Pane.swift"]) == "Edit: Pane.swift")
        #expect(ClaudeSessionStore.describeTool("Mystery", [:]) == "Mystery")
    }

    @Test func removingOursKeepsOtherHooks() {
        let hooks: [String: Any] = [
            "Stop": [
                ["hooks": [
                    ["type": "command", "command": "\"/x/Cyclop/claude-hook.sh\""],
                    ["type": "command", "command": "say done"],
                ]],
            ],
            "PreToolUse": [
                ["matcher": "*", "hooks": [["type": "command", "command": "\"/x/Cyclop/claude-hook.sh\""]]],
            ],
            "PostToolUse": [
                ["matcher": "Bash", "hooks": [["type": "command", "command": "lint"]]],
            ],
        ]
        let cleaned = ClaudeHooks.removingOurs(from: hooks)
        #expect(cleaned["PreToolUse"] == nil)
        let stop = cleaned["Stop"] as? [[String: Any]]
        let commands = (stop?.first?["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String }
        #expect(commands == ["say done"])
        #expect((cleaned["PostToolUse"] as? [[String: Any]])?.count == 1)
    }
}
