import AppKit
import SwiftUI

private let mono = Font.system(size: 12, weight: .semibold, design: .monospaced)

struct IslandView: View {
    @ObservedObject var store: Store

    var body: some View {
        let open = store.expanded
        let size = store.islandSize
        let shape = NotchShape(top: store.ear, bottom: open ? 24 : 12)
        // One black shape that grows out of the notch; the content fades in once it has room.
        ZStack(alignment: .top) {
            shape.fill(.black)
            if open {
                expanded
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { store.expandedHeight = $0 }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .top))
                            .animation(.spring(duration: 0.4).delay(0.1)),
                        removal: .opacity.animation(.easeOut(duration: 0.1))))
            } else {
                collapsed.transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    // MARK: collapsed pill around the notch

    private var collapsed: some View {
        let n = store.active.count
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                if let s = store.overall {
                    StatusIcon(status: s)
                    Text(label(s)).foregroundStyle(color(s))
                }
            }
            .padding(.leading, 10)
            .frame(width: store.wing, alignment: .leading)
            Color.clear.frame(width: store.notchWidth)
            Text(n == 0 ? "" : "\(n) session\(n == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
                .padding(.trailing, 10)
                .frame(width: store.wing, alignment: .trailing)
        }
        .font(mono)
        .lineLimit(1)
        .frame(height: store.notchHeight)
        .contentShape(Rectangle())
        .onTapGesture { store.setExpanded(true) }
    }

    private func label(_ s: Status) -> String {
        switch s {
        case .waiting: "Needs you"
        case .working: "Working…"
        case .done: "Done"
        }
    }

    // MARK: expanded list

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let u = store.usage {
                    UsageBar(usage: u)
                } else {
                    Text(store.usageError.map { "Ada · \($0)" } ?? "Ada").font(mono).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.sound.toggle() } label: {
                    Image(systemName: store.sound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(height: store.notchHeight)
            .contentShape(Rectangle())
            .onTapGesture { store.setExpanded(false) }

            if store.sessions.isEmpty {
                Text("No sessions yet").foregroundStyle(.secondary).padding(.vertical, 12)
            }
            // ponytail: capped at 6 rows instead of a scroll view; add scrolling if you run more.
            ForEach(store.sorted.prefix(6)) { SessionRow(session: $0, store: store) }
        }
        .padding(.horizontal, 18 + store.ear)
        .padding(.bottom, 14)
        .frame(width: store.islandSize.width)
    }
}

/// Notch silhouette: the top corners curve outward into the menu bar, the bottom corners are rounded.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { (top, bottom) = (newValue.first, newValue.second) }
    }

    func path(in r: CGRect) -> Path {
        let b = min(bottom, r.height - top, (r.width - 2 * top) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + b, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - b), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

func color(_ s: Status) -> Color {
    switch s {
    case .waiting: .orange
    case .working: .blue
    case .done: .green
    }
}

struct StatusIcon: View {
    let status: Status
    var body: some View {
        switch status {
        // Opacity steps a few times per second. symbolEffect and variableValue changes both redraw at full display rate (~20% CPU idle).
        case .working:
            TimelineView(.periodic(from: .now, by: 0.35)) { t in
                let step = Int(t.date.timeIntervalSinceReferenceDate / 0.35) % 4
                Image(systemName: "waveform").foregroundStyle(.blue).opacity([0.45, 0.7, 1, 0.7][step])
            }
        case .waiting:
            TimelineView(.periodic(from: .now, by: 0.7)) { t in
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                    .opacity(Int(t.date.timeIntervalSinceReferenceDate / 0.7) % 2 == 0 ? 1 : 0.45)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

struct SessionRow: View {
    let session: Session
    let store: Store

    var body: some View {
        let s = session
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                StatusIcon(status: s.status).frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text((s.project.map { "\($0) · " } ?? "") + oneLine(s.headline))
                        .font(.system(size: 13, weight: .semibold))
                    if let p = s.prompt { Text("You: \(oneLine(p))").foregroundStyle(.secondary) }
                    if s.status == .working || s.status == .waiting, let a = s.activity, s.permissions.isEmpty {
                        Text(oneLine(a)).font(.system(size: 11, design: .monospaced)).foregroundStyle(color(s.status).opacity(0.8))
                    } else if let r = s.reply, s.permissions.isEmpty {
                        Text(oneLine(r)).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if s.subagents > 0 { Tag(text: "+\(s.subagents) agent\(s.subagents == 1 ? "" : "s")") }
                if let app = s.appName { Tag(text: app) }
                TimelineView(.periodic(from: .now, by: 30)) { _ in Tag(text: age(s.updated)) }
            }
            if let p = s.permissions.first {
                if p.tool == "AskUserQuestion" {
                    QuestionCard(permission: p, session: s, store: store).id(p.id)
                } else {
                    PermissionCard(permission: p, session: s, store: store)
                }
            }
        }
        .font(.system(size: 12))
        .padding(10)
        .background(s.permissions.isEmpty ? .clear : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { store.focus(s) }
    }

    private func oneLine(_ t: String) -> String {
        t.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private func age(_ d: Date) -> String {
        let m = Int(-d.timeIntervalSinceNow / 60)
        return m < 1 ? "<1m" : m < 60 ? "\(m)m" : m < 1440 ? "\(m / 60)h" : "\(m / 1440)d"
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
    }
}

/// Claude's multiple-choice question, answered right on the island.
struct QuestionCard: View {
    let permission: Permission
    let session: Session
    let store: Store
    @State private var picks: [String: [String]] = [:] // question text -> chosen labels, in tap order

    private var questions: [[String: Any]] { permission.input["questions"] as? [[String: Any]] ?? [] }
    private var ready: Bool { questions.allSatisfy { !(picks[$0["question"] as? String ?? ""] ?? []).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                question(q)
            }
            HStack(spacing: 8) {
                Button { store.decide(session.id, .handOff) } label: { pill("Answer in Claude", .white.opacity(0.12), .white) }
                Button {
                    store.decide(session.id, .answer(picks.mapValues { $0.joined(separator: ", ") }))
                } label: { pill("Send", ready ? .orange : .white.opacity(0.06), ready ? .black : .gray) }
                .disabled(!ready)
            }
            .buttonStyle(.plain)
        }
    }

    private func question(_ q: [String: Any]) -> some View {
        let text = q["question"] as? String ?? ""
        let multi = q["multiSelect"] as? Bool ?? false
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let h = q["header"] as? String { Tag(text: h) }
                Text(text).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array((q["options"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, o in
                let label = o["label"] as? String ?? ""
                let on = picks[text]?.contains(label) ?? false
                Button { toggle(text, label, multi) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: multi ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                            .foregroundStyle(on ? Color.orange : Color.gray)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label).font(.system(size: 12, weight: .medium))
                            if let d = o["description"] as? String {
                                Text(d).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(on ? Color.orange.opacity(0.18) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggle(_ q: String, _ label: String, _ multi: Bool) {
        var cur = picks[q] ?? []
        if multi {
            if let i = cur.firstIndex(of: label) { cur.remove(at: i) } else { cur.append(label) }
        } else {
            cur = [label]
        }
        picks[q] = cur
    }

    private func pill(_ title: String, _ bg: Color, _ fg: Color) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(bg, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PermissionCard: View {
    let permission: Permission
    let session: Session
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(permission.tool, systemImage: "exclamationmark.triangle.fill")
                .font(mono).foregroundStyle(.orange)
            Text(preview)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                button("Deny", .white.opacity(0.12), .white, .deny)
                button("Allow Once", .white, .black, .once)
                if !permission.suggestions.isEmpty { button("Allow All", .orange, .black, .always) }
                button("Bypass", .red.opacity(0.8), .white, .bypass)
            }
            if session.permissions.count > 1 {
                Text("+\(session.permissions.count - 1) more waiting").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func button(_ title: String, _ bg: Color, _ fg: Color, _ choice: Choice) -> some View {
        Button { store.decide(session.id, choice) } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(fg)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(bg, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var preview: String {
        let i = permission.input
        let text: String
        switch permission.tool {
        case "Bash": text = i["command"] as? String ?? ""
        case "Write": text = "\(i["file_path"] ?? "")\n\(i["content"] ?? "")"
        case "Edit": text = "\(i["file_path"] ?? "")\n- \(i["old_string"] ?? "")\n+ \(i["new_string"] ?? "")"
        default:
            let data = try? JSONSerialization.data(withJSONObject: i, options: [.prettyPrinted, .sortedKeys])
            text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        return String(text.prefix(800))
    }
}
