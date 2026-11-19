#!/bin/zsh
# 取得兩個上游專案、套上 patches/ 裡的修改、編出 app/build.sh 要打包的執行檔：
#   airplay-cli（cliairplay，GPLv3）→ airplay-cli/bin/cliairplay-macos-arm64
#   audiotee（MIT）                → audiotee/.build/release/audiotee
# 用法：zsh scripts/fetch-deps.sh（需要 Xcode 或 Command Line Tools）
set -eu
ROOT=${0:A:h:h}
export MACOSX_DEPLOYMENT_TARGET=14.4  # 系統錄音（process tap）從 14.4 才有
# 殼層裡的編譯旗標（例如 Homebrew 教人設的 CPPFLAGS）會被編進執行檔，發佈版就不再只來自這份原始碼
unset CFLAGS CPPFLAGS CXXFLAGS LDFLAGS EXTRA_CFLAGS EXTRA_LDFLAGS MAKEFLAGS MFLAGS
[[ $(uname -m) == arm64 ]] || { echo "需要 Apple 晶片的 Mac：執行檔只做 arm64"; exit 1; }

fetch() {  # 資料夾 網址 commit
  local dir=$ROOT/$1 url=$2 rev=$3 p
  [[ -d $dir/.git ]] || git clone --quiet "$url" "$dir"
  local -a patches=($ROOT/patches/$1/*.diff(N))
  # 已經套過（例如開發用的那份）就不再動它
  if (( $#patches )) && git -C "$dir" apply --reverse --check $patches 2>/dev/null; then
    echo "$1: patches already applied"
    # 開發用的 clone 可能停在別的 commit：發布用的版本要從乾淨 clone 建，這裡只提醒
    [[ $(git -C "$dir" rev-parse HEAD) == $rev ]] || echo "$1: note: checkout is not at $rev, rebuild from a fresh clone for a release"
    return
  fi
  git -C "$dir" fetch --quiet origin "$rev" 2>/dev/null || true
  git -C "$dir" checkout --quiet --detach "$rev"
  git -C "$dir" submodule update --quiet --init --recursive
  for p in $patches; do  # 只套上新加的：舊 checkout 已經有前面幾份，重套會失敗
    if git -C "$dir" apply --reverse --check "$p" 2>/dev/null; then echo "$1: ${p:t} already applied"; continue; fi
    git -C "$dir" apply "$p"; echo "$1: applied ${p:t}"
  done
}

fetch airplay-cli https://github.com/music-assistant/airplay-cli.git 0a58c239d5fb3cf8927b9707a71c6fe897266b6a
fetch audiotee https://github.com/makeusabrew/audiotee.git 56ac954369a09318e46b88a6eec33c2d2b0d32a3

# 編譯器會把原始碼的絕對路徑寫進執行檔（__FILE__、除錯資訊），裡面有建置者的使用者名稱：一律改寫成相對路徑。
# 單引號是給 Makefile 展開後的 shell 看的，路徑有空白也不會被拆開。路徑裡的單引號和 $ 擋不住，直接拒絕
[[ $ROOT != *[\'\$]* ]] || { echo "repo 的路徑不能有單引號或 \$：$ROOT"; exit 1; }
make -C "$ROOT/airplay-cli" -j8 STATIC=1 CC=clang CXX=clang++ EXTRA_CFLAGS="'-ffile-prefix-map=$ROOT/='"  # STATIC=1：不依賴 Homebrew 的 OpenSSL
(cd "$ROOT/audiotee" && swift build -c release -Xswiftc -file-prefix-map -Xswiftc "$ROOT/=")
echo "ok: now run zsh app/build.sh"
