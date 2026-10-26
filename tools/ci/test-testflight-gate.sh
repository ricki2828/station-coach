#!/usr/bin/env bash
# Checks tools/ci/testflight-gate.sh: no secrets -> names all four and ready=false; all set -> ready=true.
set -eu
gate="$(dirname "$0")/testflight-gate.sh"
out=$(mktemp)
log=$(env -i GITHUB_OUTPUT="$out" bash "$gate")
echo "$log"
for n in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8 APPLE_TEAM_ID; do
  echo "$log" | grep -q "Missing secrets:.*$n" || { echo "FAIL: $n not named"; exit 1; }
done
grep -qx "ready=false" "$out" || { echo "FAIL: expected ready=false"; exit 1; }
: > "$out"
log=$(env -i GITHUB_OUTPUT="$out" ASC_KEY_ID=k ASC_ISSUER_ID=i ASC_KEY_P8=p APPLE_TEAM_ID=t bash "$gate")
grep -qx "ready=true" "$out" || { echo "FAIL: expected ready=true"; exit 1; }
echo "$log" | grep -q "=k\|=p" && { echo "FAIL: leaked a value"; exit 1; }
echo "gate ok"
