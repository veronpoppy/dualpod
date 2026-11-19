#!/bin/zsh
# AirPlay stereo switch: sudo zsh stereo.sh on [<speaker id>… Mac]|off|status|discover, or `serve <want file>` as the background service
# Speakers are found on the network (discover) and named by their 12-hex-digit AirPlay device id.
# on starts a background watchdog (supervise) that keeps run_pair.sh live running and restarts both speakers
# together when one re-anchors, starves, or a process disappears.
set -u
umask 022
setopt no_bg_nice extended_glob  # zsh 預設讓每層背景工作 nice +5，疊到 cliairplay／audiotee 變 nice 15，起播會慢上百 ms
DIR=${DIR:-${0:A:h}}  # 跟著腳本所在位置走：開發在 Documents，安裝後在 /Library/Application Support/AirPlayStereo
# 狀態放在腳本旁（安裝後是 root 擁有）。放 /tmp 時一般使用者能換掉 pidfile，讓 root 殺錯行程或寫穿 symlink
STATE=${STATE:-$DIR/state}
RUN_PAIR=${RUN_PAIR:-$DIR/run_pair.sh}
TOOL=$DIR/tools/stereotool
LOGDIR=${LOGDIR:-$DIR/logs}
LOG=$LOGDIR/stereo.log
PIDFILE=$STATE/supervisor.pid
DEVFILE=$STATE/devices  # supervisor 正在播的裝置組合
VOLFILE=$STATE/volumes   # 各台 HomePod 音量，serve 從使用者的音量檔整理後寫入
EQFILE=$STATE/eq  # 等化器五段 dB（80 250 1k 4k 12k Hz），serve 從使用者的 eq 檔驗過後寫入；播放中 stereotool split 自己會看到變動
RUNDIR_FILE=$STATE/rundir  # 目前 run_pair 的暫存資料夾（裡面有每台的 cmd 管道）
SPEAKERS=$STATE/speakers  # 找到的喇叭：「ID<tab>IP<tab>名稱」，App 也讀這份
DEVICES=${DEVICES:-}
LATENCY=200 TARGET=200  # 預設。11-12 實測再低會單台 REANCHOR，但當時 split 起播位置還會隨機少 0–80 ms（6dfdb28 已修）
[[ ${BUFFER_MS:-} == <120-500> ]] && LATENCY=$BUFFER_MS TARGET=$BUFFER_MS  # 設定視窗選的緩衝（serve 從使用者的 buffer-ms 讀來）
# 任何一行出現就代表兩台可能不再對齊（單台平移時間軸、斷流、結束）
BAD='REANCHOR|anchor_corrected|content_cut|\[STATUS\] (error|eof|stopped)|PCM input starved|Splice-padded'
MAX_RESTARTS=5 WINDOW_S=300 POLL_S=${POLL_S:-2}

HEARTBEAT=$STATE/heartbeat
mkdir -p $STATE $LOGDIR 2>/dev/null  # App 以一般使用者跑 status 時建不了，也不需要
say() { print -r -- "$(date '+%F %T') $*" >> $LOG; }
# 一般使用者對 root 行程 kill -0 會被拒，改用 ps；同時確認那個 PID 真的是 supervisor，避免 PID 重用時誤判或誤殺
running() {
  [[ -f $PIDFILE && ! -L $PIDFILE ]] || return 1
  local pid=$(head -c 12 $PIDFILE | tr -cd 0-9)
  [[ -n $pid ]] && ps -p $pid -o command= 2>/dev/null | grep -q 'stereo.sh supervise'
}

stop_all() {
  [[ -n ${TEST:-} ]] && return  # 自測時不碰真的 cliairplay
  # 比對任何位置的 run_pair.sh：Documents 裡手動跑的舊 session 結束時會清掉所有 cliairplay，包括新開的。
  # 用行程名稱（-x）或錨定開頭的樣式，不用裸字串 -f：命令列只是「提到」這些字的行程（編輯器、測試腳本）也會被 root 殺掉
  # 給 run_pair 最多 2 秒自己收尾（先送 DISCONNECT 給喇叭），收完就不再等；沒有在跑就完全不等
  pkill -TERM -f '^zsh .*/run_pair\.sh' 2>/dev/null &&
    for i in {1..20}; do pgrep -f '^zsh .*/run_pair\.sh' >/dev/null || break; sleep 0.1; done
  pkill -9 -f '^zsh .*/run_pair\.sh' 2>/dev/null
  pkill -9 -x cliairplay-macos-arm64 2>/dev/null
  pkill -9 -x audiotee 2>/dev/null
  pkill -9 -x localplay 2>/dev/null
  pkill -9 -x stereotool 2>/dev/null
  # 送出 SIGKILL 不代表已退出：新的 run_pair 看到舊 cliairplay 還在就會放棄，319/320 也要等它退出才釋放
  for i in {1..20}; do pgrep -x cliairplay-macos-arm64 >/dev/null || break; sleep 0.1; done
  true
}

# 回傳要重啟的原因「代碼: 細節」；空字串＝正常。代碼固定（學 AirFlash 的 channel/code），方便統計
check() {  # stamp elapsed_s
  local d hit n=0 code
  local -a logs=()
  for d in ${=DEVICES}; do [[ $d != Mac ]] && logs+=$LOGDIR/pair-$1-$d.log; done
  hit=$(grep -hE "$BAD" $logs 2>/dev/null | head -1)
  if [[ -n $hit ]]; then
    case $hit in
      *REANCHOR*|*anchor_corrected*) code=reanchor ;;
      *starved*) code=input_starved ;;
      *Splice-padded*) code=delivery_stall ;;
      *content_cut*) code=content_cut ;;
      *) code=client_status ;;
    esac
    print -r -- "$code: $hit"; return
  fi
  [[ -n ${TEST:-} ]] && return
  # 每台喇叭都起播之後，各自的 client、PTP daemon、本機播放器都要還在
  for d in $logs; do grep -q 'STATUS\] started' $d 2>/dev/null && (( n++ )); done
  if (( n < $#logs )); then
    (( $2 > 35 )) && print "not_started: not all speakers started within 35 s"  # run_pair 自己的等待加總最多約 26 秒
    return
  fi
  (( $(pgrep -x cliairplay-macos-arm64 | wc -l) < $#logs + 1 )) && { print "client_exited: a cliairplay process exited"; return; }
  # live 一律起 localplay（Mac 關著時 split 也寫它的 FIFO 當靜音），它死了 split 會卡住所有輸出，所以不看 Mac 有沒有開
  pgrep -x localplay >/dev/null || print "local_player_exited: local player exited"
}

# 一段播放一列摘要（學 AirFlash 的 session-summary.csv）。只記 ID 與數字，不記 IP、名稱
SESSIONS=$LOGDIR/sessions.csv
count() { local c=$(grep -cE "$1" $2 2>/dev/null); print ${c:-0}; }  # 檔案不存在也回 0
summarize() {  # stamp end_code began_epoch
  local d l re=0 st=0 sp=0 cc=0 fill=0 drop=0
  [[ -f $SESSIONS ]] || print "session_id,start,duration_s,devices,left,mac_sync_ms,end_code,reanchors,input_starved,delivery_stalls,content_cuts,split_fill_ms,split_drop_ms" > $SESSIONS
  for d in ${=DEVICES}; do
    [[ $d == Mac ]] && continue
    l=$LOGDIR/pair-$1-$d.log
    (( re += $(count 'REANCHOR|anchor_corrected' $l), st += $(count 'PCM input starved' $l) ))
    (( sp += $(count 'Splice-padded' $l), cc += $(count 'content_cut' $l) ))
  done
  # split 每 10 秒印一次「補靜音 X ms，丟棄 Y ms」，加總起來
  for l in ${(f)"$(sed -n 's/.*補靜音 \([0-9]*\) ms，丟棄 \([0-9]*\) ms.*/\1 \2/p' $LOGDIR/pair-$1-split.log 2>/dev/null)"}; do
    (( fill += ${l%% *}, drop += ${l##* } ))
  done
  print -r -- "$1,$(date -r $3 '+%F %T'),$(( $(date +%s) - $3 )),${DEVICES// /;},${LEFT:-},${LOCAL_ADJ_MS:-0},$2,$re,$st,$sp,$cc,$fill,$drop" >> $SESSIONS
}

# 保留 7 天：每段播放的 log 超過就刪；總事件記錄超過 1 MB 換檔；摘要只留最近 2000 列
prune_logs() {
  find $LOGDIR -maxdepth 1 -type f -name 'pair-*' -mtime +7 -delete 2>/dev/null
  rm -f $STATE/glow-*.jpg(N)  # 舊版每組顏色一個檔，現在只有 glow.jpg
  [[ -f $LOG && $(stat -f %z $LOG) -gt 1048576 ]] && mv -f $LOG $LOG.1
  # 摘要由 supervisor 追加：播放中不裁切，免得裁切中間追加的那列被蓋掉
  running || { [[ -f $SESSIONS ]] && (( $(wc -l < $SESSIONS) > 2001 )) && { head -1 $SESSIONS; tail -2000 $SESSIONS; } > $SESSIONS.$$ && mv -f $SESSIONS.$$ $SESSIONS }
  true
}

# 播放中 reroute 會改 DEVFILE（少一台喇叭、開關 Mac）：supervisor 跟著它，重啟與 check 才不會再算到已移除的喇叭
reread_devices() {
  local d=$(head -c 64 $DEVFILE 2>/dev/null)
  [[ -n $d ]] && DEVICES=$d
  true
}

# 喇叭被別的裝置（iPhone、別台 Mac）接走了嗎：HomePod 廣播的 gid 在別人播放時是「<tsid>+1+<對方的群組 UUID>」，
# DualPod 自己播時只有「<tsid>+1」，閒置時等於 pgid（HomePod mini 27.2 實測）。查不到名稱或 TXT 就當沒被接走，照舊重連
taken_by_other() {  # 喇叭 ID
  local name gid
  name=$(awk -F'\t' -v k=$1 '$1 == k { print $3; exit }' $SPEAKERS 2>/dev/null)
  [[ -n $name ]] || return 1
  gid=$( (dns-sd -L "$name" _airplay._tcp local & p=$!; sleep 1.5; kill $p) 2>/dev/null |
    grep -m1 'deviceid=' | sed -n 's/.* gid=\([^ ]*\).*/\1/p')
  [[ $gid == *+*+?* ]]
}
# HomePod 主動關掉連線（event channel closed by receiver）時才查：一般網路卡頓不會有這行，不必多等。
# HomePod 更新廣播要一點時間，最多查三輪（約 6 秒）。印出被接走的喇叭 ID，沒有就印空字串
taken_speakers() {  # stamp
  local d i
  local -a hp=() logs=() taken=()
  for d in ${=DEVICES}; do [[ $d != Mac ]] && hp+=$d logs+=$LOGDIR/pair-$1-$d.log; done
  grep -q 'event channel closed by receiver' $logs 2>/dev/null || return 0
  for i in 1 2 3; do
    sleep 0.5
    for d in $hp; do taken_by_other $d && taken+=$d; done
    (( $#taken )) && break
  done
  print -r -- ${(u)taken}
}
# 系統能力的音訊位元（kIOPMSystemCapabilityAudio＝4）沒開就是睡眠或 DarkWake。讀不到就當醒著
awake() {
  local c=${POWER_CAPS:-$(ioreg -n IOPMrootDomain -d1 -r 2>/dev/null | sed -n 's/.*"System Capabilities" = \([0-9]*\).*/\1/p' | head -1)}
  [[ $c != <-> ]] || (( c & 4 ))
}
# 和 run_pair 一樣要預設路由那張網卡有 IPv4（run_pair 拿它當 --if）。剛醒來 Wi-Fi 常晚幾秒，這時起播只會白白失敗
# shortcut: 有 IPv4 不代表喇叭已經連得到，醒來後仍可能多失敗一兩次；真的遇到再加 ping 喇叭
net_ready() { [[ -n $(ipconfig getifaddr $(route -n get default 2>/dev/null | awk '/interface:/ {print $2}') 2>/dev/null) ]] }
# 核心記的上次入睡時間（kern.sleeptime）晚於給定時刻，就是之後睡過。讀不到當沒睡過
slept_since() {
  local w=(${=$(sysctl -n kern.sleeptime 2>/dev/null)})  # { sec = 1795013485, usec = … }
  local t=${${w[4]:-}%,}
  [[ $t == <-> ]] && (( t > $1 ))
}

supervise() {
  trap '' HUP
  say "supervisor pid $$ as $(whoami)"
  echo $$ > $PIDFILE
  print -r -- $DEVICES > $DEVFILE
  local -a restarts
  local stamp="" snap reason now recent t began_at=0 summarized=""
  # 收到停止時，這段還沒寫摘要才補一列（重啟等待中收到的不重複記）
  trap 'say "stop requested"; [[ -n ${child:-} ]] && kill -TERM $child 2>/dev/null; stop_all; [[ -n $stamp && $stamp != $summarized ]] && summarize $stamp user_stop $began_at; rm -f $PIDFILE; exit 0' TERM INT
  local ended=0
  while true; do
    slept_since $ended && restarts=()  # 上一段結束後睡過，醒來重新計算次數
    # 睡眠、DarkWake、剛醒網路還沒回來時都不起播：這時一定失敗，只會把重啟次數用光（等多久都不算次數）
    if ! { awake && net_ready }; then
      say "waiting for full wake and network"
      until awake && net_ready; do sleep $POLL_S & wait $!; done
      say "awake: connecting"
    fi
    reread_devices
    stamp=$(date +%y%m%d-%H%M%S) began_at=$(date +%s)  # 含日期：跨日同一秒不會覆寫還在保留期的 log
    say "start $DEVICES left=${LEFT:-} mac_sync_ms=${LOCAL_ADJ_MS:-0} buffer_ms=$TARGET (log tag $stamp)"
    SPEAKERS=$SPEAKERS VOLFILE=$VOLFILE RUNDIR_FILE=$RUNDIR_FILE DEVICES=$DEVICES STAMP=$stamp DEBUG=3 zsh $RUN_PAIR live $LATENCY $TARGET >> $LOG 2>&1 &
    child=$!
    reason="" began=$SECONDS
    while ps -p $child >/dev/null 2>&1; do
      sleep $POLL_S & wait $!  # 前景 sleep 會讓停止的 trap 等到睡完才跑
      reread_devices
      snap=$DEVICES
      reason=$(check $stamp $(( SECONDS - began )))
      # reroute 可能夾在 reread 與 check 之間：用舊快照會算到已移除的喇叭而誤報，組合變了就重讀再查一次
      if [[ -n $reason ]]; then
        reread_devices
        [[ $DEVICES != $snap ]] && reason=$(check $stamp $(( SECONDS - began )))
      fi
      [[ -n $reason ]] && break
    done
    [[ -z $reason ]] && reason="run_pair_exited: run_pair exited"
    # 被別的裝置接走：讓位，不搶回來（否則兩邊會互相搶到 DualPod 放棄）。App 看到 yield 會顯示「點這裡搶回來」
    local taken=""
    [[ -z ${TEST:-} ]] && taken=$(taken_speakers $stamp)
    [[ -n $taken ]] && say "yield: taken by another device: $taken" || say "restart: $reason"
    kill -TERM $child 2>/dev/null
    for t in {1..30}; do kill -0 $child 2>/dev/null || break; sleep 0.1; done  # run_pair 卡住不收尾時不能永遠等
    kill -9 $child 2>/dev/null; wait $child 2>/dev/null; stop_all
    if [[ -n $taken ]]; then
      summarize $stamp taken_by_other $began_at
      rm -f $PIDFILE; exit 0
    fi
    summarize $stamp ${reason%%:*} $began_at
    summarized=$stamp
    ended=$(date +%s)
    if ! awake || slept_since $began_at; then restarts=(); continue; fi  # 睡眠造成的中斷不算，醒來從頭計算
    now=$(date +%s); restarts+=($now); recent=0
    for t in $restarts; do (( now - t < WINDOW_S )) && (( recent++ )); done
    if (( recent > MAX_RESTARTS )); then
      say "gave up: more than $MAX_RESTARTS restarts in $((WINDOW_S / 60)) min"
      rm -f $PIDFILE; exit 1
    fi
    sleep 3
  done
}

zmodload zsh/system zsh/datetime
# 讀一般使用者可寫的小檔：不跟隨 symlink、非阻塞開啟（換成 FIFO 也不會讓 root 卡住），最多 64 bytes
read_user() {
  local fd s=""
  sysopen -r -o nofollow,nonblock -u fd $1 2>/dev/null || return 0
  sysread -i $fd -s 64 s 2>/dev/null
  exec {fd}<&-
  print -r -- $s
}
# 音量檔可能有好幾台喇叭，讀長一點（同樣不跟隨 symlink、非阻塞）
read_volume() {
  local fd s=""
  sysopen -r -o nofollow,nonblock -u fd $1 2>/dev/null || return 0
  sysread -i $fd -s 1024 s 2>/dev/null
  exec {fd}<&-
  print -r -- $s
}
# 非阻塞寫 cmd 管道：run_pair 剛結束、沒有讀端時直接失敗，不會卡住
send_cmd() {
  local fd
  sysopen -w -o nonblock -u fd $1 2>/dev/null || return 1
  syswrite -o $fd -- "$2"$'\n' 2>/dev/null
  local rc=$?  # 回傳寫入結果，不是 close 的結果；寫不進去（管道滿）呼叫端才不會當成已送
  exec {fd}>&-
  return $rc
}

# 喇叭目前這一代的管道後綴（用全域 rd）：起播時就在的沒有後綴，播放中加入的是 .<n>，reroute 成功時記在 cur-<ID>
sfx() { local s=$(head -c 8 $rd/cur-$1 2>/dev/null); [[ $s == .<-> ]] && print -r -- $s; true }

# 被移除、屬於起播那一代的 client：DISCONNECT 後最多等 1 秒，還在就只 SIGKILL 它。
# 用完整 cmdpipe 路徑（run dir 內、每個 session 唯一）當固定字串比對，不用 regex
reap_client() {
  local p i; local -a pids
  pids=(${(f)"$(pgrep -x cliairplay-macos-arm64 2>/dev/null)"})
  for p in $pids; do [[ "$(ps -o args= -p $p 2>/dev/null) " == *" --cmdpipe $1 "* ]] || pids=(${pids:#$p}); done
  (( $#pids )) || return 0
  for i in {1..10}; do kill -0 $pids 2>/dev/null || return 0; sleep 0.1; done
  kill -9 $pids 2>/dev/null; true
}

my_ip() { ipconfig getifaddr $(route -n get default 2>/dev/null | awk '/interface:/ {print $2}') 2>/dev/null; }

# 找區網裡的 HomePod，寫成 SPEAKERS 與每台的 TXT 紀錄。
# 名稱與 TXT 都是網路上別人廣播的內容：只當資料存，ID 必須是 12 位十六進位、IP 必須是 IPv4 才收
discover() {
  # 一次只跑一個（mkdir 是原子的）；暫存檔帶 PID，不會互相覆蓋。當機留下的鎖超過 5 分鐘就當作失效
  [[ -n $(find $STATE/discover.lock -maxdepth 0 -mmin +5 2>/dev/null) ]] && rmdir $STATE/discover.lock
  mkdir $STATE/discover.lock 2>/dev/null || return 0
  trap 'rmdir $STATE/discover.lock 2>/dev/null' EXIT
  local me=$(my_ip) tmp=$SPEAKERS.$$ name out host txt key ip
  local -a names
  names=("${(@f)$( (dns-sd -B _airplay._tcp local & p=$!; sleep 3; kill $p) 2>/dev/null |
    awk '$2 == "Add" { sub(/.*_airplay\._tcp\.[ ]+/, ""); print }' | sort -u)}")
  : > $tmp
  for name in $names; do
    [[ -n $name ]] || continue
    out=$( (dns-sd -L "$name" _airplay._tcp local & p=$!; sleep 2; kill $p) 2>/dev/null )
    host=$(print -r -- $out | sed -n 's/.* can be reached at \([^ :]*\)\.:[0-9]* .*/\1/p' | head -1)
    txt=$(print -r -- $out | grep -m1 'deviceid=' | sed 's/^ *//')
    key=$(print -r -- $txt | sed -n 's/.*deviceid=\([0-9A-Fa-f:]*\).*/\1/p' | tr -d ':' | tr a-f A-F)
    [[ $key == [0-9A-F](#c12) && -n $host ]] || continue
    # 只列 HomePod（model=AudioAccessory…）：播放設定、Sound Glow 都只在 HomePod mini 上驗證過，
    # Apple TV、電視、別人的 Mac 選了多半沒聲音或會誤送到別人的裝置
    [[ $txt == *model=AudioAccessory* ]] || continue
    ip=$( (dns-sd -G v4 "$host" & p=$!; sleep 1.5; kill $p) 2>/dev/null | awk '$2 == "Add" { print $6; exit }')
    [[ $ip == <0-255>.<0-255>.<0-255>.<0-255> && $ip != $me && $ip != 127.* ]] || continue  # 這台 Mac 自己會解析成 127.0.0.1
    grep -q "^$key"$'\t' $tmp && continue  # 同一台改名時新舊名稱會同時廣播：同一個 ID 只留一筆
    print -r -- $txt > $STATE/txt-$key.$$ && mv -f $STATE/txt-$key.$$ $STATE/txt-$key  # 起播時不會讀到寫一半的
    print -r -- "$key"$'\t'"$ip"$'\t'"${name//[[:cntrl:]]/}"$'\t'"$(date +%s)" >> $tmp  # 第 4 欄：最後看到的時間
  done
  # 這次沒回應的保留 10 分鐘，免得一時沒回應就從選單消失；更久沒看到（換了網路、關機、別人帶走）就拿掉
  if [[ -f $SPEAKERS ]]; then  # 用檔名分辨兩個輸入（NR == FNR 遇到空的第一個檔會判錯）
    awk -F'\t' -v cutoff=$(( $(date +%s) - 600 )) 'FILENAME == ARGV[1] { seen[$1] = 1; next }
      !($1 in seen) && $4 + 0 >= cutoff && $3 !~ /^$/ { seen[$1] = 1; print }' $tmp $SPEAKERS > $tmp.old 2>/dev/null
    # 舊版留下的清單可能有非 HomePod：補回時一樣只留 HomePod
    local k rest
    while IFS=$'\t' read -r k rest; do
      grep -q 'model=AudioAccessory' $STATE/txt-$k 2>/dev/null && print -r -- "$k"$'\t'"$rest"
    done < $tmp.old >> $tmp
    rm -f $tmp.old
  fi
  sort -t$'\t' -k3 $tmp > $tmp.sorted && mv -f $tmp.sorted $SPEAKERS; rm -f $tmp
}
# 找過的喇叭 ID 才算數
known() { [[ $1 == [0-9A-F](#c12) ]] && grep -q "^$1"$'\t' $SPEAKERS 2>/dev/null; }

# Sound Glow（HomePod 27.2 頂端燈光）：燈色取自 Now Playing 封面的主色。實測只傳音訊不會亮；SENDMETA 會亮但是白色，
# 之後單獨送 ARTWORK= 才會換成那張圖的主色。cliairplay 會忽略和上一張位元組相同的封面，所以封面一律只用 ARTWORK=、不附在 SENDMETA。
# 顏色名稱表只在這裡（App 的色票另存一份顯示用，名稱要一致）
# 每組最後加一條黑：11-18 盲測同一個粉紅加黑 4、4 分，只有粉紅 2、2 分（1–5 分），封面有暗的部分燈的明暗起伏才明顯（#1）
typeset -A GLOW_PRESETS=(warm "FF2D2D FF8C00 FFD400 000000" cool "1E40FF 8A2BE2 00B4FF 000000" aurora "00C853 00E5C0 7CFC00 000000" candy "FF4FA3 B14CFF 4CC9FF 000000")
GLOW_DELAY=${GLOW_DELAY:-2}  # SENDMETA 會把顏色重設成白色；是否要隔一段才送封面沒實測過，先等這幾秒
typeset -A glow_sent  # 每個 cmd 管道收過什麼：「meta@<該送封面的 SECONDS>」或「art:<封面檔名>」；沒有這個鍵就是什麼都沒收過
glow_rd=""
glow_open=""  # 已過起播保護的 run dir
glow_made=""  # glow.jpg 目前是哪組顏色畫的
# glow 檔（使用者可寫）：off | preset:<名稱> | custom:#RRGGBB[,#RRGGBB[,#RRGGBB]]。印出顏色清單；其他內容一律當關，內容絕不當路徑用
glow_colors() {
  local v=$(read_user $dir/glow | tr -d ' \n')
  if [[ $v == preset:[a-z]## && -n ${GLOW_PRESETS[${v#preset:}]:-} ]]; then print -r -- $GLOW_PRESETS[${v#preset:}]
  elif [[ $v == custom:\#[0-9A-Fa-f](#c6)(,\#[0-9A-Fa-f](#c6))(#c0,2) ]]; then v=${(U)v#custom:}; print -r -- ${${(s:,:)v}#\#}
  fi
  true
}
# 每個 session 的每個管道：沒收過就送 SENDMETA、隔 GLOW_DELAY 秒再送 ARTWORK=；顏色換了只送新的 ARTWORK=。
# 播放中改成 off 什麼都不送，下次起播才生效（已經亮著的燈沒有關掉的指令）
glow_tick() {
  local -a cols ids; local id p s jpg key
  if [[ $rd != /tmp/cliairplay-pair.* && ! ( -n ${TEST:-} && $rd == $STATE/* ) ]] || [[ ! ( -O $rd && -f $rd/ready ) ]]; then glow_sent=(); glow_rd=""; return 0; fi
  [[ $rd != $glow_rd ]] && { glow_sent=(); glow_rd=$rd; }
  # ready 比 START 早建：cliairplay 依序處理 cmd，SENDMETA 是阻塞的網路呼叫，排在 START 前會讓那台的 START 晚到、左右各自重新對時。
  # 一定要等 start_ms 存在、且過了起播時刻再多 1 秒才碰任何管道。用這段 session 的時鐘（clock_offset＋stereotool now）比，
  # 牆上時鐘被調整也不會提早或延後放行；放行過就記住，之後每輪不再叫 stereotool。
  # 播放中加入的喇叭不用另外擋：reroute 在 serve 迴圈裡同步跑到 T2 後才回來，加入那台的管道要等 START 確認後才進 DEVFILE
  if [[ $glow_open != $rd ]]; then
    local sm=$(head -c 20 $rd/start_ms 2>/dev/null) off=$(head -c 24 $rd/clock_offset 2>/dev/null)
    [[ $sm == <-> && $off == (|-)<-> ]] && (( $($TOOL now $off 2>/dev/null || print 0) >= sm + 1000 )) || return 0
    glow_open=$rd
  fi
  cols=(${=$(glow_colors)}); (( $#cols )) || return 0
  jpg=$STATE/glow.jpg; key=${(j:-:)cols}  # 只留一張圖，顏色變了才原子換掉；送過什麼以顏色記，不以檔名記
  [[ $key == $glow_made && -f $jpg ]] || { $TOOL glowart $jpg $cols 2>/dev/null || return 0; glow_made=$key; }
  ids=(${=$(head -c 64 $DEVFILE 2>/dev/null)})
  for id in $ids; do
    [[ $id == [0-9A-F](#c12) ]] || continue
    p=$rd/cmd-$id$(sfx $id); [[ -p $p ]] || continue
    s=${glow_sent[$p]:-}
    if [[ -z $s ]]; then
      send_cmd $p "TITLE=DualPod"$'\n'"ARTIST=Mac"$'\n'"ITEMID=airplay-stereo"$'\n'"ACTION=SENDMETA" && glow_sent[$p]=meta@$(( SECONDS + GLOW_DELAY ))
    elif [[ $s == meta@* ]]; then
      (( SECONDS >= ${s#meta@} )) && send_cmd $p "ARTWORK=$jpg" && glow_sent[$p]=art:$key
    elif [[ $s != art:$key ]]; then
      send_cmd $p "ARTWORK=$jpg" && glow_sent[$p]=art:$key
    fi
  done
  true
}

[[ -n ${GLOW_LIB:-} ]] && return 0  # 自測用：只載入函式

case ${1:-status} in
  on)
    shift; DEVICES=$*
    running && { echo "already on"; exit 0; }
    stop_all  # 清掉上次手動測試留下的 daemon，否則會搶 319/320
    # 不用 nohup：以 root 從管理員對話框跑時，macOS 的 nohup 會失敗（can't detach from console）
    DEVICES=$DEVICES zsh $0 supervise < /dev/null >> $LOGDIR/supervise.err 2>&1 &!
    for i in {1..20}; do running && break; sleep 0.25; done
    running && echo "on" || { echo "failed to start: $(tail -3 $LOGDIR/supervise.err 2>/dev/null) (whoami=$(whoami))"; exit 1; }
    ;;
  off)
    running && kill -TERM $(head -c 12 $PIDFILE | tr -cd 0-9)
    for i in {1..40}; do running || break; sleep 0.25; done
    stop_all; rm -f $PIDFILE
    echo "off"
    ;;
  status)
    # 背景服務每次迴圈更新 heartbeat；開關本身最多卡十幾秒，超過 20 秒沒更新、或從沒跑過，就是服務沒在跑
    if [[ -z ${TEST:-} ]] && { [[ ! -f $HEARTBEAT ]] || (( $(date +%s) - $(stat -f %m $HEARTBEAT) > 20 )) }; then echo "noservice"
    elif running; then echo "on $(head -c 64 $DEVFILE 2>/dev/null)"; else echo "off"; fi
    tail -1 $LOG 2>/dev/null || true
    ;;
  reroute)  # 播放中不重啟就改輸出：少喇叭、開關 Mac、或一台在播時再加一台。做不到就以非 0 結束，serve 會退回關了再開
    shift
    # 不能兩個 reroute 同時改路由與 DEVFILE：拿不到鎖就以非 0 結束，serve 退回重啟（鎖的寫法同 discover）
    [[ -n $(find $STATE/reroute.lock -maxdepth 0 -mmin +5 2>/dev/null) ]] && rmdir $STATE/reroute.lock
    mkdir $STATE/reroute.lock 2>/dev/null || exit 1
    trap 'rmdir $STATE/reroute.lock 2>/dev/null' EXIT
    running || exit 1
    rd=$(head -c 256 $RUNDIR_FILE 2>/dev/null)
    [[ $rd == /tmp/cliairplay-pair.* || ( -n ${TEST:-} && $rd == $STATE/* ) ]] || exit 1
    [[ -O $rd && -f $rd/ready && -p $rd/pcm-Mac ]] || exit 1  # pcm-Mac：舊版 run_pair 起的這段沒有 routes 可改
    cur=$(head -c 64 $DEVFILE 2>/dev/null)
    new=() add=() mac=
    for w in "$@"; do
      if [[ $w == Mac ]]; then mac=1
      elif [[ $w == [0-9A-F](#c12) && " $cur " == *" $w "* ]]; then new+=$w
      elif known $w; then new+=$w add+=$w
      else exit 1; fi
    done
    (( $#new )) || exit 1
    gone=(); for d in ${=cur}; do [[ $d != Mac && -z ${new[(r)$d]:-} ]] && gone+=$d; done
    typeset -A SFX; for d in $new; do SFX[$d]=$(sfx $d); done
    j= jpid= joined= tag=
    if (( $#add )); then
      # 加喇叭：原本那台照常播，新的一台另起 client、等它的時鐘就緒，兩邊在同一個時刻 T2 切換。
      # 只做「一台在播、再加一台」；同時換掉或移除別台就退回重啟。start_ms 是新版 run_pair 才寫的
      (( $#add == 1 && $#gone == 0 && $#new == 2 )) && [[ -f $rd/start_ms ]] || exit 1
      j=$add[1]
      off=$(head -c 32 $rd/clock_offset 2>/dev/null) stamp=$(head -c 32 $rd/stamp 2>/dev/null)
      [[ $off == (|-)<-> && -n $stamp ]] || exit 1
      # 換算 frame 用的是「要求的」起播時刻：原本那台起播時若被 cliairplay 往後修正，照這個時刻加入會固定錯開，改走重啟。
      # 它自己也是播放中加入的話（有後綴），加入當時已經核對過
      T=$(head -c 20 $rd/start_ms)
      for d in $new; do
        [[ $d == $j || -n $SFX[$d] ]] || grep -q "STATUS\] started requested_unix_ms=$T at_unix_ms=$T\( \|$\)" $LOGDIR/pair-$stamp-$d.log 2>/dev/null || exit 1
      done
      rm -f $rd/join.out  # 上一次加入留下的 ready 行不能被當成這次的
      SPEAKERS=$SPEAKERS VOLFILE=$VOLFILE LOGDIR=$LOGDIR DEBUG=3 zsh $RUN_PAIR join $rd $j < /dev/null > $rd/join.out 2>> $LOG &!
      jpid=$!
      # 之後任何失敗都只收掉新加的這台（它自己會請喇叭斷開），原本那台留給 serve 的重啟處理
      trap 'rmdir $STATE/reroute.lock 2>/dev/null; [[ -z $joined ]] && { say "reroute: 加入 $j 失敗，退回重啟"; kill -TERM $jpid 2>/dev/null }' EXIT
      for i in {1..100}; do  # run_pair join 自己最多等 8 秒
        line=$(head -c 64 $rd/join.out 2>/dev/null)
        [[ -n $line ]] || ! ps -p $jpid > /dev/null 2>&1 && break
        sleep 0.1
      done
      [[ $line == "ready "<->" ."<-> ]] || exit 1
      SFX[$j]=${line##* }
      # T2 比現在晚 max(600, TARGET + 400) ms：split 要在 T2 − TARGET 就寫到那個 frame，它最多超前 60 ms、每 100 ms 才讀一次路由檔；
      # 之後 cliairplay 還要求 START 至少早 250 ms 送到。時鐘剛就緒時 ready_at 可能還在未來，取較晚的
      st=$(cat $rd/latency 2>/dev/null)  # run_pair 寫的，等於 TARGET；不合就當預設
      [[ $st == <120-500> ]] || st=200
      nowms=$($TOOL now $off)
      T2=${${line#ready }% *}
      min2=$(( st + 400 > 600 ? st + 400 : 600 ))
      (( T2 < nowms + min2 )) && T2=$(( nowms + min2 ))
      (( T2 - nowms <= 3000 )) || exit 1
      tag=@$T2
    fi
    l=$new[1] r=${new[2]:-}
    [[ -n $r && ${LEFT:-} == $r ]] && l=$r r=$new[1]
    keep=($rd/pcm-$l$SFX[$l] ${r:+$rd/pcm-$r$SFX[$r]})
    (( $#new == 2 )) && routes="$keep[1]:L$tag $keep[2]:R$tag" || routes="$keep[1]:LR"
    # 表要完整、可重複套用：run dir 裡每個不在新組合的喇叭 FIFO（含之前幾代的）都標 X。split 若漏讀一版，下一版仍叫它丟棄，FIFO 才不會填滿卡住全部輸出
    for f in $rd/pcm-[0-9A-F](#c12)(|.<->)(Np); do [[ -z ${keep[(r)$f]:-} ]] && routes+=" $f:X"; done
    routes+=" $rd/pcm-Mac:$([[ -n $mac ]] && echo LR || echo 0)$tag"
    rm -f $rd/routes.applied $rd/routes.active  # 舊的 ack 內容可能和這版一樣，先清掉才不會誤判已套用
    print -r -- $routes > $rd/routes.tmp && mv -f $rd/routes.tmp $rd/routes || exit 1
    # 先等 split 回報已套用（它才會關掉被移除的輸出）再斷開：斷開後讀端不再讀，split 若還在寫那個 FIFO 會寫滿卡死，永遠看不到 X
    for i in {1..50}; do [[ "$(head -c 4096 $rd/routes.applied 2>/dev/null)" == "$routes" ]] && break; sleep 0.02; done
    # 逾時就不能斷開：split 可能只是卡住，醒來還會寫被移除的 FIFO，沒人讀就永遠卡死。以非 0 結束，serve 退回關了再開
    [[ "$(head -c 4096 $rd/routes.applied 2>/dev/null)" == "$routes" ]] || { say "reroute: 1 秒內沒收到 split 的 ack，不斷開，退回重啟"; exit 1; }
    # watchdog 重啟可能在等 ack 時換了 session：寫 DEVFILE 前後都確認還是同一個，否則不改（或還原）並放棄
    same() { [[ "$(head -c 256 $RUNDIR_FILE 2>/dev/null)" == $rd ]] && running }
    same || exit 1
    if [[ -n $j ]]; then
      # 存成 0 的音量 cliairplay 起播時不送（只在 > 0 才設），要在 START 前先補，否則加入的那台會以接收器上次的音量先響一下
      for kv in $(<$VOLFILE 2>/dev/null); do
        [[ ${kv%%=*} == $j && ${kv%%=*} == [0-9A-F](#c12) && ${kv#*=} == <0-100> ]] && { send_cmd $rd/cmd-$j$SFX[$j] "VOLUME=${kv#*=}" || exit 1; }
      done
      # 新的一台用同一個 T2 起播。START_JOIN：這是接到已經在走的時間軸上。ack 的時刻和要求的不一樣就是它被往後修正，左右會錯開，當失敗
      send_cmd $rd/cmd-$j$SFX[$j] "START_UNIX_MS=$T2"$'\n'"START_JOIN=1"$'\n'"ACTION=START" || exit 1
      ack=
      for i in {1..150}; do ack=$(grep -m1 'STATUS\] started ' $LOGDIR/pair-$stamp-$j.log 2>/dev/null) && break; sleep 0.02; done
      [[ $ack == *"requested_unix_ms=$T2 at_unix_ms=$T2"(| *) ]] || { say "reroute: $j 的 started ack 不符（要 $T2）：$ack"; exit 1; }
      same || exit 1
      print -r -- $SFX[$j] > $rd/cur-$j.tmp && mv -f $rd/cur-$j.tmp $rd/cur-$j || exit 1
      $TOOL sleepuntil $T2 $off  # 排定的切換生效前不能再來一份路由（會取代還沒生效的排程）
      # applied 只代表 split 收下排程；split 若卡過 T2，之後的路由檔會取代還沒生效的排程，新的一台就永遠沒聲音。等 split 回報排程真的執行了才算加入成功
      while [[ "$(head -c 4096 $rd/routes.active 2>/dev/null)" != "$routes" ]]; do
        (( $($TOOL now $off) > T2 + 1000 )) && { say "reroute: T2 後 1 秒內 split 沒回報排程已執行，退回重啟"; exit 1; }
        sleep 0.02
      done
      joined=1
    fi
    now="$new${mac:+ Mac}"
    print -r -- $now > $DEVFILE.tmp && mv -f $DEVFILE.tmp $DEVFILE
    same || { print -r -- $cur > $DEVFILE.tmp && mv -f $DEVFILE.tmp $DEVFILE; exit 1; }
    for d in $gone; do
      send_cmd $rd/cmd-$d$(sfx $d) 'ACTION=DISCONNECT'
      [[ -z $(sfx $d) ]] && { reap_client $rd/cmd-$d &! }
    done
    say "reroute: $cur -> $now"
    ;;
  supervise) supervise ;;
  discover) discover ;;
  serve)  # 背景服務（root）：App 改寫 want 檔時才照內容開或關。只在檔案變動時動作，自癒放棄後不會被立刻拉起來
    want_file=$2 dir=${2:h} last="" vlast="" vdone="" found_at=-999 pruned_at=-9999
    trap 'zsh $0 off >/dev/null; exit 0' TERM INT
    while true; do
      touch $HEARTBEAT
      # 每分鐘重新找一次喇叭（背景跑，約 3 秒＋每台 3.5 秒，不擋住這個迴圈）
      if (( SECONDS - found_at > 60 )); then found_at=$SECONDS; zsh $0 discover < /dev/null > /dev/null 2>&1 &!; fi
      if (( SECONDS - pruned_at > 3600 )); then pruned_at=$SECONDS; prune_logs; fi
      # want：要出聲的裝置，喇叭 ID 加上「Mac」。只收找過的 ID、最多兩台、照排序；沒有喇叭就是關（聲音回到 Mac 本身）
      seen=$(stat -f '%Fm %i' $want_file 2>/dev/null)  # 奈秒 mtime 加 inode，同一秒內的兩次寫入也分得出來
      want="" n=0 mac=""
      for w in ${(ou)=$(read_user $want_file | tr -c 'A-Za-z0-9' ' ')}; do  # 排序並去掉重複
        if [[ $w == Mac ]]; then mac=" Mac"
        elif (( n < 2 )) && known $w; then want+="$w "; (( n++ ))
        fi
      done
      want=${want% }
      [[ -z $want ]] && want=off || want+=$mac
      # 設定視窗改的值（Mac 對齊、哪台當左聲道、緩衝）只在起播時讀；改了而且正在播，就重新起播套用
      cfg=$(stat -f '%Fm %i' $dir/mac-sync-ms $dir/left $dir/buffer-ms 2>/dev/null | tr '\n' ' ')
      cfg_changed=""
      [[ -n ${clast+x} && $cfg != $clast ]] && cfg_changed=1
      clast=$cfg
      want_changed=""
      [[ "$seen $want" != $last ]] && want_changed=1
      if [[ -n $want_changed || -n $cfg_changed ]]; then
        last="$seen $want"
        if [[ $want == off ]]; then running && zsh $0 off
        # 改裝置組合：不是已經在播這組就起播。只改設定：正在播才重新起播（自癒放棄後不會被設定拉起來）
        elif [[ -n $want_changed ]] && [[ $(zsh $0 status | head -1) != "on $want" ]] || { [[ -n $cfg_changed ]] && running }; then
          # Mac 喇叭的對齊微調（ms）：只接受 -300 到 300 的整數，其他當 0。左聲道：這次要播的其中一台，其他當第一台
          adj=$(read_user $dir/mac-sync-ms | tr -d ' \n')  # 原樣驗證，不先濾字元（1e2 不能變成 12）
          [[ $adj == (|-)<0-300> ]] || adj=0
          left=$(read_user $dir/left | tr -cd 'A-Z0-9')
          [[ " $want " == *" $left "* && $left != Mac ]] || left=${want%% *}
          # 只是裝置組合變動（少一台、開關 Mac）就不中斷留下的輸出；reroute 做不到才關了再開
          if ! { [[ -z $cfg_changed ]] && running && LEFT=$left zsh $0 reroute ${=want} }; then
            running && zsh $0 off
            buf=$(read_user $dir/buffer-ms | tr -d ' \n')  # 範圍由 on 那邊的 <120-500> 驗證，不合就用預設
            LEFT=$left LOCAL_ADJ_MS=$adj BUFFER_MS=$buf zsh $0 on ${=want}
          else vdone=""  # 播放中加入的那台也要收到存成 0 的音量
          fi
        fi
      fi
      # 等化器：五個（舊版三個）-12…12 的整數，格式不對就當原音。播放中改也不用重啟，split 約 200 ms 內自己讀到
      eseen=$(stat -f '%Fm %i' $dir/eq 2>/dev/null)
      if [[ $eseen != ${elast-x} ]]; then
        elast=$eseen
        e=(${=$(read_user $dir/eq | tr -c -- '-0-9' ' ')})
        ok=$(( $#e == 3 || $#e == 5 )); for x in $e; do [[ $x == (|-)<0-12> ]] || ok=0; done
        (( ok )) && e="$e" || e="0 0 0 0 0"
        print -r -- $e > $EQFILE.tmp && mv -f $EQFILE.tmp $EQFILE
      fi
      # 音量（如「<喇叭 ID>=40 …」）：只認喇叭 ID、0–100 的整數，整理後原子寫到 root 的 VOLFILE 給起播用
      vseen=$(stat -f '%Fm %i' $dir/volume 2>/dev/null)
      if [[ $vseen != $vlast ]]; then
        vlast=$vseen vols=""
        for kv in $(read_volume $dir/volume | tr -c 'A-Za-z0-9=' ' '); do
          [[ ${kv%%=*} == [0-9A-F](#c12) && ${kv#*=} == <0-100> ]] && vols+="$kv "
        done
        print -r -- ${vols% } > $VOLFILE.tmp && mv -f $VOLFILE.tmp $VOLFILE
        vdone=""  # 新音量要重送
      fi
      # 播放中：等這一輪的 client 都連上（run_pair 建 ready），把 VOLFILE 送給每台。每輪 run_pair 都重送一次，
      # 起播途中改的音量、或存成 0 的音量（cliairplay 起播時不送 0）才不會漏掉
      rd=$(head -c 64 $RUNDIR_FILE 2>/dev/null)
      if [[ $rd != $vdone ]] && running && [[ $rd == /tmp/cliairplay-pair.* && -O $rd && -f $rd/ready ]]; then
        for kv in $(<$VOLFILE); do
          c=$rd/cmd-${kv%%=*}$(sfx ${kv%%=*})
          [[ -p $c ]] && send_cmd $c "VOLUME=${kv#*=}"
        done
        vdone=$rd
      fi
      glow_tick
      sleep 0.3  # 拉音量滑桿要跟手
    done
    ;;
  *) echo "usage: sudo zsh stereo.sh on|off|status"; exit 2 ;;
esac
