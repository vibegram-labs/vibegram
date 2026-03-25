#!/bin/bash

set -euo pipefail

# Ensure we are in the script directory
cd "$(dirname "$0")"

echo "Installing dependencies..."
mix deps.get

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"

if [[ -z "${DATABASE_URL:-}" ]] && command -v pg_isready >/dev/null 2>&1; then
  if ! pg_isready -h "$DB_HOST" -p "$DB_PORT" >/dev/null 2>&1; then
    echo "Postgres is not reachable at ${DB_HOST}:${DB_PORT}."
    echo "Start Postgres locally or set DATABASE_URL / DB_HOST / DB_PORT before running setup."
    exit 1
  fi
fi

echo "Setting up database..."
mix ecto.setup

echo "Setup complete. Run 'mix phx.server' to start the server."
