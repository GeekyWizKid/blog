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

# Ensure Hugo Modules are resolved. If 'go' is missing (e.g. on Vercel),
# install a minimal Go toolchain into /tmp and add to PATH.
if ! command -v go >/dev/null 2>&1; then
  echo "'go' not found; attempting lightweight install for build..."
  GO_VER=${GO_VERSION:-1.22}
  case "$GO_VER" in
    *.*.*) ;;                          # already has patch
    *.*) GO_VER="${GO_VER}.0" ;;      # expand to x.y.0
    *) GO_VER="1.22.0" ;;              # sane default
  esac
  GO_OS=linux
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64) GO_ARCH=amd64 ;;
    aarch64|arm64) GO_ARCH=arm64 ;;
    *) echo "Unsupported arch: $ARCH"; exit 1 ;;
  esac
  GO_URL="https://go.dev/dl/go${GO_VER}.${GO_OS}-${GO_ARCH}.tar.gz"
  echo "Downloading Go ${GO_VER} from ${GO_URL}"
  curl -fsSL "$GO_URL" -o /tmp/go.tgz
  tar -C /tmp -xzf /tmp/go.tgz
  export PATH="/tmp/go/bin:${PATH}"
  export GOCACHE="/tmp/gocache"
  go version || { echo "Failed to bootstrap Go"; exit 1; }
fi

echo "Resolving Hugo modules..."
HUGO_MODULE_PROXY=${HUGO_MODULE_PROXY:-https://proxy.golang.org} \
  hugo mod get -u
hugo mod tidy || true

hugo --gc --minify -b "${BASE_URL}"
