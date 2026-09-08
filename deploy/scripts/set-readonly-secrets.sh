#!/bin/bash
# Generates the vibe_readonly password and the exporter DSN together, and stores
# both in the local agix broker. One password, two names, so they cannot drift.
#
# Usage: deploy/scripts/set-readonly-secrets.sh [--force] [--sync]
#   --force  overwrite names agix already holds (rotation)
#   --sync   after storing, ship them to the VPS with sync-env.sh
#
# Prints names only; the values go down a pipe and never reach argv or output.
# The role on an already-initialised cluster is created by ensure-readonly-role.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PW_NAME=VIBE_READONLY_DB_PASSWORD
DSN_NAME=POSTGRES_EXPORTER_DATA_SOURCE_NAME
DB="${READONLY_DB:-vibe_core}"

FORCE=0; SYNC=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --sync)  SYNC=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "set-readonly-secrets: unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

command -v agix >/dev/null || { echo "set-readonly-secrets: agix not on PATH" >&2; exit 1; }
command -v openssl >/dev/null || { echo "set-readonly-secrets: openssl not on PATH" >&2; exit 1; }

held="$(agix secret list 2>/dev/null | awk '{print $1}')"
is_held() { printf '%s\n' "$held" | grep -qx "$1"; }

if [ "$FORCE" -eq 0 ] && { is_held "$PW_NAME" || is_held "$DSN_NAME"; }; then
  echo "set-readonly-secrets: agix already holds one of ${PW_NAME} / ${DSN_NAME}."
  echo "  Rotating both is safe only alongside ensure-readonly-role.sh — re-run with --force."
  exit 1
fi

# No / + = so the password drops into a DSN without percent-encoding.
pw="$(openssl rand -base64 48 | tr -d '\n/+=' | cut -c1-24)"
[ "${#pw}" -eq 24 ] || { echo "set-readonly-secrets: could not generate a password" >&2; exit 1; }
dsn="postgresql://vibe_readonly:${pw}@postgres:5432/${DB}?sslmode=disable"

printf '%s' "$pw"  | agix secret set "$PW_NAME"
printf '%s' "$dsn" | agix secret set "$DSN_NAME"
unset pw dsn

echo "stored ${PW_NAME} and ${DSN_NAME} in the local agix broker"

if [ "$SYNC" -eq 1 ]; then
  "${REPO_ROOT}/deploy/scripts/sync-env.sh" postgres.env postgres-exporter.env
  echo "shipped postgres.env and postgres-exporter.env to the VPS"
else
  echo "next: deploy/scripts/set-readonly-secrets.sh --sync, or let the deploy ship them"
fi
