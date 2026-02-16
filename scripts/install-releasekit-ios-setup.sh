#!/usr/bin/env bash
set -euo pipefail

REPO="vinceglb/releasekit-ios"
INSTALL_DIR="${HOME}/.local/bin"
VERSION="${RELEASEKIT_IOS_SETUP_VERSION:-latest}"
ASSET_NAME="releasekit-ios-setup.sh"
CHECKSUM_NAME="releasekit-ios-setup.sh.sha256"

if [[ $# -gt 0 ]]; then
  case "$1" in
    --version)
      VERSION="${2:-latest}"
      shift 2
      ;;
    -h|--help)
      cat <<USAGE
Usage: install-releasekit-ios-setup.sh [--version <latest|tag>]

Environment variables:
  RELEASEKIT_IOS_SETUP_VERSION   Version tag to install (default: latest)
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

sha256_cmd() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "No SHA-256 tool found (need shasum or sha256sum)" >&2
    exit 1
  fi
}

release_api_url() {
  if [[ "${VERSION}" == "latest" ]]; then
    echo "https://api.github.com/repos/${REPO}/releases/latest"
  else
    echo "https://api.github.com/repos/${REPO}/releases/tags/${VERSION}"
  fi
}

require_cmd curl
require_cmd jq

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

API_URL="$(release_api_url)"
RELEASE_JSON="${TMP_DIR}/release.json"

HTTP_CODE="$(curl -sS -L -o "${RELEASE_JSON}" -w "%{http_code}" "${API_URL}")"
if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "Failed to fetch release metadata from ${API_URL} (HTTP ${HTTP_CODE})" >&2
  exit 1
fi

RESOLVED_TAG="$(jq -r '.tag_name // empty' "${RELEASE_JSON}")"
[[ -n "${RESOLVED_TAG}" ]] || {
  echo "Could not resolve release tag from GitHub API" >&2
  exit 1
}

ASSET_URL="$(jq -r --arg name "${ASSET_NAME}" '.assets[]? | select(.name==$name) | .browser_download_url' "${RELEASE_JSON}" | head -n 1)"
CHECKSUM_URL="$(jq -r --arg name "${CHECKSUM_NAME}" '.assets[]? | select(.name==$name) | .browser_download_url' "${RELEASE_JSON}" | head -n 1)"

if [[ -z "${ASSET_URL}" || -z "${CHECKSUM_URL}" ]]; then
  echo "Release ${RESOLVED_TAG} is missing required assets (${ASSET_NAME}, ${CHECKSUM_NAME})." >&2
  echo "Publish release artifacts before using installer." >&2
  exit 1
fi

ASSET_PATH="${TMP_DIR}/${ASSET_NAME}"
CHECKSUM_PATH="${TMP_DIR}/${CHECKSUM_NAME}"

curl -fsSL "${ASSET_URL}" -o "${ASSET_PATH}"
curl -fsSL "${CHECKSUM_URL}" -o "${CHECKSUM_PATH}"

EXPECTED_SHA="$(awk '{print $1}' "${CHECKSUM_PATH}" | head -n 1)"
ACTUAL_SHA="$(sha256_cmd "${ASSET_PATH}")"

if [[ -z "${EXPECTED_SHA}" ]]; then
  echo "Checksum file is empty or invalid: ${CHECKSUM_NAME}" >&2
  exit 1
fi

if [[ "${EXPECTED_SHA}" != "${ACTUAL_SHA}" ]]; then
  echo "Checksum verification failed for ${ASSET_NAME}" >&2
  echo "Expected: ${EXPECTED_SHA}" >&2
  echo "Actual:   ${ACTUAL_SHA}" >&2
  exit 1
fi

mkdir -p "${INSTALL_DIR}"
install -m 0755 "${ASSET_PATH}" "${INSTALL_DIR}/releasekit-ios-setup"

echo "Installed releasekit-ios-setup ${RESOLVED_TAG} to ${INSTALL_DIR}/releasekit-ios-setup"

case ":${PATH}:" in
  *":${INSTALL_DIR}:"*)
    echo "Run: releasekit-ios-setup wizard"
    ;;
  *)
    echo "${INSTALL_DIR} is not in PATH. Add this line to your shell profile:"
    echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
    echo "Then run: releasekit-ios-setup wizard"
    ;;
esac
