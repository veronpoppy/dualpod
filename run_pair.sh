#!/bin/zsh
# 左右聲道：sudo zsh run_pair.sh [test|measure|live|livemeasure|clip|clipmono] [latency_ms] [target_ms]
# DEVICES：喇叭 ID（stereo.sh discover 找到的 12 位十六進位）一到兩台，live 可再加「Mac」；兩台時 LEFT 那台收左聲道。
# 一個 PTP daemon（Mac 當主時鐘）+ 每台一個 cliairplay，同一個 START_UNIX_MS 起播。
# run_pair.sh join <run dir> <喇叭 ID>：在正在播的那一段再接一台（stereo.sh reroute 用）。只啟動 client、等它的時鐘就緒、
# 印出「ready <ready_at_unix_ms> <管道後綴>」，之後跟著 client 活著；起播時刻與 START 由 stereo.sh 決定
# 測試音：0–3 秒只有左（440 Hz），3–6 秒只有右（660 Hz），6–14 秒兩邊同時打點（每 0.5 秒一下）。
set -eu
setopt no_bg_nice extended_glob  # zsh 預設讓每層背景工作 nice +5，疊到 cliairplay／audiotee 變 nice 15，起播會慢上百 ms
DIR=${DIR:-${0:A:h}}  # 跟著腳本所在位置走：開發在 Documents，執行時在 ~/Library/Application Support/AirPlayStereo
BIN=$DIR/airplay-cli/bin/cliairplay-macos-arm64
[[ -n ${TEST:-} && -n ${FAKE_BIN:-} ]] && BIN=$FAKE_BIN  # 自測用假的 client
LOGS=${LOGDIR:-$DIR/logs}
FFMPEG=/opt/homebrew/bin/ffmpeg
# 預設路由那張網卡的 IPv4（換網路、DHCP 換位址都跟著走）
MY_IP=${MY_IP:-$(ipconfig getifaddr $(route -n get default 2>/dev/null | awk '/interface:/ {print $2}') 2>/dev/null)}
IFACE=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
[[ $MY_IP == <0-255>.<0-255>.<0-255>.<0-255> ]] || { echo "找不到這台 Mac 的區網 IP"; exit 1; }
DACP=1A2B3D4EA1B2C3D4
LATENCY=${2:-200}  # 第二個參數：cliairplay --latency（ms）
VOLUME=${VOLUME:-35}
# 背景服務會給 VOLFILE（root 擁有，內容如「<喇叭 ID>=40 …」）：每台起播時用自己的音量
typeset -A VOL
for kv in $(head -c 1024 ${VOLFILE:-/dev/null} 2>/dev/null); do
  [[ ${kv%%=*} == [0-9A-F](#c12) && ${kv#*=} == <0-100> ]] && VOL[${kv%%=*}]=${kv#*=}
done
DEVICES=${DEVICES:-}
JOIN=
if [[ ${1:-} == join ]]; then
  JOIN=1 RUN=$2 DEVICES=$3
  # start_ms 在起播後才有：沒有就是還沒起播、或舊版 run_pair 起的那一段
  [[ -O $RUN && -f $RUN/ready && -f $RUN/start_ms ]] || { echo "join: $RUN 不是正在播的 run dir" >&2; exit 1; }
  LATENCY=$(<$RUN/latency) STAMP=$(<$RUN/stamp)
fi
SPEAKERS=${SPEAKERS:-$DIR/state/speakers}  # stereo.sh discover 寫的「ID<tab>IP<tab>名稱」，root 擁有
# 時鐘與拆聲道用打包好的 stereotool：不靠 Python（一般使用者的 Mac 沒裝開發工具時 /usr/bin/python3 不能用）
TOOL=$DIR/tools/stereotool
typeset -A IP NAME
[[ -f $SPEAKERS ]] && while IFS=$'\t' read -r k ip nm; do IP[$k]=$ip NAME[$k]=$nm; done < $SPEAKERS
typeset -U HP  # 要串流的喇叭（去掉重複）
HP=()
for d in ${=DEVICES}; do [[ $d == [0-9A-F](#c12) && -n ${IP[$d]:-} ]] && HP+=$d; done
(( $#HP )) || { echo "DEVICES 裡沒有找得到的喇叭：$DEVICES"; exit 1; }
(( $#HP <= 2 )) || { echo "最多兩台喇叭（左、右聲道）"; exit 1; }
[[ ${1:-test} == (live*|join) ]] || (( $#HP == 2 )) || { echo "測試模式要兩台喇叭"; exit 1; }
WITH_MAC=; [[ " $DEVICES " == *" Mac "* ]] && WITH_MAC=1
[[ "${1:-}" == measure ]] && VOLUME=50
STAMP=${STAMP:-$(date +%H%M%S)}  # stereo.sh 會指定，好知道要盯哪一組 log
DEBUG=${DEBUG:-5}
# 以 GUI 管理員權限執行時沒有 SUDO_USER，audiotee 要用登入的使用者跑才拿得到錄音權限
AS_USER=${AS_USER:-${SUDO_USER:-$(stat -f %Su /dev/console)}}  # 背景服務由安裝時的 plist 指定
# 所有行程共用原始時鐘（CLOCK_UPTIME_RAW）加同一個位移，不受 NTP 調整系統時間影響。
# 用牆鐘時，一次時間步進會讓兩代 mini 反應不同（一台立刻跳、一台慢慢追），左右就錯開十幾 ms
# 晚加入的一台要用這一段起播時算的那個位移：重新算一次會差幾十 µs 到幾 ms，左右就錯開
if [[ -n $JOIN ]]; then CLOCK_OFFSET=$(<$RUN/clock_offset); else CLOCK_OFFSET=$($TOOL offset); fi
now_ms() { $TOOL now $CLOCK_OFFSET; }
mkdir -p $LOGS
if [[ -z $JOIN ]]; then
# 上一次沒停乾淨的 daemon 會搶 319/320，新的連線會掛到舊 daemon 上，先擋下來
pgrep -x cliairplay-macos-arm64 >/dev/null && { echo "已經有 cliairplay 在跑，先執行：sudo pkill -f '^zsh .*/run_pair\.sh'; sudo pkill -x cliairplay-macos-arm64"; exit 1; }
RUN=$(mktemp -d /tmp/cliairplay-pair.XXXX)
[[ -n ${RUNDIR_FILE:-} ]] && print -r -- $RUN > $RUNDIR_FILE  # 背景服務播放中改音量要寫到這裡的 cmd-<裝置>
print $CLOCK_OFFSET > $RUN/clock_offset; print $LATENCY > $RUN/latency; print -r -- $STAMP > $RUN/stamp  # join 要沿用
fi
PIDS=()

cleanup() {
  for f in $RUN/cmd-*(N); do printf 'ACTION=DISCONNECT\n' > $f 2>/dev/null || true; done
  sleep 1
  kill $PIDS 2>/dev/null || true
  pkill -x audiotee 2>/dev/null || true
  pkill -x localplay 2>/dev/null || true
  sleep 0.5; pkill -9 -x audiotee 2>/dev/null || true  # 寫 pipe 卡住時不理 SIGTERM
  pkill -9 -x cliairplay-macos-arm64 2>/dev/null || true  # daemon 佔著 319/320 會讓 Mac 內建 AirPlay 連不上
  rm -rf $RUN
  chmod a+r $LOGS/* 2>/dev/null || true
}
[[ -z $JOIN ]] && trap cleanup EXIT
trap 'exit 143' TERM  # zsh 被 TERM 結束時不跑 EXIT trap，轉成一般 exit 才會清掉 319/320
trap 'exit 130' INT

txt_of() {  # 喇叭 ID：先用 discover 存的，沒有再現查
  [[ -s ${SPEAKERS:h}/txt-$1 ]] && { head -c 4096 ${SPEAKERS:h}/txt-$1; return; }
  (dns-sd -L "$NAME[$1]" _airplay._tcp local & p=$!; sleep 3; kill $p) 2>/dev/null | grep -m1 'model=' | sed 's/^ *//'
}

if [[ ${1:-test} != (live|join) ]]; then  # 長時間播放不抓封包，免得 pcap 一直長大
  tcpdump -i $IFACE -n -s 200 -w $LOGS/pair-$STAMP.pcap "udp port 319 or udp port 320" 2>/dev/null &
  PIDS+=($!)
fi

if [[ -z $JOIN ]]; then
  $BIN --ptp-daemon --if $MY_IP --dacp $DACP --clock-offset-ns $CLOCK_OFFSET --debug $DEBUG > $LOGS/pair-$STAMP-daemon.log 2>&1 &
  PIDS+=($!)
  sleep 1
fi

start_client() {  # name ip [管道後綴：播放中加入的那一代用 .<n>]
  local name=$1 ip=$2 txt p=$1${3:-}
  txt=$(txt_of $name)
  [[ -n "$txt" ]] || { echo "抓不到 $NAME[$name] 的 TXT 紀錄"; exit 1; }
  mkfifo $RUN/cmd-$p $RUN/pcm-$p
  exec {fd}<>$RUN/cmd-$p      # 讓 cmdpipe 一直有 writer
  exec {fd}<>$RUN/pcm-$p      # stdin 先有 writer，ffmpeg 晚點才接上
  env CLIAIRPLAY_PTP_FOLLOW=0 $BIN --protocol airplay2 --ap2-native --ptp --ptp-shared \
      --if $MY_IP --dacp $DACP --clock-offset-ns $CLOCK_OFFSET --port 7000 --latency $LATENCY --volume ${VOL[$name]:-$VOLUME} --debug $DEBUG \
      --txt "$txt" --cmdpipe $RUN/cmd-$p $ip \
      < $RUN/pcm-$p > $LOGS/pair-$STAMP-$name.log 2>&1 &
  PIDS+=($!)
}
ready() { grep -q 'clock_ready mode=ptp state=ready' $LOGS/pair-$STAMP-$1.log 2>/dev/null; }
if [[ -n $JOIN ]]; then
  d=$HP[1] log=$LOGS/pair-$STAMP-$HP[1].log
  # split 關掉（X）過的路徑永遠不再寫，所以每次加入都用沒用過的一代 .<n>；用計數檔而不是看 FIFO 在不在，因為結束時會刪 FIFO
  n=$(( $(head -c 8 $RUN/gen-$d 2>/dev/null || true) + 1 )); print $n > $RUN/gen-$d
  # 上一代的 log 有它斷開時的 [STATUS] stopped，watchdog 會當成這一代出錯，先移開
  [[ -f $log ]] && mv -f $log $log.$(date +%H%M%S)
  # 結束時只收自己這台，不碰整段播放。先請喇叭斷開、給它 1 秒，和整段結束時一樣。client 起來後 FIFO 才保證有讀端，之前寫會卡住
  trap '(( $#PIDS )) && [[ -p $RUN/cmd-$d.$n ]] && printf "ACTION=DISCONNECT\n" > $RUN/cmd-$d.$n || true; rm -f $RUN/cmd-$d.$n $RUN/pcm-$d.$n; sleep 1; kill $PIDS 2>/dev/null; for i in {1..10}; do kill -0 $PIDS 2>/dev/null || break; sleep 0.1; done; kill -9 $PIDS 2>/dev/null || true' EXIT  # 卡住（例如被 STOP）的 client 不理 TERM，只對自己這一代補 KILL
  start_client $d $IP[$d] .$n
  for i in {1..32}; do ready $d && break; sleep 0.25; done
  ready $d || { echo "join: 8 秒內 $d 沒有 clock_ready，看 $log" >&2; exit 1; }
  print "ready $(sed -n 's/.*clock_ready mode=ptp state=ready.* ready_at_unix_ms=\([0-9]*\).*/\1/p' $log | head -1) .$n"
  wait
  exit 0
fi
for d in $HP; do start_client $d $IP[$d]; done
all_ready() { for d in $HP; do ready $d || return 1; done; }
for i in {1..60}; do all_ready && break; sleep 0.25; done
all_ready || { echo "15 秒內 $HP 沒有都 clock_ready，看 logs/pair-$STAMP-*.log"; exit 1; }
touch $RUN/ready  # 背景服務看到這個才送播放中改的音量

EXCL=()
if [[ ${1:-} == live ]]; then
  # 本機喇叭：不論有沒有選 Mac 都先啟動（沒選時 split 送靜音），播放中開關 Mac 才不必重啟，audiotee 也一直排除它的 pid。
  # localplay 先啟動、拿到 pid（audiotee 要排除它，否則自己的聲音會再被錄進來），之後才定共同的 START
  mkfifo $RUN/pcm-Mac
  exec {macfd}<>$RUN/pcm-Mac
  launchctl asuser $(id -u $AS_USER) sudo -u $AS_USER $DIR/tools/localplay $CLOCK_OFFSET ${LOCAL_ADJ_MS:-0} \
    < $RUN/pcm-Mac 2> $LOGS/pair-$STAMP-Mac.log &
  PIDS+=($!)
  for i in {1..40}; do grep -q ' ready' $LOGS/pair-$STAMP-Mac.log 2>/dev/null && break; sleep 0.1; done
  MACPID=$(sed -n 's/.*pid=\([0-9]*\) ready.*/\1/p' $LOGS/pair-$STAMP-Mac.log)
  [[ -n $MACPID ]] || { echo "本機播放器 4 秒內沒啟動，看 logs/pair-$STAMP-Mac.log"; exit 1; }
  EXCL=(--exclude-processes $MACPID)
fi

MODE=${1:-test}
LEAD_MS=2000
[[ $MODE == live* ]] && LEAD_MS=300  # cliairplay 要求 START 至少比當下晚 250 ms（AP2_MIN_WARM_LEAD_MS）
TARGET_MS=${3:-300}  # 第三個參數：AirPlay 這段的目標延遲＝START 時刻 − split 開始寫的時刻
T=$(( $(now_ms) + LEAD_MS ))
print $T > $RUN/start_ms.tmp && mv -f $RUN/start_ms.tmp $RUN/start_ms  # split 的 frame k 在 T + k/44100 秒播出，join 靠它換算
for n in $HP; do printf 'START_UNIX_MS=%d\nACTION=START\n' $T > $RUN/cmd-$n; done
(( $#EXCL )) && print "START $T" >&$macfd
echo "兩台已就緒，START_UNIX_MS=$T"

if [[ $MODE == clip || $MODE == clipmono ]]; then  # 聽感 A/B：把錄好的片段直接餵進去，不經過 tap
  $FFMPEG -hide_banner -loglevel error -y -re -f s16le -ar 44100 -ac 2 -i $DIR/signals/$MODE.raw \
    -filter_complex "[0:a]pan=stereo|c0=c0|c1=c0[l];[0:a]pan=stereo|c0=c1|c1=c1[r]" \
    -map '[l]' -f s16le $RUN/pcm-$HP[1] -map '[r]' -f s16le $RUN/pcm-$HP[2]
  exit 0
fi

if [[ $MODE == measure ]]; then  # 量測模式：餵 chirp 訊號，同時用內建麥克風錄音後分析
  SIGNAL=$DIR/signals/chirps.raw
  REC=$LOGS/pair-$STAMP-mic.wav
  sudo -u $AS_USER $DIR/tools/rec /tmp/cliairplay-mic-$STAMP.wav 38 &  # 自製錄音器；ffmpeg avfoundation 會標錯取樣率又掉 buffer
  RECPID=$!
  $FFMPEG -hide_banner -loglevel error -y -re -f s16le -ar 44100 -ac 2 -i $SIGNAL \
    -filter_complex "[0:a]pan=stereo|c0=c0|c1=c0[l];[0:a]pan=stereo|c0=c1|c1=c1[r]" \
    -map '[l]' -f s16le $RUN/pcm-$HP[1] -map '[r]' -f s16le $RUN/pcm-$HP[2]
  wait $RECPID; cp /tmp/cliairplay-mic-$STAMP.wav $REC
  ${PYTHON:-python3} -I $DIR/measure.py analyze $REC
  exit 0
fi

if [[ $MODE == live* ]]; then  # 系統聲音：audiotee（process tap，--mute 讓 Mac 本機不出聲）→ 拆左右 → 兩台
  # split 的樣本 0 會在 T 播出，所以等到 T − TARGET_MS 才開始寫，延遲就是 TARGET_MS
  OUTS=($RUN/pcm-$HP[1]:LR)  # 只有一台就送原樣立體聲
  if (( $#HP == 2 )); then  # 哪台當左聲道由設定視窗決定（背景服務給 LEFT）
    OUTS=($RUN/pcm-$HP[1]:L $RUN/pcm-$HP[2]:R)
    [[ ${LEFT:-} == $HP[2] ]] && OUTS=($RUN/pcm-$HP[2]:L $RUN/pcm-$HP[1]:R)
  fi
  (( $#EXCL )) && OUTS+=($RUN/pcm-Mac:$([[ -n $WITH_MAC ]] && echo LR || echo 0))  # 路由表之後由 stereo.sh reroute 寫到 $RUN/routes
  $TOOL sleepuntil $(( T - TARGET_MS )) $CLOCK_OFFSET
  # launchctl asuser：從背景服務啟動時也要進使用者的登入 session，系統錄音權限才找得到
  launchctl asuser $(id -u $AS_USER) sudo -u $AS_USER $DIR/audiotee/.build/release/audiotee --stereo --sample-rate 44100 \
      --chunk-duration 0.02 --mute $EXCL 2> $LOGS/pair-$STAMP-tap.log |
    $TOOL split --routes $RUN/routes --eq ${EQFILE:-$DIR/state/eq} --start-ms $T $OUTS 2> $LOGS/pair-$STAMP-split.log &
  PIDS+=($!)
  if [[ $MODE == livemeasure ]]; then  # 用 afplay 播 chirp，量端到端延遲（播放呼叫 → 麥克風）與左右偏差
    REC=$LOGS/pair-$STAMP-mic.wav
    sudo -u $AS_USER $DIR/tools/rec /tmp/cliairplay-mic-$STAMP.wav 24 > $RUN/rec.out &
    RECPID=$!
    sleep 2
    # 時間戳在 sudo 之後、exec afplay 之前才取，和本機基準（147 ms）同一種量法
    PLAY=$(sudo -u $AS_USER python3 -I -c 'import os, sys, time
print("%.6f" % time.time(), flush=True)
if os.fork() == 0:
    os.dup2(os.open(os.devnull, os.O_WRONLY), 1)
    os.execv("/usr/bin/afplay", ["afplay", "-t", "19", sys.argv[1]])
os.wait()' $DIR/signals/chirps.wav)
    wait $RECPID; cp /tmp/cliairplay-mic-$STAMP.wav $REC; cat $RUN/rec.out; echo "play_unix=$PLAY"
    FIRST=$(sed -n 's/.*first_sample_unix=\([0-9.]*\).*/\1/p' $RUN/rec.out)
    ${PYTHON:-python3} -I $DIR/measure.py analyze $REC $FIRST $PLAY
    exit 0
  fi
  echo "系統聲音串流中，Ctrl-C 結束"
  wait
  exit 0
fi

L='if(lt(t,3),0.3*sin(2*PI*440*t),if(gte(t,6),0.8*sin(2*PI*2000*t)*lt(mod(t,0.5),0.006),0))'
R='if(between(t,3,6),0.3*sin(2*PI*660*t),if(gte(t,6),0.8*sin(2*PI*2000*t)*lt(mod(t,0.5),0.006),0))'
$FFMPEG -hide_banner -loglevel error -y -re -f lavfi -i "aevalsrc=exprs='${L}|${R}':s=44100:d=14" \
  -filter_complex "[0:a]pan=stereo|c0=c0|c1=c0[l];[0:a]pan=stereo|c0=c1|c1=c1[r]" \
  -map '[l]' -f s16le $RUN/pcm-$HP[1] -map '[r]' -f s16le $RUN/pcm-$HP[2]
sleep 2
echo "log: $LOGS/pair-$STAMP-*.log"
