#!/usr/bin/env bash
# batch.sh <lead_sec> "<scn> <image> <label> [docker-run-args...]" ["..."]...
# 共通の「数分後の 0 時」を持つタイムゾーンを計算し、複数シナリオを並行実行する。
set -u
cd "$(dirname "$0")" || exit 1
LEAD=$1; shift
NOW=$(date +%s); T=$((NOW + LEAD))
OFF=$(( (86400 - T % 86400) % 86400 )); OFF=$(( OFF / 60 * 60 ))
[ "$OFF" -gt 43200 ] && OFF=$((OFF - 86400))
MID=$(( ( (NOW + OFF) / 86400 + 1 ) * 86400 - OFF ))
A=${OFF#-}; SIGN=+; [ "$OFF" -lt 0 ] && SIGN=-
TZID=$(printf 'GMT%s%02d:%02d' "$SIGN" $((A / 3600)) $(((A % 3600) / 60)))
echo "batch: tz=$TZID offset=$OFF midnight-in=$((MID - NOW))s local-now=$(date -u -d "@$((NOW + OFF))" '+%F %T')"
pids=()
for spec in "$@"; do
  # shellcheck disable=SC2086
  set -- $spec
  scn=$1; img=$2; label=$3; shift 3
  ./scenario.sh "$scn" "$img" "$label" "$MID" "$TZID" "$OFF" "$@" &
  pids+=($!)
  echo "  started $scn $img $label (pid $!)"
done
wait "${pids[@]}"
echo "batch done"
