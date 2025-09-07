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
hugo --gc --minify -b "${BASE_URL}"

