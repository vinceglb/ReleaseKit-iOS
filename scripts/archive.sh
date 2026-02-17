#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_non_empty "INPUT_WORKSPACE" "${INPUT_WORKSPACE:-}"
require_non_empty "INPUT_SCHEME" "${INPUT_SCHEME:-}"
require_non_empty "INPUT_BUNDLE_ID" "${INPUT_BUNDLE_ID:-}"
require_non_empty "INPUT_ASC_KEY_ID" "${INPUT_ASC_KEY_ID:-}"
require_non_empty "INPUT_ASC_ISSUER_ID" "${INPUT_ASC_ISSUER_ID:-}"
require_non_empty "INPUT_ASC_PRIVATE_KEY_B64" "${INPUT_ASC_PRIVATE_KEY_B64:-}"
require_non_empty "INPUT_ASC_TEAM_ID" "${INPUT_ASC_TEAM_ID:-}"
require_non_empty "INPUT_CONFIGURATION" "${INPUT_CONFIGURATION:-}"
require_non_empty "INPUT_ARCHIVE_PATH" "${INPUT_ARCHIVE_PATH:-}"
require_non_empty "INPUT_EXPORT_PATH" "${INPUT_EXPORT_PATH:-}"

archive_path="${INPUT_ARCHIVE_PATH//\$\{\{ runner.temp \}\}/${RUNNER_TEMP:-/tmp}}"
export_path="${INPUT_EXPORT_PATH//\$\{\{ runner.temp \}\}/${RUNNER_TEMP:-/tmp}}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  fail "xcodebuild not found. Use a macOS runner with Xcode installed."
fi

if [[ ! -e "${INPUT_WORKSPACE}" ]]; then
  fail "Workspace path not found: ${INPUT_WORKSPACE}"
fi
if [[ "${INPUT_WORKSPACE}" != *.xcworkspace && "${INPUT_WORKSPACE}" != *.xcworkspace/ ]]; then
  echo "::warning::workspace does not end with .xcworkspace: ${INPUT_WORKSPACE}" >&2
fi

runner_temp="${RUNNER_TEMP:-/tmp}"
tmp_dir="$(mktemp -d "${runner_temp}/releasekit-ios-archive.XXXXXX")"
private_key_path="${tmp_dir}/AuthKey.p8"
export_options_path="${tmp_dir}/ExportOptions.plist"

cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

echo "::add-mask::${INPUT_ASC_KEY_ID}"
echo "::add-mask::${INPUT_ASC_ISSUER_ID}"
echo "::add-mask::${INPUT_ASC_PRIVATE_KEY_B64}"
echo "::add-mask::${INPUT_ASC_TEAM_ID}"

if ! prepare_private_key_file "${INPUT_ASC_PRIVATE_KEY_B64}" "${private_key_path}" "${tmp_dir}"; then
  fail "Invalid ASC private key content. Expected base64-encoded .p8 key (single encoding). Example: base64 < AuthKey_XXXX.p8 | tr -d '\\n'"
fi
chmod 600 "${private_key_path}"

mkdir -p "$(dirname "${archive_path}")"
mkdir -p "${export_path}"

cat > "${export_options_path}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>signingCertificate</key>
  <string>Apple Distribution</string>
  <key>teamID</key>
  <string>$(escape_plist_string "${INPUT_ASC_TEAM_ID}")</string>
</dict>
</plist>
PLIST

echo "Archiving scheme '${INPUT_SCHEME}' from workspace '${INPUT_WORKSPACE}'"
if [[ -n "${INPUT_XCODEBUILD_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  extra_args=(${INPUT_XCODEBUILD_EXTRA_ARGS})
  xcodebuild archive \
    -workspace "${INPUT_WORKSPACE}" \
    -scheme "${INPUT_SCHEME}" \
    -configuration "${INPUT_CONFIGURATION}" \
    -archivePath "${archive_path}" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "${private_key_path}" \
    -authenticationKeyID "${INPUT_ASC_KEY_ID}" \
    -authenticationKeyIssuerID "${INPUT_ASC_ISSUER_ID}" \
    DEVELOPMENT_TEAM="${INPUT_ASC_TEAM_ID}" \
    "${extra_args[@]}"
else
  xcodebuild archive \
    -workspace "${INPUT_WORKSPACE}" \
    -scheme "${INPUT_SCHEME}" \
    -configuration "${INPUT_CONFIGURATION}" \
    -archivePath "${archive_path}" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "${private_key_path}" \
    -authenticationKeyID "${INPUT_ASC_KEY_ID}" \
    -authenticationKeyIssuerID "${INPUT_ASC_ISSUER_ID}" \
    DEVELOPMENT_TEAM="${INPUT_ASC_TEAM_ID}"
fi

echo "Exporting IPA to '${export_path}'"
xcodebuild -exportArchive \
  -archivePath "${archive_path}" \
  -exportPath "${export_path}" \
  -exportOptionsPlist "${export_options_path}" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "${private_key_path}" \
  -authenticationKeyID "${INPUT_ASC_KEY_ID}" \
  -authenticationKeyIssuerID "${INPUT_ASC_ISSUER_ID}"

ipa_path="$(find "${export_path}" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
if [[ -z "${ipa_path}" ]]; then
  echo "::group::Export directory contents"
  ls -la "${export_path}" || true
  echo "::endgroup::"
  fail "No IPA file found in export path: ${export_path}"
fi

archive_bundle_id="$(extract_archive_bundle_id "${archive_path}" || true)"
if [[ -z "${archive_bundle_id}" ]]; then
  fail "Unable to determine bundle identifier from archive at ${archive_path}"
fi
if [[ "${archive_bundle_id}" != "${INPUT_BUNDLE_ID}" ]]; then
  fail "Bundle ID mismatch. Expected '${INPUT_BUNDLE_ID}', archive has '${archive_bundle_id}'."
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "archive_path=${archive_path}"
    echo "ipa_path=${ipa_path}"
    echo "archive_bundle_id=${archive_bundle_id}"
  } >> "${GITHUB_OUTPUT}"
fi

echo "Archive/export completed."
