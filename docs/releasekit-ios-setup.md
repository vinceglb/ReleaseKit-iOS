# `releasekit-ios-setup` CLI

`releasekit-ios-setup` is a guided bootstrap tool for ReleaseKit-iOS GitHub Actions.

## Install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/vinceglb/releasekit-ios/main/scripts/install-releasekit-ios-setup.sh | sh
```

Then run from your app repository root:

```bash
releasekit-ios-setup wizard
```

## Commands

1. `releasekit-ios-setup wizard`
- Guided step-by-step setup (default command)

2. `releasekit-ios-setup check`
- Non-mutating repository audit

3. `releasekit-ios-setup apply`
- Non-interactive setup from flags

4. `releasekit-ios-setup doctor`
- Local diagnostics (dependencies + auto-detection)

5. `releasekit-ios-setup version`
- Prints CLI version

## What it configures

GitHub repository secrets:
- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_PRIVATE_KEY_B64`
- `ASC_TEAM_ID`

GitHub repository variable:
- `ASC_APP_ID`

Optional generated workflows:
- `.github/workflows/ios-build.yml`
- Generated workflow uses split jobs:
- `actions/archive` for archive/export
- `actions/upload` for App Store Connect upload

## Wizard flow

1. Context scan
- Detect current git repo and iOS workspace candidates.

2. Prerequisites
- Validate `asc`, `jq`, `base64`, `xcodebuild`.
- Detect `gh` and auth status.

3. Repository target
- Reuse detected repo when possible.
- Ask repo only if needed for GitHub sync.

4. API key path
- Ask whether you already have an Admin API key.
- If not, guide creation with checklist and docs.

5. Credential validation
- Validate Key ID + Issuer ID + private key via an ASC API probe in isolated auth context.

6. Build metadata
- Prefill workspace/scheme/bundle/team from local project when possible.
- Resolve `ASC_APP_ID` from bundle ID with `asc`, with fallback prompt.

7. Workflow generation
- Optional template generation with overwrite protection (`--force`).
- Uses local repo templates when available, otherwise built-in templates (global install friendly).

8. GitHub sync
- If `gh` is available and authenticated, optionally write secrets/variable directly.
- Otherwise prints manual values to copy.

9. Final summary
- Shows configured values and next actions.

## Key options

- `--repo owner/repo`
- `--repo-dir /path/to/repo`
- `--workspace ios/App.xcworkspace`
- `--scheme App`
- `--bundle-id com.example.app`
- `--team-id TEAMID123`
- `--app-id 123456789`
- `--asc-key-id KEYID123`
- `--asc-issuer-id ISSUER_UUID`
- `--p8-path ~/AuthKey_KEYID123.p8`
- `--p8-b64 <base64>`
- `--write-workflows`
- `--force`
- `--non-interactive`
- `--verbose` (debug traces)

## Examples

### Guided setup

```bash
releasekit-ios-setup wizard
```

### Check mode

```bash
releasekit-ios-setup check --repo owner/repo --write-workflows --repo-dir /path/to/repo
```

### Apply mode (CI/non-interactive)

```bash
releasekit-ios-setup apply \
  --repo owner/repo \
  --workspace ios/App.xcworkspace \
  --scheme App \
  --bundle-id com.example.app \
  --team-id TEAMID123 \
  --app-id 123456789 \
  --asc-key-id KEYID123 \
  --asc-issuer-id 00000000-0000-0000-0000-000000000000 \
  --p8-path ~/AuthKey_KEYID123.p8 \
  --write-workflows
```

### Doctor mode

```bash
releasekit-ios-setup doctor
```

### Verbose troubleshooting mode

```bash
releasekit-ios-setup wizard --verbose
# or
RELEASEKIT_IOS_SETUP_DEBUG=1 releasekit-ios-setup wizard
```

## Manual fallback mode

If `gh` is missing or unauthenticated, the wizard still completes setup and prints exact values to configure manually in GitHub:

- Secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_B64`, `ASC_TEAM_ID`
- Variable: `ASC_APP_ID`

## Troubleshooting

| Problem | Cause | Fix |
| --- | --- | --- |
| `Missing dependency` | Local tool not installed | Install command shown by wizard/doctor |
| `gh` not authenticated | `gh auth status` failed | Run `gh auth login` |
| ASC validation failed | Wrong key/issuer/private key | Re-enter values and ensure `.p8` is correct |
| Cloud signing errors later in CI | API key role is not Admin | Recreate key with **Admin** role |
| App ID not resolved automatically | Lookup failed/ambiguous | Provide `--app-id` manually |
| Workflow file exists | Safe overwrite guard | Use `--force` |
