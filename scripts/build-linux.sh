#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME="imsg"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT}/dist}"
BUILD_MODE=${BUILD_MODE:-release}
DIST_DIR="$(mktemp -d "/tmp/${APP_NAME}-linux.XXXXXX")"

cleanup() {
  rm -rf "$DIST_DIR"
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "scripts/build-linux.sh must run on Linux." >&2
  exit 1
fi

TARGET_TRIPLE=$(swift -print-target-info | python3 -c 'import json,sys; print(json.load(sys.stdin)["target"]["triple"])')
TARGET_ARCH="${TARGET_TRIPLE%%-*}"
BUILD_DIR="${ROOT}/.build/${TARGET_TRIPLE}/${BUILD_MODE}"
ARCHIVE_NAME="${APP_NAME}-linux-${TARGET_ARCH}.tar.gz"

swift build -c "$BUILD_MODE" --product "$APP_NAME" --static-swift-stdlib

cp "${BUILD_DIR}/${APP_NAME}" "${DIST_DIR}/${APP_NAME}"
for bundle in "${BUILD_DIR}"/*.bundle; do
  if [[ -e "$bundle" ]]; then
    cp -R "$bundle" "$DIST_DIR/"
  fi
done

mkdir -p "$OUTPUT_DIR"
tar -C "$DIST_DIR" -czf "${OUTPUT_DIR}/${ARCHIVE_NAME}" .

echo "Built ${OUTPUT_DIR}/${ARCHIVE_NAME}"
