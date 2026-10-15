import AppKit
import SwiftUI

enum Status: Int, Comparable {
    case waiting, working, done // order = sort order in the list
    static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
}

enum Choice {
    case deny, once, always, bypass
    case answer([String: String]) // AskUserQuestion: question text -> chosen label(s)
    case handOff                  // no decision; answer it in Claude instead
}

struct Permission: Identifiable {
    let id = UUID()
    let tool: String
    let input: [String: Any]
    let suggestions: [Any]
    let client: HookClient
}

struct Session: Identifiable {
    let id: String
    var cwd: String
    var title: String?
    var prompt: String?
    var reply: String?
    var activity: String?   // what it is doing right now, e.g. "Bash · npm test"
    var subagents = 0
    var status = Status.done
    var updated = Date()
    var bundleID: String?
    var appName: String?
    var hostID: String?     // Claude desktop's own id (local_…), set when the session runs in the desktop app
    var permissions: [Permission] = []

    var chatTitle: String?  // the name shown in Claude's sidebar
    /// Folder name, except for the throwaway folders the desktop app makes for sessions without a project.
    var project: String? { cwd.contains("/scratch-workspaces/") || cwd.isEmpty ? nil : (cwd as NSString).lastPathComponent }
    var headline: String { chatTitle ?? title ?? "New session" }
}

final class Store: ObservableObject {
    @Published var sessions: [String: Session] = [:]
    @Published var expanded = false
    @Published var expandedHeight: CGFloat = 200 // measured from the open list; a guess until the first open
    @Published var sound = UserDefaults.standard.object(forKey: "sound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sound, forKey: "sound") }
    }
    var notchWidth: CGFloat = 0
    var notchHeight: CGFloat = 32
    @Published var usage: Usage?
    @Published var usageError: String?

    var sorted: [Session] { sessions.values.sorted { ($0.status, $1.updated) < ($1.status, $0.updated) } }
    /// Island geometry is computed, not measured, so hit-testing and the grow animation agree on it.
    var wing: CGFloat { active.isEmpty ? 0 : 110 }
    var ear: CGFloat { expanded ? 14 : 8 }
    var islandSize: CGSize {
        expanded
            ? CGSize(width: 640 + 2 * ear, height: max(expandedHeight, notchHeight))
            : CGSize(width: notchWidth + 2 * wing + 2 * ear, height: notchHeight)
    }

    var pendingCount: Int { sessions.values.reduce(0) { $0 + $1.permissions.count } }

    func setExpanded(_ open: Bool) {
        guard open != expanded else { return }
        withAnimation(.spring(duration: 0.45, bounce: 0.25)) { expanded = open }
    }
    var active: [Session] { Array(sessions.values) }
    var overall: Status? { active.map(\.status).min() }

    func handle(_ headers: [String: String], _ body: Data, _ client: HookClient) {
        guard let e = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let id = e["session_id"] as? String,
              let event = e["hook_event_name"] as? String
        else { return client.reply() }

        var s = sessions[id] ?? Session(id: id, cwd: e["cwd"] as? String ?? "")
        if let b = headers["x-bundle"], !b.isEmpty, b != s.bundleID {
            s.bundleID = b
            s.appName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b)?.deletingPathExtension().lastPathComponent
        }
        if let h = headers["x-host-session"], h.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil {
            s.hostID = h
        }
        s.updated = Date()
        if ["SessionStart", "UserPromptSubmit", "Stop"].contains(event), let t = Self.chatTitle(e["transcript_path"] as? String) {
            s.chatTitle = t
        }

        switch event {
        case "UserPromptSubmit":
            // Desktop injects its own events as prompts (<task-notification>, <side-sessions-event>, ...); those are not you.
            if let p = e["prompt"] as? String, p.range(of: #"^\s*<[a-z-]+>"#, options: .regularExpression) == nil {
                if s.title == nil { s.title = p }
                s.prompt = p
            }
            s.reply = nil
            s.status = .working
            release(&s)
        case "PreToolUse":
            s.activity = describe(e["tool_name"] as? String, e["tool_input"] as? [String: Any])
            if s.permissions.isEmpty { s.status = .working }
        case "PostToolUse":
            if s.permissions.isEmpty { s.status = .working }
        case "Notification":
            // Claude is blocked on the terminal (dialog we did not get a hook for, MCP elicitation, ...).
            let waits = ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"]
            if waits.contains(e["notification_type"] as? String ?? ""), s.permissions.isEmpty {
                s.status = .waiting
                s.activity = e["message"] as? String
            }
        case "PreCompact":
            s.status = .working
            s.activity = "Compacting context…"
        case "SubagentStart":
            s.subagents += 1
        case "SubagentStop":
            s.subagents = max(0, s.subagents - 1)
        case "PermissionRequest":
            let perm = Permission(tool: e["tool_name"] as? String ?? "?",
                                  input: e["tool_input"] as? [String: Any] ?? [:],
                                  suggestions: e["permission_suggestions"] as? [Any] ?? [],
                                  client: client)
            client.onClose = { [weak self] in self?.drop(id, perm.id) }
            s.permissions.append(perm)
            s.status = .waiting
            sessions[id] = s
            play("Funk")
            return // answered later from the island
        case "Stop":
            if s.status == .working { play("Glass") }
            s.status = .done
            s.reply = e["last_assistant_message"] as? String ?? s.reply
            s.activity = nil
            s.subagents = 0
            release(&s)
        case "StopFailure":
            if s.status == .working { play("Basso") }
            s.status = .done
            s.reply = "⚠ " + (e["error"] as? String ?? e["message"] as? String ?? "Turn failed")
            s.activity = nil
            s.subagents = 0
            release(&s)
        case "SessionEnd":
            release(&s)
            sessions[id] = nil
            return client.reply()
        default:
            break
        }
        sessions[id] = s
        prune()
        client.reply()
    }

    func decide(_ sid: String, _ choice: Choice) {
        guard var s = sessions[sid], !s.permissions.isEmpty else { return }
        let p = s.permissions.removeFirst()
        let decision: [String: Any]
        switch choice {
        case .handOff:
            p.client.reply() // empty = no decision, Claude keeps asking in its own UI
            sessions[sid] = s
            focus(s)
            return
        case .answer(let a):
            var input = p.input
            input["answers"] = a
            decision = ["behavior": "allow", "updatedInput": input]
        case .deny: decision = ["behavior": "deny", "message": "Denied from Ada"]
        case .once: decision = ["behavior": "allow"]
        case .always: decision = ["behavior": "allow", "updatedPermissions": p.suggestions]
        // Claude ignores this unless bypass was enabled at launch; then it is a plain allow.
        case .bypass: decision = ["behavior": "allow", "updatedPermissions": [["type": "setMode", "mode": "bypassPermissions", "destination": "session"]]]
        }
        let out = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        p.client.reply((try? JSONSerialization.data(withJSONObject: out)) ?? Data())
        s.status = s.permissions.isEmpty ? .working : .waiting
        sessions[sid] = s
    }

    /// Latest `custom-title` entry in the transcript; Claude Code repeats it every few lines, so the tail is enough.
    static func chatTitle(_ path: String?) -> String? {
        guard let path, let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > 262_144 ? end - 262_144 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.contains("\"custom-title\"") {
            if let j = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
               let t = j["customTitle"] as? String, !t.isEmpty { return t }
        }
        return nil
    }

    private func describe(_ tool: String?, _ input: [String: Any]?) -> String? {
        guard let tool else { return nil }
        let i = input ?? [:]
        let detail = i["command"] ?? i["file_path"] ?? i["pattern"] ?? i["url"] ?? i["description"]
        return detail.map { "\(tool) · \($0)" } ?? tool
    }

    func focus(_ s: Session) {
        defer { setExpanded(false) }
        // Desktop sessions: the app's own "continue session" link selects that chat and restores a minimized window.
        if let h = s.hostID, let link = URL(string: "claude://code/continue?session=\(h)") {
            NSWorkspace.shared.open(link)
            return
        }
        guard let b = s.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { return }
        // Re-open like a Dock click: activate() alone is refused for a background app and leaves minimized windows in the Dock.
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Hook went away: the request was answered somewhere else.
    private func drop(_ sid: String, _ pid: UUID) {
        guard var s = sessions[sid] else { return }
        s.permissions.removeAll { $0.id == pid }
        if s.permissions.isEmpty && s.status == .waiting { s.status = .working }
        sessions[sid] = s
    }

    /// Turn moved on, so any open request is stale. An empty reply means "no decision".
    private func release(_ s: inout Session) {
        s.permissions.forEach { $0.client.reply() }
        s.permissions = []
    }

    /// ponytail: in-memory only, sessions vanish on restart. Persist if that gets annoying.
    private func prune() {
        let now = Date()
        sessions = sessions.filter { _, s in
            now.timeIntervalSince(s.updated) < 86400
        }
    }

    private func play(_ name: String) {
        if sound { NSSound(named: name)?.play() }
    }
}
