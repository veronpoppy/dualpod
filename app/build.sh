#!/bin/zsh
# 編出選單列 app：zsh app/build.sh → app/DualPod.app（自己用）
# 給別人：在 vX.Y.Z tag 的乾淨 clone 跑 scripts/fetch-deps.sh，再 zsh app/build.sh dist → dist/DualPod-X.Y.Z.zip
set -eu
cd ${0:A:h}
TARGET=arm64-apple-macos14.4  # 系統錄音（process tap）從 14.4 才有；不指定會變成只能在編譯這台的版本上跑
die() { echo "$1" >&2; exit 1; }
if [[ ${1:-} == dist ]]; then
  # 發佈的 zip 要能對回一個 tag 的原始碼（GPLv3 要提供對應原始碼）：工作目錄乾淨、HEAD 正好在 vX.Y.Z tag 上，
  # 兩個上游專案停在 fetch-deps.sh 寫的 commit、只多了 patches/ 的修改
  [[ -z $(git -C .. status --porcelain) ]] || die "有未提交的修改，先 commit 再打包"
  TAG=$(git -C .. describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null) || die "HEAD 不在 vX.Y.Z 的 tag 上"
  [[ $TAG == v<->.<->.<-> ]] || die "tag 要是 vX.Y.Z 格式：$TAG"
  VERSION=${TAG#v}
  # 先清掉之前的建置產物：打包的執行檔要從下面驗過的原始碼重編（git 看不到建置產物，cliairplay 也會在 submodule 裡產生檔案）
  make -C ../airplay-cli clean >/dev/null; make -C ../airplay-cli clean STATIC=1 CC=clang CXX=clang++ >/dev/null
  rm -rf ../audiotee/.build
  awk '$1 == "fetch" { print $2, $4 }' ../scripts/fetch-deps.sh | while read dep rev; do
    [[ $(git -C ../$dep rev-parse HEAD) == $rev ]] || die "$dep 不在 $rev：在乾淨 clone 跑 scripts/fetch-deps.sh"
    patches=(${PWD:h}/patches/$dep/*.diff(N))
    if (( $#patches )); then
      git -C ../$dep apply --reverse --check $patches || die "$dep 沒有套上 patches/$dep"
      # 改動的檔案與行數要和 patches 完全一樣：多改一行都會被發現
      [[ $(git -C ../$dep diff HEAD --numstat | sort) == $(git -C ../$dep apply --numstat $patches | sort) ]] ||
        die "$dep 除了 patches 還有別的修改"
    else
      [[ -z $(git -C ../$dep diff HEAD) ]] || die "$dep 有修改"
    fi
    # 未追蹤的檔案也會被編進去（SwiftPM 編整個資料夾）：除了 patches 改的檔案，本身和 submodule 裡都不能多任何檔案
    [[ -z $(git -C ../$dep status --porcelain --untracked-files=all --ignore-submodules=all | grep -v '^ M ') ]] ||
      die "$dep 有不屬於 patches 的檔案"
    [[ -z $(git -C ../$dep submodule status --recursive | grep -v '^ ') ]] || die "$dep 的 submodule 不在固定版本"
    [[ -z $(git -C ../$dep submodule foreach --quiet --recursive 'git status --porcelain --untracked-files=all --ignore-submodules=all') ]] ||
      die "$dep 的 submodule 裡有修改或多出的檔案"
  done
  zsh ../scripts/fetch-deps.sh
  # iCloud 同步的資料夾會一直加回 FinderInfo，整包簽不了，所以到快取資料夾建置
  OUT="$HOME/Library/Caches/airplay-stereo-dist"
  rm -rf "$OUT"; mkdir -p "$OUT"
  APP="$OUT/DualPod.app"
else
  APP="DualPod.app"
  VERSION=$(git -C .. describe --tags --always --dirty 2>/dev/null || echo dev)
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -target $TARGET StereoMenu.swift Settings.swift EqMenu.swift Align.swift Update.swift -o "$APP/Contents/MacOS/StereoMenu"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>StereoMenu</string>
  <key>CFBundleIdentifier</key><string>local.airplay-stereo.menu</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleName</key><string>DualPod</string>
  <key>CFBundleDisplayName</key><string>DualPod</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSUIElement</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>DualPod records the Mac's sound to send it to your speakers.</string>
  <key>NSMicrophoneUsageDescription</key><string>Auto-align listens to the speakers to line the Mac up with the HomePods.</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
</dict></plist>
EOF
mkdir -p "$APP/Contents/Resources"; cp AppIcon.icns "$APP/Contents/Resources/"  # 由 ../tools/make-icon.swift 從 icon.svg 產生
# 權限提示由 macOS 顯示，跟系統語言走：英文寫在 Info.plist，中文放 zh-Hant.lproj
mkdir -p "$APP/Contents/Resources/zh-Hant.lproj"
cat > "$APP/Contents/Resources/zh-Hant.lproj/InfoPlist.strings" <<'EOF'
"NSAudioCaptureUsageDescription" = "DualPod 會錄下 Mac 的聲音，送到喇叭。";
"NSMicrophoneUsageDescription" = "自動對齊會用麥克風聽喇叭，把 Mac 和 HomePod 對齊。";
EOF
swiftc -O -target $TARGET ../tools/localplay.swift -o ../tools/localplay  # 本機喇叭同步播放器
swiftc -O -target $TARGET ../tools/stereotool.swift -o ../tools/stereotool  # 時鐘與拆聲道（取代 Python）
# 背景服務要裝的檔案打包進 App，App 用管理員密碼視窗安裝或更新；VERSION 是這些檔案的雜湊
RT="$APP/Contents/Resources/runtime"
mkdir -p "$RT/airplay-cli/bin" "$RT/audiotee/.build/release" "$RT/tools"
cp ../run_pair.sh ../stereo.sh install-daemon.sh "$RT/"
cp ../airplay-cli/bin/cliairplay-macos-arm64 "$RT/airplay-cli/bin/"
cp ../audiotee/.build/release/audiotee "$RT/audiotee/.build/release/"
cp ../tools/stereotool ../tools/localplay "$RT/tools/"
# 除錯符號表記著每個 .o 的絕對路徑，裡面有建置者的使用者名稱：發佈版拿掉
[[ ${1:-} == dist ]] && strip -S "$RT/airplay-cli/bin/cliairplay-macos-arm64" "$RT/audiotee/.build/release/audiotee"
(cd "$RT" && find . -type f ! -name VERSION | sort | xargs shasum -a 256 | shasum -a 256 | cut -c1-16) > "$RT/VERSION"
HELPERS=("$RT/airplay-cli/bin/cliairplay-macos-arm64" "$RT/audiotee/.build/release/audiotee" "$RT/tools/localplay" "$RT/tools/stereotool")
for f in $HELPERS; do
  lipo -archs "$f" | grep -q arm64 || { echo "$f 不是 arm64"; exit 1; }
done
xattr -cr "$APP"  # 帶著延伸屬性 codesign 會失敗
if [[ ${1:-} == dist ]]; then
  # 臨時簽名（ad-hoc）：沒有 Developer ID 憑證就無法公證，對方第一次開要在「隱私權與安全性」按「強制打開」。
  # 用 ad-hoc 不用 Apple Development 憑證：那張憑證會把你的 email 簽進 App，而且別台 Mac 一樣不認
  for f in $HELPERS; do codesign -s - --force "$f"; done
  codesign -s - --force "$APP"
  codesign --verify --strict --deep --verbose=1 "$APP"
  for f in $HELPERS; do codesign --verify --strict "$f"; done  # 放在 Resources 裡的不算 App 的巢狀程式碼，要各自驗
  # 一個資料夾裝 App 和說明，用 ditto 壓（中文檔名用 UTF-8，zip 指令會變亂碼）
  PKG="$OUT/DualPod"
  mkdir -p "$PKG"; mv "$APP" "$PKG/"; cp ../dist-README.txt "$PKG/Install Guide.txt"; cp ../dist-README.zh-TW.txt "$PKG/安裝說明.txt"
  # GPLv3 與上游授權條款要跟著執行檔一起給；原始碼在 GitHub repo
  cp ../LICENSE ../THIRD_PARTY_NOTICES.md "$PKG/"; mkdir "$PKG/third_party"; cp ../third_party/cliairplay-THIRD_PARTY_NOTICES.md "$PKG/third_party/"  # 和 repo 同路徑，NOTICES 裡的連結才對得上
  mkdir -p ../dist; ZIP=../dist/DualPod-$VERSION.zip; rm -f $ZIP
  ditto -c -k --norsrc --keepParent "$PKG" $ZIP
  echo "dist: ${ZIP:A}"
else
  # shortcut: 專案在 iCloud 同步的 Documents，FinderInfo 會被加回、整包簽不了；執行檔已由 linker 簽好，本機可用
  codesign -s - --force "$APP" 2>/dev/null || echo "(bundle signing skipped: iCloud-synced folder; executable is linker-signed)"
  echo "built: $PWD/$APP"
fi
