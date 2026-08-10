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

echo "::add-mask::${INPUT_ASC_KEY_ID}"
echo "::add-mask::${INPUT_ASC_ISSUER_ID}"
echo "::add-mask::${INPUT_ASC_PRIVATE_KEY_B64}"

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

for command in asc python3; do
  command -v "${command}" >/dev/null 2>&1 || fail "${command} is required but was not found in PATH"
done

contract_helper="${SCRIPT_DIR}/lib/release_contract.py"
upload_contract_helper="${SCRIPT_DIR}/lib/upload_contract.py"
identity_json="$(python3 "${contract_helper}" ipa-identity "${resolved_ipa_path}")"
bundle_id="$(parse_json_field <(printf '%s' "${identity_json}") "bundle_id")"
marketing_version="$(parse_json_field <(printf '%s' "${identity_json}") "marketing_version")"
build_number="$(parse_json_field <(printf '%s' "${identity_json}") "build_number")"

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
while IFS= read -r private_key_line || [[ -n "${private_key_line}" ]]; do
  if [[ -n "${private_key_line}" ]]; then
    echo "::add-mask::${private_key_line}"
  fi
done < "${private_key_path}"

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

asc_ci apps view --id "${INPUT_APP_ID}" --output json > "${tmp_dir}/app.json"
remote_bundle_id="$(python3 "${upload_contract_helper}" app-bundle-id "${tmp_dir}/app.json")"
[[ -n "${remote_bundle_id}" ]] || fail "Unable to read the app bundle identifier from App Store Connect."
if [[ "${remote_bundle_id}" != "${bundle_id}" ]]; then
  fail "Bundle ID mismatch. IPA has '${bundle_id}', App Store Connect app has '${remote_bundle_id}'."
fi

query_exact_resources() {
  local label="$1"
  local builds_path="${tmp_dir}/builds-${label}.json"
  local uploads_path="${tmp_dir}/uploads-${label}.json"

  existing_build_id=""
  existing_build_state=""
  existing_upload_id=""
  existing_upload_state=""
  failed_upload_ids=""
  failed_upload_errors=""
  failed_upload_classification="none"

  asc_ci builds list \
    --app "${INPUT_APP_ID}" \
    --version "${marketing_version}" \
    --build-number "${build_number}" \
    --platform IOS \
    --processing-state all \
    --paginate \
    --output json > "${builds_path}"
  asc_ci builds uploads list \
    --app "${INPUT_APP_ID}" \
    --cf-bundle-short-version "${marketing_version}" \
    --cf-bundle-version "${build_number}" \
    --platform IOS \
    --paginate \
    --output json > "${uploads_path}"

  local reconciliation_path="${tmp_dir}/reconciliation-${label}.json"
  python3 "${upload_contract_helper}" reconcile \
    "${builds_path}" \
    "${uploads_path}" \
    "${marketing_version}" \
    "${build_number}" > "${reconciliation_path}"
  existing_build_id="$(parse_json_field "${reconciliation_path}" "build_id")"
  existing_build_state="$(parse_json_field "${reconciliation_path}" "build_state")"
  existing_upload_id="$(parse_json_field "${reconciliation_path}" "upload_id")"
  existing_upload_state="$(parse_json_field "${reconciliation_path}" "upload_state")"
  failed_upload_ids="$(parse_json_field "${reconciliation_path}" "failed_upload_ids")"
  failed_upload_errors="$(parse_json_field "${reconciliation_path}" "failed_upload_errors")"
  failed_upload_classification="$(parse_json_field "${reconciliation_path}" "failed_upload_classification")"

  if [[ -n "${existing_build_state}" && -z "${existing_build_id}" ]]; then
    fail "Exact App Store Connect build did not include a resource ID."
  fi
  if [[ -n "${existing_upload_state}" && -z "${existing_upload_id}" ]]; then
    fail "Exact App Store Connect build upload did not include a resource ID."
  fi
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
}

fail_if_unrecoverable_upload_error() {
  local upload_ids="$1"
  local errors="$2"
  local classification="$3"
  case "${classification}" in
    none|"") ;;
    transient)
      echo "::warning::Previous exact build upload(s) '${upload_ids}' failed transiently: ${errors}"
      ;;
    unrecoverable)
      fail "Exact build upload(s) '${upload_ids}' failed with an unrecoverable error: ${errors}. Fix the IPA and increment the immutable build number before retrying."
      ;;
    *)
      fail "Exact build upload(s) '${upload_ids}' returned unknown failure classification '${classification}'. Refusing to retry the immutable build."
      ;;
  esac
}

refresh_observed_upload() {
  local upload_id="$1"
  local label="$2"
  local view_path="${tmp_dir}/observed-upload-${label}.json"
  local refreshed_errors
  local refreshed_classification
  if ! asc_ci builds uploads view --id "${upload_id}" --output json > "${view_path}"; then
    fail "Previously observed exact build upload '${upload_id}' could not be refreshed. Refusing to create a potentially duplicate upload."
  fi
  existing_upload_id="${upload_id}"
  existing_upload_state="$(python3 "${upload_contract_helper}" upload-state "${view_path}")"
  refreshed_errors="$(python3 "${upload_contract_helper}" upload-errors "${view_path}")"
  refreshed_classification="$(python3 "${upload_contract_helper}" upload-error-classification "${view_path}")"
  case "${existing_upload_state}" in
    AWAITING_UPLOAD|PROCESSING|COMPLETE) ;;
    FAILED)
      fail_if_unrecoverable_upload_error "${upload_id}" "${refreshed_errors}" "${refreshed_classification}"
      existing_upload_id=""
      existing_upload_state=""
      observed_upload_id=""
      ;;
    *)
      fail "Exact build upload '${upload_id}' returned unsupported state '${existing_upload_state:-unknown}'. Refusing to create a potentially duplicate upload."
      ;;
  esac
}

validate_existing_build_state() {
  local build_id="$1"
  local build_state="$2"
  case "${build_state}" in
    VALID|PROCESSING) ;;
    FAILED|INVALID)
      fail "Exact build '${build_id}' is in terminal invalid state '${build_state}'. Increment the immutable build number before retrying."
      ;;
    *)
      fail "Exact build '${build_id}' returned unsupported processing state '${build_state:-unknown}'."
      ;;
  esac
}

wait_for_build_id() {
  local build_id="$1"
  local timeout="$2"
  if ! asc_ci builds wait \
      --build-id "${build_id}" \
      --timeout "${timeout}" \
      --poll-interval "${INPUT_POLL_INTERVAL}" \
      --fail-on-invalid \
      --output json > "${tmp_dir}/build-wait.json"; then
    fail "Exact build '${build_id}' did not become valid within ${timeout}. The existing upload was preserved for retry."
  fi
  waited_build_state="$(python3 "${upload_contract_helper}" build-state "${tmp_dir}/build-wait.json")"
  [[ "${waited_build_state}" == "VALID" ]] || fail "Exact build '${build_id}' did not reach VALID (state: ${waited_build_state:-unknown})."
}

wait_for_reused_upload_build() {
  local upload_id="$1"
  local deadline
  local wait_attempt=0
  local upload_state
  local now
  local remaining_seconds
  deadline="$(( $(date +%s) + 900 ))"

  while true; do
    wait_attempt="$((wait_attempt + 1))"
    asc_ci builds uploads view \
      --id "${upload_id}" \
      --output json > "${tmp_dir}/upload-view-${wait_attempt}.json"
    upload_state="$(python3 "${upload_contract_helper}" upload-state "${tmp_dir}/upload-view-${wait_attempt}.json")"
    case "${upload_state}" in
      AWAITING_UPLOAD|PROCESSING|COMPLETE) ;;
      FAILED)
        fail "Exact build upload '${upload_id}' failed while waiting for processing. Inspect its App Store Connect errors and increment the build number if the binary is invalid."
        ;;
      *)
        fail "Exact build upload '${upload_id}' returned unsupported state '${upload_state:-unknown}' while waiting."
        ;;
    esac

    query_exact_resources "wait-${wait_attempt}"
    if [[ -n "${existing_build_id}" ]]; then
      validate_existing_build_state "${existing_build_id}" "${existing_build_state}"
      case "${existing_build_state}" in
        VALID) return 0 ;;
        PROCESSING) break ;;
      esac
    fi

    now="$(date +%s)"
    if [[ "${now}" -ge "${deadline}" ]]; then
      fail "Exact upload '${upload_id}' did not produce a build within 15m. The existing upload was preserved for retry."
    fi
    sleep "${INPUT_POLL_INTERVAL}"
  done

  now="$(date +%s)"
  remaining_seconds="$((deadline - now))"
  if [[ "${remaining_seconds}" -lt 1 ]]; then
    remaining_seconds=1
  fi
  wait_for_build_id "${existing_build_id}" "${remaining_seconds}s"
}

reuse_exact_resource() {
  if [[ -n "${existing_build_id}" ]]; then
    validate_existing_build_state "${existing_build_id}" "${existing_build_state}"

    if [[ "${existing_build_state}" == "PROCESSING" ]] && is_true "${INPUT_WAIT_FOR_PROCESSING}"; then
      wait_for_build_id "${existing_build_id}" 15m
    fi

    write_reused_outputs
    echo "Exact build already exists; upload reused."
    return 0
  fi

  if [[ -n "${existing_upload_id}" ]]; then
    case "${existing_upload_state}" in
      PROCESSING|COMPLETE) ;;
      AWAITING_UPLOAD)
        return 1
        ;;
      *)
        fail "Exact build upload '${existing_upload_id}' returned unsupported state '${existing_upload_state:-unknown}'."
        ;;
    esac

    if is_true "${INPUT_WAIT_FOR_PROCESSING}"; then
      wait_for_reused_upload_build "${existing_upload_id}"
    fi

    write_reused_outputs
    echo "Exact build upload already exists; upload reused."
    return 0
  fi

  return 1
}

# Reconcile repeatedly before mutation so an upload from a previous attempt has
# time to become visible through either the build or build-upload API.
existing_build_id=""
existing_build_state=""
existing_upload_id=""
existing_upload_state=""
failed_upload_ids=""
failed_upload_errors=""
failed_upload_classification="none"
observed_upload_id=""
for reconciliation_attempt in 1 2 3; do
  query_exact_resources "pre-${reconciliation_attempt}"
  if [[ -n "${existing_build_id}" ]]; then
    reuse_exact_resource
    exit 0
  fi
  if [[ -n "${existing_upload_id}" ]]; then
    if [[ -n "${observed_upload_id}" && "${observed_upload_id}" != "${existing_upload_id}" ]]; then
      fail "App Store Connect returned conflicting exact build upload IDs '${observed_upload_id}' and '${existing_upload_id}'."
    fi
    observed_upload_id="${existing_upload_id}"
  fi
  if [[ -n "${observed_upload_id}" && "${reconciliation_attempt}" -gt 1 ]]; then
    refresh_observed_upload "${observed_upload_id}" "pre-${reconciliation_attempt}"
  fi
  if [[ "${existing_upload_state}" == "PROCESSING" || "${existing_upload_state}" == "COMPLETE" ]]; then
    reuse_exact_resource
    exit 0
  fi
  fail_if_unrecoverable_upload_error "${failed_upload_ids}" "${failed_upload_errors}" "${failed_upload_classification}"
  if [[ -n "${existing_upload_id}" && "${existing_upload_state}" != "AWAITING_UPLOAD" ]]; then
    fail "Exact build upload '${existing_upload_id}' returned unsupported state '${existing_upload_state:-unknown}'. Refusing to create a potentially duplicate upload."
  fi
  if [[ "${reconciliation_attempt}" -lt 3 ]]; then
    sleep "${INPUT_POLL_INTERVAL}"
  fi
done

if [[ -n "${observed_upload_id}" ]]; then
  fail "Exact build upload '${observed_upload_id}' is still awaiting file upload after three reconciliation passes. Resolve the stale upload or increment the build number."
fi

upload_cmd=(
  asc
  builds
  upload
  --app "${INPUT_APP_ID}"
  --ipa "${resolved_ipa_path}"
  --version "${marketing_version}"
  --build-number "${build_number}"
)

if is_true "${INPUT_WAIT_FOR_PROCESSING}"; then
  upload_cmd+=(--wait --poll-interval "${INPUT_POLL_INTERVAL}")
fi

echo "Uploading IPA with asc"
upload_succeeded=true
if ! env \
    HOME="${asc_home}" \
    ASC_BYPASS_KEYCHAIN=1 \
    ASC_KEY_ID="${INPUT_ASC_KEY_ID}" \
    ASC_ISSUER_ID="${INPUT_ASC_ISSUER_ID}" \
    ASC_PRIVATE_KEY_PATH="${private_key_path}" \
    "${upload_cmd[@]}" > "${result_json_path}"; then
  upload_succeeded=false
fi

if [[ "${upload_succeeded}" != true ]]; then
  # The connection can fail after App Store Connect commits the upload. One
  # final exact read converts only a proven accepted upload/build to reuse.
  query_exact_resources "post-upload-failure"
  if [[ -n "${existing_build_id}" || "${existing_upload_state}" == "PROCESSING" || "${existing_upload_state}" == "COMPLETE" ]]; then
    reuse_exact_resource
    exit 0
  fi
  fail_if_unrecoverable_upload_error "${failed_upload_ids}" "${failed_upload_errors}" "${failed_upload_classification}"
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
    echo "outcome=uploaded"
  } >> "${GITHUB_OUTPUT}"
fi

echo "Upload completed."
