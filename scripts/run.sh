#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

require_non_empty() {
  local name="$1"
  local value="${2:-}"
  if [[ -z "${value}" ]]; then
    fail "${name} is required"
  fi
}

is_true() {
  local value="${1:-}"
  value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  [[ "${value}" == "1" || "${value}" == "true" || "${value}" == "yes" || "${value}" == "on" ]]
}

decode_base64() {
  if printf '%s' "dGVzdA==" | base64 --decode >/dev/null 2>&1; then
    base64 --decode
  else
    base64 -D
  fi
}

pem_private_key_is_valid() {
  local file_path="$1"
  [[ -f "${file_path}" ]] || return 1
  grep -q '^-----BEGIN PRIVATE KEY-----$' "${file_path}" && grep -q '^-----END PRIVATE KEY-----$' "${file_path}"
}

write_normalized_file() {
  local input_path="$1"
  local output_path="$2"
  LC_ALL=C tr -d '\r' < "${input_path}" > "${output_path}"
}

prepare_private_key_file() {
  local input_value="$1"
  local output_path="$2"
  local work_dir="$3"

  local decoded_once="${work_dir}/decoded-once.p8"
  local decoded_twice="${work_dir}/decoded-twice.p8"
  local raw_pem="${work_dir}/raw-input.p8"

  if printf '%s' "${input_value}" | decode_base64 > "${decoded_once}" 2>/dev/null; then
    write_normalized_file "${decoded_once}" "${output_path}"
    if pem_private_key_is_valid "${output_path}"; then
      return 0
    fi

    if cat "${decoded_once}" | decode_base64 > "${decoded_twice}" 2>/dev/null; then
      write_normalized_file "${decoded_twice}" "${output_path}"
      if pem_private_key_is_valid "${output_path}"; then
        echo "::warning::asc_private_key_b64 appears to be double-base64-encoded. Please store single-encoded key content." >&2
        return 0
      fi
    fi
  fi

  if printf '%s' "${input_value}" | grep -q 'BEGIN PRIVATE KEY'; then
    printf '%s' "${input_value}" > "${raw_pem}"
    write_normalized_file "${raw_pem}" "${output_path}"
    if pem_private_key_is_valid "${output_path}"; then
      echo "::warning::asc_private_key_b64 appears to contain raw PEM text instead of base64. Please store base64-encoded .p8 content." >&2
      return 0
    fi
  fi

  return 1
}

extract_archive_bundle_id() {
  local archive_path="$1"
  local value=""
  local archive_info="${archive_path}/Info.plist"

  if [[ -f "${archive_info}" ]]; then
    value="$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleIdentifier" "${archive_info}" 2>/dev/null || true)"
    if [[ -n "${value}" ]]; then
      printf '%s' "${value}"
      return 0
    fi
  fi

  local app_info
  app_info="$(find "${archive_path}/Products/Applications" -maxdepth 2 -name Info.plist -print -quit 2>/dev/null || true)"
  if [[ -n "${app_info}" ]]; then
    value="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${app_info}" 2>/dev/null || true)"
  fi

  if [[ -n "${value}" ]]; then
    printf '%s' "${value}"
    return 0
  fi

  return 1
}

escape_plist_string() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  printf '%s' "${value}"
}

parse_json_field() {
  local file="$1"
  local key="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg key "${key}" '.[$key] // empty' "${file}"
    return 0
  fi

  sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\\1/p" "${file}" | head -n 1
}

require_non_empty "INPUT_WORKSPACE" "${INPUT_WORKSPACE:-}"
require_non_empty "INPUT_SCHEME" "${INPUT_SCHEME:-}"
require_non_empty "INPUT_APP_ID" "${INPUT_APP_ID:-}"
require_non_empty "INPUT_BUNDLE_ID" "${INPUT_BUNDLE_ID:-}"
require_non_empty "INPUT_ASC_KEY_ID" "${INPUT_ASC_KEY_ID:-}"
require_non_empty "INPUT_ASC_ISSUER_ID" "${INPUT_ASC_ISSUER_ID:-}"
require_non_empty "INPUT_ASC_PRIVATE_KEY_B64" "${INPUT_ASC_PRIVATE_KEY_B64:-}"
require_non_empty "INPUT_ASC_TEAM_ID" "${INPUT_ASC_TEAM_ID:-}"
require_non_empty "INPUT_CONFIGURATION" "${INPUT_CONFIGURATION:-}"
require_non_empty "INPUT_ARCHIVE_PATH" "${INPUT_ARCHIVE_PATH:-}"
require_non_empty "INPUT_EXPORT_PATH" "${INPUT_EXPORT_PATH:-}"
require_non_empty "INPUT_WAIT_FOR_PROCESSING" "${INPUT_WAIT_FOR_PROCESSING:-}"
require_non_empty "INPUT_POLL_INTERVAL" "${INPUT_POLL_INTERVAL:-}"

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
tmp_dir="$(mktemp -d "${runner_temp}/releasekit-ios.XXXXXX")"
private_key_path="${tmp_dir}/AuthKey.p8"
result_json_path="${tmp_dir}/asc-upload-result.json"
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

cat > "${export_options_path}" <<EOF
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
EOF

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

export ASC_KEY_ID="${INPUT_ASC_KEY_ID}"
export ASC_ISSUER_ID="${INPUT_ASC_ISSUER_ID}"
export ASC_PRIVATE_KEY_PATH="${private_key_path}"
export ASC_BYPASS_KEYCHAIN=1
export ASC_NO_UPDATE=1

if ! command -v asc >/dev/null 2>&1; then
  fail "asc CLI not found in PATH. Ensure install step runs before this script."
fi

upload_cmd=(
  asc
  builds
  upload
  --app "${INPUT_APP_ID}"
  --ipa "${ipa_path}"
)

if is_true "${INPUT_WAIT_FOR_PROCESSING}"; then
  upload_cmd+=(--wait --poll-interval "${INPUT_POLL_INTERVAL}")
fi

echo "Uploading IPA with asc"
if ! "${upload_cmd[@]}" > "${result_json_path}"; then
  if [[ -s "${result_json_path}" ]]; then
    echo "::group::asc output"
    cat "${result_json_path}" >&2
    echo "::endgroup::"
  fi
  fail "asc upload failed."
fi

upload_id="$(parse_json_field "${result_json_path}" "uploadId")"
file_id="$(parse_json_field "${result_json_path}" "fileId")"
asc_result_json="$(tr -d '\n' < "${result_json_path}")"

if [[ -z "${upload_id}" || -z "${file_id}" ]]; then
  echo "::warning::Could not parse uploadId/fileId from asc output." >&2
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "archive_path=${archive_path}"
    echo "ipa_path=${ipa_path}"
    echo "upload_id=${upload_id}"
    echo "file_id=${file_id}"
    echo "asc_result_json=${asc_result_json}"
  } >> "${GITHUB_OUTPUT}"
fi

echo "Archive/export/upload completed."
