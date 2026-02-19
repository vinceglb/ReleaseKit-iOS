# ReleaseKit-iOS

ReleaseKit-iOS provides two composite GitHub Actions for iOS CI/CD:

- `vinceglb/releasekit-ios/actions/archive` to build, archive, and export an `.ipa`
- `vinceglb/releasekit-ios/actions/upload` to upload an `.ipa` to App Store Connect with [`asc`](https://github.com/rudrankriyam/App-Store-Connect-CLI)

## Quick Start (5 minutes)

1. Create an App Store Connect API key (Admin role for cloud signing)
- Guide: [`docs/app-store-connect-api-key.md`](docs/app-store-connect-api-key.md)

2. Install CLI

```bash
curl -fsSL https://raw.githubusercontent.com/vinceglb/releasekit-ios/main/scripts/install-releasekit-ios.sh | sh
```

3. Run guided onboarding in your app repo

```bash
releasekit-ios wizard
```

## CLI Status

- `releasekit-ios` (Go CLI) is the active setup CLI release line.
- `releasekit-ios-setup` (legacy shell script) is frozen and kept for reference/migration only.

## DX Setup Docs

- API key guide: [`docs/app-store-connect-api-key.md`](docs/app-store-connect-api-key.md)
- Active Go CLI: [`cli/releasekit-ios-go/README.md`](cli/releasekit-ios-go/README.md)
- Legacy setup CLI: [`docs/releasekit-ios-setup.md`](docs/releasekit-ios-setup.md)

## Requirements

- Runner: `macos-latest` (or pinned macOS runner with Xcode)
- API key with permissions for build upload/provisioning updates
- Cloud signing/export requires API key role **Admin**
- Project configured for automatic signing

## Archive Action

### Usage

```yaml
- name: Archive and export IPA
  id: ios_archive
  uses: vinceglb/releasekit-ios/actions/archive@v0
  with:
    workspace: ios/App.xcworkspace
    scheme: App
    bundle_id: ${{ vars.BUNDLE_ID }}
    asc_key_id: ${{ secrets.ASC_KEY_ID }}
    asc_issuer_id: ${{ secrets.ASC_ISSUER_ID }}
    asc_private_key_b64: ${{ secrets.ASC_PRIVATE_KEY_B64 }}
    asc_team_id: ${{ vars.ASC_TEAM_ID }}
```

### Inputs

Required:
- `workspace`
- `scheme`
- `bundle_id`
- `asc_key_id`
- `asc_issuer_id`
- `asc_private_key_b64`
- `asc_team_id`

Optional:
- `configuration` (default `Release`)
- `archive_path` (default `${{ runner.temp }}/archive/App.xcarchive`)
- `export_path` (default `${{ runner.temp }}/export`)
- `xcodebuild_extra_args` (default `""`)

### Outputs

- `archive_path`
- `ipa_path`
- `archive_bundle_id`

## Upload Action

### Usage (path mode)

```yaml
- name: Upload IPA from path
  id: ios_upload
  uses: vinceglb/releasekit-ios/actions/upload@v0
  with:
    app_id: ${{ vars.ASC_APP_ID }}
    asc_key_id: ${{ secrets.ASC_KEY_ID }}
    asc_issuer_id: ${{ secrets.ASC_ISSUER_ID }}
    asc_private_key_b64: ${{ secrets.ASC_PRIVATE_KEY_B64 }}
    ipa_path: ${{ steps.ios_archive.outputs.ipa_path }}
    wait_for_processing: "false"
```

### Usage (artifact mode)

```yaml
- name: Upload IPA from artifact
  id: ios_upload
  uses: vinceglb/releasekit-ios/actions/upload@v0
  with:
    app_id: ${{ vars.ASC_APP_ID }}
    asc_key_id: ${{ secrets.ASC_KEY_ID }}
    asc_issuer_id: ${{ secrets.ASC_ISSUER_ID }}
    asc_private_key_b64: ${{ secrets.ASC_PRIVATE_KEY_B64 }}
    artifact_name: App.ipa
    artifact_download_path: ${{ runner.temp }}/releasekit-upload
    wait_for_processing: "false"
```

### Inputs

Required:
- `app_id`
- `asc_key_id`
- `asc_issuer_id`
- `asc_private_key_b64`

Mode inputs (exactly one):
- `ipa_path`
- `artifact_name`

Optional:
- `artifact_download_path` (default `${{ runner.temp }}/upload-input`)
- `asc_version` (default `latest`)
- `wait_for_processing` (default `false`)
- `poll_interval` (default `30s`)

### Outputs

- `ipa_path`
- `upload_id`
- `file_id`
- `asc_result_json`

## Split Workflow Example

```yaml
name: iOS Build and Upload

on:
  workflow_dispatch:

jobs:
  archive:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v6
      - id: ios_archive
        uses: vinceglb/releasekit-ios/actions/archive@v0
        with:
          workspace: ios/App.xcworkspace
          scheme: App
          bundle_id: ${{ vars.BUNDLE_ID }}
          asc_key_id: ${{ secrets.ASC_KEY_ID }}
          asc_issuer_id: ${{ secrets.ASC_ISSUER_ID }}
          asc_private_key_b64: ${{ secrets.ASC_PRIVATE_KEY_B64 }}
          asc_team_id: ${{ vars.ASC_TEAM_ID }}
      - uses: actions/upload-artifact@v6
        with:
          name: App.ipa
          path: ${{ steps.ios_archive.outputs.ipa_path }}

  upload:
    needs: archive
    runs-on: macos-latest
    steps:
      - id: ios_upload
        uses: vinceglb/releasekit-ios/actions/upload@v0
        with:
          app_id: ${{ vars.ASC_APP_ID }}
          asc_key_id: ${{ secrets.ASC_KEY_ID }}
          asc_issuer_id: ${{ secrets.ASC_ISSUER_ID }}
          asc_private_key_b64: ${{ secrets.ASC_PRIVATE_KEY_B64 }}
          artifact_name: App.ipa
          wait_for_processing: "false"
```

## Security Notes

- Cloud signing requires an API key with **Admin** role.
- `ASC_TEAM_ID` and `BUNDLE_ID` are identifiers (not secrets); store them as repository variables.
- Generated workflow files use `@v0`; pin a full tag/SHA for stricter reproducibility.

## Publishing a Release

1. Create and push a `vX.Y` tag.
2. The CLI release workflow (`.github/workflows/release-cli-beta.yml`) publishes:
   - `releasekit-ios-darwin-arm64.tar.gz`
   - `releasekit-ios-darwin-amd64.tar.gz`
   - A GitHub Release with auto-generated notes

## CLI Release Process (`releasekit-ios`)

To publish the Go CLI, create and push a stable `v*` tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Install latest:

```bash
curl -fsSL https://raw.githubusercontent.com/vinceglb/releasekit-ios/main/scripts/install-releasekit-ios.sh | sh
```

Install a pinned version:

```bash
curl -fsSL https://raw.githubusercontent.com/vinceglb/releasekit-ios/main/scripts/install-releasekit-ios.sh | sh -s -- --version v0.1.0
```

## Legacy Setup CLI (`releasekit-ios-setup`)

- The legacy shell-based release workflow is frozen.
- `scripts/releasekit-ios-setup.sh` and related docs remain in-repo for migration/reference.
- `.github/workflows/release.yml` is kept as a manual informational workflow (no automated `v*` publishing).

## Troubleshooting

- `Cloud signing permission error`
  - Use an API key with **Admin** role.
- `asc auth login failed`
  - Re-check Key ID, Issuer ID, and `.p8` content/base64 encoding.
- Upload mode validation errors
  - Provide exactly one of `ipa_path` or `artifact_name`.
