import Foundation

/// Wires Claude Code to Ada: installs hook.sh and Ada's hook entries in settings.json.
enum Setup {
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification",
                         "PreCompact", "SubagentStart", "SubagentStop", "Stop", "StopFailure", "SessionEnd"]
    static let matched: Set = ["PreToolUse", "PostToolUse", "PermissionRequest", "Notification"]

    /// Runs on every launch, so hook.sh updates ship with the app. Skips settings when Claude Code isn't installed.
    /// Returns what happened, in words, for the first-launch welcome.
    @discardableResult
    static func onLaunch() -> String {
        let home = NSHomeDirectory()
        var isDir: ObjCBool = false
        do {
            try copyHook(to: home + "/.ada/hook.sh")
            guard FileManager.default.fileExists(atPath: home + "/.claude", isDirectory: &isDir), isDir.boolValue else {
                return "Claude Code isn't installed yet. Install it, then reopen Ada."
            }
            let wrote = try apply(settings: home + "/.claude/settings.json", hook: home + "/.ada/hook.sh", install: true)
            return wrote ? "Added Ada's hooks to ~/.claude/settings.json (old file saved as settings.json.bak-ada)."
                         : "Ada's hooks are already set up in ~/.claude/settings.json."
        } catch {
            NSLog("ada: setup: \(error.localizedDescription)")
            return "Couldn't set up Claude Code hooks: \(error.localizedDescription)"
        }
    }

    /// `Ada --install-hooks|--uninstall-hooks <settings.json> <hook-path>`: runs setup on those paths and exits, no UI.
    static func cli(_ args: [String]) {
        guard args.count == 4, let install = ["--install-hooks": true, "--uninstall-hooks": false][args[1]] else { return }
        do {
            if install { try copyHook(to: args[3]) }
            let wrote = try apply(settings: args[2], hook: args[3], install: install)
            print(wrote ? (install ? "installed in " : "removed from ") + args[2] : "already current: " + args[2])
            exit(0)
        } catch {
            fputs("ada: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    /// Copies the bundled hook.sh to `path` (0755). No-op outside the .app bundle.
    static func copyHook(to path: String) throws {
        guard let src = Bundle.main.url(forResource: "hook", withExtension: "sh") else { return }
        let data = try Data(contentsOf: src), url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if (try? Data(contentsOf: url)) != data {
            try data.write(to: url, options: .atomic) // a new inode, so a hook running right now keeps reading the old one
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// Removes Ada's entries from `settings`, then re-adds them when installing. Writes only when that changes
    /// something, after backing the old file up to settings.json.bak-ada. Everything else is left as it was.
    @discardableResult
    static func apply(settings: String, hook: String, install: Bool) throws -> Bool {
        let url = URL(fileURLWithPath: settings)
        let old = FileManager.default.fileExists(atPath: settings) ? try Data(contentsOf: url) : Data()
        let corrupt = CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: settings])
        let blank = old.allSatisfy { " \t\r\n".utf8.contains($0) }
        guard let original = blank ? [:] : try JSONSerialization.jsonObject(with: old) as? [String: Any] else { throw corrupt }
        guard original["hooks"] == nil || original["hooks"] is [String: Any] else { throw corrupt } // never clobber what we can't read

        func ours(_ h: Any) -> Bool { ((h as? [String: Any])?["command"] as? String)?.contains(hook) == true }
        var cfg = original, hooks = original["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let kept = groups.compactMap { g -> Any? in
                guard var d = g as? [String: Any], let hs = d["hooks"] as? [Any], hs.contains(where: ours) else { return g }
                let rest = hs.filter { !ours($0) }
                d["hooks"] = rest
                return rest.isEmpty ? nil : d
            }
            hooks[event] = kept.isEmpty && !groups.isEmpty ? nil : kept
        }
        if install {
            for e in events {
                var h: [String: Any] = ["type": "command", "command": "'\(hook)'"]
                if e == "PermissionRequest" { h["timeout"] = 86400 } // the hook waits until you click on the island
                var group: [String: Any] = ["hooks": [h]]
                if matched.contains(e) { group["matcher"] = "*" }
                hooks[e] = (hooks[e] as? [Any] ?? []) + [group]
            }
        }
        cfg["hooks"] = hooks.isEmpty ? nil : hooks
        if NSDictionary(dictionary: cfg).isEqual(to: original) { return false }

        if !old.isEmpty { try old.write(to: URL(fileURLWithPath: settings + ".bak-ada")) }
        // ponytail: JSONSerialization can't keep key order, so a rewrite sorts keys; values are untouched.
        var out = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        out.append(0x0A)
        try out.write(to: url) // in place, so a symlinked settings.json stays a symlink
        return true
    }
}
