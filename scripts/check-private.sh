#!/bin/zsh
# 推送前擋下個人資料：掃一段 commit 新增的行（二進位檔逐位元組當文字比）、新增或改名的檔名、commit 訊息與作者 email，
# 有本機路徑、私有網段 IP、MAC、AirPlay 裝置 ID、非 noreply 的 email 就失敗。git 出錯也算失敗，不會放行。
# shortcut: 有意的取捨，誤擋就加 allow、漏抓遇到再加規則：通用的 /tmp/ 不抓（程式自己用 /tmp/cliairplay-pair）；
#   UTF-16 或壓縮過的二進位內容掃不到；裝置 ID 只抓大寫（小寫 12 位會擋到一堆 hash），大寫的 12 位 hash 會被誤擋；
#   四段版本號如 10.1.2.3 會被當成私有 IP  check-private: allow
# 用法：zsh scripts/check-private.sh [git rev-list 的參數，預設 origin/dev..HEAD]
# 一行確定沒問題（例如文件裡的範例）時，在那一行加上 check-private: allow
set -u
(( $# )) || set -- origin/dev..HEAD
die() { print -r -- "check-private: $*" >&2; exit 2 }
# 每條：說明<tab>正則（grep -E，不分大小寫的另外標 i）
rules=(
  $'本機家目錄路徑\t/Users/[^/$[:space:]"'"'"'`)]+'  # check-private: allow
  $'Linux 或 Windows 家目錄\t/home/[^/$[:space:]"'"'"'`)]+|[A-Za-z]:.[Uu][Ss][Ee][Rr][Ss].'  # check-private: allow
  $'家目錄下的資料夾\t~/[^/[:space:]]+/'  # check-private: allow
  $'暫存或外接磁碟路徑\t/private/tmp/|/private/var/folders/|/var/folders/|/Volumes/[^/[:space:]]+|/media/[^/[:space:]]+'  # check-private: allow
  $'私有網段 IPv4\t(^|[^0-9.])(10(\\.(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}|192\\.168(\\.(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){2}|172\\.(1[6-9]|2[0-9]|3[01])(\\.(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){2})([^0-9]|$)'  # check-private: allow
  $'本機 IPv6\ti\t(^|[^0-9a-z:])(fe[89ab][0-9a-f]|f[cd][0-9a-f]{2}):[0-9a-f]{0,4}:'  # check-private: allow
  $'MAC 位址\t([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}'  # check-private: allow
  $'AirPlay 裝置 ID（12 位大寫十六進位）\t(^|[^0-9A-Za-z])[0-9A-F]{12}([^0-9A-Za-z]|$)'  # check-private: allow
)
commits=$(git rev-list --reverse "$@") || die "git rev-list $* 失敗"
found=0
for c in ${(f)commits}; do
  # 和第一個 parent 比（合併 commit 也看得到整段帶進來的內容）；第一個 commit 和空樹比。
  # 新增行用 > 標記，檔頭的 +++ 不會和內容混在一起；--text 讓二進位檔也逐位元組比對
  parent=$(git rev-parse -q --verify "$c^1") || parent=$(git hash-object -t tree /dev/null)
  diff=$(git diff --no-color --no-ext-diff --text --unified=0 --output-indicator-new='>' $parent $c) || die "git diff $c 失敗"
  names=$(git diff --name-only --diff-filter=ACR $parent $c) || die "git diff --name-only $c 失敗"
  msg=$(git log -1 --format=%B $c) || die "git log $c 失敗"
  text=$msg$'\n'$names$'\n'${(F)${(M)${(f)diff}:#>*}#>}
  ids=$(git log -1 --format='%ae%n%ce' $c) || die "git log $c 失敗"
  mails=$(print -r -- $ids | grep -viE '^[^@]+@users\.noreply\.github\.com$|^noreply@[^@]+$') && {
    print -r -- "✗ $(git log -1 --format='%h %s' $c)：作者或提交者 email 不是 noreply（git config user.email 改成 GitHub 給的 noreply 位址）"
    print -r -- $mails | sort -u | sed 's/^/    /'; found=1 }
  for r in $rules; do
    local -a f=(${(ps:\t:)r})
    t=$text
    [[ $f[1] == 家目錄下的資料夾 ]] && t=${text//\~\/Library\//}  # ~/Library/Application Support 這類是通用路徑：只拿掉這一段，同一行的其他路徑照樣檢查
    if (( $#f == 3 )); then hits=$(print -r -- $t | grep -niE -- $f[3]); else hits=$(print -r -- $t | grep -nE -- $f[2]); fi
    hits=$(print -r -- $hits | grep -v 'check-private: allow')
    [[ -z $hits ]] && continue
    print -r -- "✗ $(git log -1 --format='%h %s' $c)：$f[1]"
    print -r -- $hits | head -5 | sed 's/^/    /'
    found=1
  done
done
(( found )) && { print "有疑似個人資料。刪掉或換成通用寫法；確定沒問題就在該行加 check-private: allow"; exit 1 }
print "check-private: $* 沒有發現個人資料"
