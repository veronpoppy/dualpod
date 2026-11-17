#!/bin/zsh
# 自己的修改版（總音量、左右連動、鍵盤音量、等化器）跟上官方新版：
#   1. 把官方最新的 release tag 併進目前的分支
#   2. 重新抓相依元件、編譯
#   3. 結束執行中的 DualPod，換掉 /Applications/DualPod.app 再打開
# 用法：zsh scripts/update-mine.sh（第一次安裝也是跑這支）
# 打開後選單若出現「更新背景服務…」，點它並輸入 Mac 密碼，背景服務才會換成新版。
set -eu
ROOT=${0:A:h:h}
cd $ROOT
UPSTREAM=https://github.com/NightLightTw/dualpod.git

[[ -z $(git status --porcelain --untracked-files=no) ]] || { echo "有還沒 commit 的修改，先處理再跑"; exit 1; }
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream $UPSTREAM
git fetch --quiet --tags upstream
tag=$(git tag --list 'v*' --sort=-v:refname | head -1)
[[ -n $tag ]] || { echo "抓不到官方的 release tag"; exit 1; }
if git merge-base --is-ancestor $tag HEAD; then
  echo "已經包含官方 $tag"
else
  echo "併入官方 $tag…"
  if ! git -c user.name=dualpod-update -c user.email=dualpod-update@localhost merge --no-edit $tag; then
    git merge --abort
    echo "官方 $tag 和自己的修改衝突，沒辦法自動合併。目前的 App 沒動，把這段訊息貼給 Claude 處理。"
    exit 1
  fi
fi

# 官方可能換了相依元件的版本：每次都從乾淨的 clone 重建，不沿用舊的
rm -rf airplay-cli audiotee
zsh scripts/fetch-deps.sh
zsh app/build.sh

osascript -e 'tell application id "local.airplay-stereo.menu" to quit' 2>/dev/null || pkill -x StereoMenu 2>/dev/null || true
sleep 1
rm -rf /Applications/DualPod.app
cp -R app/DualPod.app /Applications/
open /Applications/DualPod.app
echo "完成：DualPod（官方 $tag ＋ 自己的修改）已安裝。選單若出現「更新背景服務…」請點它。"
