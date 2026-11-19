# 用法：python3 -I tools/split_test.py <暫存資料夾> tools/stereotool（或舊的 tools/split.py）
# 自測 split：(1) L/R/LR 三種輸出的內容正確（開頭可能先補靜音，比對前先去掉）(2) --routes 即時改路由：換路由後
# 留下的輸出時間軸連續、被 X 的輸出不再收到資料也不卡住其他輸出
import os, subprocess, sys, array, threading, time
d, split = sys.argv[1], sys.argv[2]
paths = [f"{d}/sp-{n}" for n in "abc"]
for p in paths:
    if os.path.exists(p): os.remove(p)
    os.mkfifo(p)
n = 4410
src = array.array("h")
for k in range(1, n + 1): src.extend([k, -k])  # L=k, R=-k
cmd = [sys.executable, "-I", split] if split.endswith(".py") else [split, "split"]  # split.py 或 stereotool
pr = subprocess.Popen(cmd + [paths[0] + ":L", paths[1] + ":R", paths[2] + ":LR"],
                      stdin=subprocess.PIPE, stderr=subprocess.DEVNULL)
got = [b"", b"", b""]
def reader(i):
    fd = os.open(paths[i], os.O_RDONLY)
    end = time.time() + 1.5
    while time.time() < end:
        try: got[i] += os.read(fd, 65536)
        except BlockingIOError: pass
threads = [threading.Thread(target=reader, args=(i,)) for i in range(3)]
for t in threads: t.start()
time.sleep(0.2)
b = src.tobytes()
nxt = time.time()
for i in range(0, len(b), 3528):  # 和 tap 一樣每 20 ms 送一塊（照絕對時間，免得 sleep 誤差累積成補靜音）；一次全塞會被當成超前而丟掉
    nxt += 0.02
    pr.stdin.write(b[i:i + 3528]); pr.stdin.flush(); time.sleep(max(0, nxt - time.time()))
for t in threads: t.join()
pr.kill()
def body(b):
    a = array.array("h", b[: len(b) // 2 * 2]); i = 0
    while i < len(a) and a[i] == 0: i += 1
    return list(a[i:])
# 起播時若 split 還沒讀、已經積了好幾塊，會當成積壓只留最新一塊，所以內容可以從後面某一塊的開頭開始；之後要原樣連續到結尾
k1 = abs(body(got[2])[0])  # LR 輸出的第一個樣本編號
assert (k1 - 1) % 882 == 0 and k1 - 1 < n, f"開頭只能少整數塊、而且不能全丟（從第 {k1} 個 frame 開始）"
L, R = list(src[0::2])[k1 - 1:], list(src[1::2])[k1 - 1:]
dup = lambda x: [v for v in x for _ in (0, 1)]
want = list(src)[(k1 - 1) * 2:]  # 結尾之後 split 會補靜音，只比到來源結束
assert body(got[0])[:len(want)] == dup(L), "L"
assert body(got[1])[:len(want)] == dup(R), "R"
assert body(got[2])[:len(want)] == want, "LR"
print("split self-test ok")


# (2) 即時改路由。每個 FIFO 另外留一個 O_RDWR（和 run_pair 一樣），所以 b 的讀端停了也不會 EPIPE，只會寫滿卡住
import select
names = ["a", "b", "m"]
fp = {k: f"{d}/rt-{k}" for k in names}
for p in fp.values():
    if os.path.exists(p): os.remove(p)
    os.mkfifo(p)
routes = f"{d}/routes"
def put_routes(text):
    for ext in (".applied", ".active"):
        if os.path.exists(routes + ext): os.remove(routes + ext)  # 和 reroute 一樣先清舊 ack，免得上一輪殘留的被當成這次的
    with open(routes + ".tmp", "w") as f: f.write(text)
    os.rename(routes + ".tmp", routes)
put_routes(f"{fp['a']}:L {fp['b']}:R {fp['m']}:0")
holders = [os.open(p, os.O_RDWR) for p in fp.values()]
pr = subprocess.Popen([split, "split", "--routes", routes, f"{fp['a']}:L", f"{fp['b']}:R", f"{fp['m']}:0"],
                      stdin=subprocess.PIPE, stderr=subprocess.DEVNULL)
chunks = {k: [] for k in names}  # (收到時間, bytes)
stop = {k: False for k in names}
def rd(k):
    fd = os.open(fp[k], os.O_RDONLY | os.O_NONBLOCK)
    while not stop[k]:
        if select.select([fd], [], [], 0.05)[0]:
            try: b = os.read(fd, 65536)
            except BlockingIOError: continue
            if b: chunks[k].append((time.time(), b))
    os.close(fd)
threads = [threading.Thread(target=rd, args=(k,)) for k in names]
for t in threads: t.start()
time.sleep(0.2)
W = 32000
k0 = 0
def feed(secs):  # 照絕對時間送，不累積 sleep 的誤差，輸入才不會比牆鐘慢而被補靜音
    global k0
    nxt = time.time()
    for _ in range(int(secs / 0.02)):
        nxt += 0.02
        a = array.array("h")
        for k in range(k0, k0 + 882): a.extend([k % W + 1, -(k % W + 1)])
        k0 += 882
        pr.stdin.write(a.tobytes()); pr.stdin.flush(); time.sleep(max(0, nxt - time.time()))
feed(1.0)
t_switch = time.time()
put_routes(f"{fp['a']}:LR {fp['b']}:X {fp['m']}:LR")
ok = []
def handshake():  # 和 stereo.sh reroute 一樣：等 split 回報已套用，才讓 b 的讀端消失；沒等的話 split 會卡在寫 b，永遠看不到 X
    ack = routes + ".applied"
    end = time.time() + 2
    want = open(routes).read()
    while time.time() < end:
        try:
            if open(ack).read() == want: break
        except FileNotFoundError: pass
        time.sleep(0.01)
    else: raise AssertionError("split 沒有回報已套用")
    stop["b"] = True
    ok.append(1)  # 只有成功才設；thread 裡的例外主執行緒看不到，所以靠這個旗標
hs = threading.Thread(target=handshake); hs.start()  # 不能停餵，否則會被補靜音
feed(1.5)
hs.join()
t_end = time.time()
time.sleep(0.2)
stop["a"] = stop["m"] = stop["b"] = True  # ack 沒來時 b 不會被 handshake 停掉，這裡補停才不會卡在 join
for t in threads: t.join()
pr.kill()
assert ok, "split 沒有回報已套用（.applied）"
def frames(k):
    a = array.array("h", b"".join(b for _, b in chunks[k])); return list(zip(a[0::2], a[1::2]))
fa, fb, fm = frames("a"), frames("b"), frames("m")
sw_a = next(i for i, (l, r) in enumerate(fa) if l != r)  # a 從 L 變 LR 的第一個 frame
sw_m = next(i for i, (l, r) in enumerate(fm) if l != 0 or r != 0)
assert sw_a == sw_m, f"a、m 切換點的 frame 數要一樣（同一條時間軸）：{sw_a} vs {sw_m}"
assert all(l == r and l >= 0 for l, r in fa[:sw_a]), "a 切換前是 L 複製成雙聲道"
assert all(f == (0, 0) for f in fm[:sw_m]), "m 切換前全是靜音"
assert all(r == -l and l >= 0 for l, r in fa[sw_a:]) and fa[sw_a:] == fm[sw_m:] and len(fa) == len(fm), "切換後 a、m 都是原樣立體聲且一模一樣"
assert all(l == r and l <= 0 for l, r in fb) and len(fb) == sw_a, f"b 只收到切換前的 R，之後什麼都沒有：{len(fb)} vs {sw_a}"
src_l = [l for l, _ in fa if l != 0]
assert all((y - x) % W == 1 for x, y in zip(src_l, src_l[1:])), "a 的樣本編號跨過切換仍連續（沒丟沒重複）"
after = [t for t, _ in chunks["a"] if t_switch < t < t_end]
gap = max(y - x for x, y in zip(after, after[1:]))
assert len(fa) > sw_a + 10000 and len(fm) > sw_m + 10000, "切換後 a、m 持續收到資料"
assert gap < 0.06, f"a 切換後的最大到達間隔 {gap:.3f}s"
print(f"split reroute self-test ok (switch at frame {sw_a}, b frames {len(fb)}, a gap {gap*1000:.0f} ms)")


# (3) 排定時刻的路由（播放中加入一台）：a:LR、m:0 在播，先給一份太晚的（不能套用也不能回報），
# 再給 a:L@T2 b2:R@T2：a 正好在 frame k2 從 LR 變 L，b2 的第一個 frame 就是內容的 frame k2
T = 1_000_000
names = ["a", "b2", "b3", "m"]
fp = {k: f"{d}/jn-{k}" for k in names}
for p in fp.values():
    if os.path.exists(p): os.remove(p)
    os.mkfifo(p)
if os.path.exists(routes): os.remove(routes)
holders = [os.open(p, os.O_RDWR) for p in fp.values()]
pr = subprocess.Popen([split, "split", "--routes", routes, "--start-ms", str(T), f"{fp['a']}:LR", f"{fp['m']}:0"],
                      stdin=subprocess.PIPE, stderr=subprocess.DEVNULL)
chunks = {k: [] for k in names}
stop = {k: False for k in names}
threads = [threading.Thread(target=rd, args=(k,), daemon=True) for k in names]  # daemon：中途 assert 失敗時不會卡在讀端
for t in threads: t.start()
time.sleep(0.2)
k0 = 0
feed(1.0)
put_routes(f"{fp['a']}:L@{T + 500} {fp['b3']}:R@{T + 500} {fp['m']}:0")  # frame 22050 早就寫出去了
feed(0.5)
assert not os.path.exists(routes + ".applied"), "太晚的排程不能回報已套用"
assert not os.path.exists(routes + ".active"), "太晚的排程不能回報已執行"
T2 = T + 2600
k2 = round((T2 - T) * 44.1)
t_switch = time.time()
put_routes(f"{fp['a']}:L@{T2} {fp['b2']}:R@{T2} {fp['m']}:0")
feed(0.3)
assert open(routes + ".applied").read() == open(routes).read(), "排定的路由一收下就回報（不等到生效）"
assert not os.path.exists(routes + ".active"), "排程還沒到 frame k2，不能回報已執行（.active）"
feed(1.2)
t_end = time.time()
time.sleep(0.2)
for k in names: stop[k] = True
for t in threads: t.join()
pr.kill()
assert open(routes + ".active").read() == open(routes).read(), "frame k2 寫出後 .active 內容要和路由檔一樣"
fa, fb2, fb3, fm = (frames(k) for k in names)
assert not fb3, "太晚那份的新輸出不能收到任何資料"
sw = next(i for i, (l, r) in enumerate(fa) if l == r and l > 0)  # a 第一個「L 複製成雙聲道」的 frame
assert sw == k2, f"a 要正好在 frame {k2} 切換，實際 {sw}"
assert all(r == -l for l, r in fa[:k2]) and all(l == r for l, r in fa[k2:]), "a 切換前是原樣立體聲、之後全是 L"
assert len(fa) > k2 + 10000 and fb2[:1000] and fb2 == [(-l, -l) for l, _ in fa[k2:k2 + len(fb2)]], "b2 從內容的 frame k2 起收 R，一個 frame 都不差"
assert abs(len(fb2) - (len(fa) - k2)) < 4410, "b2 和 a 一路寫到同一個位置"
src_l = [l for l, _ in fa if l != 0]
assert all((y - x) % W == 1 for x, y in zip(src_l, src_l[1:])), "a 的樣本編號跨過切換仍連續"
assert all(f == (0, 0) for f in fm) and abs(len(fm) - len(fa)) < 4410, "m 全程靜音、沒有卡住"
after = [t for t, _ in chunks["a"] if t_switch < t < t_end]
gap = max(y - x for x, y in zip(after, after[1:]))
assert gap < 0.06, f"a 在加入期間的最大到達間隔 {gap:.3f}s"
print(f"split join self-test ok (a switches and b2 starts at frame {k2}, a gap {gap*1000:.0f} ms)")


# (4) 新的路由檔取代還沒生效的排程：舊的那份永遠不會有 .active，沒有 @ 的新檔一套用就有
names = ["a", "b2", "m"]
fp = {k: f"{d}/rp-{k}" for k in names}
for p in fp.values():
    if os.path.exists(p): os.remove(p)
    os.mkfifo(p)
holders = [os.open(p, os.O_RDWR) for p in fp.values()]
pr = subprocess.Popen([split, "split", "--routes", routes, "--start-ms", str(T), f"{fp['a']}:LR", f"{fp['m']}:0"],
                      stdin=subprocess.PIPE, stderr=subprocess.DEVNULL)
chunks = {k: [] for k in names}
stop = {k: False for k in names}
threads = [threading.Thread(target=rd, args=(k,), daemon=True) for k in names]
for t in threads: t.start()
time.sleep(0.2)
k0 = 0
feed(0.3)
first = f"{fp['a']}:L@{T + 5000} {fp['b2']}:R@{T + 5000} {fp['m']}:0"
put_routes(first)
feed(0.5)
assert open(routes + ".applied").read() == first and not os.path.exists(routes + ".active"), "排程中的檔已 applied、還沒 active"
second = f"{fp['a']}:LR {fp['m']}:0"
put_routes(second)
feed(0.5)
for k in names: stop[k] = True
for t in threads: t.join()
pr.kill()
assert open(routes + ".active").read() == second, "沒有 @ 的新檔套用後 .active 就是它，不是被取代的舊檔"
assert not frames("b2"), "被取代的排程不能執行"
print("split replaced-schedule self-test ok")


# (5) 延遲固定：輸入晚到（啟動慢 60 ms）或斷流後恢復，那批輸入都要排在「收到時刻 + (T − t0)」播出，
# 也就是 run_pair 設的 TARGET，不能被晚到的時間吃掉
names = ["a"]
fp = {"a": f"{d}/ld-a"}
if os.path.exists(fp["a"]): os.remove(fp["a"])
os.mkfifo(fp["a"])
holders = [os.open(fp["a"], os.O_RDWR)]
T = int(time.time() * 1000) + 200
pr = subprocess.Popen([split, "split", "--start-ms", str(T), f"{fp['a']}:LR"], stdin=subprocess.PIPE, stderr=subprocess.PIPE)
t0 = float(pr.stderr.readline().decode().split("t0_unix=")[1]) * 1000
chunks = {"a": []}
stop = {"a": False}
threads = [threading.Thread(target=rd, args=("a",), daemon=True)]
for t in threads: t.start()
time.sleep(0.06)
k0 = 0
t_first = time.time() * 1000
feed(1.0)
time.sleep(0.15)
k_resume, t_resume = k0, time.time() * 1000
feed(0.5)
time.sleep(0.2)
stop["a"] = True
for t in threads: t.join()
pr.kill()
fa = frames("a")
z1 = next(i for i, (l, _) in enumerate(fa) if l != 0)
z2 = next(i for i, (l, _) in enumerate(fa) if l == k_resume % W + 1 and i >= z1 + k_resume)  # 編號每 W 個繞回，從第一段之後找
want = T - t0
lead1, lead2 = T + z1 / 44.1 - t_first, T + z2 / 44.1 - t_resume
assert abs(lead1 - want) < 20, f"晚 60 ms 才來的第一批輸入，延遲要是 {want:.0f} ms，實際 {lead1:.0f}"
assert abs(lead2 - want) < 20, f"斷流 150 ms 後恢復，延遲要是 {want:.0f} ms，實際 {lead2:.0f}"
print(f"split fixed-latency self-test ok (want {want:.0f} ms, start {lead1:.0f}, after stall {lead2:.0f})")


# (6) 起播時 tap 已經積了一批（50 ms）：只留最新的 20 ms（一塊的長度），延遲才不會被那批舊樣本拉長
names = ["a"]
if os.path.exists(fp["a"]): os.remove(fp["a"])
os.mkfifo(fp["a"])
holders = [os.open(fp["a"], os.O_RDWR)]
T = int(time.time() * 1000) + 200
pr = subprocess.Popen([split, "split", "--start-ms", str(T), f"{fp['a']}:LR"], stdin=subprocess.PIPE, stderr=subprocess.PIPE)
t0 = float(pr.stderr.readline().decode().split("t0_unix=")[1]) * 1000
chunks = {"a": []}
stop = {"a": False}
threads = [threading.Thread(target=rd, args=("a",), daemon=True)]
for t in threads: t.start()
time.sleep(0.06)
k0 = 0
backlog = array.array("h")
for k in range(2205): backlog.extend([k % W + 1, -(k % W + 1)])  # 50 ms，一次寫入
k0 = 2205
t_first = time.time() * 1000
pr.stdin.write(backlog.tobytes()); pr.stdin.flush()
time.sleep(0.03)  # 讓 split 先讀到這批；feed 的第一塊若同時到，最新 20 ms 會是它而不是這批
feed(0.5)
time.sleep(0.2)
stop["a"] = True
for t in threads: t.join()
pr.kill()
fa = frames("a")
zn = next(i for i, (l, _) in enumerate(fa) if l == 2205)  # 那批最新的一個樣本
want = T - t0 + 20
lead = T + zn / 44.1 - t_first
assert abs(lead - want) < 10, f"起播時積了 50 ms，最新樣本的延遲要是 {want:.0f} ms，實際 {lead:.0f}"
print(f"split backlog self-test ok (want {want:.0f} ms, got {lead:.0f})")
