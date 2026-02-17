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

version_candidates() {
  local raw="$1"
  local -a items=()
  local -a unique=()

  items+=("${raw}")
  if [[ "${raw}" == v* ]]; then
    items+=("${raw#v}")
  else
    items+=("v${raw}")
  fi

  local item
  for item in "${items[@]}"; do
    [[ -n "${item}" ]] || continue
    local seen=0
    local existing
    for existing in "${unique[@]}"; do
      if [[ "${existing}" == "${item}" ]]; then
        seen=1
        break
      fi
    done
    if [[ "${seen}" -eq 0 ]]; then
      unique+=("${item}")
    fi
  done

  printf '%s\n' "${unique[@]}"
}

resolve_latest_tag() {
  local latest_url=""
  latest_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/rudrankriyam/App-Store-Connect-CLI/releases/latest")" \
    || fail "Failed to resolve latest asc release tag"

  local tag="${latest_url##*/}"
  [[ -n "${tag}" ]] || fail "Could not parse latest asc release tag from URL: ${latest_url}"
  printf '%s\n' "${tag}"
}

input_version="${INPUT_ASC_VERSION:-latest}"
if [[ -z "${input_version}" || "${input_version}" == "latest" ]]; then
  release_tag="$(resolve_latest_tag)"
else
  release_tag="${input_version}"
fi

runner_temp="${RUNNER_TEMP:-}"
if [[ -z "${runner_temp}" ]]; then
  fail "RUNNER_TEMP is not set"
fi

arch="$(uname -m)"
case "${arch}" in
  arm64)
    asset_arch="arm64"
    ;;
  x86_64)
    asset_arch="amd64"
    ;;
  *)
    fail "Unsupported macOS architecture: ${arch}"
    ;;
esac

release_url="https://github.com/rudrankriyam/App-Store-Connect-CLI/releases/download/${release_tag}"

tmp_dir="$(mktemp -d "${runner_temp}/asc-install.XXXXXX")"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

asset_name=""
checksums_name=""
binary_path=""
checksums_path=""
resolved_asset_version=""
downloaded=0

while IFS= read -r candidate; do
  [[ -n "${candidate}" ]] || continue

  asset_name="asc_${candidate}_macOS_${asset_arch}"
  checksums_name="asc_${candidate}_checksums.txt"
  binary_path="${tmp_dir}/${asset_name}"
  checksums_path="${tmp_dir}/${checksums_name}"

  if curl -fsSL --retry 3 --retry-all-errors -o "${binary_path}" "${release_url}/${asset_name}" \
    && curl -fsSL --retry 3 --retry-all-errors -o "${checksums_path}" "${release_url}/${checksums_name}"; then
    resolved_asset_version="${candidate}"
    downloaded=1
    break
  fi
done < <(version_candidates "${release_tag}")

if [[ "${downloaded}" -ne 1 ]]; then
  fail "Failed to download asc assets from release tag ${release_tag}"
fi

expected_sha="$(awk -v target="${asset_name}" '$2 == target {print $1}' "${checksums_path}")"
if [[ -z "${expected_sha}" ]]; then
  fail "Could not find checksum entry for ${asset_name}"
fi

actual_sha="$(shasum -a 256 "${binary_path}" | awk '{print $1}')"
if [[ "${actual_sha}" != "${expected_sha}" ]]; then
  fail "Checksum mismatch for ${asset_name}. Expected ${expected_sha}, got ${actual_sha}"
fi

bin_dir="${runner_temp}/bin"
mkdir -p "${bin_dir}"
install -m 0755 "${binary_path}" "${bin_dir}/asc"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "${bin_dir}" >> "${GITHUB_PATH}"
else
  export PATH="${bin_dir}:${PATH}"
fi

echo "Resolved asc release tag: ${release_tag} (asset version: ${resolved_asset_version})"
"${bin_dir}/asc" --version
