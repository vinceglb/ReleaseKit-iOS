# ReleaseKit-iOS

ReleaseKit-iOS is a composite GitHub Action that archives an iOS app, exports an `.ipa`, and uploads it to App Store Connect using [`asc`](https://github.com/rudrankriyam/App-Store-Connect-CLI).

## Quick Start (5 minutes)

1. Create an App Store Connect API key (Admin role for cloud signing)
- Guide: [`docs/app-store-connect-api-key.md`](docs/app-store-connect-api-key.md)

2. Install the setup CLI globally

```bash
curl -fsSL https://raw.githubusercontent.com/vinceglb/releasekit-ios/main/scripts/install-releasekit-ios-setup.sh | sh
```

3. Run guided onboarding from your app repository

```bash
releasekit-ios-setup wizard
```

The wizard guides step-by-step, auto-prefills from local git/Xcode context, validates ASC credentials, and can resume interrupted setup without persisting secrets.

## DX Setup Docs

- API key creation guide: [`docs/app-store-connect-api-key.md`](docs/app-store-connect-api-key.md)
- Setup CLI guide: [`docs/releasekit-ios-setup.md`](docs/releasekit-ios-setup.md)

## Requirements

- Runner: `macos-14` (or newer macOS runner with Xcode)
- API key with permissions for build upload/provisioning updates
- For cloud signing/export (`xcodebuild -allowProvisioningUpdates`), API key role must be **Admin**
- Project configured for automatic signing

## Inputs

### Required

| Name | Description |
| --- | --- |
| `workspace` | Path to the `.xcworkspace` file or directory. |
| `scheme` | Xcode scheme to archive. |
| `app_id` | App Store Connect app ID. |
| `bundle_id` | Expected bundle identifier for validation against archive output. |
| `asc_key_id` | App Store Connect API Key ID. |
| `asc_issuer_id` | App Store Connect API Issuer ID. |
| `asc_private_key_b64` | Base64-encoded `.p8` private key content. |
| `asc_team_id` | Apple Developer Team ID used for signing/export. |

### Optional

| Name | Default | Description |
| --- | --- | --- |
| `configuration` | `Release` | Xcode build configuration. |
| `archive_path` | `${{ runner.temp }}/archive/App.xcarchive` | Output archive path. |
| `export_path` | `${{ runner.temp }}/export` | Output export directory (contains IPA). |
| `asc_version` | `0.28.8` | `asc` CLI version to install. |
| `wait_for_processing` | `false` | If `true`, waits for ASC build processing. |
| `poll_interval` | `30s` | Poll interval when waiting. |
| `xcodebuild_extra_args` | `""` | Extra args appended to `xcodebuild archive`. |

## Outputs

| Name | Description |
| --- | --- |
| `archive_path` | Absolute path to generated `.xcarchive`. |
| `ipa_path` | Absolute path to generated `.ipa`. |
| `upload_id` | ASC upload ID returned by `asc builds upload`. |
| `file_id` | ASC upload file ID returned by `asc builds upload`. |
| `asc_result_json` | Compact JSON output from `asc builds upload`. |

## Usage

```yaml
name: Build and Upload iOS

on:
  workflow_dispatch:

jobs:
  upload:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: ReleaseKit-iOS archive, export and upload
        id: ios_upload
        uses: vinceglb/releasekit-ios@main
        with:
          workspace: ios/App.xcworkspace
          scheme: App
          app_id: ${{ vars.ASC_APP_ID }}
          bundle_id: com.example.app
          asc_key_id: ${{ secrets.ASC_KEY_ID }}
          asc_issuer_id: ${{ secrets.ASC_ISSUER_ID }}
          asc_private_key_b64: ${{ secrets.ASC_PRIVATE_KEY_B64 }}
          asc_team_id: ${{ secrets.ASC_TEAM_ID }}
          wait_for_processing: "true"
```

## Setup CLI Commands

```bash
releasekit-ios-setup wizard
releasekit-ios-setup check --repo owner/repo
releasekit-ios-setup apply --repo owner/repo --workspace ios/App.xcworkspace --scheme App --bundle-id com.example.app --team-id TEAMID --app-id 123456789 --asc-key-id KEYID --asc-issuer-id ISSUER --p8-path ~/AuthKey_KEYID.p8
releasekit-ios-setup doctor
releasekit-ios-setup version
```

## Security Notes

- Cloud signing requires an API key with **Admin** role.
- Generated workflow templates intentionally use `vinceglb/releasekit-ios@main` for simplicity.
- Tradeoff: `@main` is less reproducible than pinning to a commit SHA.
- Wizard resume state stores only non-sensitive fields in `~/.local/state/releasekit-ios-setup/session.json`.

## Troubleshooting

- `Cloud signing permission error`
  - Use an App Store Connect API key with **Admin** role.
- ASC auth validation failure in setup CLI
  - Re-check Key ID, Issuer ID, and `.p8` content.
  - Re-run with `releasekit-ios-setup wizard --verbose` for detailed ASC diagnostics.
- `gh` unavailable or unauthenticated
  - Wizard falls back to manual value output; run `gh auth login` to enable direct sync.
- Bundle ID mismatch in action runtime
  - Check `scheme` and `bundle_id` inputs.
