#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_SCRIPT="${ROOT_DIR}/scripts/releasekit-ios-setup.sh"
ASSET_SCRIPT="${ROOT_DIR}/release-assets/releasekit-ios-setup.sh"
ASSET_CHECKSUM="${ROOT_DIR}/release-assets/releasekit-ios-setup.sh.sha256"

TAG=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") --tag <vX.Y|X.Y>

This command:
1) Sets CLI_VERSION in scripts/releasekit-ios-setup.sh from tag
2) Copies script to release-assets/releasekit-ios-setup.sh
3) Regenerates release-assets/releasekit-ios-setup.sh.sha256
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${TAG}" ]]; then
  echo "--tag is required" >&2
  usage >&2
  exit 1
fi

if [[ "${TAG}" =~ ^v?([0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?)$ ]]; then
  VERSION="${BASH_REMATCH[1]}"
else
  echo "Invalid tag format: ${TAG}" >&2
  echo "Expected: vX.Y or X.Y (optionally with prerelease/build suffix)" >&2
  exit 1
fi

if [[ ! -f "${SOURCE_SCRIPT}" ]]; then
  echo "Missing source script: ${SOURCE_SCRIPT}" >&2
  exit 1
fi

if ! grep -q '^CLI_VERSION="' "${SOURCE_SCRIPT}"; then
  echo "Could not find CLI_VERSION line in ${SOURCE_SCRIPT}" >&2
  exit 1
fi

sed -i.bak -E "s/^CLI_VERSION=\"[^\"]+\"$/CLI_VERSION=\"${VERSION//\//\/}\"/" "${SOURCE_SCRIPT}"
rm -f "${SOURCE_SCRIPT}.bak"

mkdir -p "$(dirname "${ASSET_SCRIPT}")"
cp "${SOURCE_SCRIPT}" "${ASSET_SCRIPT}"

if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "${ASSET_SCRIPT}" | awk '{print $1}' > "${ASSET_CHECKSUM}"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "${ASSET_SCRIPT}" | awk '{print $1}' > "${ASSET_CHECKSUM}"
else
  echo "No SHA-256 tool found (need shasum or sha256sum)" >&2
  exit 1
fi

echo "Prepared release assets for tag ${TAG}"
echo "CLI_VERSION set to ${VERSION}"
echo "Updated: ${SOURCE_SCRIPT}"
echo "Updated: ${ASSET_SCRIPT}"
echo "Updated: ${ASSET_CHECKSUM}"
