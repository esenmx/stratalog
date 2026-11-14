#!/usr/bin/env bash
# E2E oracle: a real Dart VM running example/strata_demo.dart, verified via
# `strata --once --json`, `.jsonl` replay filtering, and live `strata --plain`.
# Proves history snapshot, unelided payloads, error fields, live stream, dedup,
# and clean SIGINT shutdown without non-portable GNU coreutils.
set -euo pipefail
cd "$(dirname "$0")"

tmp=$(mktemp -d)
demo=""
viewer=""
cleanup() {
  if [ -n "$viewer" ]; then
    kill "$viewer" 2>/dev/null || true
    wait "$viewer" 2>/dev/null || true
  fi
  if [ -n "$demo" ]; then
    kill "$demo" 2>/dev/null || true
    wait "$demo" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "e2e: FAIL: $*" >&2
  echo "--- strata live output ---" >&2
  cat "$tmp/out.txt" >&2 2>/dev/null || true
  echo "--- strata snapshot output ---" >&2
  cat "$tmp/boot.jsonl" >&2 2>/dev/null || true
  echo "--- demo output ---" >&2
  cat "$tmp/demo.log" >&2 2>/dev/null || true
  exit 1
}

go build -o "$tmp/strata" .

(cd ../../packages/stratalog &&
  exec dart run --enable-vm-service=0 --write-service-info="$tmp/info.json" \
    example/strata_demo.dart >"$tmp/demo.log" 2>&1) &
demo=$!

# Attach only once the boot records are logged: they then prove history.
for _ in $(seq 100); do
  [ -s "$tmp/info.json" ] && grep -q 'strata-demo: booted' "$tmp/demo.log" && break
  kill -0 "$demo" 2>/dev/null || fail "demo exited before booting"
  sleep 0.2
done
[ -s "$tmp/info.json" ] || fail "no service info after 20 s"
grep -q 'strata-demo: booted' "$tmp/demo.log" || fail "demo did not boot in 20 s"

# 1. One-shot JSON snapshot (with flags after target) + .jsonl filtered replay.
"$tmp/strata" "$tmp/info.json" --once --json >"$tmp/boot.jsonl"
grep -q '"message":"demo boot"' "$tmp/boot.jsonl" || fail "snapshot missing 'demo boot'"
grep -qF '"name":"Jane"' "$tmp/boot.jsonl" || fail "snapshot missing payload"
grep -q 'stale entry' "$tmp/boot.jsonl" || fail "snapshot missing error field"

"$tmp/strata" "$tmp/boot.jsonl" --plain -l info >"$tmp/replay.txt"
grep -q 'demo boot' "$tmp/replay.txt" || fail "replay missing 'demo boot'"
grep -q '✗ Bad state: stale entry' "$tmp/replay.txt" || fail "replay missing inline error"
if grep -q 'demo state' "$tmp/replay.txt"; then
  fail "trace record 'demo state' leaked past -l info"
fi

# 2. Live streaming + history merge + dedup + clean SIGINT exit.
"$tmp/strata" --plain "$tmp/info.json" >"$tmp/out.txt" &
viewer=$!

for _ in $(seq 75); do
  grep -qE '\] live 3$' "$tmp/out.txt" 2>/dev/null && break
  kill -0 "$viewer" 2>/dev/null || fail "strata exited early before 'live 3'"
  sleep 0.2
done
grep -qE '\] live 3$' "$tmp/out.txt" || fail "live record 'live 3' missing after 15 s"

kill -INT "$viewer"
wait "$viewer" || fail "strata exited non-zero on SIGINT"
viewer=""

grep -q 'demo boot' "$tmp/out.txt" || fail "history record 'demo boot' missing"
grep -qF '"name":"Jane"' "$tmp/out.txt" || fail "payload '\"name\":\"Jane\"' missing"
grep -q '✗ Bad state: stale entry' "$tmp/out.txt" || fail "inline error missing in live plain output"
boots=$(grep -c 'demo boot' "$tmp/out.txt")
[ "$boots" -eq 1 ] || fail "'demo boot' appears $boots times, want 1"

echo "e2e: OK ($(wc -l <"$tmp/out.txt" | tr -d ' ') live+history records, $(wc -l <"$tmp/boot.jsonl" | tr -d ' ') snapshot records)"
