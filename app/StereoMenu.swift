// Menu bar speaker picker for the AirPlay stereo background service (installed once by app/install-daemon.sh).
// Like Music's AirPlay picker: any mix of This Mac and up to two speakers. The app only writes the chosen ids to a want
// file; the root service watches it, so no password per switch. Two HomePods = left/right stereo.
// UI language follows the system by default; the Language submenu can pin English or Traditional Chinese.
import AppKit
import AVFoundation
import SwiftUI
import CoreAudio
import AudioToolbox  // VirtualMainVolume 定義在這裡

let runtime = "/Library/Application Support/AirPlayStereo"
let stereo = runtime + "/stereo.sh"
let logDir = runtime + "/logs"
let bundleRuntime = (Bundle.main.resourcePath ?? "") + "/runtime"  // what this build of the app would install
let wantFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/AirPlayStereo/want")
// Speaker volumes 0–100 ("<id>=40 <id>=30"); the service applies them live and on the next start
let volumeFile = wantFile.deletingLastPathComponent().appendingPathComponent("volume")

// This Mac's slider is the system output volume. The process tap captures audio before that volume,
// so it changes only the Mac speakers, never what the HomePods get.
var macVolumeAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
    mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
func defaultOutput() -> AudioObjectID {
    var id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return id
}
var macVolume: Float {
    get {
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(defaultOutput(), &macVolumeAddress, 0, nil, &size, &v)
        return v
    }
    set {
        var v = Float32(newValue)
        AudioObjectSetPropertyData(defaultOutput(), &macVolumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }
}

/// One output row in the Control Center style: a round icon that turns accent-blue when selected,
/// the name (with "Left"/"Right" underneath for the stereo pair), and the volume slider on the same line.
/// Clicking anywhere but the slider toggles the device; the menu stays open.
final class DeviceRow: NSView {
    let symbol: String
    let name = NSTextField(labelWithString: "")
    let sub = NSTextField(labelWithString: "")
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    var isOn = false { didSet { needsDisplay = true; slider.isHidden = !isOn; layoutText() } }
    var enabled = true { didSet { needsDisplay = true; name.textColor = enabled ? .labelColor : .disabledControlTextColor } }
    let onToggle: () -> Void
    let onVolume: (Double) -> Void
    let circle = NSRect(x: 14, y: 6, width: 26, height: 26)
    init(symbol: String, onToggle: @escaping () -> Void, onVolume: @escaping (Double) -> Void) {
        self.symbol = symbol
        self.onToggle = onToggle
        self.onVolume = onVolume
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 38))
        name.font = .menuFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail  // long names end in "…" instead of being cut off
        sub.font = .systemFont(ofSize: 11)
        sub.lineBreakMode = .byTruncatingTail
        sub.textColor = .secondaryLabelColor
        slider.controlSize = .small
        slider.frame = NSRect(x: 128, y: 10, width: 138, height: 18)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        [name, sub, slider].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ title: String, _ subtitle: String) {
        name.stringValue = title
        sub.stringValue = subtitle
        sub.isHidden = subtitle.isEmpty
        layoutText()
    }

    /// Without a slider (not selected) the name gets the whole row; with one, it stops short of the slider.
    func layoutText() {
        let width: CGFloat = isOn ? 74 : bounds.width - 50 - 14
        // one line centred on the circle, or name above the small caption
        name.frame = sub.isHidden ? NSRect(x: 50, y: 10, width: width, height: 17)
                                  : NSRect(x: 50, y: 17, width: width, height: 17)
        sub.frame = NSRect(x: 50, y: 3, width: width, height: 14)
        name.toolTip = name.stringValue  // the full name on hover when it's shortened
    }

    override func draw(_ dirty: NSRect) {
        (isOn && enabled ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).setFill()
        NSBezierPath(ovalIn: circle).fill()
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(.init(paletteColors: [isOn && enabled ? .white : .secondaryLabelColor]))
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let s = img.size
            img.draw(in: NSRect(x: circle.midX - s.width / 2, y: circle.midY - s.height / 2, width: s.width, height: s.height))
        }
    }
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if enabled, bounds.contains(p), !(isOn && slider.frame.contains(p)) { onToggle() }
    }
    @objc func changed() { onVolume(slider.doubleValue) }
}

enum Lang: String { case system, en, zh }
var langSetting: Lang {
    get { Lang(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "") ?? .system }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "lang") }
}
var lang: Lang {
    if langSetting != .system { return langSetting }
    return (Locale.preferredLanguages.first ?? "").hasPrefix("zh") ? .zh : .en
}
func t(_ en: String, _ zh: String) -> String { lang == .zh ? zh : en }

func shell(_ command: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", command]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try? p.run()
    p.waitUntilExit()
    return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

/// A speaker the background service found on the network: its AirPlay device id (12 hex digits) and name.
struct Speaker: Equatable { let id, name, symbol: String }

/// Reads the service's list ("id<tab>ip<tab>name" per line) and picks an icon from each one's model.
func loadSpeakers() -> [Speaker] {
    let text = (try? String(contentsOfFile: runtime + "/state/speakers", encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 3, f[0].count == 12 else { return nil }
        let txt = (try? String(contentsOfFile: runtime + "/state/txt-" + f[0], encoding: .utf8)) ?? ""
        let model = txt.split(separator: " ").first { $0.hasPrefix("model=") }.map { String($0.dropFirst(6)) } ?? ""
        let symbol = model.hasPrefix("AudioAccessory5") || model.hasPrefix("AudioAccessory11") ? "homepodmini.fill"
            : model.hasPrefix("AudioAccessory") ? "homepod.fill"
            : model.hasPrefix("AppleTV") ? "appletv.fill" : "hifispeaker.fill"
        return Speaker(id: f[0], name: f[2], symbol: symbol)
    }.reduce(into: [Speaker]()) { (list: inout [Speaker], s: Speaker) in
        if !list.contains(where: { $0.id == s.id }) { list.append(s) }  // one row per id
    }
}

final class App: NSObject, NSApplicationDelegate {
    var speakers: [Speaker] = []
    var devices: [String] { speakers.map(\.id) + ["Mac"] }  // menu order; the want file is ids then "Mac"
    var deviceItems: [String: NSMenuItem] = [:]
    var menu = NSMenu()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var header = NSMenuItem.sectionHeader(title: "")
    let warning = NSMenuItem()
    let lastLine = NSMenuItem()
    var rows: [String: DeviceRow] = [:]
    var homeVolume: [String: Int] = [:]  // speaker id → 0…100; 35 until set
    // "All" row: one slider for every output that is playing. It scales them together and keeps their balance:
    // the ratios are taken when the master starts moving and dropped as soon as a single slider moves.
    let masterItem = NSMenuItem()
    var masterRow: DeviceRow!
    var masterBase: [String: Double]?  // device → volume as a share of the loudest, while the master moves
    // Left/right link: moving one HomePod of the pair moves the other by the same amount
    let linkItem = NSMenuItem(title: "", action: #selector(toggleLink), keyEquivalent: "")
    var linkPair: Bool {
        get { UserDefaults.standard.object(forKey: "linkPair") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "linkPair") }
    }
    let settingsItem = NSMenuItem(title: "", action: #selector(openSettings), keyEquivalent: ",")
    let updateItem = NSMenuItem(title: "", action: #selector(openUpdatePage), keyEquivalent: "")
    let settings = SettingsModel()
    let channelTest = ChannelTest()
    var settingsWindow: NSWindow?
    var settingsTabs: SettingsTabs?
    let quit = NSMenuItem(title: "", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    var actual: Set<String> = ["Mac"]  // what the service is playing to now
    var pending: (want: Set<String>, deadline: Date)?  // picked, waiting for the service to get there
    var lastStatus: [String] = []
    var offeredInstall = false
    var updateInFlight = false

    func applicationDidFinishLaunching(_ note: Notification) {
        warning.target = self
        warning.action = #selector(installHelper)
        menu.addItem(warning)
        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(header)
        masterRow = DeviceRow(symbol: "speaker.wave.2.fill", onToggle: {},
                              onVolume: { [weak self] v in self?.setMaster(v) })
        masterRow.isOn = true
        masterItem.view = masterRow
        menu.addItem(masterItem)
        syncRows()
        linkItem.target = self
        menu.addItem(linkItem)
        menu.delegate = self
        menu.addItem(.separator())
        lastLine.isEnabled = false
        menu.addItem(lastLine)
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(quit)
        settings.onLangChange = { [weak self] in
            guard let self else { return }
            self.render(self.lastStatus)
        }
        settings.onUpdateChange = { [weak self] in
            guard let self else { return }
            self.render(self.lastStatus)
        }
        item.menu = menu
        render([])
        refresh()
        // .common: keep refreshing while the menu is open, so "Switching…" turns into the result in place
        RunLoop.main.add(Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }, forMode: .common)
        restoreAfterAlign()  // a crash or force quit during auto-align
        // Once shortly after launch (the network may not be up yet at login), then daily: the app runs for weeks
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.checkForUpdate(manual: false) }
        RunLoop.main.add(Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdate(manual: false)
        }, forMode: .common)
        if CommandLine.arguments.contains("--settings") { openSettings() }  // open -a … --args --settings
        if CommandLine.arguments.contains("--autoalign") {  // same as the Settings button, for testing
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.runAutoAlign() }
        }
    }

    /// Rebuild the device rows when the list of speakers changes (new speaker found, renamed, gone).
    func syncRows() {
        let fresh = loadSpeakers()
        guard fresh != speakers || rows.isEmpty else { return }
        speakers = fresh
        for (_, mi) in deviceItems { menu.removeItem(mi) }
        deviceItems = [:]
        rows = [:]
        var at = menu.index(of: masterItem) + 1
        for d in devices {
            let row = DeviceRow(symbol: speakers.first { $0.id == d }?.symbol ?? "laptopcomputer",
                                onToggle: { [weak self] in self?.toggleDevice(d) },
                                onVolume: { [weak self] v in self?.setVolume(d, v) })
            let mi = NSMenuItem()
            mi.view = row
            rows[d] = row
            deviceItems[d] = mi
            menu.insertItem(mi, at: at)
            at += 1
        }
        loadVolumes()
        settings.names = Dictionary(speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    // status line 1: "on <id> <id> Mac" / "off" / "noservice"; "missing" when the helper isn't installed
    func parse(_ first: String) -> Set<String> {
        let words = first.split(separator: " ").map(String.init)
        return words.first == "on" ? Set(words.dropFirst()) : ["Mac"]
    }

    func refresh() {
        DispatchQueue.global().async {
            let installed = FileManager.default.fileExists(atPath: stereo)
            let lines = installed
                ? shell("zsh '\(stereo)' status").split(separator: "\n").map(String.init) : ["missing"]
            DispatchQueue.main.async {
                let now = self.parse(lines.first ?? "")
                if let p = self.pending {
                    // Starting takes several seconds (stop the old set, then bring the new one up)
                    guard now == p.want || Date() > p.deadline else { return }
                    self.pending = nil
                }
                self.actual = now
                self.lastStatus = lines
                self.syncRows()
                if lines.first == "missing" { self.offerInstallOnce() }
                self.render(lines)
            }
        }
    }

    // 選單列圖示：兩個重疊圓環（和 App 圖示同一個意象），播放中兩側各加兩道往外的弧線。
    // 兩種狀態同一個 30×18 畫布，開始播放時圖示寬度不變，不會把旁邊的選單列圖示擠開
    static let iconIdle = statusIcon(waves: false)
    static let iconPlaying = statusIcon(waves: true)
    static func statusIcon(waves: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 30, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            for x in [12.1, 17.9] {
                let ring = NSBezierPath(ovalIn: NSRect(x: x - 4.5, y: 4.5, width: 9, height: 9))
                ring.lineWidth = 1.6
                ring.stroke()
            }
            guard waves else { return true }
            for r in [7.6, 10.2] {
                for (cx, start) in [(12.1, 135.0), (17.9, -45.0)] {
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: NSPoint(x: cx, y: 9), radius: r, startAngle: start, endAngle: start + 90)
                    arc.lineWidth = 1.5
                    arc.lineCapStyle = .round
                    arc.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "DualPod"
        return image
    }

    func render(_ lines: [String]) {
        let first = lines.first ?? ""
        let missing = first == "missing" || first == "noservice"
        let shown = pending?.want ?? actual
        let streaming = shown.contains { $0 != "Mac" }
        item.button?.image = streaming ? Self.iconPlaying : Self.iconIdle
        header.title = pending != nil ? t("Output · switching…", "輸出 · 切換中…")
            : streaming ? t("Output · ~0.3 s latency", "輸出 · 延遲約 0.3 秒")
            : speakers.isEmpty ? t("Output · looking for speakers…", "輸出 · 正在尋找喇叭…") : t("Output", "輸出")
        let helper = helperState(first)
        warning.title = helper == "missing" ? t("Install Background Helper…", "安裝背景服務…")
            : helper == "outdated" ? t("Update Background Helper…", "更新背景服務…")
            : t("Background helper stopped. Reinstall…", "背景服務停止了，重新安裝…")
        warning.isHidden = helper == "ok"
        warning.isEnabled = !settings.helperBusy
        if settings.helper != helper { settings.helper = helper }  // unchanged values would redraw the panes every 2 s
        let pair = shown.filter { $0 != "Mac" }.sorted()
        let left = pair.contains(settings.left) ? settings.left : pair.first ?? ""  // the service defaults the same way
        for d in devices {
            guard let row = rows[d] else { continue }
            let title = d == "Mac" ? t("This Mac", "這台 Mac") : speakers.first { $0.id == d }?.name ?? d
            let subtitle = pair.count == 2 && pair.contains(d) ? (d == left ? t("Left", "左聲道") : t("Right", "右聲道")) : ""
            row.setTitle(title, subtitle)
            row.isOn = shown.contains(d)
            row.enabled = !missing
        }
        // stereo.sh log line: "YYYY-MM-DD HH:MM:SS restart: <reason>" or "... gave up: ..."
        let last = lines.dropFirst().first ?? ""
        lastLine.title = t("Last event: ", "上次事件：") + last.dropFirst(11)
        lastLine.isHidden = !(last.contains("restart:") || last.contains("gave up"))
        if let tag = settings.foundTag {
            let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            updateItem.title = t("DualPod \(v) Is Available…", "有新版本：DualPod \(v)…")
            updateItem.isHidden = false
        } else {
            updateItem.isHidden = true
        }
        // The master only makes sense with two or more outputs; the link only with the stereo pair
        let on = devices.filter { shown.contains($0) }
        masterItem.isHidden = on.count < 2
        masterRow.setTitle(t("All", "全部"), "")
        masterRow.enabled = !missing
        if masterBase == nil { masterRow.slider.doubleValue = masterLevel() }
        linkItem.isHidden = pair.count != 2
        linkItem.title = t("Link Left and Right Volume", "左右聲道音量連動")
        linkItem.state = linkPair ? .on : .off
        settingsItem.title = t("Settings…", "設定…")
        let playing = actual.filter { $0 != "Mac" }.sorted()
        if settings.playing != playing { settings.playing = playing }
        if settings.switching != (pending != nil) { settings.switching = pending != nil }
        let canAlign = pending == nil && actual.contains("Mac") && !playing.isEmpty
        if settings.canAlign != canAlign { settings.canAlign = canAlign }
        settingsTabs?.label()
        quit.title = t("Quit DualPod", "結束 DualPod")
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let audio = NSHostingController(rootView: AudioPane(
                model: settings,
                playChannel: { [weak self] right in self?.channelTest.play(right: right) },
                autoAlign: { [weak self] in self?.runAutoAlign() },
                installHelper: { [weak self] in self?.runHelper(remove: false) },
                openMenu: { [weak self] in self?.item.button?.performClick(nil) }))
            let general = NSHostingController(rootView: GeneralPane(
                model: settings,
                openLogs: { [weak self] in self?.openLogs() },
                copyDiagnostics: { [weak self] in self?.copyDiagnostics() },
                checkUpdate: { [weak self] in self?.checkForUpdate(manual: true) },
                openUpdate: { [weak self] in self?.openUpdatePage() },
                installHelper: { [weak self] in self?.runHelper(remove: false) },
                uninstallHelper: { [weak self] in self?.uninstallHelper() }))
            let glow = NSHostingController(rootView: GlowPane(model: settings))
            audio.sizingOptions = .preferredContentSize  // the window takes each pane's own height
            glow.sizingOptions = .preferredContentSize
            general.sizingOptions = .preferredContentSize
            let lastPane = SettingsTabs.savedPane()  // before adding tabs: the first one selects itself and saves
            let tabs = SettingsTabs()
            tabs.tabStyle = .toolbar
            for (id, vc, symbol) in [("audio", audio, "hifispeaker.2"), ("glow", glow, "light.max"), ("general", general, "gearshape")] as [(String, NSViewController, String)] {
                let tab = NSTabViewItem(viewController: vc)
                tab.identifier = id
                tab.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                tabs.addTabViewItem(tab)
            }
            tabs.label()
            tabs.selectedTabViewItemIndex = tabs.tabViewItems.firstIndex { $0.identifier as? String == lastPane } ?? 0
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.toolbarStyle = .preference
            w.isReleasedWhenClosed = false
            settingsTabs = tabs
            settingsWindow = w
            w.center()
        }
        settings.reloadGlow()
        NSApp.activate(ignoringOtherApps: true)  // menu bar apps aren't active, so the window would open behind
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func toggleDevice(_ d: String) {
        var want = pending?.want ?? actual
        if want.contains(d) { want.remove(d) } else { want.insert(d) }
        if want.isEmpty { render(lastStatus); return }  // like Music: at least one output stays selected
        // Stereo means two speakers at most (left and right); a third would have nowhere to go
        if want.filter({ $0 != "Mac" }).count > 2 { NSSound.beep(); render(lastStatus); return }
        // No speaker left = the service stops and sound goes back to the Mac by itself
        let target: Set<String> = want.contains { $0 != "Mac" } ? want : ["Mac"]
        do {
            try FileManager.default.createDirectory(
                at: wantFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = (target.filter { $0 != "Mac" }.sorted() + (target.contains("Mac") ? ["Mac"] : [])).joined(separator: " ")
            try (text + "\n").write(to: wantFile, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = t("Couldn't switch speakers", "切換失敗")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        pending = (target, Date().addingTimeInterval(20))
        render(lastStatus)
        refresh()
    }

    func loadVolumes() {
        let text = (try? String(contentsOf: volumeFile, encoding: .utf8)) ?? ""
        for kv in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let p = kv.split(separator: "=")
            if p.count == 2, p[0].count == 12, let v = Int(p[1]), (0...100).contains(v) {
                homeVolume[String(p[0])] = v
            }
        }
        for s in speakers { rows[s.id]?.slider.doubleValue = Double(homeVolume[s.id] ?? 35) / 100 }
        rows["Mac"]?.slider.doubleValue = Double(macVolume)
    }

    /// One device's slider moved. With the link on, the other half of the stereo pair follows by the same amount.
    func setVolume(_ device: String, _ value: Double) {
        masterBase = nil
        if device == "Mac" { macVolume = Float(value) } else {
            let new = Int((value * 100).rounded())
            let pair = playingPair()
            if linkPair, pair.count == 2, pair.contains(device), let other = pair.first(where: { $0 != device }) {
                let delta = new - (homeVolume[device] ?? 35)
                let follow = min(100, max(0, (homeVolume[other] ?? 35) + delta))
                homeVolume[other] = follow
                rows[other]?.slider.doubleValue = Double(follow) / 100
            }
            homeVolume[device] = new
            writeVolumes()
        }
        masterRow.slider.doubleValue = masterLevel()
    }

    func writeVolumes() {
        let text = homeVolume.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        try? FileManager.default.createDirectory(
            at: volumeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (text + "\n").write(to: volumeFile, atomically: true, encoding: .utf8)
    }

    func playingPair() -> [String] { (pending?.want ?? actual).filter { $0 != "Mac" }.sorted() }
    func playingOutputs() -> [String] { devices.filter { (pending?.want ?? actual).contains($0) } }
    func level(_ d: String) -> Double { d == "Mac" ? Double(macVolume) : Double(homeVolume[d] ?? 35) / 100 }
    /// The master sits at the loudest output, so dragging it to the top brings that one to 100.
    func masterLevel() -> Double { playingOutputs().map(level).max() ?? 0 }

    func setMaster(_ value: Double) {
        let outs = playingOutputs()
        if masterBase == nil {
            let top = outs.map(level).max() ?? 0
            // everything at 0: no balance left to keep, so they rise together
            masterBase = Dictionary(uniqueKeysWithValues: outs.map { ($0, top > 0 ? level($0) / top : 1) })
        }
        for d in outs {
            let v = min(1, max(0, value * (masterBase?[d] ?? 1)))
            if d == "Mac" { macVolume = Float(v) } else { homeVolume[d] = Int((v * 100).rounded()) }
            rows[d]?.slider.doubleValue = v
        }
        writeVolumes()
    }

    @objc func toggleLink() {
        linkPair.toggle()
        render(lastStatus)
    }

    let aligner = AutoAlign()

    /// Shift the Mac 40 ms later than now, wait for the stream to come back, measure with the mic, then write
    /// the offset that lines the Mac up. Any failure, a change of outputs, or quitting puts the old offset back.
    /// The Mac lands D ms behind the HomePods with offset `before + 40`, so `before + 40 − D` lines it up;
    /// D is searched within 40 ± 15 ms, so the current offset only has to be roughly right (and reflections
    /// around 20 ms stay out of the window).
    var micDeniedMessage: String {
        t("Couldn't use the microphone. Allow it in System Settings → Privacy & Security → Microphone.",
          "無法使用麥克風，請到「系統設定 → 隱私權與安全性 → 麥克風」允許。")
    }
    func micDenied() { settings.syncStatus = micDeniedMessage }

    func runAutoAlign() {
        guard settings.canAlign, !settings.aligning else { return }
        // Ask before the run starts: a prompt that appears mid-recording leaves the recording empty
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { ok ? self.runAutoAlign() : self.micDenied() }
            }
            return
        default: micDenied(); return
        }
        let s = settings
        let before = s.appliedSync
        s.sync = before  // an unapplied value in the field would be overwritten by the result anyway
        let volume = macVolume
        let probe = before + AutoAlign.probeMs
        let outputs = actual
        let logLines = { (try? String(contentsOfFile: logDir + "/stereo.log", encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? [] }
        let seen = logLines().count
        // Survives a crash or force quit: the next launch puts these back (see restoreAfterAlign)
        guard writeSetting(alignRestoreFile, "\(before) \(volume)"), writeSetting(syncFile, String(probe)) else {
            s.syncStatus = t("Couldn't save settings. Nothing changed.", "無法寫入設定，對齊值沒有改。"); return
        }
        s.aligning = true
        s.syncStatus = t("Preparing… (the speakers reconnect)", "準備中…（喇叭會重新連線）")
        func finish(_ adj: Int, _ message: String, detail: String = "") {
            macVolume = volume
            let saved = writeSetting(syncFile, String(adj))
            try? FileManager.default.removeItem(at: alignRestoreFile)
            s.appliedSync = saved ? adj : probe  // what the file holds; the probe can be past the field's ±100
            s.sync = s.appliedSync
            s.aligning = false
            s.syncStatus = saved ? message : t("Couldn't save the offset. Set it by hand.", "無法寫入對齊值，請手動設定。")
            let line = "\(Date()) before=\(before) result=\(adj) \(detail) \(message)\n"
            let url = wantFile.deletingLastPathComponent().appendingPathComponent("align.log")
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
            else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
        let changed = t("The outputs changed. Nothing changed.", "輸出裝置變了，對齊值沒有改。")
        // Wait for the restart with the probe offset: its "start … mac_sync_ms=<probe> (log tag X)" line, then its split log
        DispatchQueue.global().async {
            var tag: String?, ready = false
            for _ in 0..<90 {
                if tag == nil, let l = logLines().dropFirst(seen).last(where: { $0.contains("mac_sync_ms=\(probe) (log tag") }) {
                    tag = l.components(separatedBy: "log tag ").last?.trimmingCharacters(in: CharacterSet(charactersIn: ")"))
                }
                if let tag, FileManager.default.fileExists(atPath: "\(logDir)/pair-\(tag)-split.log") { ready = true; break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            Thread.sleep(forTimeInterval: 2)
            DispatchQueue.main.async {
                guard s.aligning else { return }  // quit already restored everything
                guard ready else { finish(before, t("Couldn't restart the stream. Nothing changed.", "串流沒有重新連上，對齊值沒有改。")); return }
                guard self.actual == outputs, self.pending == nil else { finish(before, changed); return }
                s.syncStatus = t("Listening… keep the room quiet (about 20 s)", "錄音中，請保持安靜（約 20 秒）")
                macVolume = 0.12  // so the speakers beside the mic don't drown the HomePods out
                self.aligner.record { samples, fs in
                    macVolume = volume
                    DispatchQueue.global().async {
                        let r = AutoAlign.measure(samples, fs: fs, expected: Double(AutoAlign.probeMs))
                        DispatchQueue.main.async {
                            guard s.aligning else { return }
                            guard self.actual == outputs, self.pending == nil else { finish(before, changed); return }
                            guard let r, r.spread <= 6 else {  // past runs: 1.3–3.7 ms; wider means mismatched peaks
                                finish(before, samples.isEmpty
                                       ? (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                                          ? t("Couldn't record from the microphone. Check System Settings → Sound → Input.", "麥克風錄不到聲音，請到「系統設定 → 聲音 → 輸入」檢查。")
                                          : self.micDeniedMessage)
                                       : t("Couldn't hear both clearly. Try a quieter room. Nothing changed.", "沒有清楚聽到兩邊的聲音，請在安靜一點的地方再試，對齊值沒有改。"))
                                return
                            }
                            let adj = max(-100, min(100, Int((Double(probe) - r.gap).rounded())))
                            let spread = String(format: "%.1f", r.spread)
                            finish(adj, t("Done. Offset set to \(adj) ms.", "完成，時間差設為 \(adj) ms。"),
                                   detail: "chirps=\(r.n) spread_ms=\(spread)")
                        }
                    }
                }
            }
        }
    }

    /// Puts back the offset and volume an interrupted auto-align left behind.
    func restoreAfterAlign() {
        let parts = readSetting(alignRestoreFile).split(separator: " ")
        guard parts.count == 2, let adj = Int(parts[0]), let vol = Float(parts[1]) else { return }
        macVolume = vol
        writeSetting(syncFile, String(adj))
        settings.appliedSync = adj
        settings.sync = adj
        settings.aligning = false
        try? FileManager.default.removeItem(at: alignRestoreFile)
    }

    // Quitting ends streaming too: sound goes back to the Mac's own output, like closing any audio app
    func applicationWillTerminate(_ note: Notification) {
        restoreAfterAlign()
        writeSetting(wantFile, "Mac")
    }

    /// Recent sessions and events as plain text, with IPs, speaker names, device IDs, and the home folder
    /// replaced by placeholders (like AirFlash's "copy diagnostics"), put on the clipboard.
    func copyDiagnostics() {
        func tail(_ path: String, _ n: Int) -> String {
            ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").suffix(n).joined(separator: "\n")
        }
        let version = appVersion
        var text = [
            "DualPod \(version)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "status: \(lastStatus.first ?? "?")",
            "speakers found: \(speakers.count), mac_sync_ms: \(settings.appliedSync)",
            "", "== sessions.csv (last 10) ==", tail(logDir + "/sessions.csv", 11),
            "", "== stereo.log (last 30) ==", tail(logDir + "/stereo.log", 30),
        ].joined(separator: "\n")
        for (i, s) in speakers.enumerated() {
            text = text.replacingOccurrences(of: s.id, with: "speaker-\(i + 1)")
            if s.name.count >= 2 { text = text.replacingOccurrences(of: s.name, with: "speaker-\(i + 1)") }
        }
        let rules: [(String, String)] = [
            (#"\b\d{1,3}(\.\d{1,3}){3}\b"#, "[ip]"),                                 // IPv4
            (#"\b([0-9A-Fa-f]{1,4}:){3,7}[0-9A-Fa-f]{1,4}\b"#, "[ip-or-id]"),  // IPv6 and colon MACs (3+ colons: not times)
            (#"\b[0-9A-Fa-f]{1,4}::[0-9A-Fa-f:]*(%\w+)?"#, "[ip]"),                   // short IPv6 like fe80::1%en0
            (#"\b[0-9A-Fa-f]{12}\b"#, "[id]"),                                          // ids without colons
            (#"/(Users|private/var/folders)/[^\s/]+"#, "/[user-path]"),
            (#"\b[\w-]+\.local\.?"#, "[host]"),
        ]
        for (pattern, mask) in rules { text = text.replacingOccurrences(of: pattern, with: mask, options: .regularExpression) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: background helper (install, update, remove from inside the app)

    /// "missing", "outdated" (the app carries a different build than the one installed), "stopped", or "ok"
    func helperState(_ first: String) -> String {
        if first == "missing" { return "missing" }
        let bundled = readSetting(URL(fileURLWithPath: bundleRuntime + "/VERSION"))
        let installed = readSetting(URL(fileURLWithPath: runtime + "/VERSION"))
        if !bundled.isEmpty && bundled != installed { return "outdated" }
        return first.hasPrefix("on") || first == "off" ? "ok" : "stopped"  // unknown output is not "running"
    }

    @objc func installHelper() { runHelper(remove: false) }

    /// Runs the bundled installer as root through macOS's own password dialog. The app never sees the password.
    func runHelper(remove: Bool) {
        guard !settings.helperBusy else { return }  // one privileged install at a time
        let installer = bundleRuntime + "/install-daemon.sh"
        guard FileManager.default.fileExists(atPath: installer) else {
            let a = NSAlert()
            a.messageText = t("This copy of the app has no helper to install", "這個 App 裡沒有可安裝的背景服務")
            a.informativeText = t("Build it with app/build.sh.", "請用 app/build.sh 重新編譯。")
            a.runModal()
            return
        }
        let prompt = remove
            ? t("DualPod wants to remove its background helper.", "DualPod 要移除背景服務。")
            : t("DualPod needs to install its background helper to send sound to your speakers.",
                "DualPod 要安裝背景服務，才能把聲音送到喇叭。")
        settings.helperBusy = true
        render(lastStatus)  // grey out the menu's install item right away
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // Paths and the user name go in as arguments and through `quoted form of`, never spliced into the script
            p.arguments = ["-e", "on run argv",
                           "-e", "set cmd to \"INSTALL_USER=\" & quoted form of item 2 of argv & \" /bin/zsh -f \" & quoted form of item 1 of argv",
                           "-e", "if item 3 of argv is \"remove\" then set cmd to cmd & \" remove\"",
                           "-e", "do shell script cmd with prompt (item 4 of argv) with administrator privileges",
                           "-e", "end run",
                           installer, NSUserName(), remove ? "remove" : "install", prompt]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()
            try? p.run()
            p.waitUntilExit()
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.settings.helperBusy = false
                if p.terminationStatus != 0 && !message.contains("-128") {  // -128 = cancelled in the dialog
                    let a = NSAlert()
                    a.messageText = remove ? t("Couldn't remove the helper", "移除背景服務失敗")
                                           : t("Couldn't install the helper", "安裝背景服務失敗")
                    a.informativeText = message
                    a.runModal()
                }
                self.refresh()
            }
        }
    }

    func uninstallHelper() {
        let a = NSAlert()
        a.messageText = t("Remove the background helper?", "要移除背景服務嗎？")
        a.informativeText = t("Streaming stops and sound goes back to this Mac. You can install it again from Settings.",
                              "串流會停止，聲音回到這台 Mac。之後可以在設定裡重新安裝。")
        a.addButton(withTitle: t("Remove", "移除"))
        a.addButton(withTitle: t("Cancel", "取消"))
        if a.runModal() == .alertFirstButtonReturn {
            offeredInstall = true  // the status turns "missing" right after; the user just chose that
            runHelper(remove: true)
        }
    }

    /// First launch on a Mac without the helper: offer to install it right away.
    func offerInstallOnce() {
        guard !offeredInstall else { return }
        offeredInstall = true
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = t("Install the background helper?", "要安裝背景服務嗎？")
        a.informativeText = t("DualPod uses a small background helper to stream to your speakers. macOS will ask for your password once.",
                              "DualPod 要用一個背景服務把聲音送到喇叭。macOS 會請你輸入一次密碼。")
        a.addButton(withTitle: t("Install", "安裝"))
        a.addButton(withTitle: t("Later", "稍後"))
        if a.runModal() == .alertFirstButtonReturn { runHelper(remove: false) }
    }

    func openLogs() { NSWorkspace.shared.open(URL(fileURLWithPath: logDir)) }

    func checkForUpdate(manual: Bool) {
        guard manual || settings.autoUpdateCheck else { return }
        if manual { settings.update = .checking }
        guard !updateInFlight else { return }  // a manual check during an automatic one takes its result
        updateInFlight = true
        checkLatestRelease { [weak self] result in
            guard let self else { return }
            self.updateInFlight = false
            let waiting = self.settings.update == .checking
            switch result {
            case .available(let tag): self.settings.foundTag = tag; self.settings.update = result
            case .upToDate: self.settings.foundTag = nil; self.settings.update = result
            default:  // a failed check never hides a version already found; automatic ones fail silently
                if let tag = self.settings.foundTag { self.settings.update = .available(tag: tag) }
                else if waiting { self.settings.update = .failed }
            }
        }
    }

    @objc func openUpdatePage() {
        if let tag = settings.foundTag { NSWorkspace.shared.open(releasePage(tag)) }
    }
}

extension App: NSMenuDelegate {
    // The system volume can change from the keyboard while the menu is closed
    func menuWillOpen(_ menu: NSMenu) {
        rows["Mac"]?.slider.doubleValue = Double(macVolume)
        masterBase = nil
        masterRow.slider.doubleValue = masterLevel()
    }
}

@main
enum Entry {
    static let delegate = App()
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
        app.run()
    }
}

/// Settings with Audio, Glow and General panes in the toolbar. The window title follows the pane and the last pane reopens.
final class SettingsTabs: NSTabViewController {
    static let key = "settingsPaneID"
    /// 舊版存的是索引（0 音訊、1 一般），加了光暈頁後索引會對不上，所以改存名字並一次性轉換
    static func savedPane() -> String {
        let d = UserDefaults.standard
        if let id = d.string(forKey: key) { return id }
        return d.integer(forKey: "settingsPane") == 1 ? "general" : "audio"
    }
    func label() {
        for (tab, name) in zip(tabViewItems, [t("Audio", "音訊"), t("Glow", "光暈"), t("General", "一般")]) {
            tab.label = name
            tab.viewController?.title = name
        }
        if tabViewItems.indices.contains(selectedTabViewItemIndex) { view.window?.title = tabViewItems[selectedTabViewItemIndex].label }
    }
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        if let id = item?.identifier as? String { UserDefaults.standard.set(id, forKey: Self.key) }
    }
}
