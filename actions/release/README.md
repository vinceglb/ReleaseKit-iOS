# App Store update release

`actions/release` prepares an **update to an existing App Store app** from an IPA that has already been uploaded to App Store Connect. It extracts the binary identity, waits for that exact uploaded build, reconciles the matching App Store version and localized Store Release Notes, validates readiness, and optionally submits the update for App Review.

First-ever App Store publication is outside this action's scope. Archive, upload, and release remain separate lifecycle stages so a release retry never rebuilds or uploads the IPA again.

## App Store Connect access

Use a team App Store Connect API key that can read the app and manage versions, builds, localizations, release policy, and App Review submissions. An **App Manager or Admin** key is expected. The action validates authentication and app access before release mutations.

Apple's public API-key authentication surface does not expose the key's assigned role. ReleaseKit verifies the installed `asc` release capabilities plus effective authentication and app read access early; verify the App Manager-or-greater assignment when creating the key. Apple still enforces write permission on every later mutation.

Credentials are decoded into an isolated temporary directory, registered with a keychain-free `asc` profile, masked in GitHub Actions logs, and deleted on success, failure, interruption, or timeout.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `app_id` | Yes | — | Existing App Store Connect app ID. |
| `ipa_path` | Yes | — | Local IPA already uploaded by an earlier job. |
| `release_notes_dir` | Yes | — | Directory containing exactly one `<locale>.txt` Store Release Note for every locale enabled on the target version. |
| `asc_key_id` | Yes | — | App Store Connect API key ID. |
| `asc_issuer_id` | Yes | — | App Store Connect API issuer ID. |
| `asc_private_key_b64` | Yes | — | Single-base64-encoded `.p8` private key. |
| `review_contact_first_name` | No | — | App Review contact first name. |
| `review_contact_last_name` | No | — | App Review contact last name. |
| `review_contact_email` | No | — | App Review contact email. |
| `review_contact_phone` | No | — | App Review contact phone. |
| `submit_for_review` | No | `false` | Submit the prepared update through Apple's review-submission flow. |
| `release_type` | No | `MANUAL` | `MANUAL` or `AFTER_APPROVAL`. The latter releases to everyone after approval; this action does not enable phased release. |
| `processing_timeout` | No | `30m` | Maximum wait for the exact build to become `VALID`. |
| `poll_interval` | No | `30s` | Exact-build poll interval. |
| `asc_version` | No | `latest` | `asc` version installed by `setup-asc`; the selected version appears in the job summary. |

Store Release Notes must be valid UTF-8, non-empty, no longer than 4,000 characters, and named with the exact App Store locale. Missing, extra, malformed, and non-text entries fail the run. Notes may deliberately be identical to notes from an earlier update.

The four App Review contact inputs are optional as a group: provide all four or omit all four. When provided, ReleaseKit masks them and applies them to the editable App Store version before readiness validation. Store the values as GitHub Actions secrets; they are never exposed as action outputs or included in the job summary.

## Outputs

| Output | Description |
| --- | --- |
| `bundle_id` | IPA `CFBundleIdentifier`. |
| `marketing_version` | IPA `CFBundleShortVersionString` and Store Release Version. |
| `build_number` | IPA `CFBundleVersion`. |
| `app_store_version_id` | Matching App Store version resource ID. |
| `build_id` | Exact processed build resource ID. |
| `submission_id` | Matching review submission ID, when applicable. |
| `submission_state` | Current review submission state, when applicable. |
| `app_store_connect_url` | Direct navigation to the app's distribution area. |
| `result_json` | Compact structured result containing identity, resource IDs, requested release policy, preparation/submission status, and navigation. |

## Preparation, submission, and retries

The safe default is preparation only with manual release. Set both `submit_for_review: true` and an intentional `release_type` to submit.

Every run reconciles before changing App Store state:

- the app must match the IPA bundle identifier;
- build lookup uses the IPA marketing version and build number, never “latest”;
- editable state converges to the exact notes, build, and release policy;
- a matching submitted version is idempotent success;
- conflicting non-editable state fails without canceling review, deleting versions, detaching builds, or rolling back useful progress.

A processing timeout or readiness failure preserves the uploaded binary and prepared App Store resources. Retry the release job with the same IPA and inputs. Success after submission means App Store Connect accepted the App Review submission and configured the requested release policy; it does **not** mean the update is already public.

## Molkky integration example

Download the same IPA artifact used by the separate TestFlight upload job, then call the release action from a Linux job:

```yaml
release_ios_to_app_store:
  needs: upload_ios_to_testflight
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v6
    - uses: actions/download-artifact@v4
      with:
        name: molkky-ios-ipa
        path: ${{ runner.temp }}/ios-release
    - id: app_store_release
      uses: vinceglb/ReleaseKit-iOS/actions/release@v0
      with:
        app_id: ${{ vars.ASC_APP_ID }}
        ipa_path: ${{ runner.temp }}/ios-release/Molkky.ipa
        release_notes_dir: store/appstore/release-notes
        asc_key_id: ${{ secrets.ASC_KEY_ID }}
        asc_issuer_id: ${{ secrets.ASC_ISSUER_ID }}
        asc_private_key_b64: ${{ secrets.ASC_PRIVATE_KEY_B64 }}
        review_contact_first_name: ${{ secrets.IOS_REVIEW_CONTACT_FIRST_NAME }}
        review_contact_last_name: ${{ secrets.IOS_REVIEW_CONTACT_LAST_NAME }}
        review_contact_email: ${{ secrets.IOS_REVIEW_CONTACT_EMAIL }}
        review_contact_phone: ${{ secrets.IOS_REVIEW_CONTACT_PHONE }}
        submit_for_review: true
        release_type: AFTER_APPROVAL
```

The runner needs `bash`, `jq`, and `python3`; GitHub-hosted Ubuntu runners include them. The action installs `asc` itself.
