#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_non_empty "INPUT_WORKSPACE" "${INPUT_WORKSPACE:-}"
require_non_empty "INPUT_SCHEME" "${INPUT_SCHEME:-}"
require_non_empty "INPUT_BUNDLE_ID" "${INPUT_BUNDLE_ID:-}"
require_non_empty "INPUT_DISTRIBUTION_CERTIFICATE_P12_B64" "${INPUT_DISTRIBUTION_CERTIFICATE_P12_B64:-}"
require_non_empty "INPUT_DISTRIBUTION_CERTIFICATE_PASSWORD" "${INPUT_DISTRIBUTION_CERTIFICATE_PASSWORD:-}"
require_non_empty "INPUT_PROVISIONING_PROFILE_B64" "${INPUT_PROVISIONING_PROFILE_B64:-}"
if [[ -n "${INPUT_DEVELOPER_TEAM_ID:-}" && -n "${INPUT_ASC_TEAM_ID:-}" && "${INPUT_DEVELOPER_TEAM_ID}" != "${INPUT_ASC_TEAM_ID}" ]]; then
  fail "developer_team_id and deprecated asc_team_id must match when both are provided"
fi
developer_team_id="${INPUT_DEVELOPER_TEAM_ID:-${INPUT_ASC_TEAM_ID:-}}"
require_non_empty "INPUT_DEVELOPER_TEAM_ID" "${developer_team_id}"
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
certificate_path="${tmp_dir}/AppleDistribution.p12"
profile_path="${tmp_dir}/AppStore.mobileprovision"
profile_plist_path="${tmp_dir}/AppStore.plist"
export_options_path="${tmp_dir}/ExportOptions.plist"
keychain_path="${tmp_dir}/ReleaseKit.keychain-db"
keychain_password="$(uuidgen)"
keychain_created=false
keychain_search_list_changed=false
original_keychains=()
installed_profile_paths=()

cleanup() {
  local exit_code=$?
  local cleanup_failed=false
  local index
  local installed_profile_path
  local profile_backup_path
  trap - EXIT INT TERM
  set +e

  for index in "${!installed_profile_paths[@]}"; do
    installed_profile_path="${installed_profile_paths[${index}]}"
    profile_backup_path="${tmp_dir}/profile-backup-${index}.mobileprovision"
    if [[ -f "${profile_backup_path}" ]]; then
      if ! cp -p "${profile_backup_path}" "${installed_profile_path}"; then
        echo "::error::Unable to restore provisioning profile: ${installed_profile_path}" >&2
        cleanup_failed=true
      fi
    else
      if ! rm -f "${installed_profile_path}"; then
        echo "::error::Unable to remove temporary provisioning profile: ${installed_profile_path}" >&2
        cleanup_failed=true
      fi
    fi
  done

  if [[ "${keychain_search_list_changed}" == "true" ]]; then
    if ! security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1; then
      echo "::error::Unable to restore the original user keychain search list." >&2
      cleanup_failed=true
    fi
  fi
  if [[ "${keychain_created}" == "true" ]]; then
    if ! security delete-keychain "${keychain_path}" >/dev/null 2>&1; then
      echo "::error::Unable to delete the temporary ReleaseKit keychain." >&2
      cleanup_failed=true
    fi
  fi
  if ! rm -rf "${tmp_dir}"; then
    echo "::error::Unable to delete the temporary ReleaseKit archive directory." >&2
    cleanup_failed=true
  fi

  if [[ "${exit_code}" -eq 0 && "${cleanup_failed}" == "true" ]]; then
    exit 1
  fi
  exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "::add-mask::${INPUT_DISTRIBUTION_CERTIFICATE_P12_B64}"
echo "::add-mask::${INPUT_DISTRIBUTION_CERTIFICATE_PASSWORD}"
echo "::add-mask::${keychain_password}"
echo "::add-mask::${developer_team_id}"

if ! printf '%s' "${INPUT_DISTRIBUTION_CERTIFICATE_P12_B64}" | decode_base64 > "${certificate_path}" 2>/dev/null || [[ ! -s "${certificate_path}" ]]; then
  fail "Invalid Apple Distribution certificate. Expected base64-encoded .p12 content."
fi
chmod 600 "${certificate_path}"

if ! printf '%s' "${INPUT_PROVISIONING_PROFILE_B64}" | decode_base64 > "${profile_path}" 2>/dev/null || [[ ! -s "${profile_path}" ]]; then
  fail "Invalid provisioning profile. Expected base64-encoded .mobileprovision content."
fi
chmod 600 "${profile_path}"

if ! security cms -D -i "${profile_path}" > "${profile_plist_path}" 2>/dev/null; then
  fail "Unable to decode the provisioning profile."
fi

profile_uuid="$(/usr/libexec/PlistBuddy -c "Print :UUID" "${profile_plist_path}" 2>/dev/null || true)"
profile_team_id="$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "${profile_plist_path}" 2>/dev/null || true)"
profile_app_identifier="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" "${profile_plist_path}" 2>/dev/null || true)"
profile_bundle_id="${profile_app_identifier#*.}"

if [[ -z "${profile_uuid}" || -z "${profile_team_id}" || -z "${profile_app_identifier}" ]]; then
  fail "Provisioning profile is missing its UUID, TeamIdentifier, or application-identifier."
fi
if [[ "${profile_team_id}" != "${developer_team_id}" ]]; then
  fail "Provisioning profile Team ID mismatch. Expected '${developer_team_id}', profile has '${profile_team_id}'."
fi
if [[ "${profile_bundle_id}" != "${INPUT_BUNDLE_ID}" ]]; then
  fail "Provisioning profile bundle ID mismatch. Expected '${INPUT_BUNDLE_ID}', profile has '${profile_bundle_id}'."
fi

while IFS= read -r existing_keychain; do
  existing_keychain="${existing_keychain#${existing_keychain%%[![:space:]]*}}"
  existing_keychain="${existing_keychain#\"}"
  existing_keychain="${existing_keychain%\"}"
  if [[ -n "${existing_keychain}" ]]; then
    original_keychains+=("${existing_keychain}")
  fi
done < <(security list-keychains -d user | tr -d '\r')

security create-keychain -p "${keychain_password}" "${keychain_path}"
keychain_created=true
security set-keychain-settings -lut 21600 "${keychain_path}"
security unlock-keychain -p "${keychain_password}" "${keychain_path}"
if ! security import "${certificate_path}" \
  -k "${keychain_path}" \
  -P "${INPUT_DISTRIBUTION_CERTIFICATE_PASSWORD}" \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null; then
  fail "Unable to import the Apple Distribution certificate. Check the .p12 and its password."
fi
security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "${keychain_password}" \
  "${keychain_path}" >/dev/null

identity_output="$(security find-identity -v -p codesigning "${keychain_path}")"
has_distribution_identity=false
has_team_distribution_identity=false
while IFS= read -r identity_line; do
  if [[ "${identity_line}" == *'Apple Distribution:'* ]]; then
    has_distribution_identity=true
    if [[ "${identity_line}" == *"(${developer_team_id})\""* ]]; then
      has_team_distribution_identity=true
    fi
  fi
done <<< "${identity_output}"
if [[ "${has_distribution_identity}" != "true" ]]; then
  fail "The .p12 does not contain a valid Apple Distribution signing identity."
fi
if [[ "${has_team_distribution_identity}" != "true" ]]; then
  fail "Apple Distribution certificate Team ID mismatch. Expected '${developer_team_id}'."
fi

keychain_search_list_changed=true
security list-keychains -d user -s "${keychain_path}" "${original_keychains[@]}"

for profiles_dir in \
  "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles" \
  "${HOME}/Library/MobileDevice/Provisioning Profiles"; do
  mkdir -p "${profiles_dir}"
  installed_profile_path="${profiles_dir}/${profile_uuid}.mobileprovision"
  profile_backup_path="${tmp_dir}/profile-backup-${#installed_profile_paths[@]}.mobileprovision"
  if [[ -f "${installed_profile_path}" ]]; then
    cp -p "${installed_profile_path}" "${profile_backup_path}"
  fi
  cp "${profile_path}" "${installed_profile_path}"
  installed_profile_paths+=("${installed_profile_path}")
done

mkdir -p "$(dirname "${archive_path}")"
mkdir -p "${export_path}"

cat > "${export_options_path}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>export</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Apple Distribution</string>
  <key>teamID</key>
  <string>$(escape_plist_string "${developer_team_id}")</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>$(escape_plist_string "${INPUT_BUNDLE_ID}")</key>
    <string>$(escape_plist_string "${profile_uuid}")</string>
  </dict>
</dict>
</plist>
PLIST

echo "Archiving scheme '${INPUT_SCHEME}' from workspace '${INPUT_WORKSPACE}'"
xcodebuild archive \
  -workspace "${INPUT_WORKSPACE}" \
  -scheme "${INPUT_SCHEME}" \
  -configuration "${INPUT_CONFIGURATION}" \
  -archivePath "${archive_path}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Apple Distribution" \
  PROVISIONING_PROFILE_SPECIFIER="${profile_uuid}" \
  DEVELOPMENT_TEAM="${developer_team_id}"

echo "Exporting IPA to '${export_path}'"
xcodebuild -exportArchive \
  -archivePath "${archive_path}" \
  -exportPath "${export_path}" \
  -exportOptionsPlist "${export_options_path}"

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
