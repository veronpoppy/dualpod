// 背景服務在播放路徑上要用的兩件小事，編成一支執行檔，不依賴 Python（一般使用者的 Mac 沒裝開發工具時 /usr/bin/python3 不能用）。
//
//   stereotool offset                       印出「Unix 時間 − CLOCK_UPTIME_RAW」（ns）。所有行程用同一個原始時鐘加這個位移，
//                                           NTP 調整系統時間時兩台不會一台跳、一台慢慢追
//   stereotool now <offset>                 依上面的時鐘印出現在的 Unix ms
//   stereotool sleepuntil <unix_ms> <offset>  睡到那個時刻
//   stereotool split [--routes <檔>] [--start-ms <T>] <路徑:聲道>…   stdin 的 s16le 44.1 kHz 立體聲拆給各輸出：L、R（複製成雙聲道）、LR（原樣）、
//                                           0（寫靜音，時間軸照走）、X（關掉 fd，之後不再寫）
//   split --eq <檔>：三段等化器「低 中 高」各 -12…12 dB 的整數（例「4 0 -2」），約每 200 ms 看一次有沒有變，變了立刻套用；
//                                           檔不在或格式不對就不處理（原音）。拆聲道前套用，所以每個輸出聽到的音色一樣、對時不受影響
//   stereotool glowart <out.jpg> <RRGGBB>…   寫 512x512 sRGB JPEG，1 到 3 個顏色等寬直條。HomePod 的 Sound Glow 從 Now Playing 封面取主色，
//                                           這張圖就是拿來指定光暈顏色的
//   --routes 檔內容是空白分隔的「路徑:聲道」，約每 100 ms 看一次有沒有變，變了就套用到已開啟的輸出（不認得的路徑略過）；
//   整個檔格式不對就整份忽略、stderr 記一次。路由只改下一塊起寫給各 fd 的內容，樣本時間軸不動
//   「路徑:聲道@<unix_ms>」排定在那個時刻對應的 frame 才生效（--start-ms 是 frame 0 播出的時刻 T，frame k 在 T + k/44100 秒播出）。
//   沒見過的路徑要帶 @ 才會開啟，它的第一個 frame 就是那個 frame：播放中加入的喇叭把起播時刻設成同一個 unix_ms 就和其他台對齊。
//   那個 frame 已經寫出去（太晚）就整份不套用、不回報，寫入端逾時後改走重啟
//
// split 的輸出鎖在牆鐘的 44.1 kHz：process tap 在系統沒出聲時不送資料，這時補靜音，否則 cliairplay 會判定斷流、
// 各自平移時間軸，兩台的對齊就散了。輸入比牆鐘超前太多（tap 恢復時一次湧入，或時脈漂移累積）就丟掉最舊的，延遲維持固定。
// shortcut: 丟樣本／補靜音是整段硬切，漂移累積到門檻時會有一次小爆音；要更乾淨再改成重取樣
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func rawNs() -> Int64 { Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) }
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func usage() -> Never { err("用法: stereotool offset | now <offset> | sleepuntil <unix_ms> <offset> | glowart <out.jpg> <RRGGBB>… | split [--routes <檔>] [--start-ms <T>] <路徑:L|R|LR|0|X>…"); exit(2) }

let args = CommandLine.arguments
guard args.count >= 2 else { usage() }

switch args[1] {
case "offset":
    var tv = timespec()
    clock_gettime(CLOCK_REALTIME, &tv)
    let unixNs = Int64(tv.tv_sec) * 1_000_000_000 + Int64(tv.tv_nsec)
    print(unixNs - rawNs())

case "now":
    guard args.count == 3, let off = Int64(args[2]) else { usage() }
    print((rawNs() + off) / 1_000_000)

case "sleepuntil":
    guard args.count == 4, let ms = Int64(args[2]), let off = Int64(args[3]) else { usage() }
    let wait = ms * 1_000_000 - off - rawNs()
    if wait > 0 { Thread.sleep(forTimeInterval: Double(wait) / 1e9) }

case "glowart":
    glowart(out: args.count >= 4 ? args[2] : "", hex: Array(args.dropFirst(3)))

case "split":
    split(Array(args.dropFirst(2)))

default:
    usage()
}

func glowart(out: String, hex: [String]) {
    guard !out.isEmpty, (1...3).contains(hex.count),
          hex.allSatisfy({ $0.count == 6 && $0.allSatisfy(\.isHexDigit) && $0.allSatisfy(\.isASCII) }) else { usage() }
    let n = 512
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { err("glowart: 建不了畫布"); exit(1) }
    for (i, h) in hex.enumerated() {
        let v = UInt32(h, radix: 16)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [CGFloat(v >> 16 & 255) / 255, CGFloat(v >> 8 & 255) / 255, CGFloat(v & 255) / 255, 1])!)
        ctx.fill(CGRect(x: i * n / hex.count, y: 0, width: (i + 1) * n / hex.count - i * n / hex.count, height: n))
    }
    let tmp = out + ".tmp.\(getpid())"  // 沒有 .jpg 結尾也沒關係，destination 指定了型別
    guard let img = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: tmp) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { err("glowart: 寫不出 \(out)"); exit(1) }
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(dest), rename(tmp, out) == 0 else { unlink(tmp); err("glowart: 寫不出 \(out)"); exit(1) }
}

func split(_ argv: [String]) {
    var specs = argv
    var routesFile: String?
    var eqFile: String?
    var startMs: Int64?
    while let opt = specs.first, opt == "--routes" || opt == "--start-ms" || opt == "--eq" {
        guard specs.count >= 2 else { usage() }
        if opt == "--routes" { routesFile = specs[1] } else if opt == "--eq" { eqFile = specs[1] }
        else if let t = Int64(specs[1]) { startMs = t } else { usage() }
        specs.removeFirst(2)
    }
    let fs = 44100.0
    let idle = Int(0.080 * fs)      // 輸入落後超過 80 ms 才當成斷流補靜音；一般抖動（±20 ms）不動作
    let maxAhead = Int(0.060 * fs)  // 輸入比基準超前 60 ms 以上就丟
    enum Mode { case left, right, both, zero, closed }
    func parseMode(_ m: Substring) -> Mode? {
        switch m {
        case "L": return .left
        case "R": return .right
        case "LR": return .both
        case "0": return .zero
        case "X": return .closed
        default: return nil
        }
    }
    // at：排定生效的 frame；沒寫 @ 就是 nil（下一塊起生效）
    func parseSpec(_ spec: Substring) -> (path: String, mode: Mode, at: Int?)? {
        guard let colon = spec.lastIndex(of: ":") else { return nil }
        let parts = spec[spec.index(after: colon)...].split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2, let mode = parseMode(parts[0]) else { return nil }
        var at: Int?
        if parts.count == 2 {
            guard let t0 = startMs, let ms = Int64(parts[1]) else { return nil }
            at = Int((Double(ms - t0) * 44.1).rounded())
        }
        return (String(spec[..<colon]), mode, at)
    }
    var outputs: [(path: String, fd: Int32, mode: Mode)] = []
    for spec in specs {
        guard let (path, mode, at) = parseSpec(Substring(spec)), at == nil else { err("split: 不認得的輸出 \(spec)"); exit(2) }
        if mode == .closed { outputs.append((path, -1, .closed)); continue }
        let fd = open(path, O_WRONLY)
        guard fd >= 0 else { err("split: 開不了 \(path)"); exit(1) }
        outputs.append((path, fd, mode))
    }
    guard !outputs.isEmpty else { usage() }
    signal(SIGPIPE, SIG_IGN)

    func writeAll(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) {
        var done = 0
        while done < n {
            let r = write(fd, p + done, n - done)
            if r < 0 { if errno == EINTR { continue }; exit(0) }  // 下游關了：播放結束
            done += r
        }
    }
    var dup: [Int16] = []
    func emit(_ pcm: UnsafeBufferPointer<Int16>) {  // pcm：交錯的 L, R
        for (_, fd, mode) in outputs {
            if mode == .closed { continue }
            if mode == .both { writeAll(fd, pcm.baseAddress!, pcm.count * 2); continue }
            if mode == .zero {
                dup.removeAll(keepingCapacity: true)
                dup.append(contentsOf: repeatElement(0, count: pcm.count))
                dup.withUnsafeBytes { writeAll(fd, $0.baseAddress!, $0.count) }
                continue
            }
            let off = mode == .left ? 0 : 1
            dup.removeAll(keepingCapacity: true)
            for i in stride(from: 0, to: pcm.count - 1, by: 2) { dup.append(pcm[i + off]); dup.append(pcm[i + off]) }
            dup.withUnsafeBytes { writeAll(fd, $0.baseAddress!, $0.count) }
        }
    }

    var written = 0                 // 已輸出的 frame 數；基準線＝牆鐘，tap 在系統靜音時（包括剛啟動）完全不送資料，所以一開始就要補
    var scheduled: [(frame: Int, path: String, mode: Mode, fd: Int32)] = []  // fd：新輸出預先開好的，既有輸出是 -1
    var activeText: String?         // 已收下、排程還沒全部執行的路由檔內容；執行完才回報 .active
    func markActive() {
        guard scheduled.isEmpty, let t = activeText, let file = routesFile else { return }
        activeText = nil
        try? t.write(toFile: file + ".active", atomically: true, encoding: .utf8)
    }
    func setMode(_ path: String, _ mode: Mode, newFd: Int32) {
        guard let i = outputs.firstIndex(where: { $0.path == path }) else {
            if newFd >= 0 { outputs.append((path, newFd, mode)) }
            return
        }
        guard outputs[i].mode != .closed else { return }  // X 之後不再打開
        if mode == .closed { close(outputs[i].fd); outputs[i].fd = -1 }
        outputs[i].mode = mode
    }
    // 從 frame `written` 接著寫；遇到排定的 frame 就在那裡切開，切換正好落在那個 frame
    func emitAdvancing(_ pcm: UnsafeBufferPointer<Int16>) {
        var done = 0
        let total = pcm.count / 2
        while true {
            for s in scheduled where s.frame <= written { setMode(s.path, s.mode, newFd: s.fd) }
            scheduled.removeAll { $0.frame <= written }
            markActive()
            if done == total { break }
            let n = min(total - done, (scheduled.map { $0.frame }.min() ?? Int.max) - written)
            emit(UnsafeBufferPointer(rebasing: pcm[done * 2 ..< (done + n) * 2]))
            done += n
            written += n
        }
    }

    // 路由檔用 mtime（奈秒）加 inode 判斷有沒有換：寫入端是 tmp＋mv，inode 會變
    var routesSig = "", lastPoll: Int64 = 0
    func pollRoutes(_ now: Int64) {
        guard let file = routesFile, now - lastPoll >= 100_000_000 else { return }
        lastPoll = now
        var st = stat()
        guard stat(file, &st) == 0 else { return }
        let sig = "\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec) \(st.st_ino)"
        guard sig != routesSig else { return }
        routesSig = sig
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return }
        var table: [(path: String, mode: Mode, at: Int?)] = []
        for tok in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }) {
            guard let e = parseSpec(tok) else { err("split: 路由檔格式不對，整份忽略（\(tok)）"); return }
            table.append(e)
        }
        // 先整份驗過再動：排定的 frame 不能已經寫出去，新輸出要開得起來。有一項不行就整份不套用、不回報
        var incoming: [(frame: Int, path: String, mode: Mode, fd: Int32)] = []
        func reject(_ why: String) { err("split: \(why)，整份不套用"); for s in incoming where s.fd >= 0 { close(s.fd) } }
        for (path, mode, at) in table {
            guard let at = at else { continue }
            guard at >= written else { reject("\(path) 排定的 frame \(at) 已經寫出（現在 \(written)）"); return }
            var fd: Int32 = -1
            let known = outputs.first { $0.path == path }
            guard known?.mode != .closed || mode == .closed else { reject("\(path) 已經關掉，不能再排程"); return }
            if mode != .closed, known == nil {
                // 非阻塞開啟：FIFO 沒有讀端時直接失敗而不是卡住全部輸出；開好再改回阻塞寫，和其他輸出一樣
                fd = open(path, O_WRONLY | O_NONBLOCK)
                guard fd >= 0 else { reject("開不了 \(path)"); return }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            }
            incoming.append((at, path, mode, fd))
        }
        for s in scheduled where s.fd >= 0 { close(s.fd) }  // 新的一份取代還沒生效的排程
        scheduled = incoming
        for (path, mode, at) in table where at == nil { setMode(path, mode, newFd: -1) }
        // 套用完才回報：寫入端等到這份 ack 才能斷開被移除的輸出（斷開後讀端不再讀，FIFO 會寫滿卡住 split）。atomically 即 tmp＋rename
        try? text.write(toFile: file + ".applied", atomically: true, encoding: .utf8)
        activeText = text  // 取代還沒生效排程的新檔會蓋掉舊的，舊的就永遠不會有 .active
        markActive()
    }

    let eq = Equalizer(fs: fs)
    var eqSig = "", eqPoll: Int64 = 0
    func pollEq(_ now: Int64) {
        guard let file = eqFile, now - eqPoll >= 200_000_000 else { return }
        eqPoll = now
        var st = stat()
        let sig = stat(file, &st) == 0 ? "\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec) \(st.st_ino)" : "none"
        guard sig != eqSig else { return }
        eqSig = sig
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let g = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Int($0) }
        if g.count == 3, g.allSatisfy({ (-12...12).contains($0) }) { eq.set(g.map(Double.init)) } else { eq.set([0, 0, 0]) }
        err("split: eq \(eq.gains.map { Int($0) })")
    }
    var eqBuf: [Int16] = []

    _ = fcntl(0, F_SETFL, fcntl(0, F_GETFL) | O_NONBLOCK)
    let t0 = rawNs()
    var tv = timespec()
    clock_gettime(CLOCK_REALTIME, &tv)
    err(String(format: "split: t0_unix=%.6f", Double(tv.tv_sec) + Double(tv.tv_nsec) / 1e9))  // 樣本 0 寫出的時間
    var pending = [UInt8]()
    var silenceFrames = 0, droppedFrames = 0, lastLog = -1
    var buf = [UInt8](repeating: 0, count: 65536)
    var pfd = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
    while true {
        _ = poll(&pfd, 1, 5)  // 每 5 ms 檢查一次
        let n = buf.withUnsafeMutableBytes { read(0, $0.baseAddress!, $0.count) }
        if n == 0 { break }  // 上游結束
        if n > 0 { pending.append(contentsOf: buf[0..<n]) }
        let nowNs = rawNs()
        pollRoutes(nowNs)
        pollEq(nowNs)
        let elapsed = Double(nowNs - t0) / 1e9
        let due = Int(elapsed * fs)  // 照牆鐘此刻應該輸出到第幾個 frame
        let frames = pending.count / 4
        if frames > 0 {
            let take = min(frames, max(0, due + maxAhead - written))
            droppedFrames += frames - take
            if take > 0 {  // 丟最舊的、留最新的，延遲才不會被拉長
                pending.withUnsafeBytes { raw in
                    let s = raw.bindMemory(to: Int16.self)
                    let slice = UnsafeBufferPointer(rebasing: s[(frames - take) * 2 ..< frames * 2])
                    if eq.flat { emitAdvancing(slice); return }
                    eqBuf.removeAll(keepingCapacity: true)
                    eqBuf.append(contentsOf: slice)
                    eqBuf.withUnsafeMutableBufferPointer { eq.process($0) }
                    eqBuf.withUnsafeBufferPointer { emitAdvancing($0) }
                }
            }
            pending.removeFirst(frames * 4)
        } else if written < due - idle {  // 斷流：補靜音到基準線
            let gap = due - written
            let zeros = [Int16](repeating: 0, count: gap * 2)
            zeros.withUnsafeBufferPointer { emitAdvancing($0) }
            silenceFrames += gap
        }
        let sec = Int(elapsed)
        if sec % 10 == 0, sec != lastLog, silenceFrames > 0 || droppedFrames > 0 {
            lastLog = sec
            err(String(format: "split: 補靜音 %.0f ms，丟棄 %.0f ms",
                       Double(silenceFrames) / fs * 1000, Double(droppedFrames) / fs * 1000))
            silenceFrames = 0
            droppedFrames = 0
        }
    }
}

/// 三段等化器：低音 low shelf 100 Hz、中音 peaking 1 kHz、高音 high shelf 8 kHz（RBJ Audio EQ Cookbook）。
/// 有任何一段提高時整體先降同樣的 dB 留餘裕，否則大聲的歌一提低音就削波爆音；最後仍超出就硬限幅。
/// 左右聲道各自一組濾波器狀態，改設定時保留狀態，只換係數，切換不會有一聲爆音
final class Equalizer {
    struct Biquad { var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0 }
    let fs: Double
    private(set) var gains = [0.0, 0.0, 0.0]
    private(set) var flat = true
    private var bands = [Biquad](repeating: Biquad(), count: 3)
    private var z = [Double](repeating: 0, count: 3 * 2 * 2)  // band × 聲道 × (z1, z2)，transposed direct form II
    private var pre = 1.0
    init(fs: Double) { self.fs = fs }

    func set(_ g: [Double]) {
        gains = g
        let wasFlat = flat
        flat = g.allSatisfy { $0 == 0 }
        if flat { return }
        if wasFlat { z = z.map { _ in 0 } }  // 從原音切回來：舊狀態是很久以前的，清掉
        bands = [shelf(100, g[0], high: false), peak(1000, g[1], q: 0.7), shelf(8000, g[2], high: true)]
        pre = pow(10, -max(0, g.max() ?? 0) / 20)
    }

    private func shelf(_ f: Double, _ db: Double, high: Bool) -> Biquad {
        let a = pow(10, db / 40), w = 2 * Double.pi * f / fs, c = cos(w)
        let alpha = sin(w) / 2 * sqrt(2)  // 斜率 S = 1
        let k = 2 * sqrt(a) * alpha
        let sgn = high ? -1.0 : 1.0
        let b0 = a * ((a + 1) - sgn * (a - 1) * c + k)
        let b1 = sgn * 2 * a * ((a - 1) - sgn * (a + 1) * c)
        let b2 = a * ((a + 1) - sgn * (a - 1) * c - k)
        let a0 = (a + 1) + sgn * (a - 1) * c + k
        let a1 = -sgn * 2 * ((a - 1) + sgn * (a + 1) * c)
        let a2 = (a + 1) + sgn * (a - 1) * c - k
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
    private func peak(_ f: Double, _ db: Double, q: Double) -> Biquad {
        let a = pow(10, db / 40), w = 2 * Double.pi * f / fs, alpha = sin(w) / (2 * q), c = cos(w)
        let a0 = 1 + alpha / a
        return Biquad(b0: (1 + alpha * a) / a0, b1: -2 * c / a0, b2: (1 - alpha * a) / a0,
                      a1: -2 * c / a0, a2: (1 - alpha / a) / a0)
    }

    /// pcm：交錯的 L, R，原地處理
    func process(_ pcm: UnsafeMutableBufferPointer<Int16>) {
        var i = 0
        while i < pcm.count {
            let ch = i & 1
            var x = Double(pcm[i]) * pre
            for b in 0..<3 {
                let q = bands[b], zi = (b * 2 + ch) * 2
                let y = q.b0 * x + z[zi]
                z[zi] = q.b1 * x - q.a1 * y + z[zi + 1]
                z[zi + 1] = q.b2 * x - q.a2 * y
                x = y
            }
            pcm[i] = Int16(max(-32768, min(32767, x.rounded())))
            i += 1
        }
    }
}
