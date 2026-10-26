#!/usr/bin/env bash
# Decides whether the TestFlight lane has what it needs. Reads the secrets from the environment and
# never prints their values. Exit 0 always; writes ready=true|false to $GITHUB_OUTPUT when it is set.
set -u
required=(ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8 APPLE_TEAM_ID)
missing=()
for name in "${required[@]}"; do
  [ -n "${!name:-}" ] || missing+=("$name")
done
if [ ${#missing[@]} -eq 0 ]; then
  echo "All TestFlight secrets are present."
  ready=true
else
  echo "TestFlight upload skipped. Missing secrets: ${missing[*]}"
  echo "One-time setup: docs/SIGNING.md"
  echo "::notice title=TestFlight skipped::Missing secrets: ${missing[*]}"
  ready=false
fi
[ -z "${GITHUB_OUTPUT:-}" ] || echo "ready=$ready" >> "$GITHUB_OUTPUT"
