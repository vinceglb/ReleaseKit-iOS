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

for command in asc jq python3; do
  command -v "${command}" >/dev/null 2>&1 || fail "${command} is required but was not found in PATH"
done

contract_helper="${SCRIPT_DIR}/lib/release_contract.py"
identity_json="$(python3 "${contract_helper}" ipa-identity "${resolved_ipa_path}")"
bundle_id="$(jq -r '.bundle_id' <<< "${identity_json}")"
marketing_version="$(jq -r '.marketing_version' <<< "${identity_json}")"
build_number="$(jq -r '.build_number' <<< "${identity_json}")"

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

asc_ci() {
  env \
    HOME="${asc_home}" \
    ASC_BYPASS_KEYCHAIN=1 \
    ASC_PROFILE="releasekit-ios-ci" \
    ASC_KEY_ID="${INPUT_ASC_KEY_ID}" \
    ASC_ISSUER_ID="${INPUT_ASC_ISSUER_ID}" \
    ASC_PRIVATE_KEY_PATH="${private_key_path}" \
    ASC_TELEMETRY_DISABLED=1 \
    asc "$@"
}

write_reused_outputs() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "ipa_path=${resolved_ipa_path}"
      echo "upload_id="
      echo "file_id="
      echo "asc_result_json="
      echo "outcome=reused"
    } >> "${GITHUB_OUTPUT}"
  fi
  echo "Exact IPA upload already exists; reusing it."
}

build_matches_identity() {
  local build_id="$1"
  local actual_build_number="$2"
  local pre_release_path="${tmp_dir}/pre-release-${build_id}.json"

  if ! asc_ci builds pre-release-version view \
      --build-id "${build_id}" \
      --output json > "${pre_release_path}"; then
    fail "Unable to verify the marketing version and platform for build '${build_id}'."
  fi

  local actual_marketing_version
  local actual_platform
  actual_marketing_version="$(jq -r '.data.attributes.version // .version // empty' "${pre_release_path}")"
  actual_platform="$(jq -r '.data.attributes.platform // .platform // empty' "${pre_release_path}")"

  [[ "${actual_build_number}" == "${build_number}" \
    && "${actual_marketing_version}" == "${marketing_version}" \
    && "${actual_platform}" == "IOS" ]]
}

wait_for_build_id() {
  local build_id="$1"
  local wait_path="${tmp_dir}/build-wait-${build_id}.json"

  if ! asc_ci builds wait \
      --build-id "${build_id}" \
      --poll-interval "${INPUT_POLL_INTERVAL}" \
      --fail-on-invalid \
      --output json > "${wait_path}"; then
    asc_ci builds info --build-id "${build_id}" --output json > "${tmp_dir}/build-after-wait.json" || true
    local final_state
    final_state="$(jq -r '.data.attributes.processingState // .processingState // empty' "${tmp_dir}/build-after-wait.json" 2>/dev/null || true)"
    if [[ "${final_state}" == "FAILED" || "${final_state}" == "INVALID" ]]; then
      fail "Exact build '${build_id}' reached terminal state '${final_state}'. Upload a new build number."
    fi
    fail "asc failed while waiting for exact build '${build_id}' to finish processing."
  fi

  local waited_state
  waited_state="$(jq -r '.data.attributes.processingState // .processingState // empty' "${wait_path}")"
  [[ "${waited_state}" == "VALID" ]] || fail "Exact build '${build_id}' did not reach VALID (state: ${waited_state:-unknown})."
}

wait_for_delivery_build() {
  local upload_id="$1"
  local wait_path="${tmp_dir}/delivery-build-wait.json"

  if ! asc_ci builds wait \
      --app "${INPUT_APP_ID}" \
      --version "${marketing_version}" \
      --build-number "${build_number}" \
      --platform IOS \
      --poll-interval "${INPUT_POLL_INTERVAL}" \
      --fail-on-invalid \
      --output json > "${wait_path}"; then
    if asc_ci builds uploads view --id "${upload_id}" --output json > "${tmp_dir}/upload-after-wait.json"; then
      local delivery_state
      local delivery_errors
      delivery_state="$(jq -r '.data.attributes.state.state // .state.state // empty' "${tmp_dir}/upload-after-wait.json")"
      delivery_errors="$(jq -r '[.data.attributes.state.errors[]? | ((.code // "UNKNOWN") + ": " + (.message // "Upload failed"))] | join("; ")' "${tmp_dir}/upload-after-wait.json")"
      if [[ "${delivery_state}" == "FAILED" ]]; then
        fail "Delivery '${upload_id}' failed while waiting${delivery_errors:+: ${delivery_errors}}"
      fi
    fi
    fail "asc failed while waiting for delivery '${upload_id}' to produce a processed build."
  fi

  local waited_build_id
  local waited_build_number
  local waited_state
  waited_build_id="$(jq -r '.data.id // .id // empty' "${wait_path}")"
  waited_build_number="$(jq -r '.data.attributes.version // .version // empty' "${wait_path}")"
  waited_state="$(jq -r '.data.attributes.processingState // .processingState // empty' "${wait_path}")"
  [[ -n "${waited_build_id}" ]] || fail "asc did not return a build ID after waiting for delivery '${upload_id}'."
  if ! build_matches_identity "${waited_build_id}" "${waited_build_number}"; then
    fail "asc returned build '${waited_build_id}' with an identity different from the IPA."
  fi
  [[ "${waited_state}" == "VALID" ]] || fail "Exact build '${waited_build_id}' did not reach VALID (state: ${waited_state:-unknown})."
}

if ! asc_ci apps view --id "${INPUT_APP_ID}" --output json > "${tmp_dir}/app.json"; then
  fail "Unable to inspect App Store Connect app '${INPUT_APP_ID}'."
fi
remote_bundle_id="$(jq -r '.data.attributes.bundleId // .bundleId // empty' "${tmp_dir}/app.json")"
[[ -n "${remote_bundle_id}" ]] || fail "Unable to read the selected app bundle identifier from App Store Connect."
if [[ "${remote_bundle_id}" != "${bundle_id}" ]]; then
  fail "Bundle ID mismatch. IPA has '${bundle_id}', App Store Connect app has '${remote_bundle_id}'."
fi

if ! asc_ci builds list \
    --app "${INPUT_APP_ID}" \
    --version "${marketing_version}" \
    --build-number "${build_number}" \
    --platform IOS \
    --processing-state all \
    --paginate \
    --output json > "${tmp_dir}/builds.json"; then
  fail "Unable to inspect existing builds for the exact IPA identity."
fi

if ! asc_ci builds uploads list \
    --app "${INPUT_APP_ID}" \
    --cf-bundle-short-version "${marketing_version}" \
    --cf-bundle-version "${build_number}" \
    --platform IOS \
    --paginate \
    --output json > "${tmp_dir}/uploads.json"; then
  fail "Unable to inspect existing deliveries for the exact IPA identity."
fi

if ! jq -e \
    --arg version "${marketing_version}" \
    --arg build "${build_number}" \
    '[.data[]? | select(
      (.attributes.cfBundleShortVersionString // "") != $version
      or (.attributes.cfBundleVersion // "") != $build
      or (.attributes.platform // "") != "IOS"
    )] | length == 0' "${tmp_dir}/uploads.json" >/dev/null; then
  fail "asc returned a delivery with an identity different from the IPA."
fi

unknown_delivery_summary="$(jq -c '[.data[]? | select((.attributes.state.state // "") as $state | ["AWAITING_UPLOAD", "PROCESSING", "FAILED", "COMPLETE"] | index($state) | not) | {id, state: .attributes.state.state}]' "${tmp_dir}/uploads.json")"
if [[ "${unknown_delivery_summary}" != "[]" ]]; then
  fail "App Store Connect returned unsupported delivery state: ${unknown_delivery_summary}"
fi

active_delivery_count="$(jq '[.data[]? | select(.attributes.state.state != "FAILED")] | length' "${tmp_dir}/uploads.json")"
if [[ "${active_delivery_count}" -gt 1 ]]; then
  delivery_summary="$(jq -c '[.data[]? | select(.attributes.state.state != "FAILED") | {id, state: .attributes.state.state}]' "${tmp_dir}/uploads.json")"
  fail "App Store Connect returned multiple active deliveries for the exact IPA identity: ${delivery_summary}"
fi

build_count="$(jq '[.data[]?] | length' "${tmp_dir}/builds.json")"
if [[ "${build_count}" -gt 1 ]]; then
  build_summary="$(jq -c '[.data[]? | {id, state: .attributes.processingState, build_number: .attributes.version}]' "${tmp_dir}/builds.json")"
  fail "App Store Connect returned multiple builds for the exact IPA filters: ${build_summary}"
elif [[ "${build_count}" -eq 1 ]]; then
  build_id="$(jq -r '.data[0].id // empty' "${tmp_dir}/builds.json")"
  build_state="$(jq -r '.data[0].attributes.processingState // empty' "${tmp_dir}/builds.json")"
  actual_build_number="$(jq -r '.data[0].attributes.version // empty' "${tmp_dir}/builds.json")"
  [[ -n "${build_id}" ]] || fail "asc returned a build without an ID."
  if ! build_matches_identity "${build_id}" "${actual_build_number}"; then
    fail "asc returned build '${build_id}' with an identity different from the IPA."
  fi

  case "${build_state}" in
    VALID)
      write_reused_outputs
      exit 0
      ;;
    PROCESSING)
      if is_true "${INPUT_WAIT_FOR_PROCESSING}"; then
        wait_for_build_id "${build_id}"
      fi
      write_reused_outputs
      exit 0
      ;;
    FAILED|INVALID)
      fail "Exact build '${build_id}' is in terminal state '${build_state}'. Upload a new build number."
      ;;
    *)
      fail "Exact build '${build_id}' returned unsupported processing state '${build_state:-unknown}'."
      ;;
  esac
fi

if [[ "${active_delivery_count}" -eq 1 ]]; then
  delivery_id="$(jq -r '.data[] | select(.attributes.state.state != "FAILED") | .id' "${tmp_dir}/uploads.json")"
  delivery_state="$(jq -r '.data[] | select(.attributes.state.state != "FAILED") | .attributes.state.state' "${tmp_dir}/uploads.json")"

  case "${delivery_state}" in
    PROCESSING|COMPLETE)
      if is_true "${INPUT_WAIT_FOR_PROCESSING}"; then
        wait_for_delivery_build "${delivery_id}"
      fi
      write_reused_outputs
      exit 0
      ;;
    AWAITING_UPLOAD)
      fail "Delivery '${delivery_id}' is still awaiting its file transfer. Resolve or retry that delivery before starting another upload."
      ;;
  esac
fi

upload_cmd=(
  builds
  upload
  --app "${INPUT_APP_ID}"
  --ipa "${resolved_ipa_path}"
  --output json
)

if is_true "${INPUT_WAIT_FOR_PROCESSING}"; then
  upload_cmd+=(--wait --poll-interval "${INPUT_POLL_INTERVAL}")
fi

echo "Uploading IPA with asc"
if ! asc_ci "${upload_cmd[@]}" > "${result_json_path}"; then
  if [[ -s "${result_json_path}" ]]; then
    echo "::group::asc output"
    cat "${result_json_path}" >&2
    echo "::endgroup::"
  fi
  fail "asc upload failed."
fi

upload_id="$(jq -r '.uploadId // empty' "${result_json_path}")"
file_id="$(jq -r '.fileId // empty' "${result_json_path}")"
asc_result_json="$(jq -c '.' "${result_json_path}")"

if [[ -z "${upload_id}" || -z "${file_id}" ]]; then
  echo "::warning::Could not parse uploadId/fileId from asc output." >&2
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "ipa_path=${resolved_ipa_path}"
    echo "upload_id=${upload_id}"
    echo "file_id=${file_id}"
    echo "asc_result_json=${asc_result_json}"
    echo "outcome=uploaded"
  } >> "${GITHUB_OUTPUT}"
fi

echo "Upload completed."
