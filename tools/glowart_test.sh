#!/bin/zsh
# 用法：zsh tools/glowart_test.sh <暫存資料夾>
# 自測 stereotool glowart：JPEG 結構、尺寸、每條直條的顏色；錯誤參數要以非 0 結束且不留檔案
set -u
S=${1:?暫存資料夾}; HERE=${0:A:h}; T=$HERE/stereotool
rm -rf $S/ga; mkdir -p $S/ga; S=$S/ga
fail() { print -u2 "FAIL: $*"; exit 1 }
check() {  # 檔名 顏色… ：SOI/EOI、512x512、各直條中心像素
  local f=$S/$1; shift
  [[ "$(head -c2 $f | xxd -p)" == ffd8 && "$(tail -c2 $f | xxd -p)" == ffd9 ]] || fail "$f 不是完整 JPEG"
  [[ "$(sips -g pixelWidth -g pixelHeight $f | awk '/pixel/ {printf "%s ", $2}')" == "512 512 " ]] || fail "$f 不是 512x512"
  sips -s format bmp $f --out $f.bmp > /dev/null || fail "sips 轉檔失敗"
  python3 -I - $f.bmp "$@" <<'PY' || fail "$f 顏色不符"
import sys
d = open(sys.argv[1], 'rb').read(); off = int.from_bytes(d[10:14], 'little'); bpp = int.from_bytes(d[28:30], 'little') // 8
cols = sys.argv[2:]; n = len(cols)
for i, c in enumerate(cols):
    x = (2 * i + 1) * 512 // (2 * n)
    for y in (10, 256, 500):
        p = off + ((511 - y) * 512 + x) * bpp
        got = (d[p + 2], d[p + 1], d[p]); want = tuple(int(c[k:k + 2], 16) for k in (0, 2, 4))
        assert all(abs(a - b) <= 6 for a, b in zip(got, want)), (i, y, got, want)
PY
}
$T glowart $S/one.jpg FF2D2D || fail "1 色"; check one.jpg FF2D2D
$T glowart $S/two.jpg 1E40FF ffd400 || fail "2 色"; check two.jpg 1E40FF FFD400
$T glowart $S/three.jpg 00C853 8A2BE2 00B4FF || fail "3 色"; check three.jpg 00C853 8A2BE2 00B4FF
$T glowart $S/four.jpg FF4FA3 B14CFF 4CC9FF 000000 || fail "4 色"; check four.jpg FF4FA3 B14CFF 4CC9FF 000000
$T glowart $S/one.jpg 0000FF || fail "覆寫"; check one.jpg 0000FF
[[ -z "$(print -l $S/*.tmp*(N))" ]] || fail "留下暫存檔"
for bad in "" "GGGGGG" "FFF" "FF2D2D1" "#FF2D2D" "FF2D2D 00 11" "FF0000 00FF00 0000FF FFFFFF 000000" "../x" "ＦＦ００００"; do
  $T glowart $S/bad.jpg ${=bad} 2>/dev/null && fail "[$bad] 應該失敗"
done
$T glowart 2>/dev/null && fail "沒有參數應該失敗"
$T glowart $S/nodir/x.jpg FF0000 2>/dev/null && fail "資料夾不存在應該失敗"
[[ ! -e $S/bad.jpg ]] || fail "失敗時不能留檔案"
print "glowart self-test ok"
