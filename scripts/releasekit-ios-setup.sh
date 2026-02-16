#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLI_VERSION="0.4.0"

COMMAND="wizard"
INTERACTIVE=1
WRITE_WORKFLOWS=0
FORCE=0
VERBOSE=0

REPO=""
REPO_DIR=""
WORKSPACE=""
SCHEME=""
BUNDLE_ID=""
TEAM_ID=""
APP_ID=""
ASC_KEY_ID=""
ASC_ISSUER_ID=""
P8_PATH=""
ASC_PRIVATE_KEY_B64=""
RUNNER_LABEL="macos-14"
ACTION_REF="main"

GH_AVAILABLE=0
GH_AUTHENTICATED=0
GITHUB_SYNC_STATUS="manual"
WORKFLOWS_STATUS="not requested"

TMP_DIR=""
ASC_TMP_P8_PATH=""
ASC_AUTH_HOME=""
ASC_AUTH_READY=0
ASC_AUTH_PROFILE_NAME="ReleaseKit-iOS Setup"

normalize_truthy_flag() {
  local value="${1:-}"
  value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  case "${value}" in
    1|true|yes|y|on)
      printf '1\n'
      ;;
    *)
      printf '0\n'
      ;;
  esac
}

VERBOSE="$(normalize_truthy_flag "${RELEASEKIT_IOS_SETUP_DEBUG:-0}")"

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} [subcommand] [options]

Subcommands:
  wizard     Guided step-by-step setup (default)
  check      Non-mutating audit of repo secrets/variables/workflows
  apply      Non-interactive setup using flags
  doctor     Diagnose local prerequisites and context detection
  version    Print CLI version

Core options:
  --repo <owner/repo>            GitHub repository (optional; prompted only when needed)
  --repo-dir <path>              Local checkout path used when writing/checking workflows
  --workspace <path>             Xcode workspace path
  --scheme <name>                Xcode scheme
  --bundle-id <id>               App bundle identifier
  --team-id <id>                 Apple Team ID
  --app-id <id>                  App Store Connect app ID (auto-resolved when possible)

ASC auth options:
  --asc-key-id <id>              App Store Connect API key ID
  --asc-issuer-id <id>           App Store Connect issuer ID
  --p8-path <path>               Path to AuthKey_XXXXXX.p8
  --p8-b64 <value>               Base64-encoded .p8 content

Workflow generation:
  --write-workflows              Generate ios-build.yml and ios-deploy.yml from templates
  --runner-label <label>         Runner label in generated workflows (default: macos-14)
  --force                        Overwrite existing generated workflow files

Mode and compatibility:
  --check                        Compatibility alias for check mode
  --non-interactive              Disable prompts (same as apply behavior)
  --verbose                      Print detailed debug logs (or set RELEASEKIT_IOS_SETUP_DEBUG=1)
  -h, --help                     Show this help

Examples:
  ${SCRIPT_NAME} wizard
  ${SCRIPT_NAME} check --repo owner/repo
  ${SCRIPT_NAME} apply --repo owner/repo --workspace ios/App.xcworkspace --scheme App \\
    --bundle-id com.example.app --team-id TEAMID123 --app-id 123456789 \\
    --asc-key-id KEYID123 --asc-issuer-id ISSUER_UUID --p8-path ~/AuthKey_KEYID123.p8
USAGE
}

log() {
  local section="$1"
  local message="$2"
  printf '[%s] %s\n' "${section}" "${message}"
}

log_debug() {
  local message="$1"
  if [[ "${VERBOSE}" -eq 1 ]]; then
    printf '[debug] %s\n' "${message}" >&2
  fi
}

die() {
  local message="$1"
  printf '[error] %s\n' "${message}" >&2
  exit 1
}

install_hint() {
  local cmd="$1"
  case "${cmd}" in
    gh)
      printf 'Install GitHub CLI: brew install gh\n'
      ;;
    asc)
      printf 'Install ASC CLI: brew tap rudrankriyam/tap && brew install asc\n'
      ;;
    jq)
      printf 'Install jq: brew install jq\n'
      ;;
    xcodebuild)
      printf 'Install Xcode and command line tools (xcode-select --install).\n'
      ;;
    base64)
      printf 'base64 should be available on macOS by default.\n'
      ;;
    *)
      printf 'Install missing dependency: %s\n' "${cmd}"
      ;;
  esac
}

mask_value() {
  local value="$1"
  if [[ -n "${GITHUB_ACTIONS:-}" && -n "${value}" ]]; then
    printf '::add-mask::%s\n' "${value}"
  fi
}

decode_base64_to_stdout() {
  if printf '%s' "dGVzdA==" | base64 --decode >/dev/null 2>&1; then
    base64 --decode
  else
    base64 -D
  fi
}

is_valid_base64() {
  local value="$1"
  [[ -n "${value}" ]] || return 1
  printf '%s' "${value}" | decode_base64_to_stdout >/dev/null 2>&1
}

encode_file_base64() {
  local file_path="$1"
  base64 < "${file_path}" | tr -d '\n'
}

validate_repo_value() {
  local repo_value="$1"
  [[ -n "${repo_value}" && "${repo_value}" =~ ^[^/]+/[^/]+$ ]]
}

prompt_yes_no() {
  local prompt_label="$1"
  local default_value="${2:-y}"
  local input=""

  while true; do
    if [[ "${default_value}" == "y" ]]; then
      read -r -p "${prompt_label} [Y/n]: " input
      input="${input:-y}"
    else
      read -r -p "${prompt_label} [y/N]: " input
      input="${input:-n}"
    fi

    input="$(printf '%s' "${input}" | tr '[:upper:]' '[:lower:]')"
    case "${input}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) printf '[prompt] Please answer yes or no.\n' >&2 ;;
    esac
  done
}

prompt_value() {
  local var_name="$1"
  local prompt_label="$2"
  local default_value="${3:-}"
  local secret="${4:-0}"
  local required="${5:-1}"
  local current_value="${!var_name:-}"

  if [[ -n "${current_value}" ]]; then
    return 0
  fi

  while true; do
    local input=""
    if [[ -n "${default_value}" ]]; then
      if [[ "${secret}" == "1" ]]; then
        read -r -s -p "${prompt_label} [${default_value}]: " input
        echo
      else
        read -r -p "${prompt_label} [${default_value}]: " input
      fi
    else
      if [[ "${secret}" == "1" ]]; then
        read -r -s -p "${prompt_label}: " input
        echo
      else
        read -r -p "${prompt_label}: " input
      fi
    fi

    if [[ -z "${input}" && -n "${default_value}" ]]; then
      input="${default_value}"
    fi

    if [[ -n "${input}" ]]; then
      printf -v "${var_name}" '%s' "${input}"
      return 0
    fi

    if [[ "${required}" == "0" ]]; then
      return 0
    fi

    printf '[prompt] Value is required.\n' >&2
  done
}

confirm_checklist_step() {
  local prompt_label="$1"
  while ! prompt_yes_no "${prompt_label}" "y"; do
    printf '[guide] Complete the step first, then confirm to continue.\n'
  done
}

print_api_key_creation_guide() {
  local guide_ref="https://github.com/vinceglb/releasekit-ios/blob/main/docs/app-store-connect-api-key.md"
  if [[ -f "${ROOT_DIR}/docs/app-store-connect-api-key.md" ]]; then
    guide_ref="${ROOT_DIR}/docs/app-store-connect-api-key.md"
  fi

  cat <<GUIDE
[guide] Create an App Store Connect API key with Admin role:
  1) Open App Store Connect: https://appstoreconnect.apple.com/
  2) Users and Access > Integrations > App Store Connect API
  3) Generate API key (Role: Admin)
  4) Copy Key ID and Issuer ID
  5) Download AuthKey_*.p8 (one-time)

Detailed walkthrough with screenshot placeholders:
  ${guide_ref}
GUIDE
}

prepare_tmp_dir() {
  if [[ -z "${TMP_DIR}" ]]; then
    TMP_DIR="$(mktemp -d)"
  fi
}

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

asc_in_isolated_context() {
  # asc prioritizes repo-local ./.asc/config.json, so run from temp workdir.
  local workdir="${TMP_DIR}/asc-workdir"
  mkdir -p "${workdir}"
  log_debug "Running ASC command in isolated context (HOME=${ASC_AUTH_HOME}, cwd=${workdir}): $*"
  (
    cd "${workdir}"
    HOME="${ASC_AUTH_HOME}" ASC_BYPASS_KEYCHAIN=1 "$@"
  )
}

prepare_asc_key_path() {
  if [[ -n "${P8_PATH}" ]]; then
    ASC_TMP_P8_PATH="${P8_PATH}"
    log_debug "Using provided .p8 path: ${ASC_TMP_P8_PATH}"
    return 0
  fi

  if [[ -z "${ASC_PRIVATE_KEY_B64}" ]]; then
    return 1
  fi

  prepare_tmp_dir
  ASC_TMP_P8_PATH="${TMP_DIR}/AuthKey.p8"
  printf '%s' "${ASC_PRIVATE_KEY_B64}" | decode_base64_to_stdout > "${ASC_TMP_P8_PATH}" 2>/dev/null || return 1
  chmod 600 "${ASC_TMP_P8_PATH}"
  log_debug "Decoded base64 private key to temporary file: ${ASC_TMP_P8_PATH}"
  return 0
}

detect_current_github_repo() {
  if ! command -v git >/dev/null 2>&1; then
    return 1
  fi
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 1
  fi

  local remote=""
  remote="$(git config --get remote.origin.url || true)"
  [[ -n "${remote}" ]] || return 1

  remote="${remote%.git}"
  local repo=""

  case "${remote}" in
    git@github.com:*)
      repo="${remote#git@github.com:}"
      ;;
    https://github.com/*)
      repo="${remote#https://github.com/}"
      ;;
    http://github.com/*)
      repo="${remote#http://github.com/}"
      ;;
    ssh://git@github.com/*)
      repo="${remote#ssh://git@github.com/}"
      ;;
    ssh://github.com/*)
      repo="${remote#ssh://github.com/}"
      ;;
    *)
      return 1
      ;;
  esac

  if validate_repo_value "${repo}"; then
    printf '%s\n' "${repo}"
    return 0
  fi
  return 1
}

detect_git_root() {
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git rev-parse --show-toplevel
    return 0
  fi
  return 1
}

ensure_repo_access() {
  if ! gh repo view "${REPO}" --json nameWithOwner >/dev/null 2>&1; then
    die "Cannot access ${REPO}. Check repository name and permissions."
  fi
}

update_gh_status() {
  if command -v gh >/dev/null 2>&1; then
    GH_AVAILABLE=1
    if gh auth status >/dev/null 2>&1; then
      GH_AUTHENTICATED=1
    else
      GH_AUTHENTICATED=0
    fi
  else
    GH_AVAILABLE=0
    GH_AUTHENTICATED=0
  fi
}

check_required_dependencies() {
  local missing=0
  local cmd=""

  for cmd in asc jq base64 xcodebuild; do
    if command -v "${cmd}" >/dev/null 2>&1; then
      log done "Dependency found: ${cmd}"
    else
      log error "Missing dependency: ${cmd}"
      install_hint "${cmd}"
      missing=1
    fi
  done

  if command -v asc >/dev/null 2>&1; then
    log_debug "asc version: $(asc --version 2>/dev/null || echo 'unknown')"
  fi

  update_gh_status
  if [[ "${GH_AVAILABLE}" -eq 1 ]]; then
    if [[ "${GH_AUTHENTICATED}" -eq 1 ]]; then
      log done "GitHub CLI detected and authenticated"
    else
      log check "GitHub CLI detected but not authenticated (manual mode remains available)"
      log check "To enable direct repo sync: gh auth login"
    fi
  else
    log check "GitHub CLI not found (manual mode remains available)"
  fi

  return "${missing}"
}

detect_workspace_candidate() {
  local candidate=""

  candidate="$(find . -type d -name '*.xcworkspace' -not -path '*/Pods/*' -not -path '*/Carthage/*' | sed 's#^\./##' | sort | head -n 1 || true)"
  if [[ -n "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  return 1
}

list_schemes() {
  local workspace_path="$1"
  local schemes_json=""

  if ! schemes_json="$(xcodebuild -list -workspace "${workspace_path}" -json 2>/dev/null || true)"; then
    return 1
  fi

  if [[ -z "${schemes_json}" ]]; then
    return 1
  fi

  printf '%s' "${schemes_json}" | jq -r '(.workspace.schemes // .project.schemes // [])[]?' | sed '/^$/d'
}

detect_build_settings_value() {
  local key="$1"
  local workspace_path="$2"
  local scheme_name="$3"

  xcodebuild -showBuildSettings -workspace "${workspace_path}" -scheme "${scheme_name}" 2>/dev/null \
    | awk -F' = ' -v k="${key}" '$1 ~ k { print $2; exit }'
}

ensure_workspace() {
  if [[ -n "${WORKSPACE}" ]]; then
    return 0
  fi

  local candidate=""
  if candidate="$(detect_workspace_candidate)"; then
    if [[ "${INTERACTIVE}" -eq 1 ]]; then
      prompt_value WORKSPACE "Xcode workspace path" "${candidate}"
    else
      WORKSPACE="${candidate}"
      log done "Auto-detected workspace: ${WORKSPACE}"
    fi
  elif [[ "${INTERACTIVE}" -eq 1 ]]; then
    prompt_value WORKSPACE "Xcode workspace path"
  fi

  [[ -n "${WORKSPACE}" ]] || die "Missing workspace. Pass --workspace or run wizard in project root."
  [[ -e "${WORKSPACE}" ]] || die "Workspace path does not exist: ${WORKSPACE}"
}

ensure_scheme() {
  if [[ -n "${SCHEME}" ]]; then
    return 0
  fi

  local schemes_raw=""
  schemes_raw="$(list_schemes "${WORKSPACE}" || true)"

  if [[ -n "${schemes_raw}" ]]; then
    local scheme_count
    scheme_count="$(printf '%s\n' "${schemes_raw}" | wc -l | tr -d ' ')"

    if [[ "${scheme_count}" == "1" ]]; then
      SCHEME="$(printf '%s\n' "${schemes_raw}" | head -n 1)"
      log done "Auto-detected scheme: ${SCHEME}"
      return 0
    fi

    if [[ "${INTERACTIVE}" -eq 1 ]]; then
      log check "Detected multiple schemes:"
      local i=1
      while IFS= read -r scheme; do
        printf '  %d) %s\n' "${i}" "${scheme}"
        i=$((i + 1))
      done <<EOF_SCHEMES
${schemes_raw}
EOF_SCHEMES

      while true; do
        local pick=""
        read -r -p "Choose scheme number: " pick
        if [[ "${pick}" =~ ^[0-9]+$ ]]; then
          local chosen
          chosen="$(printf '%s\n' "${schemes_raw}" | sed -n "${pick}p" || true)"
          if [[ -n "${chosen}" ]]; then
            SCHEME="${chosen}"
            break
          fi
        fi
        printf '[prompt] Invalid selection.\n' >&2
      done
      return 0
    fi
  fi

  if [[ "${INTERACTIVE}" -eq 1 ]]; then
    prompt_value SCHEME "Xcode scheme"
  fi

  [[ -n "${SCHEME}" ]] || die "Missing scheme. Pass --scheme or run wizard interactively."
}

ensure_bundle_and_team() {
  local detected_bundle=""
  local detected_team=""

  detected_bundle="$(detect_build_settings_value "PRODUCT_BUNDLE_IDENTIFIER" "${WORKSPACE}" "${SCHEME}" || true)"
  detected_team="$(detect_build_settings_value "DEVELOPMENT_TEAM" "${WORKSPACE}" "${SCHEME}" || true)"

  if [[ -z "${BUNDLE_ID}" ]]; then
    if [[ "${INTERACTIVE}" -eq 1 ]]; then
      prompt_value BUNDLE_ID "Bundle ID" "${detected_bundle}" "0"
    else
      BUNDLE_ID="${detected_bundle}"
    fi
  fi

  if [[ -z "${TEAM_ID}" ]]; then
    if [[ "${INTERACTIVE}" -eq 1 ]]; then
      prompt_value TEAM_ID "Apple Team ID" "${detected_team}" "0"
    else
      TEAM_ID="${detected_team}"
    fi
  fi

  [[ -n "${BUNDLE_ID}" ]] || die "Missing bundle ID. Pass --bundle-id or provide it in wizard."
  [[ -n "${TEAM_ID}" ]] || die "Missing team ID. Pass --team-id or provide it in wizard."
}

collect_api_key_inputs() {
  if [[ -n "${ASC_KEY_ID}" && -n "${ASC_ISSUER_ID}" && ( -n "${P8_PATH}" || -n "${ASC_PRIVATE_KEY_B64}" ) ]]; then
    return 0
  fi

  if [[ "${INTERACTIVE}" -ne 1 ]]; then
    die "Missing ASC auth inputs. Provide --asc-key-id --asc-issuer-id and --p8-path (or --p8-b64)."
  fi

  if [[ -z "${ASC_KEY_ID}" && -z "${ASC_ISSUER_ID}" && -z "${P8_PATH}" && -z "${ASC_PRIVATE_KEY_B64}" ]]; then
    if ! prompt_yes_no "Do you already have an App Store Connect API key with Admin role?" "y"; then
      print_api_key_creation_guide
      confirm_checklist_step "Did you open Users and Access in App Store Connect?"
      confirm_checklist_step "Did you open Integrations > App Store Connect API?"
      confirm_checklist_step "Did you generate a new API key with role Admin?"
      confirm_checklist_step "Did you copy Key ID and Issuer ID?"
      confirm_checklist_step "Did you download the .p8 file?"
    fi
  fi

  prompt_value ASC_KEY_ID "ASC Key ID"
  prompt_value ASC_ISSUER_ID "ASC Issuer ID"

  if [[ -z "${P8_PATH}" && -z "${ASC_PRIVATE_KEY_B64}" ]]; then
    if prompt_yes_no "Provide a local .p8 file path (recommended)?" "y"; then
      prompt_value P8_PATH "Path to .p8 private key file"
    else
      prompt_value ASC_PRIVATE_KEY_B64 "ASC private key base64" "" "1"
    fi
  fi

  if [[ -n "${P8_PATH}" && ! -f "${P8_PATH}" ]]; then
    die "p8 file not found: ${P8_PATH}"
  fi

  if [[ -z "${ASC_PRIVATE_KEY_B64}" ]]; then
    log_debug "Encoding .p8 file to base64 for GitHub secret payload."
    ASC_PRIVATE_KEY_B64="$(encode_file_base64 "${P8_PATH}")"
  fi

  if ! is_valid_base64 "${ASC_PRIVATE_KEY_B64}"; then
    die "ASC private key is not valid base64"
  fi

  mask_value "${ASC_KEY_ID}"
  mask_value "${ASC_ISSUER_ID}"
  mask_value "${ASC_PRIVATE_KEY_B64}"
}

run_asc_auth_validate() {
  ensure_asc_temp_auth
  local err_file="${TMP_DIR}/asc-auth.err"
  local out_file="${TMP_DIR}/asc-auth.out"
  local status_verbose_out="${TMP_DIR}/asc-status-verbose.out"
  local status_verbose_err="${TMP_DIR}/asc-status-verbose.err"
  local doctor_out="${TMP_DIR}/asc-doctor.out"
  local doctor_err="${TMP_DIR}/asc-doctor.err"

  log_debug "Validating ASC auth via API probe: asc apps list --limit 1 --output json"
  if asc_in_isolated_context asc apps list --limit 1 --output json >"${out_file}" 2>"${err_file}"; then
    return 0
  fi

  if [[ "${VERBOSE}" -eq 1 ]]; then
    asc_in_isolated_context asc auth status --verbose >"${status_verbose_out}" 2>"${status_verbose_err}" || true
    asc_in_isolated_context asc auth doctor >"${doctor_out}" 2>"${doctor_err}" || true
  fi

  log error "ASC auth validation failed"
  sed 's/^/[asc] /' "${out_file}" >&2 || true
  sed 's/^/[asc] /' "${err_file}" >&2 || true
  if [[ "${VERBOSE}" -eq 1 ]]; then
    sed 's/^/[asc-debug-status] /' "${status_verbose_out}" >&2 || true
    sed 's/^/[asc-debug-status] /' "${status_verbose_err}" >&2 || true
    sed 's/^/[asc-debug-doctor] /' "${doctor_out}" >&2 || true
    sed 's/^/[asc-debug-doctor] /' "${doctor_err}" >&2 || true
  fi

  if grep -Eqi 'forbidden|unauthorized|permission' "${err_file}"; then
    die "ASC credentials were rejected. Confirm key/issuer/private key and ensure the API key role is Admin for cloud signing."
  fi

  die "Could not validate ASC credentials. Check key ID, issuer ID, and private key."
}

ensure_asc_temp_auth() {
  if [[ "${ASC_AUTH_READY}" -eq 1 ]]; then
    return 0
  fi

  prepare_tmp_dir
  [[ -n "${ASC_TMP_P8_PATH}" ]] || die "Missing ASC private key path for auth setup."

  ASC_AUTH_HOME="${TMP_DIR}/asc-home"
  mkdir -p "${ASC_AUTH_HOME}"
  if [[ -f ./.asc/config.json ]]; then
    log_debug "Detected repo-local ./.asc/config.json in current directory; isolated ASC context will ignore it."
  fi
  log_debug "Initializing temporary ASC auth profile in HOME=${ASC_AUTH_HOME}"

  local err_file="${TMP_DIR}/asc-login.err"
  if ! asc_in_isolated_context asc auth login \
      --bypass-keychain \
      --skip-validation \
      --name "${ASC_AUTH_PROFILE_NAME}" \
      --key-id "${ASC_KEY_ID}" \
      --issuer-id "${ASC_ISSUER_ID}" \
      --private-key "${ASC_TMP_P8_PATH}" > /dev/null 2>"${err_file}"; then
    log error "Failed to prepare temporary ASC auth profile"
    sed 's/^/[asc] /' "${err_file}" >&2 || true
    die "Could not initialize ASC authentication. Check key ID, issuer ID, and private key path."
  fi

  ASC_AUTH_READY=1
}

verify_asc_credentials() {
  prepare_tmp_dir
  if ! prepare_asc_key_path; then
    die "Could not prepare ASC private key file for validation"
  fi

  log check "Validating ASC credentials with asc API probe"
  run_asc_auth_validate
  log done "ASC credentials validated"
}

resolve_app_id_candidates() {
  local bundle_id="$1"
  local apps_json=""

  ensure_asc_temp_auth

  log_debug "Resolving App Store Connect app ID from bundle ID: ${bundle_id}"
  apps_json="$(asc_in_isolated_context asc apps list \
    --bundle-id "${bundle_id}" \
    --paginate \
    --output json 2>/dev/null || true)"

  if [[ -z "${apps_json}" ]]; then
    log_debug "Falling back to legacy 'asc apps' command for compatibility."
    apps_json="$(asc_in_isolated_context asc apps \
      --bundle-id "${bundle_id}" \
      --paginate \
      --output json 2>/dev/null || true)"
  fi

  [[ -n "${apps_json}" ]] || return 1
  if ! printf '%s' "${apps_json}" | jq -e . >/dev/null 2>&1; then
    log_debug "ASC apps response is not valid JSON; skipping automatic app ID resolution."
    log_debug "ASC apps raw output (first 240 chars): $(printf '%s' "${apps_json}" | head -c 240)"
    return 1
  fi

  printf '%s' "${apps_json}" | jq -r --arg bundle "${bundle_id}" '
    (if type == "array" then . else (.data // .apps // []) end)[]? as $app
    | ($app.attributes.bundleId // $app.bundleId // "") as $bundleId
    | select($bundleId == $bundle)
    | [($app.id // ""), ($app.attributes.name // $app.name // "Unknown"), $bundleId] | @tsv
  ' 2>/dev/null
}

ensure_app_id() {
  if [[ -n "${APP_ID}" ]]; then
    return 0
  fi

  log check "Resolving App Store Connect app ID for bundle '${BUNDLE_ID}'"
  local candidates=""
  candidates="$(resolve_app_id_candidates "${BUNDLE_ID}" || true)"

  if [[ -n "${candidates}" ]]; then
    local count
    count="$(printf '%s\n' "${candidates}" | sed '/^$/d' | wc -l | tr -d ' ')"

    if [[ "${count}" == "1" ]]; then
      APP_ID="$(printf '%s\n' "${candidates}" | head -n 1 | cut -f1)"
      log done "Resolved ASC app ID: ${APP_ID}"
      return 0
    fi

    if [[ "${INTERACTIVE}" -eq 1 ]]; then
      log check "Multiple apps matched bundle ID. Choose one:"
      local i=1
      while IFS=$'\t' read -r id name bundle; do
        printf '  %d) %s (%s) [bundle: %s]\n' "${i}" "${name}" "${id}" "${bundle}"
        i=$((i + 1))
      done <<EOF_APPS
${candidates}
EOF_APPS

      while true; do
        local pick=""
        read -r -p "Choose app number (or press Enter to type manually): " pick
        if [[ -z "${pick}" ]]; then
          break
        fi
        if [[ "${pick}" =~ ^[0-9]+$ ]]; then
          local selected
          selected="$(printf '%s\n' "${candidates}" | sed -n "${pick}p" || true)"
          if [[ -n "${selected}" ]]; then
            APP_ID="$(printf '%s' "${selected}" | cut -f1)"
            log done "Selected ASC app ID: ${APP_ID}"
            return 0
          fi
        fi
        printf '[prompt] Invalid selection.\n' >&2
      done
    fi
  fi

  if [[ "${INTERACTIVE}" -eq 1 ]]; then
    prompt_value APP_ID "App Store Connect app ID"
  fi

  [[ -n "${APP_ID}" ]] || die "Unable to resolve app ID automatically. Provide --app-id."
}

validate_input_combinations() {
  if [[ -n "${REPO}" ]] && ! validate_repo_value "${REPO}"; then
    die "--repo must be in owner/repo format"
  fi

  if [[ -n "${P8_PATH}" && -n "${ASC_PRIVATE_KEY_B64}" ]]; then
    die "Use either --p8-path or --p8-b64, not both"
  fi

  if [[ -n "${P8_PATH}" && ! -f "${P8_PATH}" ]]; then
    die "p8 file not found: ${P8_PATH}"
  fi

  if [[ -n "${ASC_PRIVATE_KEY_B64}" ]] && ! is_valid_base64 "${ASC_PRIVATE_KEY_B64}"; then
    die "--p8-b64 is not valid base64"
  fi
}

render_template() {
  local template_path="$1"
  local output_path="$2"

  cp "${template_path}" "${output_path}"

  local escaped_workspace escaped_scheme escaped_bundle_id escaped_team_id escaped_runner escaped_action_ref
  escaped_workspace="$(printf '%s' "${WORKSPACE}" | sed 's/[\/&]/\\&/g')"
  escaped_scheme="$(printf '%s' "${SCHEME}" | sed 's/[\/&]/\\&/g')"
  escaped_bundle_id="$(printf '%s' "${BUNDLE_ID}" | sed 's/[\/&]/\\&/g')"
  escaped_team_id="$(printf '%s' "${TEAM_ID}" | sed 's/[\/&]/\\&/g')"
  escaped_runner="$(printf '%s' "${RUNNER_LABEL}" | sed 's/[\/&]/\\&/g')"
  escaped_action_ref="$(printf '%s' "${ACTION_REF}" | sed 's/[\/&]/\\&/g')"

  sed -i.bak \
    -e "s/__WORKSPACE__/${escaped_workspace}/g" \
    -e "s/__SCHEME__/${escaped_scheme}/g" \
    -e "s/__BUNDLE_ID__/${escaped_bundle_id}/g" \
    -e "s/__TEAM_ID__/${escaped_team_id}/g" \
    -e "s/__RUNNER_LABEL__/${escaped_runner}/g" \
    -e "s/__ACTION_REF__/${escaped_action_ref}/g" \
    "${output_path}"
  rm -f "${output_path}.bak"
}

write_embedded_template() {
  local template_key="$1"
  local output_path="$2"

  case "${template_key}" in
    build)
      cat > "${output_path}" <<'EOF'
name: iOS Build

on:
  workflow_dispatch:
    inputs:
      wait_for_processing:
        description: Wait for App Store Connect processing before this workflow completes
        required: false
        type: boolean
        default: false
      asc_version:
        description: asc CLI version installed by the shared action
        required: false
        default: 0.28.8
  workflow_call:
    inputs:
      wait_for_processing:
        description: Wait for App Store Connect processing before this workflow completes
        required: false
        type: boolean
        default: false
      asc_version:
        description: asc CLI version installed by the shared action
        required: false
        type: string
        default: 0.28.8
    outputs:
      ipa-artifact-name:
        description: Uploaded IPA artifact name
        value: Marmalade.ipa

env:
  WORKSPACE: __WORKSPACE__
  SCHEME: __SCHEME__
  BUNDLE_ID: __BUNDLE_ID__
  TEAM_ID: __TEAM_ID__

jobs:
  build:
    runs-on: __RUNNER_LABEL__
    timeout-minutes: 60

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: ReleaseKit-iOS archive, export, and upload
        id: ios_upload
        uses: vinceglb/releasekit-ios@__ACTION_REF__
        with:
          workspace: ${{ env.WORKSPACE }}
          scheme: ${{ env.SCHEME }}
          app_id: ${{ vars.ASC_APP_ID }}
          bundle_id: ${{ env.BUNDLE_ID }}
          asc_key_id: ${{ secrets.ASC_KEY_ID }}
          asc_issuer_id: ${{ secrets.ASC_ISSUER_ID }}
          asc_private_key_b64: ${{ secrets.ASC_PRIVATE_KEY_B64 }}
          asc_team_id: ${{ secrets.ASC_TEAM_ID }}
          configuration: Release
          asc_version: ${{ inputs.asc_version }}
          wait_for_processing: ${{ inputs.wait_for_processing }}
          poll_interval: 30s

      - name: Upload IPA artifact
        uses: actions/upload-artifact@v4
        with:
          name: Marmalade.ipa
          path: ${{ steps.ios_upload.outputs.ipa_path }}
          if-no-files-found: error

      - name: Build summary
        run: |
          echo "## iOS Build Summary" >> "$GITHUB_STEP_SUMMARY"
          echo "" >> "$GITHUB_STEP_SUMMARY"
          echo "- **Archive Path**: \`${{ steps.ios_upload.outputs.archive_path }}\`" >> "$GITHUB_STEP_SUMMARY"
          echo "- **IPA Path**: \`${{ steps.ios_upload.outputs.ipa_path }}\`" >> "$GITHUB_STEP_SUMMARY"
          echo "- **ASC Upload ID**: \`${{ steps.ios_upload.outputs.upload_id }}\`" >> "$GITHUB_STEP_SUMMARY"
EOF
      ;;
    deploy)
      cat > "${output_path}" <<'EOF'
name: iOS Deploy

on:
  workflow_dispatch:
    inputs:
      destination:
        description: Where to deploy this build
        required: true
        default: testflight
        type: choice
        options:
          - testflight
          - appstore
      testflight_group:
        description: TestFlight group name (used only for destination=testflight)
        required: false
        default: Internal Testers
      submit_for_review:
        description: Submit App Store release for review
        required: false
        type: boolean
        default: false

jobs:
  build:
    uses: ./.github/workflows/ios-build.yml
    secrets: inherit

  deploy:
    runs-on: __RUNNER_LABEL__
    timeout-minutes: 60
    needs: build

    steps:
      - name: Install asc CLI
        run: |
          curl -fsSL https://raw.githubusercontent.com/rudrankriyam/App-Store-Connect-CLI/main/install.sh | bash
          echo "$HOME/.local/bin" >> "$GITHUB_PATH"

      - name: Configure ASC auth
        env:
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          ASC_PRIVATE_KEY_B64: ${{ secrets.ASC_PRIVATE_KEY_B64 }}
          ASC_BYPASS_KEYCHAIN: '1'
        run: |
          echo "$ASC_PRIVATE_KEY_B64" | base64 --decode > /tmp/AuthKey.p8
          chmod 600 /tmp/AuthKey.p8

          asc auth login --skip-validation --name "CI" \
            --key-id "$ASC_KEY_ID" \
            --issuer-id "$ASC_ISSUER_ID" \
            --private-key /tmp/AuthKey.p8 \
            --bypass-keychain

          rm /tmp/AuthKey.p8

      - name: Download IPA artifact
        uses: actions/download-artifact@v4
        with:
          name: Marmalade.ipa
          path: ./ipa

      - name: Resolve IPA path
        id: ipa
        run: |
          ipa_path=$(find ./ipa -type f -name "*.ipa" -print -quit)
          if [[ -z "$ipa_path" ]]; then
            echo "No IPA found in ./ipa"
            exit 1
          fi
          echo "path=$ipa_path" >> "$GITHUB_OUTPUT"

      - name: Deploy to TestFlight
        if: ${{ inputs.destination == 'testflight' }}
        env:
          ASC_BYPASS_KEYCHAIN: '1'
        run: |
          asc publish testflight \
            --app "${{ vars.ASC_APP_ID }}" \
            --ipa "${{ steps.ipa.outputs.path }}" \
            --group "${{ inputs.testflight_group }}" \
            --notify \
            --wait \
            --timeout 30m

      - name: Deploy to App Store
        if: ${{ inputs.destination == 'appstore' }}
        env:
          ASC_BYPASS_KEYCHAIN: '1'
        run: |
          submit_flag=""
          if [[ "${{ inputs.submit_for_review }}" == "true" ]]; then
            submit_flag="--submit --confirm"
          fi

          asc publish appstore \
            --app "${{ vars.ASC_APP_ID }}" \
            --ipa "${{ steps.ipa.outputs.path }}" \
            $submit_flag \
            --wait \
            --timeout 30m

      - name: Deploy summary
        run: |
          echo "## iOS Deploy Summary" >> "$GITHUB_STEP_SUMMARY"
          echo "" >> "$GITHUB_STEP_SUMMARY"
          echo "- **Destination**: ${{ inputs.destination }}" >> "$GITHUB_STEP_SUMMARY"
          echo "- **Artifact**: \`${{ steps.ipa.outputs.path }}\`" >> "$GITHUB_STEP_SUMMARY"
          echo "- **ASC App ID**: \`${{ vars.ASC_APP_ID }}\`" >> "$GITHUB_STEP_SUMMARY"
EOF
      ;;
    *)
      die "Unknown embedded template key: ${template_key}"
      ;;
  esac
}

write_template_with_fallback() {
  local template_key="$1"
  local template_path="$2"
  local output_path="$3"

  if [[ -f "${template_path}" ]]; then
    render_template "${template_path}" "${output_path}"
    return 0
  fi

  log check "Template file not found at ${template_path}. Using embedded '${template_key}' template."
  write_embedded_template "${template_key}" "${output_path}"

  local escaped_workspace escaped_scheme escaped_bundle_id escaped_team_id escaped_runner escaped_action_ref
  escaped_workspace="$(printf '%s' "${WORKSPACE}" | sed 's/[\/&]/\\&/g')"
  escaped_scheme="$(printf '%s' "${SCHEME}" | sed 's/[\/&]/\\&/g')"
  escaped_bundle_id="$(printf '%s' "${BUNDLE_ID}" | sed 's/[\/&]/\\&/g')"
  escaped_team_id="$(printf '%s' "${TEAM_ID}" | sed 's/[\/&]/\\&/g')"
  escaped_runner="$(printf '%s' "${RUNNER_LABEL}" | sed 's/[\/&]/\\&/g')"
  escaped_action_ref="$(printf '%s' "${ACTION_REF}" | sed 's/[\/&]/\\&/g')"

  sed -i.bak \
    -e "s/__WORKSPACE__/${escaped_workspace}/g" \
    -e "s/__SCHEME__/${escaped_scheme}/g" \
    -e "s/__BUNDLE_ID__/${escaped_bundle_id}/g" \
    -e "s/__TEAM_ID__/${escaped_team_id}/g" \
    -e "s/__RUNNER_LABEL__/${escaped_runner}/g" \
    -e "s/__ACTION_REF__/${escaped_action_ref}/g" \
    "${output_path}"
  rm -f "${output_path}.bak"
}

write_workflow_files() {
  local target_dir="$1"
  local workflow_dir="${target_dir}/.github/workflows"
  local build_tpl="${ROOT_DIR}/templates/workflows/ios-build.yml.tpl"
  local deploy_tpl="${ROOT_DIR}/templates/workflows/ios-deploy.yml.tpl"
  local build_out="${workflow_dir}/ios-build.yml"
  local deploy_out="${workflow_dir}/ios-deploy.yml"

  mkdir -p "${workflow_dir}"

  if [[ -f "${build_out}" && "${FORCE}" -ne 1 ]]; then
    die "${build_out} already exists (use --force to overwrite)"
  fi
  if [[ -f "${deploy_out}" && "${FORCE}" -ne 1 ]]; then
    die "${deploy_out} already exists (use --force to overwrite)"
  fi

  write_template_with_fallback "build" "${build_tpl}" "${build_out}"
  write_template_with_fallback "deploy" "${deploy_tpl}" "${deploy_out}"

  log write "Wrote ${build_out}"
  log write "Wrote ${deploy_out}"
  WORKFLOWS_STATUS="written"
}

check_secret_exists() {
  local repo="$1"
  local name="$2"
  gh secret list --repo "${repo}" --json name --jq '.[].name' 2>/dev/null | grep -Fxq "${name}"
}

check_variable_exists() {
  local repo="$1"
  local name="$2"
  gh variable list --repo "${repo}" --json name --jq '.[].name' 2>/dev/null | grep -Fxq "${name}"
}

set_repo_secret() {
  local name="$1"
  local value="$2"

  printf '%s' "${value}" | gh secret set "${name}" --repo "${REPO}" --body - >/dev/null
  log set "Configured secret ${name}"
}

set_repo_variable() {
  local name="$1"
  local value="$2"

  gh variable set "${name}" --repo "${REPO}" --body "${value}" >/dev/null
  log set "Configured variable ${name}"
}

print_manual_values() {
  cat <<VALUES

[done] Configure these in your GitHub repository manually:

Secrets:
  ASC_KEY_ID=${ASC_KEY_ID}
  ASC_ISSUER_ID=${ASC_ISSUER_ID}
  ASC_PRIVATE_KEY_B64=${ASC_PRIVATE_KEY_B64}
  ASC_TEAM_ID=${TEAM_ID}

Variable:
  ASC_APP_ID=${APP_ID}

VALUES
}

ensure_repo_for_sync() {
  if [[ -z "${REPO}" ]]; then
    local detected_repo=""
    detected_repo="$(detect_current_github_repo || true)"

    if [[ "${INTERACTIVE}" -eq 1 ]]; then
      if [[ -n "${detected_repo}" ]]; then
        prompt_value REPO "GitHub repo (owner/repo)" "${detected_repo}"
      else
        prompt_value REPO "GitHub repo (owner/repo)"
      fi
    else
      REPO="${detected_repo}"
    fi
  fi

  [[ -n "${REPO}" ]] || die "Repository is required to sync to GitHub. Provide --repo."
  validate_repo_value "${REPO}" || die "Repository value must be owner/repo"
  ensure_repo_access
}

sync_to_github() {
  ensure_repo_for_sync

  log set "Configuring GitHub secrets and variable in ${REPO}"
  set_repo_secret "ASC_KEY_ID" "${ASC_KEY_ID}"
  set_repo_secret "ASC_ISSUER_ID" "${ASC_ISSUER_ID}"
  set_repo_secret "ASC_PRIVATE_KEY_B64" "${ASC_PRIVATE_KEY_B64}"
  set_repo_secret "ASC_TEAM_ID" "${TEAM_ID}"
  set_repo_variable "ASC_APP_ID" "${APP_ID}"

  GITHUB_SYNC_STATUS="written"
}

run_check_mode() {
  log check "Running repository audit"

  if ! check_required_dependencies; then
    die "Missing required local dependencies. Install them and rerun check."
  fi

  if [[ "${GH_AVAILABLE}" -ne 1 ]]; then
    die "gh CLI is required for check mode. Install gh and rerun."
  fi
  if [[ "${GH_AUTHENTICATED}" -ne 1 ]]; then
    die "gh is not authenticated. Run: gh auth login"
  fi

  if [[ -z "${REPO}" ]]; then
    REPO="$(detect_current_github_repo || true)"
  fi
  [[ -n "${REPO}" ]] || die "check mode requires --repo owner/repo (or run inside a git repo with GitHub origin)"
  validate_repo_value "${REPO}" || die "--repo must be in owner/repo format"

  ensure_repo_access

  local missing=0

  if ! check_secret_exists "${REPO}" "ASC_KEY_ID"; then
    log check "Missing secret: ASC_KEY_ID"
    missing=1
  else
    log done "Secret present: ASC_KEY_ID"
  fi

  if ! check_secret_exists "${REPO}" "ASC_ISSUER_ID"; then
    log check "Missing secret: ASC_ISSUER_ID"
    missing=1
  else
    log done "Secret present: ASC_ISSUER_ID"
  fi

  if ! check_secret_exists "${REPO}" "ASC_PRIVATE_KEY_B64"; then
    log check "Missing secret: ASC_PRIVATE_KEY_B64"
    missing=1
  else
    log done "Secret present: ASC_PRIVATE_KEY_B64"
  fi

  if ! check_secret_exists "${REPO}" "ASC_TEAM_ID"; then
    log check "Missing secret: ASC_TEAM_ID"
    missing=1
  else
    log done "Secret present: ASC_TEAM_ID"
  fi

  if ! check_variable_exists "${REPO}" "ASC_APP_ID"; then
    log check "Missing variable: ASC_APP_ID"
    missing=1
  else
    log done "Variable present: ASC_APP_ID"
  fi

  if [[ "${WRITE_WORKFLOWS}" -eq 1 ]]; then
    local target_dir="${REPO_DIR:-}"
    if [[ -z "${target_dir}" ]]; then
      target_dir="$(detect_git_root || pwd)"
    fi

    local build_file="${target_dir}/.github/workflows/ios-build.yml"
    local deploy_file="${target_dir}/.github/workflows/ios-deploy.yml"

    if [[ -f "${build_file}" ]]; then
      log done "Workflow present: ${build_file}"
    else
      log check "Workflow missing: ${build_file}"
      missing=1
    fi

    if [[ -f "${deploy_file}" ]]; then
      log done "Workflow present: ${deploy_file}"
    else
      log check "Workflow missing: ${deploy_file}"
      missing=1
    fi
  fi

  if [[ "${missing}" -eq 0 ]]; then
    log done "All required items are configured"
    return 0
  fi

  die "Audit failed. Configure missing items and rerun."
}

run_doctor_mode() {
  log check "Diagnosing local setup"

  local result=0
  if ! check_required_dependencies; then
    result=1
  fi

  local detected_repo=""
  detected_repo="$(detect_current_github_repo || true)"
  if [[ -n "${detected_repo}" ]]; then
    log done "Detected current GitHub repo: ${detected_repo}"
  else
    log check "No GitHub repo detected from current directory"
  fi

  local workspace_candidate=""
  workspace_candidate="$(detect_workspace_candidate || true)"
  if [[ -n "${workspace_candidate}" ]]; then
    log done "Detected workspace candidate: ${workspace_candidate}"
    local schemes
    schemes="$(list_schemes "${workspace_candidate}" || true)"
    if [[ -n "${schemes}" ]]; then
      log done "Detected schemes from workspace"
      printf '%s\n' "${schemes}" | sed 's/^/[doctor] scheme: /'
    else
      log check "Could not detect schemes from workspace candidate"
    fi
  else
    log check "No .xcworkspace detected from current directory"
  fi

  if [[ "${result}" -ne 0 ]]; then
    die "Doctor found blocking issues"
  fi

  log done "Doctor completed"
}

parse_args() {
  if [[ $# -gt 0 && "$1" != -* ]]; then
    COMMAND="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)
        COMMAND="check"
        shift
        ;;
      --write-workflows)
        WRITE_WORKFLOWS=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --non-interactive)
        INTERACTIVE=0
        shift
        ;;
      --verbose)
        VERBOSE=1
        shift
        ;;
      --repo)
        REPO="${2:-}"
        shift 2
        ;;
      --repo-dir)
        REPO_DIR="${2:-}"
        shift 2
        ;;
      --workspace)
        WORKSPACE="${2:-}"
        shift 2
        ;;
      --scheme)
        SCHEME="${2:-}"
        shift 2
        ;;
      --bundle-id)
        BUNDLE_ID="${2:-}"
        shift 2
        ;;
      --team-id)
        TEAM_ID="${2:-}"
        shift 2
        ;;
      --app-id)
        APP_ID="${2:-}"
        shift 2
        ;;
      --asc-key-id)
        ASC_KEY_ID="${2:-}"
        shift 2
        ;;
      --asc-issuer-id)
        ASC_ISSUER_ID="${2:-}"
        shift 2
        ;;
      --p8-path)
        P8_PATH="${2:-}"
        shift 2
        ;;
      --p8-b64|--asc-private-key-b64)
        ASC_PRIVATE_KEY_B64="${2:-}"
        shift 2
        ;;
      --runner-label)
        RUNNER_LABEL="${2:-}"
        shift 2
        ;;
      --action-ref)
        ACTION_REF="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  case "${COMMAND}" in
    wizard|check|apply|doctor|version)
      ;;
    *)
      die "Unknown subcommand: ${COMMAND}"
      ;;
  esac

  if [[ "${COMMAND}" == "apply" ]]; then
    INTERACTIVE=0
  fi
}

collect_context_defaults() {
  if [[ -z "${REPO}" ]]; then
    REPO="$(detect_current_github_repo || true)"
    if [[ -n "${REPO}" ]]; then
      log done "Detected current repo from git remote: ${REPO}"
    fi
  fi

  if [[ -z "${REPO_DIR}" ]]; then
    REPO_DIR="$(detect_git_root || true)"
  fi
}

collect_and_validate_setup_inputs() {
  log check "Step 1/9: Context scan"
  collect_context_defaults

  log check "Step 2/9: Prerequisites"
  if ! check_required_dependencies; then
    die "Install missing dependencies, then rerun ${SCRIPT_NAME} wizard"
  fi

  log check "Step 3/9: Repository target"
  if [[ "${INTERACTIVE}" -eq 1 ]]; then
    if [[ -n "${REPO}" ]]; then
      if ! prompt_yes_no "Use repository '${REPO}' for potential GitHub sync?" "y"; then
        REPO=""
      fi
    fi
  fi

  log check "Step 4/9: App Store Connect API key"
  collect_api_key_inputs

  log check "Step 5/9: Credential validation"
  verify_asc_credentials

  log check "Step 6/9: Project build metadata"
  ensure_workspace
  ensure_scheme
  ensure_bundle_and_team
  ensure_app_id

  log check "Step 7/9: Workflow generation choice"
  if [[ "${INTERACTIVE}" -eq 1 && "${WRITE_WORKFLOWS}" -eq 0 ]]; then
    if prompt_yes_no "Generate iOS build/deploy workflows from templates now?" "n"; then
      WRITE_WORKFLOWS=1
    fi
  fi

  if [[ "${WRITE_WORKFLOWS}" -eq 1 ]]; then
    if [[ -z "${REPO_DIR}" ]]; then
      REPO_DIR="$(detect_git_root || pwd)"
    fi

    if [[ "${INTERACTIVE}" -eq 1 ]]; then
      prompt_value REPO_DIR "Workflow target directory" "${REPO_DIR}"
    fi

    write_workflow_files "${REPO_DIR}"
  fi

  log check "Step 8/9: GitHub sync choice"
  update_gh_status
  if [[ "${GH_AVAILABLE}" -eq 1 && "${GH_AUTHENTICATED}" -eq 1 ]]; then
    local should_sync=1
    if [[ "${INTERACTIVE}" -eq 1 ]]; then
      if ! prompt_yes_no "Create/update GitHub secrets and ASC_APP_ID in the target repo now?" "y"; then
        should_sync=0
      fi
    fi

    if [[ "${should_sync}" -eq 1 ]]; then
      sync_to_github
    else
      GITHUB_SYNC_STATUS="manual (user chose not to sync)"
      print_manual_values
    fi
  else
    if [[ "${GH_AVAILABLE}" -eq 0 ]]; then
      log check "gh is not installed. Showing manual values."
    else
      log check "gh is not authenticated. Showing manual values."
      log check "Run 'gh auth login' to enable direct sync."
    fi
    GITHUB_SYNC_STATUS="manual (gh unavailable or unauthenticated)"
    print_manual_values
  fi

  log check "Step 9/9: Final verification"
  log done "Setup values are ready"
}

run_apply_mode() {
  log check "Running apply mode (non-interactive)"

  if ! check_required_dependencies; then
    die "Install missing dependencies before running apply mode"
  fi

  collect_context_defaults
  collect_api_key_inputs
  verify_asc_credentials
  ensure_workspace
  ensure_scheme
  ensure_bundle_and_team
  ensure_app_id

  if [[ "${WRITE_WORKFLOWS}" -eq 1 ]]; then
    if [[ -z "${REPO_DIR}" ]]; then
      REPO_DIR="$(detect_git_root || pwd)"
    fi
    write_workflow_files "${REPO_DIR}"
  fi

  update_gh_status
  if [[ -n "${REPO}" && "${GH_AVAILABLE}" -eq 1 && "${GH_AUTHENTICATED}" -eq 1 ]]; then
    sync_to_github
  else
    if [[ -z "${REPO}" ]]; then
      log check "No --repo provided in apply mode; skipping direct GitHub sync"
    fi
    GITHUB_SYNC_STATUS="manual"
    print_manual_values
  fi
}

print_summary() {
  cat <<SUMMARY

[done] Setup completed.

Summary:
  Command:         ${COMMAND}
  Repo:            ${REPO:-not selected}
  Workspace:       ${WORKSPACE:-not set}
  Scheme:          ${SCHEME:-not set}
  Bundle ID:       ${BUNDLE_ID:-not set}
  Team ID:         ${TEAM_ID:-not set}
  ASC_APP_ID:      ${APP_ID:-not set}
  GitHub sync:     ${GITHUB_SYNC_STATUS}
  Workflows:       ${WORKFLOWS_STATUS}

Next:
  1) Trigger .github/workflows/ios-build.yml
  2) Validate archive/export/upload outputs in GitHub Actions
SUMMARY
}

main() {
  parse_args "$@"

  if [[ "${COMMAND}" == "version" ]]; then
    printf '%s\n' "${CLI_VERSION}"
    exit 0
  fi

  validate_input_combinations

  case "${COMMAND}" in
    doctor)
      run_doctor_mode
      ;;
    check)
      run_check_mode
      ;;
    apply)
      run_apply_mode
      print_summary
      ;;
    wizard)
      collect_and_validate_setup_inputs
      print_summary
      ;;
  esac
}

main "$@"
