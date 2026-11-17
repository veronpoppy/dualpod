// Settings window: the things you set once (which HomePod is left, Mac speaker offset, language).
// The menu bar keeps only what you use every day: picking outputs and their volume.
import AVFoundation
import AppKit
import SwiftUI

let leftFile = wantFile.deletingLastPathComponent().appendingPathComponent("left")
let syncFile = wantFile.deletingLastPathComponent().appendingPathComponent("mac-sync-ms")
let glowFile = wantFile.deletingLastPathComponent().appendingPathComponent("glow")
// Equalizer, five bands (80 Hz, 250 Hz, 1 kHz, 4 kHz, 12 kHz) in dB, -12…12 each; the service checks it and the stream picks it up within a moment
let eqFile = wantFile.deletingLastPathComponent().appendingPathComponent("eq")
func parseEq(_ raw: String) -> [Int] {
    let g = raw.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Int($0) }
    guard (g.count == 3 || g.count == 5), g.allSatisfy({ (-12...12).contains($0) }) else { return [0, 0, 0, 0, 0] }
    return g.count == 5 ? g : [g[0], 0, g[1], 0, g[2]]  // an older three-band setting
}
let eqPresets: [(en: String, zh: String, gains: [Int])] = [
    ("Flat", "原音", [0, 0, 0, 0, 0]),
    ("Bass Boost", "加強低音", [4, 2, 0, 0, 0]),
    ("Vocal", "人聲", [-2, -1, 2, 2, 0]),
    ("Bright", "明亮", [0, 0, 0, 2, 3]),
    ("Late Night", "夜間小聲", [-4, -2, 1, 0, -2]),
]
let alignRestoreFile = wantFile.deletingLastPathComponent().appendingPathComponent("align-restore")

func readSetting(_ url: URL) -> String {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}
/// 和 helper 的 read_user 一樣讀 glow 檔：不跟隨 symlink、非阻塞、只讀前 64 bytes；空白與換行由 parseGlow 去掉，其他字元（tab、CR）不去，所以兩邊對同一個檔判斷一致
func readGlowFile(_ url: URL = glowFile) -> String {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { return "" }
    defer { close(fd) }
    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(fd, &buf, 64)
    return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
}
@discardableResult
func writeSetting(_ url: URL, _ text: String) -> Bool {
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        return true
    } catch {
        NSSound.beep()  // nothing changed on screen either, so the user can just try again
        return false
    }
}

/// Sound Glow colors. The names and colors must match GLOW_PRESETS in stereo.sh: the app only writes the name,
/// the service turns it into the colors, and the swatches here are just for display.
/// parseGlow below must accept exactly what glow_colors in stereo.sh accepts.
let glowPresets: [(name: String, en: String, zh: String, hex: [String])] = [
    ("warm", "Warm", "暖色", ["FF2D2D", "FF8C00", "FFD400"]),
    ("cool", "Cool", "冷色", ["1E40FF", "8A2BE2", "00B4FF"]),
    ("aurora", "Aurora", "極光", ["00C853", "00E5C0", "7CFC00"]),
    ("candy", "Candy", "糖果", ["FF4FA3", "B14CFF", "4CC9FF"]),
]
/// 規則同 stereo.sh 的 glow_colors：去掉空白與換行，preset 名稱要在表內，custom 是 1 到 3 個 #RRGGBB；其他一律當 off
func parseGlow(_ raw: String) -> String {
    let v = raw.filter { $0 != " " && $0 != "\n" }
    if v.hasPrefix("preset:"), glowPresets.contains(where: { "preset:" + $0.name == v }) { return v }
    if v.range(of: "^custom:#[0-9A-Fa-f]{6}(,#[0-9A-Fa-f]{6}){0,2}\\z", options: .regularExpression) != nil { return v }
    return "off"
}
extension Color {
    init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0
        self.init(.sRGB, red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

final class SettingsModel: ObservableObject {
    // The service reads both files when it (re)starts the stream and restarts on change
    @Published var left = readSetting(leftFile)  // a speaker id; the service falls back to the first of the pair
    @Published var playing: [String] = []  // speakers playing now (not the Mac), sorted by id
    @Published var switching = false  // outputs picked in the menu, the service isn't there yet
    @Published var names: [String: String] = [:]
    @Published var sync = Int(readSetting(syncFile)) ?? 0 {  // what the field shows
        didSet {
            if sync != max(-100, min(100, sync)) { sync = max(-100, min(100, sync)) }
            if sync != appliedSync, !aligning { syncStatus = "" }  // "Saved" or "Done" is about the old value
        }
    }
    @Published var appliedSync = Int(readSetting(syncFile)) ?? 0  // what's saved for the service
    @Published var canAlign = false  // the Mac and at least one HomePod are playing
    @Published var aligning = false
    @Published var syncStatus = ""
    @Published var helper = "ok"  // "missing", "outdated", "stopped", "ok"
    @Published var helperBusy = false
    @Published var lang = langSetting { didSet { langSetting = lang; onLangChange() } }
    @Published var autoUpdateCheck = UserDefaults.standard.object(forKey: "checkUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoUpdateCheck, forKey: "checkUpdates") }
    }
    @Published var update = UpdateState.idle { didSet { onUpdateChange() } }
    @Published var foundTag: String? { didSet { onUpdateChange() } }  // newest release seen; stays while checking again
    var onUpdateChange: () -> Void = {}
    /// "off", "preset:<name>" or "custom:#RRGGBB"; the service reads it when playback starts and when it changes
    @Published private(set) var eq = parseEq(readSetting(eqFile))
    func setEq(_ band: Int, _ db: Int) {
        var g = eq
        g[band] = max(-12, min(12, db))
        setEq(g)
    }
    func setEq(_ g: [Int]) {
        guard g != eq else { return }
        if writeSetting(eqFile, g.map(String.init).joined(separator: " ")) { eq = g }
    }
    @Published private(set) var glow = parseGlow(readGlowFile())
    /// Saves first and updates the UI only if that worked, so a failed write leaves the old state and picking again retries
    func setGlow(_ v: String) {
        if writeSetting(glowFile, v) { glow = v; if v.hasPrefix("custom:#") { lastCustom = v } }
    }
    /// 切去預設色再切回來時，自訂色要還在
    private(set) var lastCustom: String?
    /// 設定視窗每次出現都重讀，外部改了檔（例如手動編輯）才會反映出來
    func reloadGlow() {
        glow = parseGlow(readGlowFile())
        if glow.hasPrefix("custom:#") { lastCustom = glow }
    }
    init() { if glow.hasPrefix("custom:#") { lastCustom = glow } }
    private var glowBeforeOff = "preset:warm"
    var glowOn: Bool { glow != "off" }
    func setGlowOn(_ on: Bool) {
        if on { setGlow(glowBeforeOff) } else if glowOn { glowBeforeOff = glow; setGlow("off") }
    }
    var customGlow: Color {
        get { Color(hex: String((lastCustom ?? "custom:#FFFFFF").dropFirst(8).prefix(6))) }
        set { setGlow("custom:#" + newValue.hexString) }
    }
    var onLangChange: () -> Void = {}
    var pair: [String] { playing.count == 2 ? playing : [] }
    var pairReady: Bool { pair.count == 2 && !switching }
    var leftID: String { pair.contains(left) ? left : pair.first ?? "" }
    var rightID: String { pair.first { $0 != leftID } ?? "" }
    func name(_ id: String) -> String { names[id] ?? id }

    func swap() {
        let r = rightID
        if !r.isEmpty, writeSetting(leftFile, r) { left = r }
    }
    func applySync() {
        if writeSetting(syncFile, String(sync)) {
            appliedSync = sync
            syncStatus = t("Saved. The speakers reconnect for a few seconds.", "已儲存，喇叭會重新連線幾秒。")
        }
    }
    func revertSync() { sync = appliedSync }
}

/// Plays a soft chime on the left channel, then a higher one on the right, through the normal system
/// output, so it takes the same path as everything else and comes out of whichever HomePod has that channel.
final class ChannelTest {
    private var players: [AVAudioPlayer] = []

    /// A small bell: two notes a third apart, a few milliseconds of fade-in, a gentle decay,
    /// and a quiet octave partial for warmth. Mono 16-bit WAV in memory.
    static func chime(_ notes: [Double], fs: Double = 44100, seconds: Double = 1.2) -> Data {
        let n = Int(fs * seconds)
        var pcm = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / fs
            var x = 0.0
            for (k, f) in notes.enumerated() {
                let start = Double(k) * 0.07  // the upper note rolls in just after the lower one
                guard t >= start else { continue }
                let u = t - start
                let env = min(1, u / 0.005) * exp(-u / 0.32)
                x += env * (sin(2 * .pi * f * u) + 0.22 * sin(4 * .pi * f * u) * exp(-u / 0.12))
            }
            pcm[i] = Int16(max(-1, min(1, x * 0.22)) * 32767)
        }
        return wav(pcm, fs: fs)
    }

    static func wav(_ pcm: [Int16], fs: Double) -> Data {
        let n = pcm.count
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + n * 2).littleEndian)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16).littleEndian)
        put(UInt16(1).littleEndian); put(UInt16(1).littleEndian)
        put(UInt32(fs).littleEndian); put(UInt32(fs * 2).littleEndian)
        put(UInt16(2).littleEndian); put(UInt16(16).littleEndian)
        d.append(contentsOf: Array("data".utf8)); put(UInt32(n * 2).littleEndian)
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    /// One channel: left is A4 + C#5, right a third higher (E5 + G#5), so the two sides also sound different.
    func play(right: Bool) {
        guard let p = try? AVAudioPlayer(data: Self.chime(right ? [659.26, 830.61] : [440.0, 554.37])) else { NSSound.beep(); return }
        p.pan = right ? 1 : -1
        players = [p]
        p.play()
    }
}

/// The two Settings panes. Audio is what people come for; General holds the rarely touched upkeep.
struct AudioPane: View {
    @ObservedObject var model: SettingsModel
    let playChannel: (_ right: Bool) -> Void
    let autoAlign: () -> Void
    let installHelper: () -> Void
    let openMenu: () -> Void

    var body: some View {
        let _ = model.lang  // t() reads the global language; this makes the view redraw when it changes
        Form {
            if model.helper != "ok" {
                Section { HelperProblem(model: model, install: installHelper) }
            }
            Section {
                if model.pair.count == 2 {
                    pairDiagram
                } else {
                    LabeledContent {
                        Button(t("Show Speakers", "打開喇叭選單"), action: openMenu)
                    } label: {
                        Text(model.switching ? t("Switching speakers…", "正在切換喇叭…")
                             : model.playing.count == 1
                             ? t("Playing on \(model.name(model.playing[0])) only", "目前只播 \(model.name(model.playing[0]))")
                             : t("No speakers selected", "還沒選喇叭"))
                        Text(t("Select two speakers to play left and right.", "勾選兩台喇叭，就能分左右聲道。"))
                    }
                }
            } header: {
                Text(t("Stereo Pair", "左右聲道"))
            } footer: {
                if model.pair.count == 2 {
                    Text(model.switching ? t("The speakers are reconnecting.", "喇叭重新連線中。")
                         : t("Click a speaker to hear a chime from it. If it comes from the wrong side, swap them; the speakers reconnect for a few seconds.",
                             "點喇叭會從它那一邊響一聲。方向不對就按中間交換，喇叭會重新連線幾秒。"))
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent(t("Offset", "時間差")) {
                    HStack(spacing: 4) {
                        TextField(t("Offset", "時間差"), value: $model.sync, format: .number)
                            .labelsHidden().multilineTextAlignment(.trailing).frame(width: 52)
                        Text("ms").foregroundStyle(.secondary)
                        Stepper(t("Offset", "時間差"), value: $model.sync, in: -100...100).labelsHidden()
                    }
                    .disabled(model.aligning)  // auto-align writes this value when it finishes
                }
                if model.sync != model.appliedSync {
                    LabeledContent {
                        HStack {
                            Button(t("Revert", "還原"), action: model.revertSync)
                            Button(t("Apply", "套用")) {
                                // a click doesn't take focus, so the field may still hold typed text: commit it first
                                NSApp.keyWindow?.makeFirstResponder(nil)
                                DispatchQueue.main.async { model.applySync() }
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                        .disabled(model.aligning)  // a write now would restart the stream mid-measurement
                    } label: {
                        Text(t("Not applied", "尚未套用"))
                        Text(t("The speakers reconnect for a few seconds.", "套用時喇叭會重新連線幾秒。"))
                    }
                }
                LabeledContent {
                    Button(t("Align Automatically…", "自動對齊…"), action: autoAlign)
                        .disabled(!model.canAlign || model.aligning)
                } label: {
                    Text(t("Hear an echo?", "聽到回音？"))
                    Text(model.canAlign || model.aligning
                         ? t("Uses the microphone for about a minute. Keep the room quiet.", "會用麥克風錄約一分鐘，請保持安靜。")
                         : t("Select This Mac and a HomePod to use it.", "要同時勾選這台 Mac 和一台 HomePod 才能用。"))
                }
                if !model.syncStatus.isEmpty {
                    HStack(spacing: 6) {
                        if model.aligning { ProgressView().controlSize(.small) }
                        Text(model.syncStatus).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(t("This Mac's Speakers", "這台 Mac 的喇叭"))
            } footer: {
                Text(model.sync == 0 ? t("The Mac plays together with the HomePods.", "Mac 和 HomePod 同時播。")
                     : model.sync < 0 ? t("The Mac plays \(-model.sync) ms earlier than the HomePods.", "Mac 比 HomePod 早 \(-model.sync) ms 播。")
                     : t("The Mac plays \(model.sync) ms later than the HomePods.", "Mac 比 HomePod 晚 \(model.sync) ms 播。"))
                    .foregroundStyle(.secondary)
            }
            Section {
                eqBand(0, t("Bass", "低音"), "80 Hz")
                eqBand(1, t("Low Mid", "中低"), "250 Hz")
                eqBand(2, t("Mid", "中音"), "1 kHz")
                eqBand(3, t("High Mid", "中高"), "4 kHz")
                eqBand(4, t("Treble", "高音"), "12 kHz")
                LabeledContent(t("Preset", "預設")) {
                    Picker(t("Preset", "預設"), selection: Binding(
                        get: { eqPresets.firstIndex { $0.gains == model.eq } ?? -1 },
                        set: { if eqPresets.indices.contains($0) { model.setEq(eqPresets[$0].gains) } })) {
                        if !eqPresets.contains(where: { $0.gains == model.eq }) { Text(t("Custom", "自訂")).tag(-1) }
                        ForEach(eqPresets.indices, id: \.self) { Text(t(eqPresets[$0].en, eqPresets[$0].zh)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            } header: {
                Text(t("Equalizer", "等化器"))
            } footer: {
                Text(t("Applies to every speaker, including this Mac, within a moment. Raising a band lowers everything a little so loud songs don't distort.",
                       "套用到所有喇叭（含這台 Mac），調了馬上生效。調高任一段時整體會小聲一點，避免爆音。"))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func eqBand(_ band: Int, _ name: String, _ freq: String) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { Double(model.eq[band]) }, set: { model.setEq(band, Int($0.rounded())) }),
                       in: -12...12, step: 1)
                    .frame(width: 200)
                Text(model.eq[band] > 0 ? "+\(model.eq[band]) dB" : "\(model.eq[band]) dB")
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
            }
        } label: {
            Text(name)
            Text(freq)
        }
    }

    /// Like the Home app's stereo pair screen: the left speaker on the left, the right one on the right.
    private var pairDiagram: some View {
        HStack(spacing: 20) {
            speaker(model.leftID, right: false)
            Button(action: model.swap) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .help(t("Swap Left and Right", "交換左右"))
            .accessibilityLabel(t("Swap Left and Right", "交換左右"))
            speaker(model.rightID, right: true)
        }
        .disabled(!model.pairReady)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func speaker(_ id: String, right: Bool) -> some View {
        Button { playChannel(right) } label: {
            VStack(spacing: 6) {
                Image(systemName: "homepodmini.fill").font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))
                Text(model.name(id)).lineLimit(1).truncationMode(.middle)
                Text(right ? t("Right", "右") : t("Left", "左")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 130)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(t("Play a chime on this side", "在這一邊響一聲"))
        .accessibilityLabel((right ? t("Right: ", "右聲道：") : t("Left: ", "左聲道：")) + model.name(id))
        .accessibilityHint(t("Plays a chime", "播放測試音"))
    }
}

/// 光暈控制的是燈不是聲音，所以自成一頁。
struct GlowPane: View {
    @ObservedObject var model: SettingsModel
    @State private var colorBridge = ColorPanelBridge()

    var body: some View {
        let _ = model.lang
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.glowOn }, set: { if !$0 { closeColorPanel() }; model.setGlowOn($0) })) {
                    Text(t("Light up the HomePods", "讓 HomePod 亮光暈"))
                    Text(t("Colors the light on top while streaming.", "串流時讓頂端的燈亮出顏色。"))
                }
                if model.glowOn {
                    glowChoices
                }
            } header: {
                Text(t("Sound Glow", "聲波光暈"))
            } footer: {
                Text(t("Needs HomePod software 27.2 and Sound Glow turned on in the Home app. Turning it off takes effect the next time playback starts.",
                       "需要 HomePod 軟體 27.2，並在「家庭」App 開啟聲波光暈。關閉要等下次開始播放才生效。"))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.reloadGlow() }
    }

    private var glowChoices: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(glowPresets, id: \.name) { p in
                glowItem(label: t(p.en, p.zh), selected: model.glow == "preset:" + p.name) {
                    HStack(spacing: 0) { ForEach(p.hex, id: \.self) { Color(hex: $0) } }
                } action: { closeColorPanel(); model.setGlow("preset:" + p.name) }
            }
            customItem
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    /// 第五顆色票。沒選時點一下開調色盤；選了再點一下也開調色盤，所以「點選」和「編輯」都在這顆上。
    /// 不用 ColorPicker：它是固定的膠囊按鈕，放不進圓形色票。
    private var customItem: some View {
        let selected = model.glow.hasPrefix("custom:#")
        return glowItem(label: t("Custom", "自訂"), selected: selected) {
            if model.lastCustom == nil {
                AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)
                    .overlay(Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(.white).shadow(radius: 2))
            } else {
                model.customGlow
            }
        } action: {
            if let c = model.lastCustom, !selected { model.setGlow(c) } else { openColorPanel() }
        }
        .help(selected ? t("Click to change the color", "點一下改顏色") : t("Pick your own color", "自己選顏色"))
    }

    private func closeColorPanel() {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.orderOut(nil)
    }

    private func openColorPanel() {
        // 面板的回呼只在選了自訂時才寫檔，所以先選起來；寫入失敗就不開
        if !model.glow.hasPrefix("custom:#") {
            model.setGlow("custom:#" + model.customGlow.hexString)
            guard model.glow.hasPrefix("custom:#") else { return }
        }
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(model.customGlow)
        colorBridge.onChange = { if model.glow.hasPrefix("custom:#") { model.customGlow = Color(nsColor: $0) } }
        panel.setTarget(colorBridge)
        panel.setAction(#selector(ColorPanelBridge.changed(_:)))
        panel.orderFront(nil)
    }

    private func glowItem<Swatch: View>(label: String, selected: Bool, @ViewBuilder swatch: () -> Swatch, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            swatch().frame(width: 44, height: 44).clipShape(Circle())
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 3 : 1))
                .contentShape(Circle())
                .onTapGesture(perform: action)
            Text(label).font(.caption).foregroundStyle(selected ? .primary : .secondary)
        }
        .frame(width: 70)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// NSColorPanel 只認 target/action，這裡把它轉成閉包。
final class ColorPanelBridge: NSObject {
    var onChange: (NSColor) -> Void = { _ in }
    @objc func changed(_ p: NSColorPanel) { onChange(p.color) }
}

/// Shown on the Audio pane too: nothing plays until the helper is fixed, so it can't hide on the other pane.
struct HelperProblem: View {
    @ObservedObject var model: SettingsModel
    let install: () -> Void
    var body: some View {
        LabeledContent {
            Button(model.helper == "missing" ? t("Install…", "安裝…")
                   : model.helper == "outdated" ? t("Update…", "更新…") : t("Reinstall…", "重新安裝…"), action: install)
                .disabled(model.helperBusy)
        } label: {
            Label(model.helper == "missing" ? t("Background helper isn't installed", "背景服務還沒安裝")
                  : model.helper == "outdated" ? t("Background helper update available", "背景服務有新版本")
                  : t("Background helper stopped", "背景服務停止了"),
                  systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
            Text(model.helper == "outdated"
                 ? t("It may still play. Update to get this version's fixes. Needs your administrator password.", "可能還能播放，更新後才有這一版的修正。需要管理員密碼。")
                 : t("Speakers can't play until it's fixed. Needs your administrator password.", "修好之前喇叭不會出聲，需要管理員密碼。"))
        }
    }
}

struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    let openLogs: () -> Void
    let copyDiagnostics: () -> Void
    let checkUpdate: () -> Void
    let openUpdate: () -> Void
    let installHelper: () -> Void
    let uninstallHelper: () -> Void
    @State private var showDetails = false

    private var updateStatus: String {
        switch model.update {
        case .idle: return ""
        case .checking: return t("Checking…", "檢查中…")
        case .upToDate: return t("You have the latest version.", "已經是最新版。")
        case .failed: return t("Couldn't check. Try again later.", "無法檢查，請稍後再試。")
        case .available(let tag): return t("Version \(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag) is available.",
                                           "有新版本 \(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)。")
        }
    }

    var body: some View {
        let _ = model.lang
        Form {
            Section {
                Picker(t("Language", "語言"), selection: $model.lang) {
                    Text(t("Follow System", "跟隨系統")).tag(Lang.system)
                    Text("English").tag(Lang.en)
                    Text("中文").tag(Lang.zh)
                }
            }
            Section {
                if model.helper == "ok" {
                    LabeledContent {
                        Menu(t("Manage", "管理")) {
                            Button(t("Reinstall…", "重新安裝…"), action: installHelper)
                            Button(t("Remove…", "移除…"), role: .destructive, action: uninstallHelper)
                        }
                        .fixedSize()
                        .disabled(model.helperBusy)
                    } label: {
                        Text(t("Background helper", "背景服務"))
                        Text(t("Running", "執行中"))
                    }
                } else {
                    HelperProblem(model: model, install: installHelper)
                    if model.helper != "missing" {
                        LabeledContent(t("Remove the helper", "移除背景服務")) {
                            Button(t("Remove…", "移除…"), action: uninstallHelper).disabled(model.helperBusy)
                        }
                    }
                }
            } footer: {
                Text(t("It streams the Mac's sound to the speakers. Installing, updating, and removing it need your administrator password.",
                       "負責把 Mac 的聲音送到喇叭。安裝、更新、移除都要輸入管理員密碼。"))
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(t("Check for updates automatically", "自動檢查更新"), isOn: $model.autoUpdateCheck)
                LabeledContent {
                    HStack {
                        if model.foundTag != nil {
                            Button(t("Open Download Page", "打開下載頁"), action: openUpdate)
                        }
                        Button(t("Check Now", "立即檢查"), action: checkUpdate).disabled(model.update == .checking)
                    }
                } label: {
                    Text(t("Version ", "版本 ") + appVersion)
                    if !updateStatus.isEmpty { Text(updateStatus) }
                }
            } header: {
                Text(t("Updates", "更新"))
            } footer: {
                Text(t("DualPod only asks GitHub for the latest version number. It doesn't download or install anything.",
                       "只會向 GitHub 查最新的版本號，不會自動下載或安裝。"))
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button(t("Open Log Folder", "打開 log 資料夾"), action: openLogs)
                    Button(t("Copy Diagnostics", "複製診斷資訊"), action: copyDiagnostics)
                }
                DisclosureGroup(t("What's in the diagnostics", "診斷資訊包含什麼"), isExpanded: $showDetails) {
                    Text(t("Plain text for reporting a problem: recent sessions and events. IP addresses, device IDs, .local host names, your home folder, and the names of speakers found now are replaced by placeholders. Check it once more before sending.",
                           "回報問題用的純文字：最近幾段播放與事件。IP、裝置 ID、.local 結尾的主機名稱、你的家目錄、目前找到的喇叭名稱會換成代號，送出前請自己再看一次。"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(t("Troubleshooting", "疑難排解"))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
