// Menu bar panels built in SwiftUI and hosted in NSMenuItem views. Clicks inside a view are handled by the view,
// so the menu stays open; it closes when the user clicks outside it (or picks a regular menu item).
import AppKit
import SwiftUI

let menuWidth: CGFloat = 280

/// A menu item whose content is a SwiftUI view. Menus don't resize item views on their own: call `fit()` after the
/// content changes height (a preset saved, a row shown).
final class HostedMenuItem<Content: View>: NSMenuItem {
    let host: NSHostingView<Content>
    init(_ view: Content) {
        host = NSHostingView(rootView: view)
        super.init(title: "", action: nil, keyEquivalent: "")
        self.view = host
        fit()
    }
    required init(coder: NSCoder) { fatalError() }
    func fit() {
        host.frame.size = NSSize(width: menuWidth, height: 10)
        host.layoutSubtreeIfNeeded()
        let h = host.fittingSize.height
        host.frame = NSRect(x: 0, y: 0, width: menuWidth, height: h)
    }
}

/// Control Center style switch row: the label on the left, a small switch on the right.
struct MenuSwitchRow: View {
    let title: () -> String
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            Text(title()).font(.system(size: 13))
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }  // the whole row is the target, like Control Center
    }
}

struct LinkRow: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        let _ = model.lang
        MenuSwitchRow(title: { t("Link Left and Right Volume", "左右聲道音量連動") }, isOn: $model.linkPair)
    }
}

struct KeysRow: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        let _ = model.lang
        MenuSwitchRow(title: { t("Volume Keys Control All Speakers", "鍵盤音量鍵控制全部喇叭") }, isOn: $model.keysControlAll)
    }
}

/// The equalizer: preset chips, five vertical faders (0 dB in the middle), save / delete.
struct EqMenuView: View {
    @ObservedObject var model: SettingsModel
    let save: () -> Void
    static let bands: [(freq: String, en: String, zh: String)] = [
        ("80", "Bass", "低音"), ("250", "Low mid", "中低"), ("1k", "Mid", "中音"),
        ("4k", "High mid", "中高"), ("12k", "Treble", "高音"),
    ]

    var body: some View {
        let _ = model.lang
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Equalizer", "等化器")).font(.system(size: 13, weight: .semibold))
            ChipFlow(spacing: 5) {
                ForEach(eqPresets.indices, id: \.self) { i in
                    chip(t(eqPresets[i].en, eqPresets[i].zh), tag: "b:\(i)")
                }
                ForEach(model.userEqPresets, id: \.name) { p in chip(p.name, tag: "u:" + p.name) }
                chip(t("Custom", "自訂"), tag: "custom")
            }
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { b in
                    Fader(value: model.eq[b], set: { model.setEq(b, $0) },
                          freq: Self.bands[b].freq, name: t(Self.bands[b].en, Self.bands[b].zh))
                        .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 8) {
                Text(t("Double-click a fader to reset it.", "雙擊推桿歸零"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                if model.eqSelection.hasPrefix("u:") {
                    Button(t("Delete", "刪除")) { model.deleteEqPreset(String(model.eqSelection.dropFirst(2))) }
                }
                Button(t("Save…", "儲存…"), action: save)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: menuWidth, alignment: .leading)
    }

    func chip(_ title: String, tag: String) -> some View {
        let on = model.eqSelection == tag
        return Text(title)
            .font(.system(size: 11, weight: on ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(Capsule().fill(on ? Color.accentColor : Color.primary.opacity(0.08)))
            .contentShape(Capsule())
            .onTapGesture { model.selectEq(tag) }
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.selectEq(tag) }
    }
}

/// A vertical fader for -12…12 dB in 1 dB steps. The bar grows from the 0 dB line, up for boost, down for cut.
struct Fader: View {
    let value: Int
    let set: (Int) -> Void
    let freq: String
    let name: String
    static let trackHeight: CGFloat = 132
    static let knob: CGFloat = 14

    var body: some View {
        VStack(spacing: 4) {
            Text(value > 0 ? "+\(value)" : "\(value)")
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(value == 0 ? .secondary : .primary)
            GeometryReader { g in
                let h = g.size.height, mid = h / 2
                let travel = h - Self.knob
                let y = mid - CGFloat(value) / 12 * travel / 2  // knob centre
                ZStack(alignment: .top) {
                    Capsule().fill(Color.primary.opacity(0.10)).frame(width: 4)
                    // 0 dB 的刻度比圓鈕寬，推桿停在 0 時兩側還看得到
                    Capsule().fill(Color.primary.opacity(0.35)).frame(width: 24, height: 2).offset(y: mid - 1)
                    Capsule().fill(Color.accentColor)
                        .frame(width: 4, height: abs(y - mid))
                        .offset(y: min(y, mid))
                    Circle().fill(.white).shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                        .frame(width: Self.knob, height: Self.knob)
                        .offset(y: y - Self.knob / 2)
                }
                .frame(width: g.size.width, height: h)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                    let v = Int(((mid - d.location.y) / (travel / 2) * 12).rounded())
                    let clamped = max(-12, min(12, v))
                    if clamped != value { set(clamped) }
                })
                .simultaneousGesture(TapGesture(count: 2).onEnded { set(0) })
            }
            .frame(height: Self.trackHeight)
            Text(freq).font(.system(size: 10, weight: .medium)).monospacedDigit()
            Text(name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement()
        .accessibilityLabel("\(name) \(freq) Hz")
        .accessibilityValue("\(value) dB")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: set(min(12, value + 1))
            case .decrement: set(max(-12, value - 1))
            @unknown default: break
            }
        }
    }
}

/// Lays chips out left to right and wraps to the next line when the row is full.
struct ChipFlow: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var cur: [Int] = [], w: CGFloat = 0, h: CGFloat = 0
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            if !cur.isEmpty, w + spacing + s.width > width {
                rows.append((cur, w, h)); cur = []; w = 0; h = 0
            }
            w += (cur.isEmpty ? 0 : spacing) + s.width
            h = max(h, s.height)
            cur.append(i)
        }
        if !cur.isEmpty { rows.append((cur, w, h)) }
        return rows
    }
}
