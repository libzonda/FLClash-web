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

# Resolve and checkout latest upstream FlClash release tag
FLCLASH_TAG="${FLCLASH_TAG:-latest}"
if [ -d "${FLCLASH_DIR}/.git" ]; then
  echo "[1/6] Resolving upstream FlClash release tag (FLCLASH_TAG=${FLCLASH_TAG})..."
  git -C "${FLCLASH_DIR}" fetch --tags origin 2>/dev/null || true
  if [ "${FLCLASH_TAG}" = "latest" ]; then
    RESOLVED_TAG="$(git -C "${FLCLASH_DIR}" tag -l "v*" --sort="version:refname" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | tail -n 1)"
    if [ -z "${RESOLVED_TAG}" ]; then
      RESOLVED_TAG="$(git -C "${FLCLASH_DIR}" tag -l "v*" --sort="version:refname" | tail -n 1)"
    fi
  else
    RESOLVED_TAG="${FLCLASH_TAG}"
    # Automatically add 'v' prefix if user input "0.9.3" instead of "v0.9.3"
    if [[ "${RESOLVED_TAG}" =~ ^[0-9] ]]; then
      RESOLVED_TAG="v${RESOLVED_TAG}"
    fi
  fi

  if [ -n "${RESOLVED_TAG}" ]; then
    # Ensure the target tag/commit is fetched from upstream if not already present
    if ! git -C "${FLCLASH_DIR}" rev-parse --verify "${RESOLVED_TAG}^{commit}" >/dev/null 2>&1; then
      echo "      Fetching tag ${RESOLVED_TAG} from upstream..."
      git -C "${FLCLASH_DIR}" fetch origin "refs/tags/${RESOLVED_TAG}:refs/tags/${RESOLVED_TAG}" 2>/dev/null || \
      git -C "${FLCLASH_DIR}" fetch --depth=1 origin "${RESOLVED_TAG}" 2>/dev/null || true
    fi
    echo "      Targeting FlClash tag: ${RESOLVED_TAG}"
    git -C "${FLCLASH_DIR}" checkout -q "${RESOLVED_TAG}"
  fi
fi

RAW_VERSION="$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' "${FLCLASH_DIR}/pubspec.yaml" | head -n 1)"
VERSION="${RAW_VERSION:-0.9.2}"
echo "      FlClash version: ${VERSION}"

# Ensure Clash.Meta submodule is initialized if building from git
SUBMODULE_COMMIT="$(git -C "${FLCLASH_DIR}" ls-tree HEAD core/Clash.Meta 2>/dev/null | awk '{print $3}' || true)"
CURRENT_META_HEAD="$(git -C "${FLCLASH_DIR}/core/Clash.Meta" rev-parse HEAD 2>/dev/null || true)"
if [ ! -f "${FLCLASH_DIR}/core/Clash.Meta/go.mod" ] || [ -n "${SUBMODULE_COMMIT}" -a "${CURRENT_META_HEAD}" != "${SUBMODULE_COMMIT}" ]; then
  echo "[2/6] Syncing Clash.Meta submodule (${SUBMODULE_COMMIT:-Alpha})..."
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
  echo "[3/6] Downloading sqlite3.wasm (v${SQLITE3_WASM_VERSION})..."
  curl -fsSL "${SQLITE3_WASM_URL}" -o "${ROOT_DIR}/overlay/web/sqlite3.wasm"
fi

# Apply non-destructive Web adaptation patches and ensure revert on exit
cleanup() {
  echo "[cleanup] Reverting build-time Web patches on upstream files..."
  python3 "${ROOT_DIR}/scripts/prepare_web.py" --revert || true
}
trap cleanup EXIT

echo "[4/6] Applying FlClash-web build-time adaptation..."
python3 "${ROOT_DIR}/scripts/prepare_web.py" --apply

echo "[5/6] Running flutter build web --release (version: ${VERSION})..."
pushd "${FLCLASH_DIR}" >/dev/null
flutter pub get
flutter build web --release --no-tree-shake-icons --dart-define=APP_ENV=stable --build-name="${VERSION}"
popd >/dev/null

# Copy compiled Flutter Web output into Go embed directory
WEB_DIST_DIR="${FLCLASH_DIR}/core/cmd/flclash-web/web_dist"
rm -rf "${WEB_DIST_DIR}"
mkdir -p "${WEB_DIST_DIR}"
cp -r "${FLCLASH_DIR}/build/web/." "${WEB_DIST_DIR}/"

echo "[6/6] Compiling standalone FlClash-web binary..."
mkdir -p "${DIST_DIR}"
TAGS="$(sed -n 's/^tags: *//p' "${FLCLASH_DIR}/build_config.yaml" || echo "with_gvisor")"
TARGET_OS="${GOOS:-linux}"
BUILD_ARCHS="${BUILD_ARCHS:-${GOARCH:-$(go env GOARCH)}}"

pushd "${FLCLASH_DIR}/core" >/dev/null
for ARCH in ${BUILD_ARCHS}; do
  echo "      Compiling binary for ${TARGET_OS}/${ARCH}..."
  OUTPUT_BIN="${DIST_DIR}/FlClash-web-${TARGET_OS}-${ARCH}"
  VERSIONED_BIN="${DIST_DIR}/FlClash-web-${VERSION}-${TARGET_OS}-${ARCH}"

  CGO_ENABLED=0 GOOS="${TARGET_OS}" GOARCH="${ARCH}" \
    go build -trimpath -tags "${TAGS}" -ldflags "-w -s -X main.Version=${VERSION}" \
    -o "${OUTPUT_BIN}" ./cmd/flclash-web

  cp -f "${OUTPUT_BIN}" "${VERSIONED_BIN}"
  chmod +x "${OUTPUT_BIN}" "${VERSIONED_BIN}"

  # Package tar.gz release bundle
  tar -czf "${DIST_DIR}/FlClash-web-${VERSION}-${TARGET_OS}-${ARCH}.tar.gz" \
    -C "${DIST_DIR}" "FlClash-web-${VERSION}-${TARGET_OS}-${ARCH}"
done
popd >/dev/null

# Default executable for local host architecture
HOST_ARCH="$(go env GOARCH)"
if [ -f "${DIST_DIR}/FlClash-web-${TARGET_OS}-${HOST_ARCH}" ]; then
  cp -f "${DIST_DIR}/FlClash-web-${TARGET_OS}-${HOST_ARCH}" "${DIST_DIR}/FlClash-web"
  chmod +x "${DIST_DIR}/FlClash-web"
fi

# Generate SHA256 checksums
pushd "${DIST_DIR}" >/dev/null
sha256sum FlClash-web-${VERSION}-* > "FlClash-web-${VERSION}-checksums.txt" 2>/dev/null || true
popd >/dev/null

echo "========================================================"
echo "  Build complete!"
echo "  Standalone binary: ${DIST_DIR}/FlClash-web"
echo "  Run locally:       ${DIST_DIR}/FlClash-web --listen 0.0.0.0:9090"
echo "========================================================"

