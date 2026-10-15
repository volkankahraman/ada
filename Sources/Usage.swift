import Foundation
import SwiftUI

/// Claude plan limits from the OAuth usage API, using Claude Code's login in the keychain.
/// The desktop app has no statusline, so this is the only source that works without the CLI.
struct Usage: Equatable {
    let percent: Double
    let resets: Date?

    /// The 5-hour session window. Weekly caps are skipped: this plan only has a model-scoped one.
    init?(_ j: [String: Any]) {
        if let w = j["five_hour"] as? [String: Any], let p = w["utilization"] as? Double {
            percent = p
            resets = (w["resets_at"] as? String).flatMap(parseDate)
        } else if let l = (j["limits"] as? [[String: Any]])?.first(where: { $0["group"] as? String == "session" }),
                  let p = l["percent"] as? Double {
            percent = p
            resets = (l["resets_at"] as? String).flatMap(parseDate)
        } else {
            return nil
        }
    }
}

private func parseDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

enum ClaudeAuthError: LocalizedError {
    case noLogin, refreshFailed(Int), http(Int)
    var errorDescription: String? {
        switch self {
        case .noLogin: "No Claude Code login in keychain"
        case .refreshFailed(let c): "Login expired (refresh \(c))"
        case .http(let c): "Usage API \(c)"
        }
    }
}

/// Reads the "Claude Code-credentials" keychain item, refreshes the token when it expires and writes it back,
/// exactly like Claude Code does, so the CLI stays logged in too.
/// ponytail: no lock against a CLI refreshing at the same moment; fine while the CLI is rarely used.
enum ClaudeAuth {
    static let service = "Claude Code-credentials"
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" // Claude Code's public OAuth client
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func usage() async throws -> Usage? {
        var creds = try read()
        guard var oauth = creds["claudeAiOauth"] as? [String: Any] else { throw ClaudeAuthError.noLogin }
        var refreshed = false
        if (oauth["expiresAt"] as? Double ?? 0) / 1000 < Date().timeIntervalSince1970 + 60 {
            oauth = try await refresh(oauth, &creds)
            refreshed = true
        }
        var (data, code) = try await get(oauth)
        if code == 401 && !refreshed {
            oauth = try await refresh(oauth, &creds)
            (data, code) = try await get(oauth)
        }
        guard code == 200 else { throw ClaudeAuthError.http(code) }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap(Usage.init)
    }

    private static func get(_ oauth: [String: Any]) async throws -> (Data, Int) {
        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(oauth["accessToken"] as? String ?? "")", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func refresh(_ oauth: [String: Any], _ creds: inout [String: Any]) async throws -> [String: Any] {
        guard let token = oauth["refreshToken"] as? String else { throw ClaudeAuthError.noLogin }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": token,
            "client_id": clientID,
            "scope": (oauth["scopes"] as? [String] ?? []).joined(separator: " "),
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = j["access_token"] as? String
        else { throw ClaudeAuthError.refreshFailed(code) }
        var o = oauth
        o["accessToken"] = access
        o["refreshToken"] = j["refresh_token"] as? String ?? token
        o["expiresAt"] = (Date().timeIntervalSince1970 + (j["expires_in"] as? Double ?? 3600)) * 1000
        creds["claudeAiOauth"] = o
        try write(creds) // the old refresh token is now spent; losing this write means logging in again
        return o
    }

    // MARK: keychain via /usr/bin/security, which already has access to Claude Code's item (no prompt)

    private static func read() throws -> [String: Any] {
        let out = try security(["find-generic-password", "-s", service, "-w"])
        guard let j = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any] else { throw ClaudeAuthError.noLogin }
        return j
    }

    private static func write(_ creds: [String: Any]) throws {
        let hex = try JSONSerialization.data(withJSONObject: creds).map { String(format: "%02x", $0) }.joined()
        // `security -i` takes the command on stdin, so the token never shows up in `ps`.
        _ = try security(["-i"], stdin: "add-generic-password -U -a \"\(NSUserName())\" -s \"\(service)\" -X \(hex)\n")
    }

    @discardableResult
    private static func security(_ args: [String], stdin: String? = nil) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = inp
        try p.run()
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
        try inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ClaudeAuthError.noLogin }
        return data
    }
}

struct UsageBar: View {
    let usage: Usage

    var body: some View {
        let reset = (usage.resets ?? .distantFuture) < Date() // window rolled over since the last fetch
        let p = reset ? 0 : usage.percent
        HStack(spacing: 6) {
            Text("Claude 5h").foregroundStyle(.secondary)
            Text("\(Int(p.rounded()))%").foregroundStyle(p < 50 ? Color.green : p < 80 ? Color.orange : Color.red)
            if let r = usage.resets, !reset { Text(left(r)).foregroundStyle(.tertiary) }
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
    }

    private func left(_ d: Date) -> String {
        let m = max(0, Int(d.timeIntervalSinceNow / 60))
        return m >= 1440 ? "\(m / 1440)d" : m >= 60 ? "\(m / 60)h\(m % 60)m" : "\(m)m"
    }
}
