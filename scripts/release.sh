#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_non_empty "INPUT_APP_ID" "${INPUT_APP_ID:-}"
require_non_empty "INPUT_IPA_PATH" "${INPUT_IPA_PATH:-}"
require_non_empty "INPUT_RELEASE_NOTES_DIR" "${INPUT_RELEASE_NOTES_DIR:-}"
require_non_empty "INPUT_ASC_KEY_ID" "${INPUT_ASC_KEY_ID:-}"
require_non_empty "INPUT_ASC_ISSUER_ID" "${INPUT_ASC_ISSUER_ID:-}"
require_non_empty "INPUT_ASC_PRIVATE_KEY_B64" "${INPUT_ASC_PRIVATE_KEY_B64:-}"
require_non_empty "INPUT_SUBMIT_FOR_REVIEW" "${INPUT_SUBMIT_FOR_REVIEW:-}"
require_non_empty "INPUT_RELEASE_TYPE" "${INPUT_RELEASE_TYPE:-}"
require_non_empty "INPUT_PROCESSING_TIMEOUT" "${INPUT_PROCESSING_TIMEOUT:-}"
require_non_empty "INPUT_POLL_INTERVAL" "${INPUT_POLL_INTERVAL:-}"
require_non_empty "INPUT_ASC_VERSION" "${INPUT_ASC_VERSION:-}"

echo "::add-mask::${INPUT_ASC_KEY_ID}"
echo "::add-mask::${INPUT_ASC_ISSUER_ID}"
echo "::add-mask::${INPUT_ASC_PRIVATE_KEY_B64}"

submit_for_review_input="$(printf '%s' "${INPUT_SUBMIT_FOR_REVIEW}" | tr '[:upper:]' '[:lower:]')"
case "${submit_for_review_input}" in
  true|1|yes|on) submit_for_review=true ;;
  false|0|no|off) submit_for_review=false ;;
  *) fail "submit_for_review must be true or false" ;;
esac

case "${INPUT_RELEASE_TYPE}" in
  MANUAL|AFTER_APPROVAL) ;;
  *) fail "release_type must be MANUAL or AFTER_APPROVAL" ;;
esac

ipa_path="${INPUT_IPA_PATH//\$\{\{ runner.temp \}\}/${RUNNER_TEMP:-/tmp}}"
release_notes_dir="${INPUT_RELEASE_NOTES_DIR//\$\{\{ runner.temp \}\}/${RUNNER_TEMP:-/tmp}}"
[[ -f "${ipa_path}" ]] || fail "IPA path not found: ${ipa_path}"
[[ -d "${release_notes_dir}" ]] || fail "Store Release Notes directory not found: ${release_notes_dir}"

for command in asc jq python3; do
  command -v "${command}" >/dev/null 2>&1 || fail "${command} is required but was not found in PATH"
done

contract_helper="${SCRIPT_DIR}/lib/release_contract.py"
identity_json="$(python3 "${contract_helper}" ipa-identity "${ipa_path}")"
# Validate all deterministic note constraints before authentication or mutation.
notes_json="$(python3 "${contract_helper}" validate-notes "${release_notes_dir}")"

bundle_id="$(jq -r '.bundle_id' <<< "${identity_json}")"
marketing_version="$(jq -r '.marketing_version' <<< "${identity_json}")"
build_number="$(jq -r '.build_number' <<< "${identity_json}")"

runner_temp="${RUNNER_TEMP:-/tmp}"
tmp_dir="$(mktemp -d "${runner_temp}/releasekit-ios-release.XXXXXX")"
private_key_path="${tmp_dir}/AuthKey.p8"
asc_home="${tmp_dir}/asc-home"
mkdir -p "${asc_home}"

cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! prepare_private_key_file "${INPUT_ASC_PRIVATE_KEY_B64}" "${private_key_path}" "${tmp_dir}"; then
  fail "Invalid ASC private key content. Expected base64-encoded .p8 key."
fi
chmod 600 "${private_key_path}"
while IFS= read -r private_key_line || [[ -n "${private_key_line}" ]]; do
  if [[ -n "${private_key_line}" ]]; then
    echo "::add-mask::${private_key_line}"
  fi
done < "${private_key_path}"

asc_ci() {
  env \
    HOME="${asc_home}" \
    ASC_BYPASS_KEYCHAIN=1 \
    ASC_PROFILE="releasekit-ios-release-ci" \
    ASC_TELEMETRY_DISABLED=1 \
    asc "$@"
}

if ! HOME="${asc_home}" ASC_BYPASS_KEYCHAIN=1 ASC_TELEMETRY_DISABLED=1 asc auth login \
    --bypass-keychain \
    --name "releasekit-ios-release-ci" \
    --key-id "${INPUT_ASC_KEY_ID}" \
    --issuer-id "${INPUT_ASC_ISSUER_ID}" \
    --private-key "${private_key_path}" \
    --network >/dev/null 2>&1; then
  fail "asc authentication failed. Check the App Store Connect credentials and API access."
fi

if ! asc_ci capabilities \
    --area release \
    --status cli-supported \
    --output json > "${tmp_dir}/capabilities.json"; then
  fail "The selected asc version cannot inspect its App Store release capabilities."
fi
if ! jq -e '[.. | objects | select(.area? == "release" and .status? == "cli-supported")] | length >= 2' \
    "${tmp_dir}/capabilities.json" >/dev/null; then
  fail "The selected asc version does not expose the required App Store release and readiness capabilities."
fi

if ! asc_ci account status --app "${INPUT_APP_ID}" --output json > "${tmp_dir}/account.json"; then
  fail "asc capability check failed. The API key must be able to manage this app's versions and submissions."
fi
if ! jq -e '
  .summary.errorCount == 0
  and (.summary.health == "green" or .summary.health == "yellow")
  and any(.checks[]?; .name == "authentication" and (.status == "ok" or .status == "warn"))
  and any(.checks[]?; .name == "api_access" and .status == "ok")
' "${tmp_dir}/account.json" >/dev/null; then
  fail "asc account capability check reported unhealthy authentication or app access."
fi

asc_ci apps view --id "${INPUT_APP_ID}" --output json > "${tmp_dir}/app.json"
remote_bundle_id="$(jq -r '.data.attributes.bundleId // .bundleId // empty' "${tmp_dir}/app.json")"
[[ -n "${remote_bundle_id}" ]] || fail "Unable to read the approved app bundle identifier from App Store Connect."
if [[ "${remote_bundle_id}" != "${bundle_id}" ]]; then
  fail "Bundle ID mismatch. IPA has '${bundle_id}', App Store Connect app has '${remote_bundle_id}'."
fi

if ! asc_ci builds info \
    --app "${INPUT_APP_ID}" \
    --build-number "${build_number}" \
    --version "${marketing_version}" \
    --platform IOS \
    --output json > "${tmp_dir}/build.json"; then
  fail "No unique App Store Connect build matches IPA version '${marketing_version}' and build '${build_number}'. Retry after the upload is visible."
fi

build_id="$(jq -r '.data.id // .id // empty' "${tmp_dir}/build.json")"
build_state="$(jq -r '.data.attributes.processingState // .processingState // empty' "${tmp_dir}/build.json")"
[[ -n "${build_id}" ]] || fail "asc did not return a processed build resource ID for the exact IPA identity."

case "${build_state}" in
  VALID) ;;
  FAILED|INVALID) fail "Exact build '${build_id}' is in terminal invalid state '${build_state}'." ;;
  PROCESSING|"")
    if ! asc_ci builds wait \
        --build-id "${build_id}" \
        --timeout "${INPUT_PROCESSING_TIMEOUT}" \
        --poll-interval "${INPUT_POLL_INTERVAL}" \
        --fail-on-invalid \
        --output json > "${tmp_dir}/build-wait.json"; then
      asc_ci builds info --build-id "${build_id}" --output json > "${tmp_dir}/build-after-wait.json" || true
      build_state="$(jq -r '.data.attributes.processingState // .processingState // empty' "${tmp_dir}/build-after-wait.json" 2>/dev/null || true)"
      if [[ "${build_state}" == "FAILED" || "${build_state}" == "INVALID" ]]; then
        fail "Exact build '${build_id}' reached terminal invalid state '${build_state}'."
      fi
      fail "Timed out waiting for exact build '${build_id}' to become VALID. The upload and partial App Store state were preserved; retry this release action."
    fi
    build_state="$(jq -r '.data.attributes.processingState // .processingState // empty' "${tmp_dir}/build-wait.json")"
    [[ "${build_state}" == "VALID" ]] || fail "Exact build '${build_id}' did not reach VALID (state: ${build_state:-unknown})."
    ;;
  *) fail "Exact build '${build_id}' returned unsupported processing state '${build_state}'." ;;
esac

asc_ci versions list \
  --app "${INPUT_APP_ID}" \
  --version "${marketing_version}" \
  --platform IOS \
  --output json > "${tmp_dir}/versions.json"
version_count="$(jq '[.data[]?] | length' "${tmp_dir}/versions.json")"
if [[ "${version_count}" -gt 1 ]]; then
  fail "App Store Connect returned multiple iOS versions matching '${marketing_version}'."
elif [[ "${version_count}" -eq 0 ]]; then
  asc_ci versions create \
    --app "${INPUT_APP_ID}" \
    --version "${marketing_version}" \
    --platform IOS \
    --release-type "${INPUT_RELEASE_TYPE}" \
    --output json > "${tmp_dir}/version-created.json"
  app_store_version_id="$(jq -r '.data.id // .id // empty' "${tmp_dir}/version-created.json")"
else
  app_store_version_id="$(jq -r '.data[0].id // empty' "${tmp_dir}/versions.json")"
fi
[[ -n "${app_store_version_id}" ]] || fail "Unable to resolve the matching App Store version resource ID."

asc_ci versions view \
  --version-id "${app_store_version_id}" \
  --include-build \
  --include-submission \
  --output json > "${tmp_dir}/version.json"
asc_ci versions list \
  --app "${INPUT_APP_ID}" \
  --version "${marketing_version}" \
  --platform IOS \
  --output json > "${tmp_dir}/version-current.json"
version_state="$(jq -r --arg id "${app_store_version_id}" '.data[] | select(.id == $id) | .attributes.appStoreState // empty' "${tmp_dir}/version-current.json")"
remote_release_type="$(jq -r --arg id "${app_store_version_id}" '.data[] | select(.id == $id) | .attributes.releaseType // empty' "${tmp_dir}/version-current.json")"
attached_build_id="$(jq -r '
  (.buildId // empty),
  (.data.relationships.build.data.id // empty),
  (.included[]? | select(.type == "builds") | .id)
' "${tmp_dir}/version.json" | head -n 1)"

asc_ci localizations list \
  --version "${app_store_version_id}" \
  --paginate \
  --output json > "${tmp_dir}/localizations.json"
enabled_locales_json="$(jq -c '[.data[]?.attributes.locale] | sort' "${tmp_dir}/localizations.json")"
notes_json="$(python3 "${contract_helper}" validate-notes "${release_notes_dir}" "${enabled_locales_json}")"

state_is_editable=false
if [[ "${version_state}" == "PREPARE_FOR_SUBMISSION" ]]; then
  state_is_editable=true
fi

localization_matches=true
while IFS= read -r locale; do
  requested_note="$(jq -r --arg locale "${locale}" '.notes[$locale]' <<< "${notes_json}")"
  remote_note="$(jq -r --arg locale "${locale}" '.data[] | select(.attributes.locale == $locale) | .attributes.whatsNew // ""' "${tmp_dir}/localizations.json")"
  if [[ "${remote_note}" != "${requested_note}" ]]; then
    localization_matches=false
    if [[ "${state_is_editable}" == true ]]; then
      asc_ci localizations update \
        --version "${app_store_version_id}" \
        --locale "${locale}" \
        --whats-new "${requested_note}" \
        --output json > /dev/null
    fi
  fi
done < <(jq -r '.locales[]' <<< "${notes_json}")

if [[ "${state_is_editable}" == true ]]; then
  if [[ "${remote_release_type}" != "${INPUT_RELEASE_TYPE}" ]]; then
    asc_ci versions update \
      --version-id "${app_store_version_id}" \
      --release-type "${INPUT_RELEASE_TYPE}" \
      --output json > /dev/null
  fi
  if [[ "${attached_build_id}" != "${build_id}" ]]; then
    asc_ci versions attach-build \
      --version-id "${app_store_version_id}" \
      --build-id "${build_id}" \
      --output json > /dev/null
  fi

  asc_ci versions view \
    --version-id "${app_store_version_id}" \
    --include-build \
    --include-submission \
    --output json > "${tmp_dir}/version-reconciled.json"
  asc_ci versions list \
    --app "${INPUT_APP_ID}" \
    --version "${marketing_version}" \
    --platform IOS \
    --output json > "${tmp_dir}/version-list-reconciled.json"
  reconciled_release_type="$(jq -r --arg id "${app_store_version_id}" '.data[] | select(.id == $id) | .attributes.releaseType // empty' "${tmp_dir}/version-list-reconciled.json")"
  reconciled_build_id="$(jq -r '
    (.buildId // empty),
    (.data.relationships.build.data.id // empty),
    (.included[]? | select(.type == "builds") | .id)
  ' "${tmp_dir}/version-reconciled.json" | head -n 1)"
  if [[ "${reconciled_release_type}" != "${INPUT_RELEASE_TYPE}" || "${reconciled_build_id}" != "${build_id}" ]]; then
    fail "App Store version did not reconcile to the requested release policy and exact build. Prepared state was preserved for retry."
  fi

  asc_ci localizations list \
    --version "${app_store_version_id}" \
    --paginate \
    --output json > "${tmp_dir}/localizations-reconciled.json"
  while IFS= read -r locale; do
    requested_note="$(jq -r --arg locale "${locale}" '.notes[$locale]' <<< "${notes_json}")"
    reconciled_note="$(jq -r --arg locale "${locale}" '.data[] | select(.attributes.locale == $locale) | .attributes.whatsNew // ""' "${tmp_dir}/localizations-reconciled.json")"
    if [[ "${reconciled_note}" != "${requested_note}" ]]; then
      fail "Store Release Note for '${locale}' did not reconcile to the requested content. Prepared state was preserved for retry."
    fi
  done < <(jq -r '.locales[]' <<< "${notes_json}")
elif [[ "${remote_release_type}" != "${INPUT_RELEASE_TYPE}" || "${attached_build_id}" != "${build_id}" || "${localization_matches}" != true ]]; then
  fail "Matching App Store version is non-editable and conflicts with the requested release policy, exact build, or Store Release Notes. No state was changed."
fi

submission_id=""
submission_state=""
submission_state_is_accepted() {
  case "$1" in
    WAITING_FOR_REVIEW|IN_REVIEW|COMPLETING|COMPLETE) return 0 ;;
    *) return 1 ;;
  esac
}

find_matching_submission() {
  asc_ci review submissions-list \
    --global \
    --app "${INPUT_APP_ID}" \
    --platform IOS \
    --include items \
    --item-fields appStoreVersion,state \
    --paginate \
    --output json > "${tmp_dir}/submissions.json"
  jq -r --arg version_id "${app_store_version_id}" '
    [.included[]?
      | select(.type == "reviewSubmissionItems")
      | select(.relationships.appStoreVersion.data.id == $version_id)
      | .id] as $item_ids
    | .data[]?
    | select(any(.relationships.items.data[]?; .id as $id | $item_ids | index($id)))
    | [.id, (.attributes.state // "")]
    | @tsv
  ' "${tmp_dir}/submissions.json" | head -n 1
}

if [[ "${submit_for_review}" == true || "${state_is_editable}" != true ]]; then
  matching_submission="$(find_matching_submission)"
  if [[ -n "${matching_submission}" ]]; then
    IFS=$'\t' read -r submission_id submission_state <<< "${matching_submission}"
  fi
fi

if [[ "${state_is_editable}" != true ]]; then
  if [[ -z "${submission_id}" || -z "${submission_state}" || "${submission_state}" == "READY_FOR_REVIEW" ]]; then
    fail "Matching App Store version is non-editable but no matching accepted review submission was found. No state was changed."
  fi
  if ! submission_state_is_accepted "${submission_state}"; then
    fail "Matching review submission state '${submission_state}' is not an accepted state. No state was changed."
  fi
elif [[ "${submit_for_review}" == true ]]; then
  if ! asc_ci validate \
      --app "${INPUT_APP_ID}" \
      --version-id "${app_store_version_id}" \
      --platform IOS \
      --output json > "${tmp_dir}/validation.json"; then
    fail "App Store readiness validation failed. Prepared state was preserved; resolve the reported blockers and retry."
  fi

  if [[ -z "${submission_id}" ]]; then
    asc_ci review submissions-create \
      --app "${INPUT_APP_ID}" \
      --platform IOS \
      --output json > "${tmp_dir}/submission-created.json"
    submission_id="$(jq -r '.data.id // .id // empty' "${tmp_dir}/submission-created.json")"
    [[ -n "${submission_id}" ]] || fail "asc did not return a review submission ID."
    asc_ci review items add \
      --submission "${submission_id}" \
      --item-type appStoreVersions \
      --item-id "${app_store_version_id}" \
      --output json > /dev/null
    submission_state="READY_FOR_REVIEW"
  fi

  if [[ "${submission_state}" == "READY_FOR_REVIEW" ]]; then
    asc_ci review submissions-submit \
      --id "${submission_id}" \
      --confirm \
      --output json > "${tmp_dir}/submission-submit.json"
  fi

  asc_ci review submissions-get \
    --id "${submission_id}" \
    --output json > "${tmp_dir}/submission.json"
  submission_state="$(jq -r '.data.attributes.state // .state // empty' "${tmp_dir}/submission.json")"
  if ! submission_state_is_accepted "${submission_state}"; then
    fail "Review submission state '${submission_state:-unknown}' is not an accepted state. Prepared state was preserved for retry."
  fi
else
  if ! asc_ci validate \
      --app "${INPUT_APP_ID}" \
      --version-id "${app_store_version_id}" \
      --platform IOS \
      --output json > "${tmp_dir}/validation.json"; then
    fail "App Store readiness validation failed. Prepared state was preserved; resolve the reported blockers and retry."
  fi
fi

app_store_connect_url="https://appstoreconnect.apple.com/apps/${INPUT_APP_ID}/distribution"
if [[ "${submit_for_review}" == true || "${state_is_editable}" != true ]]; then
  result_status="submitted"
  submitted=true
else
  result_status="prepared"
  submitted=false
fi

result_json="$(jq -cn \
  --arg status "${result_status}" \
  --arg app_id "${INPUT_APP_ID}" \
  --arg bundle_id "${bundle_id}" \
  --arg marketing_version "${marketing_version}" \
  --arg build_number "${build_number}" \
  --arg app_store_version_id "${app_store_version_id}" \
  --arg build_id "${build_id}" \
  --arg submission_id "${submission_id}" \
  --arg submission_state "${submission_state}" \
  --arg release_type "${INPUT_RELEASE_TYPE}" \
  --arg app_store_connect_url "${app_store_connect_url}" \
  --argjson submitted "${submitted}" \
  '{status: $status, submitted: $submitted, appId: $app_id, bundleId: $bundle_id, marketingVersion: $marketing_version, buildNumber: $build_number, appStoreVersionId: $app_store_version_id, buildId: $build_id, submissionId: $submission_id, submissionState: $submission_state, releaseType: $release_type, appStoreConnectUrl: $app_store_connect_url}')"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "bundle_id=${bundle_id}"
    echo "marketing_version=${marketing_version}"
    echo "build_number=${build_number}"
    echo "app_store_version_id=${app_store_version_id}"
    echo "build_id=${build_id}"
    echo "submission_id=${submission_id}"
    echo "submission_state=${submission_state}"
    echo "app_store_connect_url=${app_store_connect_url}"
    echo "result_json=${result_json}"
  } >> "${GITHUB_OUTPUT}"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### App Store update ${result_status}"
    echo
    echo "- Version: \`${marketing_version}\` (build \`${build_number}\`)"
    echo "- Release policy: \`${INPUT_RELEASE_TYPE}\`"
    if [[ "${submitted}" == true ]]; then
      echo "- App Review submission: \`${submission_state}\`"
      echo "- Availability: releases according to \`${INPUT_RELEASE_TYPE}\` after App Review approval; this job does not claim the update is public yet."
    else
      echo "- Submission: not requested; the update remains prepared only."
    fi
    echo "- App Store Connect: ${app_store_connect_url}"
  } >> "${GITHUB_STEP_SUMMARY}"
fi

echo "App Store update ${result_status}."
