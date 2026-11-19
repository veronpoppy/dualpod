#!/bin/zsh
# 一般使用者身分執行，背景服務要在播、房間要安靜（或設 SKIP_E2E=1 不量端到端）：zsh tools/sweep.sh <每檔分鐘> <緩衝 ms>…（由大到小）
# 每檔寫 buffer-ms 讓背景服務重新起播，播完後記下斷流與重啟次數、split lead，再跑一次 hourcheck 量端到端與左右偏差。
# 一檔斷流 2 次以上或自癒放棄就停：再小只會更糟。結束時把 buffer-ms 還原。
set -u
DIR=${0:A:h:h}
CFG=~/Library/Application\ Support/AirPlayStereo
export LOGS=${LOGS:-/Library/Application Support/AirPlayStereo/logs}
SLOG=$LOGS/stereo.log
MIN=$1; shift
OUT=$DIR/checks/sweep-$(date +%H%M%S).txt
orig=$(cat $CFG/buffer-ms 2>/dev/null)
restore() { if [[ -n $orig ]]; then print -r -- $orig > $CFG/buffer-ms; else rm -f $CFG/buffer-ms; fi }
trap 'restore; exit 1' INT TERM
echo "緩衝掃描 $*，每檔 $MIN 分鐘，結果寫到 $OUT" | tee $OUT
for b in "$@"; do
  n0=$(wc -l < $SLOG)
  print -r -- $b > $CFG/buffer-ms
  stamp=""
  for i in {1..60}; do
    stamp=$(tail -n +$(( n0 + 1 )) $SLOG | sed -n "s/.* start .*buffer_ms=$b (log tag \([0-9-]*\)).*/\1/p" | head -1)
    [[ -n $stamp ]] && break; sleep 1
  done
  [[ -n $stamp ]] || { echo "=== $b ms：60 秒內沒有以這個緩衝起播，停止" | tee -a $OUT; break; }
  gave=""
  for i in $(seq 1 $(( MIN * 2 ))); do
    sleep 30
    tail -n +$(( n0 + 1 )) $SLOG | grep -q 'gave up' && { gave=1; break; }
  done
  new=$(tail -n +$(( n0 + 1 )) $SLOG)
  stamps=(${(f)"$(print -r -- $new | sed -n 's/.*(log tag \([0-9-]*\)).*/\1/p')"})
  # 一次斷流會在 log 記好幾行（Splice-padded 加 REANCHOR，有時兩台都記），看門狗則每次斷流重啟一次，用重啟次數算
  bad=$(print -r -- $new | grep -c 'restart:')
  { echo "=== $b ms（$(date +%H:%M)）起播 $stamp"
    echo "斷流 $bad 次（看門狗重啟次數）${gave:+，自癒放棄}"
    grep 'lead_ms' $LOGS/pair-$stamps[-1]-split.log | tail -1
    # tap 照常每 20 ms 一塊時，lead 最大值應該是 T − t0 加一塊：多出很多就是起播時舊樣本把延遲拉長了
    T=$(grep -A3 "log tag $stamps[-1]" $SLOG | sed -n 's/.*START_UNIX_MS=//p' | head -1)
    t0=$(sed -n 's/.*t0_unix=//p' $LOGS/pair-$stamps[-1]-split.log | head -1)
    [[ -n $T && -n $t0 ]] && printf 'T − t0 %.1f ms\n' $(( T - t0 * 1000 ))
    # 喇叭漏收封包時會要求重傳（cliairplay patch 0003 每 5 秒印一次）。age 是封包送出到被要求的時間，接近緩衝減 HomePod 處理時間就來不及補
    # 沒有 retransmit 行的那台記為 0：可能真的沒漏包，也可能還沒滿 5 秒就結束
    spk=(); for s in $stamps; do spk+=($LOGS/pair-$s-[0-9A-F]*.log(N)); done
    for f in $spk; do
      print -r -- "${${f##*-}%.log} $(grep -h 'retransmit:' $f | tail -1 | sed -n 's/.*retransmit: \([0-9]*\) requested, \([0-9]*\) resent, \([0-9]*\) already retired.*/\1 \2 \3/p')"
    done | awk '{r[$1]+=$2; a[$1]+=$3; x[$1]+=$4} END {for (k in r) printf "重傳 %s：要求 %d、補送 %d、已淘汰 %d\n", k, r[k], a[k], x[k]}'
    (( $#spk )) && grep -h 'retransmit:' $spk | sed -n 's/.*last 5 s: \([0-9]*\) found, age avg \([0-9]*\) max \([0-9]*\) ms.*/\1 \2 \3/p' |
      awk '{n+=$1; s+=$1*$2; if ($3>m) m=$3} END {if (n) printf "被要求的封包從送出到被要求：平均 %.0f ms，最大 %d ms\n", s/n, m}'
  } | tee -a $OUT
  [[ -n $gave ]] && break
  [[ -n ${SKIP_E2E:-} ]] || zsh $DIR/tools/hourcheck.sh 1 1 2>&1 | grep -E '右減左|端到端|峰值|Error|Traceback' | tee -a $OUT  # 放著音樂掃時設 SKIP_E2E=1，chirp 會被音樂蓋掉
  (( bad >= 2 )) && { echo "斷流 2 次以上，不再往下" | tee -a $OUT; break; }
done
restore
echo "已還原 buffer-ms" | tee -a $OUT
