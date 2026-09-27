#!/bin/bash
# =============================================================================
# entrypoint_test.sh — docker/base/entrypoint.sh / entrypoint.taskid.sh の分岐試験
#                      (Docker も JBoss も不要。Linux / WSL で数十秒)
#
#   usage: test/local/entrypoint_test.sh [shell...]
#          shell 既定: "dash" "bash --posix" "busybox sh" (入っているものだけ)
#   必要なもの: bash, python3 (メタデータ v4 の代用), curl, GNU coreutils
#
# コンテナの代わりに一時ディレクトリへ「疑似ルート」を作り、JBOSS_HOME / EFS_LOG_DIR /
# JBOSS_CONF_DIR / JBOSS_CONF_SEED_DIR を向けて実行する。CMD には引数と環境を
# 表示するだけの疑似 standalone.sh を渡し、exec 直前の状態 (挿入された引数・
# JBOSS_LOG_DIR・current・logging.properties) を検証する。
# /usr/local/bin を使うラッパー試験だけは user+mount 名前空間 (unshare -rm) で
# tmpfs を重ねて行う (root 不要。使えない環境では SKIP)。
# =============================================================================
# check の条件式は eval で評価するため、そこでだけ参照する変数 (RC・bad・L など) がある
# shellcheck disable=SC2034
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SHELLS=("$@")
if [ ${#SHELLS[@]} -eq 0 ]; then
  for s in "dash" "bash --posix" "busybox sh"; do
    command -v "${s%% *}" >/dev/null 2>&1 && SHELLS+=("$s")
  done
fi
EP="$REPO/docker/base/entrypoint.sh"
WRAP="$REPO/docker/base/entrypoint.taskid.sh"
for c in python3 curl; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c が必要です"; exit 2; }
done

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS + 1)); echo "    ok   $*"; }
ng()   { FAIL=$((FAIL + 1)); echo "    FAIL $*"; }
skip() { SKIP=$((SKIP + 1)); echo "    SKIP $*"; }
check(){ if eval "$2"; then ok "$1"; else ng "$1   [cond: $2]"; fi; }

# --- 疑似ルートの作成 ---------------------------------------------------------
mkroot() {
  R=$(mktemp -d /tmp/epu.XXXXXX)
  JH=$R/opt/jboss-eap; SD=$JH/standalone
  EFS=$R/mnt/logs/intra-web-front/logs/intra-web
  MID=$EFS/mid
  mkdir -p "$SD/configuration" "$SD/configuration-seed" "$SD/tmp" "$SD/data" "$SD/deployments" "$JH/bin" "$R/mnt/logs"
  cat > "$SD/configuration-seed/logging.properties" <<'LP'
loggers=sun.rmi
handler.FILE=org.jboss.logmanager.handlers.PeriodicRotatingFileHandler
handler.FILE.properties=autoFlush,append,fileName,suffix,enabled,encoding
handler.FILE.fileName=${org.jboss.boot.log.file\:server.log}
handler.FILE.suffix=.yyyy-MM-dd
LP
  echo '<server/>' > "$SD/configuration-seed/standalone.xml"
  # ビルド時に焼き込む 2 段リンクの入口 (front/back の Dockerfile と同じ形)
  ln -s "$MID/current" "$SD/log"
  # 疑似 standalone.sh: 自分のパス、引数 1 つずつ [] で囲んだもの、環境を出す
  cat > "$JH/bin/standalone.sh" <<'SS'
#!/bin/sh
echo "SCRIPT=$0"
for a in "$@"; do echo "ARG[$a]"; done
echo "JBOSS_LOG_DIR=${JBOSS_LOG_DIR:-<unset>}"
echo "LOG_ID_SOURCE=${LOG_ID_SOURCE:-<unset>}"
echo "JAVA_OPTS=${JAVA_OPTS:-<unset>}"
SS
  chmod +x "$JH/bin/standalone.sh"
}

# エントリポイントの実行 (出力は $OUT、終了コードは $RC)
run_ep() {  # run_ep <env...> -- <cmd...>
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  OUT=$(env -i PATH="$PATH" HOME=/tmp \
        JBOSS_HOME="$JH" JBOSS_CONF_DIR="$SD/configuration" JBOSS_CONF_SEED_DIR="$SD/configuration-seed" \
        EFS_LOG_DIR="$EFS" COMPONENT_ROLE=back Service_Name=intra-web \
        "${envs[@]}" $SH "$EP" "$@" 2>&1)
  RC=$?
}
own_dir() { sed -n 's/^\[efs-entrypoint\] JBoss EAP log dir: \(.*\) (LOG_ID_SOURCE=.*$/\1/p' <<<"$OUT"; }

# --- メタデータエンドポイント v4 の代用 ---------------------------------------
META_PORT=${META_PORT:-18765}
start_meta() {
  META_DIR=$(mktemp -d /tmp/epmeta.XXXXXX)
  mkdir -p "$META_DIR/v4/ok" "$META_DIR/v4/old" "$META_DIR/v4/bad" "$META_DIR/v4/pretty"
  printf '%s' '{"Cluster":"arn:aws:ecs:ap-northeast-1:123456789012:cluster/demo","TaskARN":"arn:aws:ecs:ap-northeast-1:123456789012:task/demo/0123456789abcdef0123456789abcdef","Family":"intra-web"}' > "$META_DIR/v4/ok/task"
  printf '%s' '{"TaskARN":"arn:aws:ecs:ap-northeast-1:123456789012:task/11111111-2222-3333-4444-555555555555"}' > "$META_DIR/v4/old/task"
  printf '%s' '{"TaskARN":"arn:aws:ecs:ap-northeast-1:123456789012:task/demo/../../x;rm -rf"}' > "$META_DIR/v4/bad/task"
  printf '{\n  "Cluster": "demo",\n  "TaskARN": "arn:aws:ecs:ap-northeast-1:123456789012:task/demo/fedcba9876543210fedcba9876543210",\n  "Family": "x"\n}\n' > "$META_DIR/v4/pretty/task"
  (cd "$META_DIR" && exec python3 -m http.server "$META_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
  META_PID=$!
  for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$META_PORT/v4/ok/task" >/dev/null 2>&1 && return 0; sleep 0.1; done
  echo "meta server did not start"; return 1
}
stop_meta() { kill "$META_PID" 2>/dev/null; wait "$META_PID" 2>/dev/null; rm -rf "$META_DIR"; }

start_meta || exit 1
trap stop_meta EXIT

for SH in "${SHELLS[@]}"; do
  echo "################ shell: $SH"

  echo "  [1] 既定 (pin=on) + CMD=.../standalone.sh → コマンド直後に -Djboss.server.log.dir=<実体パス> を挿入"
  mkroot
  run_ep -- "$JH/bin/standalone.sh" -b 0.0.0.0 "-Dfoo=a b"
  D=$(own_dir)
  check "rc=0" '[ $RC -eq 0 ]'
  check "mid/<LOG_ID> が random 形式 (YYYYMMDDhhmmss-8桁)" '[[ "$(basename "$D")" =~ ^[0-9]{14}-[a-z0-9]{8}$ ]]'
  check "current -> <LOG_ID> (相対リンク)" '[ "$(readlink "$MID/current")" = "$(basename "$D")" ]'
  check "1 番目の引数が -Djboss.server.log.dir=<実体パス>" '[ "$(grep -m1 "^ARG\[" <<<"$OUT")" = "ARG[-Djboss.server.log.dir=$D]" ]'
  check "元の引数が順序・空白を保って続く" '[ "$(grep "^ARG\[" <<<"$OUT" | sed -n 2,4p | tr "\n" "|")" = "ARG[-b]|ARG[0.0.0.0]|ARG[-Dfoo=a b]|" ]'
  check "JBOSS_LOG_DIR=<実体パス> を export" 'grep -qx "JBOSS_LOG_DIR=$D" <<<"$OUT"'
  check "log pin の案内行" 'grep -q "log pin: JBoss は $D へ直接書き込みます" <<<"$OUT"'
  check "preflight OK 行に挿入後の引数" 'grep -q "preflight OK. starting: $JH/bin/standalone.sh -Djboss.server.log.dir=$D -b 0.0.0.0" <<<"$OUT"'
  check "configuration を seed から復元" '[ -f "$SD/configuration/standalone.xml" ] && [ -f "$SD/configuration/logging.properties" ]'
  check "既定の \${org.jboss.boot.log.file} 形式は書き換えない" 'grep -qF "handler.FILE.fileName=\${org.jboss.boot.log.file\:server.log}" "$SD/configuration/logging.properties"'
  check "実体パスに current が含まれない" '[[ "$D" != *current* ]]'
  rm -rf "$R"

  echo "  [1b] CMD=standalone.sh (パス無し) でも挿入"
  mkroot
  OUT=$(cd "$JH/bin" && env -i PATH="$JH/bin:$PATH" HOME=/tmp JBOSS_HOME="$JH" JBOSS_CONF_DIR="$SD/configuration" JBOSS_CONF_SEED_DIR="$SD/configuration-seed" EFS_LOG_DIR="$EFS" COMPONENT_ROLE=back $SH "$EP" standalone.sh -b 0.0.0.0 2>&1); RC=$?
  D=$(own_dir)
  check "rc=0 かつ 1 番目の引数が -Djboss.server.log.dir" '[ $RC -eq 0 ] && [ "$(grep -m1 "^ARG\[" <<<"$OUT")" = "ARG[-Djboss.server.log.dir=$D]" ]'
  rm -rf "$R"

  echo "  [2] CMD が eap / standalone.sh 以外 → WARN のみ (-D は付けない。そのまま exec) / JBOSS_LOG_DIR は export"
  mkroot
  run_ep -- sh -c 'for a in "$@"; do echo "ARG[$a]"; done; echo "JBOSS_LOG_DIR=${JBOSS_LOG_DIR:-<unset>}"' sh -b 0.0.0.0
  D=$(own_dir)
  check "rc=0" '[ $RC -eq 0 ]'
  check "WARN: CMD が eap / standalone.sh ではない" 'grep -q "WARN: CMD が eap / standalone.sh ではないため" <<<"$OUT"'
  check "引数は変更なし" '[ "$(grep "^ARG\[" <<<"$OUT" | tr "\n" "|")" = "ARG[-b]|ARG[0.0.0.0]|" ]'
  check "JBOSS_LOG_DIR=<実体パス>" 'grep -qx "JBOSS_LOG_DIR=$D" <<<"$OUT"'
  rm -rf "$R"

  echo "  [3] -Djboss.server.log.dir を引数で明示 → 明示を優先 (pin しない)"
  mkroot
  run_ep -- "$JH/bin/standalone.sh" -b 0.0.0.0 -Djboss.server.log.dir=/manual/dir
  check "rc=0 / WARN / 引数そのまま / JBOSS_LOG_DIR 未設定" '[ $RC -eq 0 ] && grep -q "明示指定されているため pin を適用しません" <<<"$OUT" && [ "$(grep "^ARG\[" <<<"$OUT" | tr "\n" "|")" = "ARG[-b]|ARG[0.0.0.0]|ARG[-Djboss.server.log.dir=/manual/dir]|" ] && grep -qx "JBOSS_LOG_DIR=<unset>" <<<"$OUT"'
  rm -rf "$R"

  echo "  [3b] JAVA_OPTS に -Djboss.server.log.dir → 明示を優先"
  mkroot
  run_ep "JAVA_OPTS=-Xmx64m -Djboss.server.log.dir=/manual/dir" -- "$JH/bin/standalone.sh" -b 0.0.0.0
  check "rc=0 / pin しない" '[ $RC -eq 0 ] && grep -q "明示指定されているため pin を適用しません" <<<"$OUT" && [ "$(grep -m1 "^ARG\[" <<<"$OUT")" = "ARG[-b]" ]'
  rm -rf "$R"

  echo "  [3c] JAVA_OPTS に本番と同じ -Djboss.server.log.dir=<JBOSS_HOME>/standalone/log → 共有の置き場なので pin で上書き"
  mkroot
  run_ep "JAVA_OPTS=-Xmx64m -Djboss.server.log.dir=$JH/standalone/log" -- "$JH/bin/standalone.sh" -b 0.0.0.0
  D=$(own_dir)
  check "rc=0 / 1 番目の引数が pin" '[ $RC -eq 0 ] && [ "$(grep -m1 "^ARG\[" <<<"$OUT")" = "ARG[-Djboss.server.log.dir=$D]" ]'
  check "上書きの note に出どころと値" 'grep -q "note: 共有の置き場 (current 経由) を指す -Djboss.server.log.dir の指定 (JAVA_OPTS: $JH/standalone/log) は pin で上書きします" <<<"$OUT"'
  check "明示指定優先の WARN は出ない" '! grep -q "pin を適用しません" <<<"$OUT"'
  check "JAVA_OPTS は変えずに渡す / JBOSS_LOG_DIR=<実体パス>" 'grep -qx "JAVA_OPTS=-Xmx64m -Djboss.server.log.dir=$JH/standalone/log" <<<"$OUT" && grep -qx "JBOSS_LOG_DIR=$D" <<<"$OUT"'
  rm -rf "$R"

  echo "  [3d] 引用符付き・末尾 / ・mid/current の直指定も共有の置き場と判定"
  mkroot
  run_ep "JAVA_OPTS=-Djboss.server.log.dir=\"$JH/standalone/log/\"" -- "$JH/bin/standalone.sh"
  check "\"<JBOSS_HOME>/standalone/log/\" → pin" '[ $RC -eq 0 ] && [ "$(grep -m1 "^ARG\[" <<<"$OUT")" = "ARG[-Djboss.server.log.dir=$(own_dir)]" ]'
  run_ep "JAVA_OPTS='-Djboss.server.log.dir=$MID/current'" -- "$JH/bin/standalone.sh"
  check "'<mid>/current' → pin" '[ $RC -eq 0 ] && [ "$(grep -m1 "^ARG\[" <<<"$OUT")" = "ARG[-Djboss.server.log.dir=$(own_dir)]" ]'
  rm -rf "$R"

  echo "  [3e] 起動引数に共有の置き場を指す -Djboss.server.log.dir → 取り除いてから pin (後ろに残すと pin に勝つため)"
  mkroot
  run_ep -- "$JH/bin/standalone.sh" -b 0.0.0.0 "-Djboss.server.log.dir=$JH/standalone/log" -Dx=1
  D=$(own_dir)
  check "rc=0 / 引数は pin・-b 0.0.0.0・-Dx=1 だけ" '[ $RC -eq 0 ] && [ "$(grep "^ARG\[" <<<"$OUT" | tr "\n" "|")" = "ARG[-Djboss.server.log.dir=$D]|ARG[-b]|ARG[0.0.0.0]|ARG[-Dx=1]|" ]'
  check "note の出どころは起動引数" 'grep -q "(起動引数: $JH/standalone/log) は pin で上書きします" <<<"$OUT"'
  rm -rf "$R"

  echo "  [3f] mid の外の実在するディレクトリを明示 → 運用者の指定として尊重 (pin しない)"
  mkroot
  mkdir -p "$R/var/jboss-log"
  run_ep "JAVA_OPTS=-Djboss.server.log.dir=$R/var/jboss-log" -- "$JH/bin/standalone.sh" -b 0.0.0.0
  check "rc=0 / WARN に値 / pin 無し / JBOSS_LOG_DIR 未設定" '[ $RC -eq 0 ] && grep -q "WARN: -Djboss.server.log.dir=$R/var/jboss-log が明示指定されているため pin を適用しません" <<<"$OUT" && [ "$(grep -m1 "^ARG\[" <<<"$OUT")" = "ARG[-b]" ] && grep -qx "JBOSS_LOG_DIR=<unset>" <<<"$OUT"'
  rm -rf "$R"

  echo "  [4] JBOSS_LOG_PIN=off → 従来どおり current 経由 (WARN)"
  mkroot
  run_ep JBOSS_LOG_PIN=off -- "$JH/bin/standalone.sh" -b 0.0.0.0
  check "rc=0 / WARN / -D 無し / JBOSS_LOG_DIR 未設定" '[ $RC -eq 0 ] && grep -q "WARN: JBOSS_LOG_PIN=off" <<<"$OUT" && [ "$(grep -m1 "^ARG\[" <<<"$OUT")" = "ARG[-b]" ] && grep -qx "JBOSS_LOG_DIR=<unset>" <<<"$OUT"'
  rm -rf "$R"

  echo "  [5] JBOSS_LOG_PIN=maybe (不正値) → FATAL。current・mid を一切触らない"
  mkroot
  mkdir -p "$MID/prev-task"; ln -s prev-task "$MID/current"
  run_ep JBOSS_LOG_PIN=maybe -- "$JH/bin/standalone.sh"
  check "rc=1 / FATAL / 診断ダンプ" '[ $RC -eq 1 ] && grep -q "FATAL: JBOSS_LOG_PIN の値が不正です" <<<"$OUT" && grep -q "diagnostics" <<<"$OUT"'
  check "current は prev-task のまま・新ディレクトリ無し・configuration 未復元" '[ "$(readlink "$MID/current")" = prev-task ] && [ "$(ls "$MID" | wc -l)" -eq 2 ] && [ ! -f "$SD/configuration/standalone.xml" ]'
  rm -rf "$R"

  echo "  [6] LOG_ID_SOURCE=foo (不正値) → FATAL。current を触らない"
  mkroot
  mkdir -p "$MID/prev-task"; ln -s prev-task "$MID/current"
  run_ep LOG_ID_SOURCE=foo -- "$JH/bin/standalone.sh"
  check "rc=1 / FATAL / current 不変" '[ $RC -eq 1 ] && grep -q "FATAL: LOG_ID_SOURCE の値が不正です" <<<"$OUT" && [ "$(readlink "$MID/current")" = prev-task ]'
  rm -rf "$R"

  echo "  [7] LOG_ID_SOURCE=taskid・メタデータ無し → WARN して random で代替"
  mkroot
  run_ep LOG_ID_SOURCE=taskid -- "$JH/bin/standalone.sh"
  D=$(own_dir)
  check "rc=0 / WARN / random 形式 / pin 有効" '[ $RC -eq 0 ] && grep -q "ECS タスク ID を取得できないため random 方式" <<<"$OUT" && [[ "$(basename "$D")" =~ ^[0-9]{14}-[a-z0-9]{8}$ ]] && [ "$(grep -m1 "^ARG\[" <<<"$OUT")" = "ARG[-Djboss.server.log.dir=$D]" ]'
  rm -rf "$R"

  echo "  [7b] LOG_ID_SOURCE=taskid・メタデータ有り (新形式 ARN) → タスク ID。再起動では同じディレクトリを再利用"
  mkroot
  run_ep LOG_ID_SOURCE=taskid ECS_CONTAINER_METADATA_URI_V4="http://127.0.0.1:$META_PORT/v4/ok" -- "$JH/bin/standalone.sh"
  D=$(own_dir)
  check "rc=0 / LOG_ID=タスク ID / current -> タスク ID / -D=実体パス" '[ $RC -eq 0 ] && [ "$(basename "$D")" = 0123456789abcdef0123456789abcdef ] && [ "$(readlink "$MID/current")" = 0123456789abcdef0123456789abcdef ] && [ "$(grep -m1 "^ARG\[" <<<"$OUT")" = "ARG[-Djboss.server.log.dir=$D]" ]'
  echo "previous run" > "$D/server.log"
  run_ep LOG_ID_SOURCE=taskid ECS_CONTAINER_METADATA_URI_V4="http://127.0.0.1:$META_PORT/v4/ok" -- "$JH/bin/standalone.sh"
  check "2 回目 (restartPolicy 相当): rc=0・同じディレクトリ・既存 server.log は残る" '[ $RC -eq 0 ] && [ "$(own_dir)" = "$D" ] && [ "$(cat "$D/server.log")" = "previous run" ] && [ "$(ls "$MID" | wc -l)" -eq 2 ]'
  rm -rf "$R"

  echo "  [7c] taskid・旧形式 ARN (task/<id>) と整形 JSON"
  mkroot
  run_ep LOG_ID_SOURCE=taskid ECS_CONTAINER_METADATA_URI_V4="http://127.0.0.1:$META_PORT/v4/old" -- "$JH/bin/standalone.sh"
  check "旧形式: LOG_ID=11111111-2222-3333-4444-555555555555" '[ $RC -eq 0 ] && [ "$(basename "$(own_dir)")" = 11111111-2222-3333-4444-555555555555 ]'
  run_ep LOG_ID_SOURCE=taskid ECS_CONTAINER_METADATA_URI_V4="http://127.0.0.1:$META_PORT/v4/pretty" -- "$JH/bin/standalone.sh"
  check "整形 JSON: LOG_ID=fedcba9876543210fedcba9876543210" '[ $RC -eq 0 ] && [ "$(basename "$(own_dir)")" = fedcba9876543210fedcba9876543210 ]'
  rm -rf "$R"

  echo "  [7d] taskid・不正な文字を含む ARN → 採用せず random で代替"
  mkroot
  run_ep LOG_ID_SOURCE=taskid ECS_CONTAINER_METADATA_URI_V4="http://127.0.0.1:$META_PORT/v4/bad" -- "$JH/bin/standalone.sh"
  check "rc=0 / WARN / random 形式" '[ $RC -eq 0 ] && grep -q "random 方式" <<<"$OUT" && [[ "$(basename "$(own_dir)")" =~ ^[0-9]{14}-[a-z0-9]{8}$ ]]'
  rm -rf "$R"

  echo "  [8] ラッパーの自己呼び出し検出 (EFS_ENTRYPOINT_TASKID_WRAPPED=1)"
  OUT=$(env -i PATH="$PATH" EFS_ENTRYPOINT_TASKID_WRAPPED=1 $SH "$WRAP" true 2>&1); RC=$?
  check "rc=1 / FATAL" '[ $RC -eq 1 ] && grep -q "FATAL: ラッパーが自分自身を呼び出しました" <<<"$OUT"'

  echo "  [8b] ラッパー経由 (/usr/local/bin を tmpfs で差し替えた名前空間) → LOG_ID_SOURCE=taskid で本体を実行"
  if ! unshare -rm sh -c 'mount -t tmpfs tmpfs /usr/local/bin' >/dev/null 2>&1; then
    skip "unshare -rm (user+mount 名前空間) が使えない環境のため [8b] を省略"
  else
  mkroot
  OUT=$(unshare -rm $SH -c '
    mount -t tmpfs tmpfs /usr/local/bin || exit 97
    cp "$1" /usr/local/bin/efs-entrypoint.sh && cp "$2" /usr/local/bin/efs-entrypoint-taskid.sh
    chmod 755 /usr/local/bin/efs-entrypoint.sh /usr/local/bin/efs-entrypoint-taskid.sh
    exec env -i PATH="$PATH" HOME=/tmp JBOSS_HOME="$3" JBOSS_CONF_DIR="$3/standalone/configuration" JBOSS_CONF_SEED_DIR="$3/standalone/configuration-seed" \
      EFS_LOG_DIR="$4" COMPONENT_ROLE=back ECS_CONTAINER_METADATA_URI_V4="$5" \
      /usr/local/bin/efs-entrypoint-taskid.sh "$3/bin/standalone.sh" -b 0.0.0.0' sh "$EP" "$WRAP" "$JH" "$EFS" "http://127.0.0.1:$META_PORT/v4/ok" 2>&1); RC=$?
  D=$(own_dir)
  check "rc=0 / LOG_ID=タスク ID / LOG_ID_SOURCE=taskid / pin 有効" '[ $RC -eq 0 ] && [ "$(basename "$D")" = 0123456789abcdef0123456789abcdef ] && grep -qx "LOG_ID_SOURCE=taskid" <<<"$OUT" && [ "$(grep -m1 "^ARG\[" <<<"$OUT")" = "ARG[-Djboss.server.log.dir=$D]" ]'
  OUT=$(unshare -rm $SH -c '
    mount -t tmpfs tmpfs /usr/local/bin || exit 97
    cp "$1" /usr/local/bin/efs-entrypoint.sh && cp "$2" /usr/local/bin/efs-entrypoint-taskid.sh
    chmod 755 /usr/local/bin/efs-entrypoint.sh /usr/local/bin/efs-entrypoint-taskid.sh
    exec env -i PATH="$PATH" HOME=/tmp JBOSS_HOME="$3" JBOSS_CONF_DIR="$3/standalone/configuration" JBOSS_CONF_SEED_DIR="$3/standalone/configuration-seed" \
      EFS_LOG_DIR="$4" COMPONENT_ROLE=back ECS_CONTAINER_METADATA_URI_V4="$5" SERVER_CONFIG=standalone.xml \
      /usr/local/bin/efs-entrypoint-taskid.sh eap' sh "$EP" "$WRAP" "$JH" "$EFS" "http://127.0.0.1:$META_PORT/v4/ok" 2>&1); RC=$?
  check "ラッパー経由の CMD=eap: rc=0 / 同じタスク ID のディレクトリ / pin → -b 0.0.0.0" '[ $RC -eq 0 ] && [ "$(own_dir)" = "$D" ] && [ "$(grep "^ARG\[" <<<"$OUT" | head -3 | tr "\n" "|")" = "ARG[-Djboss.server.log.dir=$D]|ARG[-b]|ARG[0.0.0.0]|" ]'
  OUT=$(unshare -rm $SH -c '
    mount -t tmpfs tmpfs /usr/local/bin || exit 97
    cp "$1" /usr/local/bin/efs-entrypoint.sh; chmod 755 /usr/local/bin/efs-entrypoint.sh
    exec env -i PATH="$PATH" /usr/local/bin/efs-entrypoint.sh true' sh "$WRAP" 2>&1); RC=$?
  check "誤って efs-entrypoint.sh としてラッパーを置いた場合 → 無限 exec せず FATAL" '[ $RC -eq 1 ] && grep -q "FATAL: ラッパーが自分自身を呼び出しました" <<<"$OUT"'
  rm -rf "$R"
  fi

  echo "  [9] logging.properties に current 経由・前回 LOG_ID の絶対パスが残っている (CONFIG_SEED_MODE=skip)"
  mkroot
  cp "$SD/configuration-seed/"* "$SD/configuration/"
  sed -i 's#^handler.FILE.fileName=.*#handler.FILE.fileName='"$SD"'/log/server.log#' "$SD/configuration/logging.properties"
  printf 'handler.OLD=org.jboss.logmanager.handlers.FileHandler\nhandler.OLD.fileName=%s/20260101000000-oldrun00/app.log\nhandler.CUR.fileName=%s/current/cur.log\nhandler.OTHER.fileName=/var/log/other.log\n' "$MID" "$MID" >> "$SD/configuration/logging.properties"
  run_ep CONFIG_SEED_MODE=skip -- "$JH/bin/standalone.sh"
  D=$(own_dir)
  check "rc=0 / 揃えた旨のログ" '[ $RC -eq 0 ] && grep -q "logging.properties の fileName を $D へ揃えました" <<<"$OUT"'
  check "handler.FILE: standalone/log → 実体パス" 'grep -qx "handler.FILE.fileName=$D/server.log" "$SD/configuration/logging.properties"'
  check "handler.OLD: 前回 LOG_ID → 実体パス" 'grep -qx "handler.OLD.fileName=$D/app.log" "$SD/configuration/logging.properties"'
  check "handler.CUR: mid/current → 実体パス" 'grep -qx "handler.CUR.fileName=$D/cur.log" "$SD/configuration/logging.properties"'
  check "無関係なパスは変更しない" 'grep -qx "handler.OTHER.fileName=/var/log/other.log" "$SD/configuration/logging.properties"'
  rm -rf "$R"

  echo "  [10] 並行起動 8 本 (random) → 全員が別ディレクトリ・自分の実体パスを受け取る (current は 1 本)"
  mkroot
  cp "$SD/configuration-seed/"* "$SD/configuration/"   # 同じ configuration を共有するので skip モードで先に置く
  outs=(); pids=()
  for _ in 1 2 3 4 5 6 7 8; do
    o=$(mktemp /tmp/epo.XXXXXX); outs+=("$o")
    ( env -i PATH="$PATH" HOME=/tmp JBOSS_HOME="$JH" JBOSS_CONF_DIR="$SD/configuration" JBOSS_CONF_SEED_DIR="$SD/configuration-seed" \
        EFS_LOG_DIR="$EFS" COMPONENT_ROLE=back CONFIG_SEED_MODE=skip $SH "$EP" "$JH/bin/standalone.sh" > "$o" 2>&1; echo "RC=$?" >> "$o" ) &
    pids+=($!)
  done
  wait "${pids[@]}"   # メタデータ用の http.server は待たない
  bad=0; dirs=""
  for o in "${outs[@]}"; do
    OUT=$(cat "$o"); d=$(own_dir); dirs="$dirs $d"
    grep -qx "RC=0" "$o" || bad=1
    [ "$(grep -m1 "^ARG\[" "$o")" = "ARG[-Djboss.server.log.dir=$d]" ] || bad=1
    grep -qx "JBOSS_LOG_DIR=$d" "$o" || bad=1
    rm -f "$o"
  done
  check "全 8 本 rc=0 かつ各自の -D / JBOSS_LOG_DIR が自分の LOG_ID" '[ $bad -eq 0 ]'
  check "LOG_ID は 8 個とも異なる" '[ "$(tr " " "\n" <<<"$dirs" | grep -c .)" -eq 8 ] && [ "$(tr " " "\n" <<<"$dirs" | grep . | sort -u | wc -l)" -eq 8 ]'
  check "current はそのうちの 1 つを指す" 'tr " " "\n" <<<"$dirs" | grep -qx "$MID/$(readlink "$MID/current")"'
  rm -rf "$R"

  echo "  [11] standalone/log が別タスクを指していても異常扱いしない (note のみ)"
  mkroot
  mkdir -p "$MID"
  # 自分の ln -sfn の直後に別タスクが current を張り替えた状況を、疑似 CMD 側ではなく
  # 「standalone/log の入口が別ディレクトリを指す」形で再現する
  rm "$SD/log"; mkdir -p "$MID/other-task"; ln -s "$MID/other-task" "$SD/log"
  run_ep -- "$JH/bin/standalone.sh"
  D=$(own_dir)
  check "rc=0 / note 行 / 書き込み確認は自分の実体パス" '[ $RC -eq 0 ] && grep -q "note: .* は別タスクのディレクトリ $MID/other-task を指しています" <<<"$OUT" && grep -q "log -> $D (書き込み可)" <<<"$OUT"'
  rm -rf "$R"

  echo "  [12] standalone/log が dangling → FATAL"
  mkroot
  rm "$SD/log"; ln -s "$R/nowhere/x" "$SD/log"
  run_ep -- "$JH/bin/standalone.sh"
  check "rc=1 / dangling の FATAL" '[ $RC -eq 1 ] && grep -q "の解決に失敗しました (dangling symlink)" <<<"$OUT"'
  rm -rf "$R"

  echo "  [13] EFS 側がシンボリックリンク経由でも実体 (pwd -P) を渡す"
  mkroot
  mkdir -p "$R/real-efs"; rmdir "$R/mnt/logs"; ln -s "$R/real-efs" "$R/mnt/logs"
  run_ep -- "$JH/bin/standalone.sh"
  D=$(own_dir); L=$(basename "$D")
  check "rc=0 / -D は /real-efs/... の物理パス" '[ $RC -eq 0 ] && grep -qx "ARG\[-Djboss.server.log.dir=$R/real-efs/intra-web-front/logs/intra-web/mid/$L\]" <<<"$OUT"'
  rm -rf "$R"

  echo "  [14] CONFIG_SEED_MODE の不正値 / seed 無し / logging.properties 無し → FATAL"
  mkroot
  run_ep CONFIG_SEED_MODE=bogus -- "$JH/bin/standalone.sh"
  check "CONFIG_SEED_MODE=bogus → rc=1" '[ $RC -eq 1 ] && grep -q "CONFIG_SEED_MODE の値が不正です" <<<"$OUT"'
  rm "$SD/configuration-seed/logging.properties"
  run_ep -- "$JH/bin/standalone.sh"
  check "logging.properties 無し → rc=1" '[ $RC -eq 1 ] && grep -q "logging.properties がありません" <<<"$OUT"'
  rm -rf "$SD/configuration-seed"
  run_ep -- "$JH/bin/standalone.sh"
  check "seed 無し → rc=1" '[ $RC -eq 1 ] && grep -q "seed ディレクトリ .* がありません" <<<"$OUT"'
  rm -rf "$R"

  # ---- CMD=eap (本番の起動方式) ----------------------------------------------
  EAP_FIXED="ARG[-b]|ARG[0.0.0.0]|ARG[-bmanagement]|ARG[0.0.0.0]|ARG[-c]|ARG[standalone.xml]|"

  echo "  [15] CMD=eap → 本番と同じ引数で \$JBOSS_HOME/bin/standalone.sh を起動し、コマンド直後に pin"
  mkroot
  run_ep SERVER_CONFIG=standalone.xml EXTRASLB_TRUSTSTORE_PATH=/opt/ts/extra.jks "EXTRASLB_TRUSTSTORE_PASSWORD=pa ss" \
         EXTRASLB_TRUSTSTORE_TYPE=JKS "JBOSS_SERVER_OPTS=-Dx=1  -Dy=a*b" -- eap
  D=$(own_dir)
  check "rc=0 / 起動したのは \$JBOSS_HOME/bin/standalone.sh" '[ $RC -eq 0 ] && grep -qx "SCRIPT=$JH/bin/standalone.sh" <<<"$OUT"'
  check "引数: pin → 本番と同じ並び → JBOSS_SERVER_OPTS を空白で分割" '[ "$(grep "^ARG\[" <<<"$OUT" | tr "\n" "|")" = "ARG[-Djboss.server.log.dir=$D]|${EAP_FIXED}ARG[-Djavax.net.ssl.truststore=/opt/ts/extra.jks]|ARG[-Djavax.net.ssl.trustStorePassword=pa ss]|ARG[-Djavax.net.ssl.trustStoreType=JKS]|ARG[-Dx=1]|ARG[-Dy=a*b]|" ]'
  check "JBOSS_LOG_DIR=<実体パス> / log pin 行" 'grep -qx "JBOSS_LOG_DIR=$D" <<<"$OUT" && grep -q "log pin: JBoss は $D へ直接書き込みます" <<<"$OUT"'
  check "preflight 行は実際の起動行 (パスワードは ****)" 'grep -qF "preflight OK. starting: $JH/bin/standalone.sh -Djboss.server.log.dir=$D -b 0.0.0.0 -bmanagement 0.0.0.0 -c standalone.xml -Djavax.net.ssl.truststore=/opt/ts/extra.jks -Djavax.net.ssl.trustStorePassword=**** -Djavax.net.ssl.trustStoreType=JKS -Dx=1 -Dy=a*b" <<<"$OUT"'
  check "エントリポイント自身の出力にパスワードが出ない" '! grep "^\[efs-entrypoint" <<<"$OUT" | grep -q "pa ss"'
  check "EXTRASLB_TRUSTSTORE_TYPE があれば WARN は出ない" '! grep -q "WARN: EXTRASLB_TRUSTSTORE_TYPE が空です" <<<"$OUT"'
  rm -rf "$R"

  echo "  [15b] CMD=eap・EXTRASLB_* と JBOSS_SERVER_OPTS が未設定 → set -u でも止まらず、本番と同じく空の値で渡す"
  mkroot
  run_ep SERVER_CONFIG=standalone.xml -- eap
  D=$(own_dir)
  check "rc=0 / 引数 (値が空の -D を含む)" '[ $RC -eq 0 ] && [ "$(grep "^ARG\[" <<<"$OUT" | tr "\n" "|")" = "ARG[-Djboss.server.log.dir=$D]|${EAP_FIXED}ARG[-Djavax.net.ssl.truststore=]|ARG[-Djavax.net.ssl.trustStorePassword=]|ARG[-Djavax.net.ssl.trustStoreType=]|" ]'
  check "EXTRASLB_TRUSTSTORE_TYPE が空 → WARN (止めない)" 'grep -q "WARN: EXTRASLB_TRUSTSTORE_TYPE が空です" <<<"$OUT"'
  check "空のパスワードは伏せない (未設定と分かる)" 'grep -qF -- "-Djavax.net.ssl.trustStorePassword= -Djavax.net.ssl.trustStoreType=" <<<"$(grep "preflight OK" <<<"$OUT")"'
  rm -rf "$R"

  echo "  [15c] CMD=eap + JAVA_OPTS に本番と同じ -Djboss.server.log.dir=\${JBOSS_HOME}/standalone/log → pin で上書き"
  mkroot
  run_ep SERVER_CONFIG=standalone.xml "JAVA_OPTS=-Xms64m -Djboss.server.log.dir=$JH/standalone/log" -- eap
  D=$(own_dir)
  check "rc=0 / 1 番目の引数が pin / 起動引数の -Djboss.server.log.dir は 1 つだけ" '[ $RC -eq 0 ] && [ "$(grep -m1 "^ARG\[" <<<"$OUT")" = "ARG[-Djboss.server.log.dir=$D]" ] && [ "$(grep -c "^ARG\[-Djboss.server.log.dir=" <<<"$OUT")" -eq 1 ]'
  check "note (JAVA_OPTS) が出て、明示指定優先の WARN は出ない" 'grep -q "(JAVA_OPTS: $JH/standalone/log) は pin で上書きします" <<<"$OUT" && ! grep -q "pin を適用しません" <<<"$OUT"'
  check "JAVA_OPTS は変えずに渡す / JBOSS_LOG_DIR=<実体パス>" 'grep -qx "JAVA_OPTS=-Xms64m -Djboss.server.log.dir=$JH/standalone/log" <<<"$OUT" && grep -qx "JBOSS_LOG_DIR=$D" <<<"$OUT"'
  rm -rf "$R"

  echo "  [15d] CMD=eap + JBOSS_SERVER_OPTS の -Djboss.server.log.dir: 共有の置き場なら除いて pin、別の場所なら尊重"
  mkroot
  run_ep SERVER_CONFIG=standalone.xml "JBOSS_SERVER_OPTS=-Djboss.server.log.dir=$JH/standalone/log -Dx=1" -- eap
  D=$(own_dir)
  check "共有: -Djboss.server.log.dir は pin の 1 つだけ・-Dx=1 は残る" '[ $RC -eq 0 ] && [ "$(grep -c "^ARG\[-Djboss.server.log.dir=" <<<"$OUT")" -eq 1 ] && [ "$(grep -m1 "^ARG\[" <<<"$OUT")" = "ARG[-Djboss.server.log.dir=$D]" ] && [ "$(grep "^ARG\[" <<<"$OUT" | tail -1)" = "ARG[-Dx=1]" ]'
  mkdir -p "$R/var/jboss-log"
  run_ep SERVER_CONFIG=standalone.xml "JBOSS_SERVER_OPTS=-Djboss.server.log.dir=$R/var/jboss-log" -- eap
  check "別の場所: pin しない (WARN)・指定はそのまま・JBOSS_LOG_DIR 未設定" '[ $RC -eq 0 ] && grep -q "WARN: -Djboss.server.log.dir=$R/var/jboss-log が明示指定されているため pin を適用しません" <<<"$OUT" && [ "$(grep -m1 "^ARG\[" <<<"$OUT")" = "ARG[-b]" ] && [ "$(grep "^ARG\[" <<<"$OUT" | tail -1)" = "ARG[-Djboss.server.log.dir=$R/var/jboss-log]" ] && grep -qx "JBOSS_LOG_DIR=<unset>" <<<"$OUT"'
  rm -rf "$R"

  echo "  [15e] CMD=eap + JBOSS_LOG_PIN=off → pin 無し (本番の修正前と同じ引数)"
  mkroot
  run_ep SERVER_CONFIG=standalone.xml JBOSS_LOG_PIN=off -- eap
  check "rc=0 / WARN / 引数は本番と同じ並びのみ" '[ $RC -eq 0 ] && grep -q "WARN: JBOSS_LOG_PIN=off" <<<"$OUT" && [ "$(grep "^ARG\[" <<<"$OUT" | tr "\n" "|")" = "${EAP_FIXED}ARG[-Djavax.net.ssl.truststore=]|ARG[-Djavax.net.ssl.trustStorePassword=]|ARG[-Djavax.net.ssl.trustStoreType=]|" ]'
  rm -rf "$R"

  echo "  [15f] CMD=eap で SERVER_CONFIG 未設定 → FATAL。current・mid・configuration を触らない"
  mkroot
  mkdir -p "$MID/prev-task"; ln -s prev-task "$MID/current"
  run_ep -- eap
  check "rc=1 / FATAL / current は prev-task のまま・新ディレクトリ無し・configuration 未復元" '[ $RC -eq 1 ] && grep -q "FATAL: CMD=eap ですが SERVER_CONFIG" <<<"$OUT" && [ "$(readlink "$MID/current")" = prev-task ] && [ "$(ls "$MID" | wc -l)" -eq 2 ] && [ ! -f "$SD/configuration/standalone.xml" ]'
  rm -rf "$R"

  echo "  [15g] CMD=eap: SERVER_CONFIG のファイルの有無を確認 / standalone.sh が無ければ FATAL"
  mkroot
  run_ep SERVER_CONFIG=standalone-full.xml -- eap
  check "seed に無い → rc=1" '[ $RC -eq 1 ] && grep -q "standalone-full.xml がありません" <<<"$OUT"'
  cp "$SD/configuration-seed/standalone.xml" "$SD/configuration-seed/standalone-full.xml"
  run_ep SERVER_CONFIG=standalone-full.xml -- eap
  check "seed にある → rc=0 / -c standalone-full.xml" '[ $RC -eq 0 ] && grep -A1 -x "ARG\[-c\]" <<<"$OUT" | grep -qx "ARG\[standalone-full.xml\]"'
  rm "$JH/bin/standalone.sh"
  run_ep SERVER_CONFIG=standalone.xml -- eap
  check "standalone.sh 無し → rc=1" '[ $RC -eq 1 ] && grep -q "bin/standalone.sh がありません" <<<"$OUT"'
  rm -rf "$R"

  echo "  [15i] 起動コマンドが空 (entryPoint だけ上書きして command を付け忘れた) → FATAL。current を触らない"
  mkroot
  mkdir -p "$MID/prev-task"; ln -s prev-task "$MID/current"
  run_ep SERVER_CONFIG=standalone.xml --
  check "rc=1 / FATAL / current は prev-task のまま・新ディレクトリ無し" '[ $RC -eq 1 ] && grep -q "FATAL: 起動コマンド (CMD) がありません" <<<"$OUT" && [ "$(readlink "$MID/current")" = prev-task ] && [ "$(ls "$MID" | wc -l)" -eq 2 ]'
  rm -rf "$R"

  echo "  [15h] CMD=eap の後ろの引数は使わない (本番と同じ。WARN は伏せ字付き)"
  mkroot
  run_ep SERVER_CONFIG=standalone.xml -- eap --debug -Dfoo.password=zzz
  check "rc=0 / WARN / 引数に含まれない" '[ $RC -eq 0 ] && grep -qF "WARN: CMD=eap の後ろの引数は使いません (本番と同じ): --debug -Dfoo.password=****" <<<"$OUT" && ! grep -q "^ARG\[--debug\]" <<<"$OUT" && ! grep -q "zzz" <<<"$OUT"'
  rm -rf "$R"
done

echo "================ RESULT: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (shells: ${SHELLS[*]})"
[ "$FAIL" -eq 0 ]
