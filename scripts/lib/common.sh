#!/usr/bin/env bash

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
