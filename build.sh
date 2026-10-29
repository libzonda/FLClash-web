#!/usr/bin/env bash
set -euo pipefail

export PATH="${PATH}:/usr/local/go/bin:${HOME}/go/bin:${HOME}/lib/flutter/flutter/bin:${HOME}/flutter/bin:/opt/flutter/bin:/usr/local/flutter/bin:${HOME}/fvm/default/bin:${HOME}/.local/bin:/snap/bin"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLCLASH_DIR="${ROOT_DIR}/FlClash"
DIST_DIR="${ROOT_DIR}/dist"
SQLITE3_WASM_VERSION="${SQLITE3_WASM_VERSION:-3.7.0}"
SQLITE3_WASM_URL="https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-${SQLITE3_WASM_VERSION}/sqlite3.wasm"

echo "========================================================"
echo "  Building FlClash-web (Native Flutter Web + Go Core)"
echo "========================================================"

# Ensure Clash.Meta submodule is initialized if building from git
if [ ! -f "${FLCLASH_DIR}/core/Clash.Meta/go.mod" ]; then
  echo "[1/5] Initializing Clash.Meta submodule (shallow fetch)..."
  SUBMODULE_COMMIT="$(git -C "${FLCLASH_DIR}" ls-tree HEAD core/Clash.Meta | awk '{print $3}')"
  rm -rf "${FLCLASH_DIR}/core/Clash.Meta" "${FLCLASH_DIR}/.git/modules/core/Clash.Meta"
  mkdir -p "${FLCLASH_DIR}/core/Clash.Meta"
  git -C "${FLCLASH_DIR}/core/Clash.Meta" init
  git -C "${FLCLASH_DIR}/core/Clash.Meta" remote add origin https://github.com/chen08209/Clash.Meta.git
  git -C "${FLCLASH_DIR}/core/Clash.Meta" fetch --depth 1 origin "${SUBMODULE_COMMIT:-Alpha}"
  git -C "${FLCLASH_DIR}/core/Clash.Meta" checkout FETCH_HEAD
fi

# Ensure sqlite3.wasm for Drift Web SQLite support
mkdir -p "${ROOT_DIR}/overlay/web"
if [ ! -f "${ROOT_DIR}/overlay/web/sqlite3.wasm" ]; then
  echo "[2/5] Downloading sqlite3.wasm (v${SQLITE3_WASM_VERSION})..."
  curl -fsSL "${SQLITE3_WASM_URL}" -o "${ROOT_DIR}/overlay/web/sqlite3.wasm"
fi

# Apply non-destructive Web adaptation patches and ensure revert on exit
cleanup() {
  echo "[cleanup] Reverting build-time Web patches on upstream files..."
  python3 "${ROOT_DIR}/scripts/prepare_web.py" --revert || true
}
trap cleanup EXIT

echo "[3/5] Applying FlClash-web build-time adaptation..."
python3 "${ROOT_DIR}/scripts/prepare_web.py" --apply

echo "[4/5] Running flutter build web --release..."
pushd "${FLCLASH_DIR}" >/dev/null
flutter pub get
flutter build web --release --no-tree-shake-icons --dart-define=APP_ENV=stable
popd >/dev/null

# Copy compiled Flutter Web output into Go embed directory
WEB_DIST_DIR="${FLCLASH_DIR}/core/cmd/flclash-web/web_dist"
rm -rf "${WEB_DIST_DIR}"
mkdir -p "${WEB_DIST_DIR}"
cp -r "${FLCLASH_DIR}/build/web/." "${WEB_DIST_DIR}/"

echo "[5/5] Compiling standalone FlClash-web binary..."
mkdir -p "${DIST_DIR}"
TAGS="$(sed -n 's/^tags: *//p' "${FLCLASH_DIR}/build_config.yaml" || echo "with_gvisor")"
TARGET_OS="${GOOS:-linux}"
TARGET_ARCH="${GOARCH:-$(go env GOARCH)}"
OUTPUT_BIN="${DIST_DIR}/FlClash-web-${TARGET_OS}-${TARGET_ARCH}"

pushd "${FLCLASH_DIR}/core" >/dev/null
CGO_ENABLED=0 GOOS="${TARGET_OS}" GOARCH="${TARGET_ARCH}" \
  go build -trimpath -tags "${TAGS}" -ldflags "-w -s" \
  -o "${OUTPUT_BIN}" ./cmd/flclash-web
popd >/dev/null

cp -f "${OUTPUT_BIN}" "${DIST_DIR}/FlClash-web"
chmod +x "${OUTPUT_BIN}" "${DIST_DIR}/FlClash-web"

echo "========================================================"
echo "  Build complete!"
echo "  Standalone binary: ${DIST_DIR}/FlClash-web"
echo "  Run locally:       ${DIST_DIR}/FlClash-web --listen 0.0.0.0:9090"
echo "========================================================"

