# App Store Connect API Key Setup (Step by Step)

This guide walks through creating an App Store Connect API key for GitHub Actions and `asc`.

## Why this key matters

`ReleaseKit-iOS` uses this key to:
- authenticate with App Store Connect
- support cloud signing/export (`xcodebuild -allowProvisioningUpdates`)
- upload builds via `asc`

Important:
- For cloud signing/export, the API key must have an **Admin** role in App Store Connect.

## Prerequisites

- You can sign in to [App Store Connect](https://appstoreconnect.apple.com/)
- Your account can manage API keys
- Your app already exists in App Store Connect

## Step 1: Open Users and Access

Expected screen:
- App Store Connect home, then **Users and Access**

What to click:
1. Open [App Store Connect](https://appstoreconnect.apple.com/)
2. Open **Users and Access**

Screenshot placeholder:

![Users and Access](assets/app-store-connect-api-key/01-users-and-access.png)

## Step 2: Open Integrations > API Keys

Expected screen:
- Users and Access page with **Integrations** tab

What to click:
1. Select **Integrations**
2. Select **App Store Connect API**

Screenshot placeholder:

![Integrations API](assets/app-store-connect-api-key/02-integrations-api.png)

## Step 3: Generate a new API key

Expected screen:
- API Keys list with a button to create a key

What to click:
1. Click **Generate API Key**
2. Enter a key name (example: `github-actions-ci`)
3. Set role to **Admin**
4. Confirm generation

What to copy/store:
- **Key ID** (save as `ASC_KEY_ID`)

Screenshot placeholder:

![Generate key](assets/app-store-connect-api-key/03-generate-key.png)

## Step 4: Download and store the `.p8` file

Expected screen:
- Newly generated key row and download action

What to click:
1. Download the key file (`AuthKey_<KEYID>.p8`)
2. Store it safely (download is available once)

What to copy/store:
- **Issuer ID** (save as `ASC_ISSUER_ID`)
- `.p8` file for setup CLI (`--p8-path`) or base64 (`ASC_PRIVATE_KEY_B64`)

Screenshot placeholder:

![Download p8](assets/app-store-connect-api-key/04-download-p8.png)

## Convert `.p8` to base64

macOS/Linux:

```bash
base64 < AuthKey_ABC1234567.p8 | tr -d '\n'
```

Save this value as GitHub secret `ASC_PRIVATE_KEY_B64`.

## Validate credentials with `asc`

The setup CLI runs this automatically. Manual validation example:

```bash
asc auth login \
  --bypass-keychain \
  --skip-validation \
  --name "ReleaseKit-iOS Manual Check" \
  --key-id "<ASC_KEY_ID>" \
  --issuer-id "<ASC_ISSUER_ID>" \
  --private-key "/path/to/AuthKey_<KEYID>.p8"

ASC_BYPASS_KEYCHAIN=1 asc auth status --validate
```

If validation fails due to permissions, recreate the key with **Admin** role.

## Values you should have at the end

- `ASC_KEY_ID`
- `ASC_ISSUER_ID`
- `ASC_PRIVATE_KEY_B64`
- `ASC_TEAM_ID` (from Apple Developer account)
- `ASC_APP_ID` (App Store Connect app ID)

## Verification checklist

- API key role is **Admin**
- `.p8` file is downloaded and stored securely
- Base64 value is one line
- `asc auth status --validate` succeeds
