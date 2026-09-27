#!/usr/bin/env bash
# =============================================================================
# scenario.sh — JBoss (WildFly) を「ECS タスク相当」のコンテナで複数起動し、
# 日付変更 (= JVM タイムゾーン上の 0 時) をまたいだ server.log の挙動を記録する。
#
#   usage: scenario.sh <S1|S2|S2r|R1|R2> <image> <label> <midnight_epoch> <tz_id> <tz_offset_sec> [docker-run-args...]
#
# ECS との対応:
#   --read-only                       = readonlyRootFilesystem=true
#   --tmpfs configuration/tmp/data    = タスクローカルの空ボリューム (ECS は中身をコピーしない)
#   -v rot-<label>-logs:/mnt/logs     = タスク間で共有される EFS
#   コンテナ A / B                     = 旧タスク / 新タスク (別 JVM・別コンテナ・同じ EFS)
# 0 時を待たずに検証するため、JVM だけを GMT±hh:mm の時差に置き、
# 数分後が「その JVM にとっての 0 時」になるようにしている (ロジックは実時刻そのもの)。
# =============================================================================
set -u
export MSYS_NO_PATHCONV=1
DOCKER_BIN="$(command -v docker)"
docker() { timeout 90 "$DOCKER_BIN" "$@"; }
cd "$(dirname "$0")" || exit 1

SCN=$1; IMG=$2; LABEL=$3; MID=$4; TZID=$5; OFF=$6; shift 6
EXTRA=("$@")

OUT="results/${LABEL}.log"; mkdir -p results; : > "$OUT"
VOL_LOGS="rot-${LABEL}-logs"; VOL_DATA="rot-${LABEL}-data"
A="${LABEL}-A"; B="${LABEL}-B"
MIDDIR=/mnt/logs/intra-web-front/logs/intra-web/mid

lnow() { date -u -d "@$(( $(date +%s) + OFF ))" '+%F %T'; }
log()  { echo "$(lnow) | $*" >> "$OUT"; }

NET="${LABEL}-net"; META="${LABEL}-meta"
cleanup() {
  docker rm -f -v "$A" "$B" "$META" >/dev/null 2>&1
  docker volume rm -f "$VOL_LOGS" "$VOL_DATA" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
}

# ECS タスクメタデータエンドポイント v4 の代用 (/v4/fake/task に TaskARN を返す)
start_meta() {
  docker network create "$NET" >/dev/null
  docker run -d --name "$META" --network "$NET" alpine:latest sh -c '
    mkdir -p /www/v4/fake
    printf "%s" "{\"Cluster\":\"arn:aws:ecs:ap-northeast-1:123456789012:cluster/demo\",\"TaskARN\":\"arn:aws:ecs:ap-northeast-1:123456789012:task/demo/0123456789abcdef0123456789abcdef\",\"Family\":\"intra-web\",\"Revision\":\"42\"}" > /www/v4/fake/task
    exec busybox httpd -f -p 8000 -h /www' >/dev/null
  log "META  $META started (TaskARN=.../task/demo/0123456789abcdef0123456789abcdef)"
}

run_task() {
  docker run -d --name "$1" --read-only \
    --tmpfs /tmp:rw,exec,mode=1777 \
    --tmpfs /opt/jboss-eap/standalone/configuration:rw,mode=1777 \
    --tmpfs /opt/jboss-eap/standalone/tmp:rw,exec,mode=1777 \
    --tmpfs /opt/jboss-eap/standalone/data:rw,mode=1777 \
    -v /opt/jboss-eap/standalone/deployments \
    -v "$VOL_LOGS":/mnt/logs -v "$VOL_DATA":/mnt/data \
    -e HOME=/tmp \
    -e JAVA_OPTS="-Xms32m -Xmx192m -XX:+UseSerialGC -Djava.net.preferIPv4Stack=true -Djava.awt.headless=true -Duser.timezone=${TZID}" \
    "${EXTRA[@]}" "$IMG" >/dev/null
  sleep 2
  log "START $1  $(docker logs "$1" 2>&1 | grep -E 'log dir:|pin' | tr '\n' ' ')"
}

# n 回目の起動完了 (WFLYSRV0025/0026) を待つ
wait_boot() {
  local n=${2:-1} c
  for _ in $(seq 1 80); do
    c=$(docker logs "$1" 2>&1 | grep -c 'WFLYSRV0025\|WFLYSRV0026')
    [ "$c" -ge "$n" ] && { log "BOOTED $1 (#$n)"; return 0; }
    sleep 3
  done
  log "BOOT TIMEOUT $1"; return 1
}

tick() {
  local r; r=$(docker exec "$1" curl -s "localhost:8080/ticker/log.jsp?who=$2")
  log "TICK  $1 who=$2 -> ${r:-<no response>}"
}

wait_until() { while [ "$(date +%s)" -lt "$1" ]; do sleep 2; done; }

# JVM が実際に握っている server.log の fd (カーネルが解決した実パス)
fdview() {
  docker exec "$1" sh -c '
    for p in /proc/[0-9]*; do
      case "$(readlink "$p/exe" 2>/dev/null)" in
        */java) ls -l "$p/fd" 2>/dev/null | grep -E "server\.log" | sed "s/.* -> /fd -> /" ;;
      esac
    done' 2>/dev/null | while read -r l; do log "FD    $1 $l"; done
}

cli() { docker exec -w /tmp -e HOME=/tmp "$1" /opt/jboss-eap/bin/jboss-cli.sh -c --command="$2" 2>&1 | tr '\n' ' ' | cut -c1-160; }

snapshot() {
  log "==== SNAPSHOT: $1 ===="
  docker run --rm -v "$VOL_LOGS":/mnt/logs alpine:latest sh -c "
    cd $MIDDIR 2>/dev/null || { echo '(no mid dir)'; exit 0; }
    echo \"current -> \$(readlink current)\"
    for d in \$(ls -1 | grep -v '^current\$' | sort); do
      echo \"[\$d]\"
      for f in \$(ls -1 \"\$d\" | grep '^server\.log' | sort); do
        echo \"  \$f  (size=\$(wc -c < \"\$d/\$f\") bytes, inode=\$(stat -c %i \"\$d/\$f\"))\"
        grep -E 'TICK|WFLYSRV0049|WFLYSRV0025|WFLYSRV0050|WFLYSRV0272' \"\$d/\$f\" \
          | sed -E 's/^([0-9-]+ [0-9:,]+) +[A-Z]+ +\[[^]]+\] \([^)]*\) /      \1  /' | cut -c1-118
      done
    done" >> "$OUT" 2>&1
}

cleanup
docker volume create "$VOL_LOGS" >/dev/null; docker volume create "$VOL_DATA" >/dev/null
log "scenario=$SCN image=$IMG tz=$TZID local-midnight=$(date -u -d "@$((MID + OFF))" '+%F %T') extra=[${EXTRA[*]}]"

case "$SCN" in
  S1) # 新タスクが 0 時「後」に起動 → その後に旧タスクが停止 (ユーザー報告の症状)
    wait_until $((MID - 170)); run_task "$A"; wait_boot "$A"; tick "$A" "A:before-midnight"
    wait_until $((MID + 5));  log "---- (0 時を通過: A はアイドルでログ未出力) ----"
    run_task "$B"; wait_boot "$B"; tick "$B" "B:booted-after-midnight"; fdview "$B"
    log "---- rolling deploy: 旧タスク A を停止 (SIGTERM → 停止ログ = 0 時以降の最初のレコード) ----"
    docker stop -t 60 "$A" >/dev/null
    tick "$B" "B:after-A-stopped-1"; tick "$B" "B:after-A-stopped-2"; fdview "$B"
    snapshot "S1 final"
    ;;
  S2|S2r) # 2 タスクが 0 時をまたいで稼働 (desiredCount=2 / 0 時直前の起動)
    wait_until $((MID - 200)); run_task "$A"; wait_boot "$A"; tick "$A" "A:before-midnight"
    run_task "$B"; wait_boot "$B"; tick "$B" "B:before-midnight"; fdview "$A"; fdview "$B"
    wait_until $((MID + 5)); log "---- 0 時を通過 ----"
    if [ "$SCN" = S2 ]; then first=$A; second=$B; else first=$B; second=$A; fi
    tick "$first"  "${first##*-}:after-midnight-1"
    tick "$second" "${second##*-}:after-midnight-1"
    tick "$first"  "${first##*-}:after-midnight-2"
    tick "$second" "${second##*-}:after-midnight-2"
    fdview "$A"; fdview "$B"
    snapshot "$SCN final"
    ;;
  R1) # 0 時とは無関係: 旧タスク A の JVM 再起動 (:shutdown(restart=true)) と :reload
    run_task "$A"; wait_boot "$A"; tick "$A" "A:first-run"
    run_task "$B"; wait_boot "$B"; tick "$B" "B:running"; fdview "$A"; fdview "$B"
    log "---- A: :reload (JVM は同じ) ----"; log "cli: $(cli "$A" ':reload')"
    wait_boot "$A" 2; tick "$A" "A:after-reload"; fdview "$A"
    log "---- A: :shutdown(restart=true) (standalone.sh が exit 10 を受けて JVM を再起動) ----"
    log "cli: $(cli "$A" ':shutdown(restart=true)')"
    wait_boot "$A" 3; tick "$A" "A:after-jvm-restart"; tick "$B" "B:still-running"; fdview "$A"; fdview "$B"
    snapshot "R1 final"
    ;;
  R2) # 0 時前にクラッシュ → 0 時後に「同じタスク内で」コンテナ再起動 (ECS restartPolicy 相当)
      # EXTRA に --network <label>-net -e LOG_ID_SOURCE=taskid ... を渡すと taskid モード
    wait_until $((MID - 200)); start_meta
    run_task "$A"; wait_boot "$A"; tick "$A" "A:run1-before-midnight"; fdview "$A"
    wait_until $((MID - 20)); log "---- クラッシュ: docker kill A (SIGKILL = 停止ログなし、server.log の最終更新は 0 時前) ----"
    docker kill "$A" >/dev/null
    wait_until $((MID + 5)); log "---- 0 時を通過 → 同じコンテナを再起動 (entrypoint も再実行される) ----"
    docker start "$A" >/dev/null; sleep 2
    log "START $A (2nd)  $(docker logs "$A" 2>&1 | grep -E 'log dir:' | tail -1)"
    wait_boot "$A" 2; tick "$A" "A:run2-after-midnight"; fdview "$A"
    snapshot "R2 final"
    ;;
esac

log "docker logs (entrypoint lines) A: $(docker logs "$A" 2>&1 | grep efs-entrypoint | tr '\n' ' ' | cut -c1-600)"
log "docker logs (entrypoint lines) B: $(docker logs "$B" 2>&1 | grep efs-entrypoint | tr '\n' ' ' | cut -c1-600)"
cleanup
log "DONE"
