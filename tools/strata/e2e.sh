#!/usr/bin/env bash
# E2E oracle: a real Dart VM running example/strata_demo.dart, read by
# `strata --plain`. Proves history, full payloads, live records and dedup.
set -euo pipefail
cd "$(dirname "$0")"

tmp=$(mktemp -d)
demo=""
cleanup() {
  if [ -n "$demo" ]; then kill "$demo" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "e2e: FAIL: $*" >&2
  echo "--- strata output ---" >&2
  cat "$tmp/out.txt" >&2 2>/dev/null || true
  echo "--- demo output ---" >&2
  cat "$tmp/demo.log" >&2 2>/dev/null || true
  exit 1
}

# Build first so the demo's 11 s aren't spent compiling.
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

timeout 15 "$tmp/strata" --plain "$tmp/info.json" >"$tmp/out.txt" || true

grep -q 'demo boot' "$tmp/out.txt" || fail "history record 'demo boot' missing"
grep -qF '"name":"Jane"' "$tmp/out.txt" || fail "payload '\"name\":\"Jane\"' missing"
grep -qE '\] live 3$' "$tmp/out.txt" || fail "live record 'live 3' missing"
boots=$(grep -c 'demo boot' "$tmp/out.txt")
[ "$boots" -eq 1 ] || fail "'demo boot' appears $boots times, want 1"

echo "e2e: OK ($(wc -l <"$tmp/out.txt" | tr -d ' ') records)"
