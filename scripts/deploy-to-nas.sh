#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   NAS_HOST=192.168.1.10 NAS_USER=youruser NAS_DIR=/volume1/web/blog \
#   NAS_PORT=22 ./scripts/deploy-to-nas.sh

NAS_HOST=${NAS_HOST:-}
NAS_USER=${NAS_USER:-}
NAS_DIR=${NAS_DIR:-}
NAS_PORT=${NAS_PORT:-22}

if [[ -z "$NAS_HOST" || -z "$NAS_USER" || -z "$NAS_DIR" ]]; then
  echo "Please set NAS_HOST, NAS_USER, NAS_DIR (and optional NAS_PORT)." >&2
  exit 1
fi

echo "Building site with Hugo..."
hugo --minify

echo "Deploying to ${NAS_USER}@${NAS_HOST}:${NAS_DIR} via rsync (port ${NAS_PORT})..."
rsync -avz --delete -e "ssh -p ${NAS_PORT}" public/ "${NAS_USER}@${NAS_HOST}:${NAS_DIR}"

echo "Done."

