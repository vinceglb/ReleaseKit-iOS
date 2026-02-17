#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_non_empty "INPUT_APP_ID" "${INPUT_APP_ID:-}"
require_non_empty "INPUT_ASC_KEY_ID" "${INPUT_ASC_KEY_ID:-}"
require_non_empty "INPUT_ASC_ISSUER_ID" "${INPUT_ASC_ISSUER_ID:-}"
require_non_empty "INPUT_ASC_PRIVATE_KEY_B64" "${INPUT_ASC_PRIVATE_KEY_B64:-}"
require_non_empty "INPUT_WAIT_FOR_PROCESSING" "${INPUT_WAIT_FOR_PROCESSING:-}"
require_non_empty "INPUT_POLL_INTERVAL" "${INPUT_POLL_INTERVAL:-}"
require_non_empty "INPUT_ARTIFACT_DOWNLOAD_PATH" "${INPUT_ARTIFACT_DOWNLOAD_PATH:-}"

ipa_path_input="${INPUT_IPA_PATH:-}"
artifact_name_input="${INPUT_ARTIFACT_NAME:-}"
resolved_ipa_path=""

if [[ -n "${ipa_path_input}" && -n "${artifact_name_input}" ]]; then
  fail "Provide exactly one source: ipa_path or artifact_name (not both)."
fi
if [[ -z "${ipa_path_input}" && -z "${artifact_name_input}" ]]; then
  fail "Provide exactly one source: ipa_path or artifact_name."
fi

if [[ -n "${ipa_path_input}" ]]; then
  resolved_ipa_path="${ipa_path_input//\$\{\{ runner.temp \}\}/${RUNNER_TEMP:-/tmp}}"
  [[ -f "${resolved_ipa_path}" ]] || fail "IPA path not found: ${resolved_ipa_path}"
else
  artifact_path_root="${INPUT_ARTIFACT_DOWNLOAD_PATH//\$\{\{ runner.temp \}\}/${RUNNER_TEMP:-/tmp}}"
  [[ -d "${artifact_path_root}" ]] || fail "Artifact download path not found: ${artifact_path_root}. Ensure artifact_name exists and download step succeeded."
  resolved_ipa_path="$(find "${artifact_path_root}" -type f -name '*.ipa' -print -quit)"
  [[ -n "${resolved_ipa_path}" ]] || fail "No .ipa found under artifact_download_path: ${artifact_path_root}"
fi

echo "::add-mask::${INPUT_ASC_KEY_ID}"
echo "::add-mask::${INPUT_ASC_ISSUER_ID}"
echo "::add-mask::${INPUT_ASC_PRIVATE_KEY_B64}"

runner_temp="${RUNNER_TEMP:-/tmp}"
tmp_dir="$(mktemp -d "${runner_temp}/releasekit-ios-upload.XXXXXX")"
private_key_path="${tmp_dir}/AuthKey.p8"
result_json_path="${tmp_dir}/asc-upload-result.json"
asc_home="${tmp_dir}/asc-home"

cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

if ! prepare_private_key_file "${INPUT_ASC_PRIVATE_KEY_B64}" "${private_key_path}" "${tmp_dir}"; then
  fail "Invalid ASC private key content. Expected base64-encoded .p8 key (single encoding). Example: base64 < AuthKey_XXXX.p8 | tr -d '\\n'"
fi
chmod 600 "${private_key_path}"

if ! command -v asc >/dev/null 2>&1; then
  fail "asc CLI not found in PATH. Ensure install step runs before this script."
fi

mkdir -p "${asc_home}"

asc_login_err="${tmp_dir}/asc-login.err"
if ! HOME="${asc_home}" ASC_BYPASS_KEYCHAIN=1 asc auth login \
    --bypass-keychain \
    --skip-validation \
    --name "releasekit-ios-ci" \
    --key-id "${INPUT_ASC_KEY_ID}" \
    --issuer-id "${INPUT_ASC_ISSUER_ID}" \
    --private-key "${private_key_path}" > /dev/null 2> "${asc_login_err}"; then
  if [[ -s "${asc_login_err}" ]]; then
    echo "::group::asc auth login output"
    cat "${asc_login_err}" >&2
    echo "::endgroup::"
  fi
  fail "asc auth login failed. Check asc_key_id, asc_issuer_id, and asc_private_key_b64."
fi

upload_cmd=(
  asc
  builds
  upload
  --app "${INPUT_APP_ID}"
  --ipa "${resolved_ipa_path}"
)

if is_true "${INPUT_WAIT_FOR_PROCESSING}"; then
  upload_cmd+=(--wait --poll-interval "${INPUT_POLL_INTERVAL}")
fi

echo "Uploading IPA with asc"
if ! HOME="${asc_home}" ASC_BYPASS_KEYCHAIN=1 "${upload_cmd[@]}" > "${result_json_path}"; then
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
    echo "ipa_path=${resolved_ipa_path}"
    echo "upload_id=${upload_id}"
    echo "file_id=${file_id}"
    echo "asc_result_json=${asc_result_json}"
  } >> "${GITHUB_OUTPUT}"
fi

echo "Upload completed."
