#!/usr/bin/env bash
set -euo pipefail

# Decide baseURL for Hugo on Vercel.
# - Preview:  https://$VERCEL_URL/
# - Production: use PROD_BASE_URL if set, otherwise fall back to https://$VERCEL_URL/

VERCEL_ENV=${VERCEL_ENV:-}
VERCEL_URL=${VERCEL_URL:-localhost:3000}

if [[ "${VERCEL_ENV}" == "production" && -n "${PROD_BASE_URL:-}" ]]; then
  BASE_URL="${PROD_BASE_URL%/}/"
else
  BASE_URL="https://${VERCEL_URL%/}/"
fi

echo "Building with baseURL=${BASE_URL} (env=${VERCEL_ENV:-local})"

# Ensure Hugo Modules are resolved (requires Go in PATH)
if command -v go >/dev/null 2>&1; then
  echo "Resolving Hugo modules..."
  hugo mod get -u
  hugo mod tidy || true
else
  echo "[warn] 'go' not found; skipping 'hugo mod' step."
  echo "       Ensure Go is available in CI when using Hugo Modules."
fi

hugo --gc --minify -b "${BASE_URL}"
