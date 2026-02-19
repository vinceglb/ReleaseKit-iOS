#!/usr/bin/env bash
set -euo pipefail

REPO="vinceglb/releasekit-ios"
INSTALL_DIR="${HOME}/.local/bin"
VERSION="${RELEASEKIT_IOS_VERSION:-latest}"

if [[ $# -gt 0 ]]; then
  case "$1" in
    --version)
      VERSION="${2:-latest}"
      shift 2
      ;;
    -h|--help)
      cat <<USAGE
Usage: install-releasekit-ios.sh [--version <latest|vX.Y[.Z][-suffix]>]

Environment variables:
  RELEASEKIT_IOS_VERSION   Version tag to install (default: latest)
USAGE
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
fi

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing dependency: ${cmd}" >&2
    exit 1
  }
}

resolve_asset_name() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  if [[ "${os}" != "Darwin" ]]; then
    echo "releasekit-ios installer currently supports macOS only (detected ${os})" >&2
    exit 1
  fi

  case "${arch}" in
    arm64)
      echo "releasekit-ios-darwin-arm64.tar.gz"
      ;;
    x86_64|amd64)
      echo "releasekit-ios-darwin-amd64.tar.gz"
      ;;
    *)
      echo "Unsupported macOS architecture: ${arch}" >&2
      exit 1
      ;;
  esac
}

resolve_latest_stable_tag() {
  local release_json tag
  release_json="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")"

  if command -v jq >/dev/null 2>&1; then
    tag="$(printf '%s' "${release_json}" | jq -r '.tag_name // empty')"
  else
    tag="$(printf '%s' "${release_json}" | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1)"
  fi

  if [[ -z "${tag}" ]]; then
    echo "Could not resolve latest stable tag from GitHub releases." >&2
    echo "Create a release with tag like v0.1.0 first." >&2
    exit 1
  fi

  if [[ ! "${tag}" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?([-.][0-9A-Za-z.]+)?$ ]]; then
    echo "Latest release tag must match vX.Y or vX.Y.Z (optional suffix)." >&2
    echo "Got: ${tag}" >&2
    exit 1
  fi

  printf '%s\n' "${tag}"
}

require_cmd curl
require_cmd tar

ASSET_NAME="$(resolve_asset_name)"

if [[ "${VERSION}" == "latest" ]]; then
  RESOLVED_TAG="$(resolve_latest_stable_tag)"
else
  RESOLVED_TAG="${VERSION}"
fi

if [[ ! "${RESOLVED_TAG}" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?([-.][0-9A-Za-z.]+)?$ ]]; then
  echo "Invalid CLI version tag: ${RESOLVED_TAG}" >&2
  echo "Expected format: vX.Y or vX.Y.Z (optional suffix)" >&2
  exit 1
fi

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${RESOLVED_TAG}/${ASSET_NAME}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ARCHIVE_PATH="${TMP_DIR}/${ASSET_NAME}"

if ! curl -fsSL "${DOWNLOAD_URL}" -o "${ARCHIVE_PATH}"; then
  echo "Failed to download ${ASSET_NAME} for ${RESOLVED_TAG}" >&2
  echo "URL: ${DOWNLOAD_URL}" >&2
  exit 1
fi

mkdir -p "${TMP_DIR}/extract"
tar -xzf "${ARCHIVE_PATH}" -C "${TMP_DIR}/extract"

BIN_PATH="${TMP_DIR}/extract/releasekit-ios"
if [[ ! -f "${BIN_PATH}" ]]; then
  echo "Downloaded archive does not contain 'releasekit-ios' binary" >&2
  exit 1
fi

mkdir -p "${INSTALL_DIR}"
install -m 0755 "${BIN_PATH}" "${INSTALL_DIR}/releasekit-ios"

echo "Installed releasekit-ios ${RESOLVED_TAG} to ${INSTALL_DIR}/releasekit-ios"

case ":${PATH}:" in
  *":${INSTALL_DIR}:"*)
    echo "Run: releasekit-ios wizard"
    ;;
  *)
    echo "${INSTALL_DIR} is not in PATH. Add this line to your shell profile:"
    echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
    echo "Then run: releasekit-ios wizard"
    ;;
esac
