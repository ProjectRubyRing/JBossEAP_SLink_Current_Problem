#!/usr/bin/env bash
# =============================================================================
# rotation_local.sh — Docker を使わずに (Linux / WSL の ext4 上で) 「ECS タスク相当の
# JBoss」を複数プロセス起動し、JVM タイムゾーン上の 0 時をまたいだ server.log の
# 挙動を記録する。test/rotation/scenario.sh (Docker 版) と同じシナリオ・同じ記録形式。
#
#   test/local/rotation_local.sh setup <wf26|wf41>
#       JRE (Temurin 11 / 21) と WildFly (26.1.3 / 41.0.1) を $ROTWORK に展開する
#       (wf26 ≒ EAP 7.4 相当: 約 400MB、wf41 ≒ EAP 8.x 相当: 約 500MB)
#   test/local/rotation_local.sh batch <lead_sec> "<S1|S2|S2r|R1|R2> <wf26|wf41> <label> <port_base> [VAR=VAL...]" ...
#       lead_sec 秒後が JVM にとっての 0 時になるタイムゾーンを計算し、シナリオを並行実行する。
#       port_base はシナリオごとに重ならない値 (100, 200, ...)。VAR=VAL はタスクの環境変数
#       (例: JBOSS_LOG_PIN=off で修正前の挙動、LOG_ID_SOURCE=taskid でタスク ID 方式)。
#       次の 2 つは試験道具への指示 (T_ で始まる):
#         T_CMD=eap              本番と同じ起動方式 (entrypoint.sh eap)。既定は CMD に standalone.sh を直接渡す
#         T_JAVA_OPTS_LOG_DIR=1  本番と同じく JAVA_OPTS に -Djboss.server.log.dir=<JBOSS_HOME>/standalone/log を入れる
#       結果は $ROTWORK/results/<label>.log
#   test/local/rotation_local.sh clean     … $ROTWORK を削除
#
# 環境変数: ROTWORK (作業場所。既定 ~/rotwork。ext4 等の POSIX ファイルシステムに置くこと)
#           DL_DIR  (WildFly の zip の一時置き場。既定 $ROTWORK。WSL で C: の仮想ディスクを
#                    膨らませたくなければ /mnt/c/Users/<you>/AppData/Local/Temp などを指定)
# 必要なもの: bash, curl, unzip, tar, python3, ps (procps), GNU coreutils
#
# ECS との対応:
#   タスク A / B           = 別プロセス (entrypoint.sh → exec standalone.sh → java)
#   EFS                     = シナリオごとの共有ディレクトリ ($RUN/efs)。A も B も同じ場所
#   タスクローカルの空ボリューム = タスクごとの standalone/{configuration,tmp,data} (空で開始)
#   イメージに焼いたリンク   = standalone/log -> $RUN/efs/.../mid/current (front/back の Dockerfile と同形)
#   ECS の SIGTERM 停止      = kill -TERM <standalone.sh> (LAUNCH_JBOSS_IN_BACKGROUND=true で JVM へ中継)
# 0 時は JVM のタイムゾーンだけを GMT±hh:mm にずらして作る (時計は実時刻)。
# readonlyRootFilesystem は再現しない (Docker 版の scenario.sh が --read-only で再現する)。
# =============================================================================
set -u
W=${ROTWORK:-$HOME/rotwork}
REPO=$(cd "$(dirname "$0")/../.." && pwd)   # 試験対象のリポジトリ (entrypoint.sh 等)
EP=$REPO/docker/base/entrypoint.sh
DL_DIR=${DL_DIR:-$W}

wf_dir()  { case $1 in wf26) echo "$W/wildfly-26.1.3.Final";; wf41) echo "$W/wildfly-41.0.1.Final";; esac; }
jre_dir() { case $1 in wf26) echo "$W/jre11";; wf41) echo "$W/jre21";; esac; }

setup() {
  local wf=$1 jre wfd url jurl zip c
  for c in curl unzip tar python3 ps; do
    command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c が必要です"; return 1; }
  done
  mkdir -p "$W" "$DL_DIR"
  jre=$(jre_dir "$wf"); wfd=$(wf_dir "$wf")
  case $wf in
    wf26) jurl="https://api.adoptium.net/v3/binary/latest/11/ga/linux/x64/jre/hotspot/normal/eclipse?project=jdk"
          url="https://github.com/wildfly/wildfly/releases/download/26.1.3.Final/wildfly-26.1.3.Final.zip" ;;
    wf41) jurl="https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jre/hotspot/normal/eclipse?project=jdk"
          url="https://github.com/wildfly/wildfly/releases/download/41.0.1.Final/wildfly-41.0.1.Final.zip" ;;
  esac
  if [ ! -x "$jre/bin/java" ]; then
    mkdir -p "$jre" && curl -fsSL "$jurl" | tar -xz -C "$jre" --strip-components=1 || return 1
  fi
  "$jre/bin/java" -version 2>&1 | head -1
  if [ ! -x "$wfd/bin/standalone.sh" ]; then
    zip="$DL_DIR/$(basename "$url")"
    curl -fsSL -o "$zip" "$url" || return 1
    unzip -q "$zip" -d "$W" || return 1
    rm -f "$zip"
  fi
  # 検証用 WAR (リポジトリの make_ticker_war.py で作る)
  if [ ! -f "$W/ticker.war" ]; then
    ( cd "$W" && python3 "$REPO/test/rotation/fake-eap/make_ticker_war.py" ) || return 1
  fi
  echo "setup ok: $wfd ($(du -sh "$wfd" | cut -f1)), $jre ($(du -sh "$jre" | cut -f1))"
}

# ---------------------------------------------------------------------------
# 1 シナリオ
# ---------------------------------------------------------------------------
scenario() {
  SCN=$1; WF=$2; LABEL=$3; PBASE=$4; MID=$5; TZID=$6; OFF=$7; shift 7
  EXTRA_ENV=("$@")
  WFD=$(wf_dir "$WF"); JRE=$(jre_dir "$WF")
  RUN=$W/runs/$LABEL; rm -rf "$RUN"; mkdir -p "$RUN/efs"
  OUT=$W/results/$LABEL.log; mkdir -p "$W/results"; : > "$OUT"
  EFSLOG=$RUN/efs/mnt/logs/intra-web-front/logs/intra-web
  MIDDIR=$EFSLOG/mid
  META_PORT=$((PBASE + 7000)); META_ENV=""

  lnow() { date -u -d "@$(( $(date +%s) + OFF ))" '+%F %T'; }
  log()  { echo "$(lnow) | $*" >> "$OUT"; }

  # イメージ相当のタスク用 JBOSS_HOME を作る (bin/modules は共有、standalone はタスクごと)
  mk_home() {
    local H=$RUN/$1/opt/jboss-eap x
    mkdir -p "$H/standalone" "$RUN/$1/home"
    for x in "$WFD"/* "$WFD"/.[!.]*; do
      [ -e "$x" ] || continue
      case $(basename "$x") in standalone) ;; *) ln -s "$x" "$H/$(basename "$x")";; esac
    done
    cp -a "$WFD/standalone/." "$H/standalone/"
    rm -rf "$H/standalone/log" "$H/standalone/tmp" "$H/standalone/data"
    # base の Dockerfile と同じ seed 退避 → configuration は「空のボリューム」から始める
    mkdir -p "$H/standalone/configuration-seed"
    cp -a "$H/standalone/configuration/." "$H/standalone/configuration-seed/"
    rm -rf "$H/standalone/configuration-seed/standalone_xml_history" "$H/standalone/configuration"
    mkdir -p "$H/standalone/configuration" "$H/standalone/tmp" "$H/standalone/data"
    cp "$W/ticker.war" "$H/standalone/deployments/"
    # front/back の Dockerfile が焼き込むリンクと同形 (絶対パスで EFS 上の current へ)
    ln -s "$MIDDIR/current" "$H/standalone/log"
  }

  port_off() { case $1 in A) echo "$PBASE";; B) echo $((PBASE + 1));; esac; }

  has_extra() { case " ${EXTRA_ENV[*]:-} " in *" $1 "*) return 0;; esac; return 1; }

  run_task() {  # run_task <A|B> [append]
    local t=$1 H=$RUN/$1/opt/jboss-eap po jopts cmd eap_env=""; po=$(port_off "$1")
    local redir=">"; [ "${2:-}" = append ] && redir=">>"
    jopts="-Xms32m -Xmx192m -XX:+UseSerialGC -XX:TieredStopAtLevel=1 -Djava.net.preferIPv4Stack=true -Djava.awt.headless=true -Duser.timezone=$TZID"
    # 本番のエントリポイントと同じく、JAVA_OPTS に既定と同じログ出力先を入れる
    has_extra T_JAVA_OPTS_LOG_DIR=1 && jopts="$jopts -Djboss.server.log.dir=$H/standalone/log"
    if has_extra T_CMD=eap; then
      # 本番と同じ起動方式。SERVER_CONFIG と EXTRASLB_TRUSTSTORE_TYPE は base の Dockerfile の ENV と同じ値
      # (TYPE が空だと JVM 既定のトラストストアを読めず、HTTPS の SSL コンテキストが起動に失敗する)。
      # ポートのずらしは JBOSS_SERVER_OPTS で渡す。どれも VAR=VAL の指定 (後ろに置く) で上書きできる
      eap_env="SERVER_CONFIG=standalone.xml EXTRASLB_TRUSTSTORE_TYPE=JKS JBOSS_SERVER_OPTS=\"-Djboss.socket.binding.port-offset=$po\""
      cmd="sh \"$EP\" eap"
    else
      cmd="sh \"$EP\" \"$H/bin/standalone.sh\" -b 127.0.0.1 -Djboss.socket.binding.port-offset=$po"
    fi
    (
      cd /tmp || exit 1
      eval "exec env -i PATH=\"$JRE/bin:/usr/bin:/bin\" HOME=\"$RUN/$t/home\" JAVA_HOME=\"$JRE\" \
        JBOSS_HOME=\"$H\" JBOSS_CONF_DIR=\"$H/standalone/configuration\" JBOSS_CONF_SEED_DIR=\"$H/standalone/configuration-seed\" \
        EFS_LOG_DIR=\"$EFSLOG\" COMPONENT_ROLE=back Service_Name=intra-web Component_name=intra-web-front \
        LAUNCH_JBOSS_IN_BACKGROUND=true JAVA_OPTS=\"$jopts\" $eap_env \
        ${META_ENV:-} ${EXTRA_ENV[*]:-} $cmd $redir \"$RUN/$t.console\" 2>&1"
    ) &
    echo $! > "$RUN/$t.pid"
    disown $! 2>/dev/null || true   # 後片付けの kill -9 で "Killed" を表示させない
    sleep 2
    log "START $t  $(grep -E 'log dir:|log pin|note: 共有' "$RUN/$t.console" | tail -3 | tr '\n' ' ')"
  }

  java_pid() { ps -o pid= --ppid "$(cat "$RUN/$1.pid")" 2>/dev/null | head -1 | tr -d ' '; }

  wait_boot() {  # wait_boot <A|B> [n]   (WFLYSRV0026 = started (with errors))
    local n=${2:-1} c
    for _ in $(seq 1 100); do
      c=$(grep -c 'WFLYSRV0025\|WFLYSRV0026' "$RUN/$1.console" 2>/dev/null)
      if [ "${c:-0}" -ge "$n" ]; then
        log "BOOTED $1 (#$n) $(grep -o 'WFLYSRV002[56]' "$RUN/$1.console" | sed -n "${n}p") ERROR 行=$(grep -c ' ERROR ' "$RUN/$1.console")"
        return 0
      fi
      sleep 3
    done
    log "BOOT TIMEOUT $1"; return 1
  }

  tick() {
    local r; r=$(curl -s --max-time 15 "http://127.0.0.1:$((8080 + $(port_off "$1")))/ticker/log.jsp?who=$2")
    log "TICK  $1 who=$2 -> ${r:-<no response>}"
  }

  wait_until() { while [ "$(date +%s)" -lt "$1" ]; do sleep 1; done; }

  fdview() {
    local jp; jp=$(java_pid "$1")
    [ -n "$jp" ] || { log "FD    $1 (java not running)"; return; }
    ls -l "/proc/$jp/fd" 2>/dev/null | grep -E 'server\.log' | sed "s#.* -> #fd -> #; s#$EFSLOG/##" \
      | while read -r l; do log "FD    $1 $l"; done
  }

  cmdline() {  # JVM に渡ったログ出力先の -D と、起動行 (-c / -b / -bmanagement / javax.net.ssl)
    local jp; jp=$(java_pid "$1")
    [ -n "$jp" ] && tr '\0' '\n' < "/proc/$jp/cmdline" \
      | awk 'p { print prev " " $0; p = 0; next }
             /^(-c|-b|-bmanagement)$/ { prev = $0; p = 1; next }
             /jboss\.server\.log\.dir|org\.jboss\.boot\.log\.file|javax\.net\.ssl/ { print }' \
      | sed "s#$EFSLOG/##" | while read -r l; do log "ARGV  $1 $l"; done
  }

  logdir() {  # JBoss 本体が実際に使っている jboss.server.log.dir (CLI でサーバ側の式を解決)
    local H=$RUN/$1/opt/jboss-eap r
    # shellcheck disable=SC2016  # ${jboss.server.log.dir} はサーバ側で解決させる
    r=$(env -i PATH="$JRE/bin:/usr/bin:/bin" HOME="$RUN/$1/home" JAVA_HOME="$JRE" JBOSS_HOME="$H" \
        "$H/bin/jboss-cli.sh" -c --controller="127.0.0.1:$((9990 + $(port_off "$1")))" \
        --command=':resolve-expression(expression=${jboss.server.log.dir})' 2>&1 \
        | tr -d '\n' | sed -n 's/.*"result" => "\([^"]*\)".*/\1/p')
    log "LOGDIR $1 jboss.server.log.dir=${r:-<取得できず>}"
  }

  cli() {
    local H=$RUN/$1/opt/jboss-eap
    env -i PATH="$JRE/bin:/usr/bin:/bin" HOME="$RUN/$1/home" JAVA_HOME="$JRE" JBOSS_HOME="$H" \
      "$H/bin/jboss-cli.sh" -c --controller="127.0.0.1:$((9990 + $(port_off "$1")))" --command="$2" 2>&1 | tr '\n' ' ' | cut -c1-160
  }

  stop_task() {  # ECS の停止 (SIGTERM → JBoss が停止ログを書いて終了)
    local p; p=$(cat "$RUN/$1.pid")
    kill -TERM "$p" 2>/dev/null
    for _ in $(seq 1 60); do kill -0 "$p" 2>/dev/null || return 0; sleep 1; done
    kill -KILL "$p" "$(java_pid "$1")" 2>/dev/null
  }

  crash_task() {  # クラッシュ (SIGKILL = 停止ログなし)
    local p jp; p=$(cat "$RUN/$1.pid"); jp=$(java_pid "$1")
    kill -KILL "$jp" "$p" 2>/dev/null; sleep 1
  }

  snapshot() {
    log "==== SNAPSHOT: $1 ===="
    (
      cd "$MIDDIR" 2>/dev/null || { echo '(no mid dir)'; exit 0; }
      echo "current -> $(readlink current)"
      for d in $(ls -1 | grep -v '^current$' | sort); do
        echo "[$d]"
        for f in $(ls -1 "$d" | grep '^server\.log' | sort); do
          echo "  $f  (size=$(wc -c < "$d/$f") bytes, inode=$(stat -c %i "$d/$f"))"
          grep -E 'TICK|WFLYSRV0049|WFLYSRV0025|WFLYSRV0050|WFLYSRV0272' "$d/$f" \
            | sed -E 's/^([0-9-]+ [0-9:,]+) +[A-Z]+ +\[[^]]+\] \([^)]*\) /      \1  /' | cut -c1-118
        done
      done
    ) >> "$OUT" 2>&1
  }

  start_meta() {
    mkdir -p "$RUN/meta/v4/fake"
    printf '%s' '{"Cluster":"arn:aws:ecs:ap-northeast-1:123456789012:cluster/demo","TaskARN":"arn:aws:ecs:ap-northeast-1:123456789012:task/demo/0123456789abcdef0123456789abcdef","Family":"intra-web","Revision":"42"}' > "$RUN/meta/v4/fake/task"
    ( cd "$RUN/meta" && exec python3 -m http.server "$META_PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
    echo $! > "$RUN/meta.pid"
    disown $! 2>/dev/null || true
    META_ENV="ECS_CONTAINER_METADATA_URI_V4=http://127.0.0.1:$META_PORT/v4/fake"
    log "META  started (ECS_CONTAINER_METADATA_URI_V4=http://127.0.0.1:$META_PORT/v4/fake, TaskARN=.../task/demo/0123456789abcdef0123456789abcdef)"
  }

  cleanup() {
    local t p
    for t in A B; do
      [ -f "$RUN/$t.pid" ] || continue
      p=$(cat "$RUN/$t.pid"); kill -KILL "$(java_pid "$t")" "$p" 2>/dev/null
    done
    [ -f "$RUN/meta.pid" ] && kill "$(cat "$RUN/meta.pid")" 2>/dev/null
  }

  mk_home A; mk_home B
  log "scenario=$SCN image=$WF tz=$TZID local-midnight=$(date -u -d "@$((MID + OFF))" '+%F %T') extra=[${EXTRA_ENV[*]:-}]"

  case "$SCN" in
    S1) # 新タスクが 0 時「後」に起動 → その後に旧タスクが停止 (ご報告の症状)
      wait_until $((MID - 170)); run_task A; wait_boot A; tick A "A:before-midnight"; logdir A
      wait_until $((MID + 5));  log "---- (0 時を通過: A はアイドルでログ未出力) ----"
      run_task B; wait_boot B; tick B "B:booted-after-midnight"; fdview B; cmdline B; logdir B
      log "---- rolling deploy: 旧タスク A を停止 (SIGTERM → 停止ログ = 0 時以降の最初のレコード) ----"
      stop_task A
      tick B "B:after-A-stopped-1"; tick B "B:after-A-stopped-2"; fdview B
      snapshot "S1 final"
      ;;
    S2|S2r) # 2 タスクが 0 時をまたいで稼働
      wait_until $((MID - 200)); run_task A; wait_boot A; tick A "A:before-midnight"
      run_task B; wait_boot B; tick B "B:before-midnight"; fdview A; fdview B
      wait_until $((MID + 5)); log "---- 0 時を通過 ----"
      if [ "$SCN" = S2 ]; then first=A; second=B; else first=B; second=A; fi
      tick $first  "$first:after-midnight-1"
      tick $second "$second:after-midnight-1"
      tick $first  "$first:after-midnight-2"
      tick $second "$second:after-midnight-2"
      fdview A; fdview B
      snapshot "$SCN final"
      ;;
    R1) # 0 時とは無関係: 旧タスク A の :reload と JVM 再起動 (:shutdown(restart=true))
      run_task A; wait_boot A; tick A "A:first-run"; fdview A
      run_task B; wait_boot B; tick B "B:running"; fdview B
      log "---- A: :reload (JVM は同じ。current は B を指している) ----"; log "cli: $(cli A ':reload')"
      wait_boot A 2; tick A "A:after-reload"; fdview A
      log "---- A: :shutdown(restart=true) (standalone.sh が exit 10 を受けて JVM を再起動) ----"
      log "cli: $(cli A ':shutdown(restart=true)')"
      sleep 5; wait_boot A 3; tick A "A:after-jvm-restart"; tick B "B:still-running"; fdview A; fdview B; cmdline A
      snapshot "R1 final"
      ;;
    R2) # 0 時前にクラッシュ → 0 時後に「同じタスク内で」コンテナ再起動 (ECS restartPolicy 相当)
      wait_until $((MID - 200)); start_meta
      run_task A; wait_boot A; tick A "A:run1-before-midnight"; fdview A
      wait_until $((MID - 20)); log "---- クラッシュ: kill -9 A (停止ログなし、server.log の最終更新は 0 時前) ----"
      crash_task A
      wait_until $((MID + 5)); log "---- 0 時を通過 → 同じタスクのコンテナを再起動 (entrypoint も再実行。tmpfs 相当の tmp/data/configuration は空に戻る) ----"
      H=$RUN/A/opt/jboss-eap; rm -rf "$H/standalone/tmp/"* "$H/standalone/data/"* "$H/standalone/configuration/"*
      run_task A append
      log "START A (2nd)  $(grep -E 'log dir:' "$RUN/A.console" | tail -1)"
      wait_boot A 2; tick A "A:run2-after-midnight"; fdview A
      snapshot "R2 final"
      ;;
  esac

  log "entrypoint lines A: $(grep efs-entrypoint "$RUN/A.console" 2>/dev/null | sed "s#$EFSLOG/##g" | tr '\n' ' ' | cut -c1-700)"
  log "entrypoint lines B: $(grep efs-entrypoint "$RUN/B.console" 2>/dev/null | sed "s#$EFSLOG/##g" | tr '\n' ' ' | cut -c1-700)"
  cleanup
  sed -i "s#$EFSLOG/##g" "$OUT"
  log "DONE"
}

batch() {
  local LEAD=$1; shift
  local NOW T OFF MID A SIGN TZID pids=()
  NOW=$(date +%s); T=$((NOW + LEAD))
  OFF=$(( (86400 - T % 86400) % 86400 )); OFF=$(( OFF / 60 * 60 ))
  [ "$OFF" -gt 43200 ] && OFF=$((OFF - 86400))
  MID=$(( ( (NOW + OFF) / 86400 + 1 ) * 86400 - OFF ))
  A=${OFF#-}; SIGN=+; [ "$OFF" -lt 0 ] && SIGN=-
  TZID=$(printf 'GMT%s%02d:%02d' "$SIGN" $((A / 3600)) $(((A % 3600) / 60)))
  echo "batch: tz=$TZID offset=$OFF midnight-in=$((MID - NOW))s local-now=$(date -u -d "@$((NOW + OFF))" '+%F %T')"
  for spec in "$@"; do
    # shellcheck disable=SC2086
    set -- $spec
    local scn=$1 wf=$2 label=$3 pb=$4; shift 4
    ( scenario "$scn" "$wf" "$label" "$pb" "$MID" "$TZID" "$OFF" "$@" ) &
    pids+=($!)
    echo "  started $scn $wf $label (pid $!)"
  done
  wait "${pids[@]}"
  echo "batch done"
}

case ${1:-} in
  setup) shift; setup "$@" ;;
  batch) shift; batch "$@" ;;
  clean) rm -rf "$W"; echo "removed $W" ;;
  *) echo "usage: $0 setup <wf26|wf41> | batch <lead_sec> \"<scn> <wf> <label> <port_base> [VAR=VAL...]\"... | clean"; exit 2 ;;
esac
