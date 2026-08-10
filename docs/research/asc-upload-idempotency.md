# `asc` upload idempotency research

Research date: 2026-08-10. The current upstream release is [`asc` 3.7.0](https://github.com/rorkai/App-Store-Connect-CLI/releases/tag/3.7.0); the locally installed 3.5.0 exposes the same commands and flags used below (`asc version`, `asc builds list --help`, `asc builds uploads list --help`, and `asc builds wait --help`).

## Conclusions

1. `asc builds upload` is not an idempotent operation. After validating the IPA and selected app, it immediately creates a new build-upload reservation, creates a file reservation, transfers the IPA, and commits the file. It does not look for an existing exact build or upload first. ReleaseKit therefore needs to reconcile before invoking it. ([3.7.0 upload implementation](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/cli/builds/builds_commands.go#L191-L274), [transfer and commit](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/cli/builds/builds_commands.go#L293-L342))
2. The exact identity is bundle ID + marketing version (`CFBundleShortVersionString`) + build number (`CFBundleVersion`), with platform included to disambiguate the App Store Connect resources. Apple says the first three values uniquely identify a build; `asc` can filter builds and build uploads by the corresponding version/build/platform fields. ([Apple app information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information), [`asc builds list` filters](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/cli/builds/builds_commands.go#L456-L493), [`asc builds uploads list` filters](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/cli/builds/builds_uploads.go#L47-L71))
3. Build resources and build-upload resources have different state machines and must not be conflated. Builds expose `PROCESSING`, `FAILED`, `INVALID`, and `VALID`; build uploads expose `AWAITING_UPLOAD`, `PROCESSING`, `FAILED`, and `COMPLETE`. ([Apple build attributes](https://developer.apple.com/documentation/appstoreconnectapi/build/attributes-data.dictionary), [Apple `BuildUploadState`](https://developer.apple.com/documentation/appstoreconnectapi/builduploadstate))
4. A one-shot build lookup is insufficient. Apple says a successfully delivered binary must be processed before it appears as a build in App Store Connect, while the build-upload API exposes delivery state before or alongside that build resource. Reconciliation must query both surfaces for a bounded interval. ([Apple upload guidance](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/), [Apple build-upload API overview](https://developer.apple.com/documentation/appstoreconnectapi/build-uploads))

## Exact read APIs

Query both resources on every reconciliation pass; do not use `--latest`:

```bash
asc builds list \
  --app "$APP_ID" \
  --version "$MARKETING_VERSION" \
  --build-number "$BUILD_NUMBER" \
  --platform IOS \
  --processing-state all \
  --paginate \
  --output json

asc builds uploads list \
  --app "$APP_ID" \
  --cf-bundle-short-version "$MARKETING_VERSION" \
  --cf-bundle-version "$BUILD_NUMBER" \
  --platform IOS \
  --paginate \
  --output json
```

`asc builds list` applies marketing version through the pre-release-version relationship and applies build number, platform, and processing-state filters before returning JSON. `--paginate` makes the result exhaustive rather than relying on a first page. ([implementation](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/cli/builds/builds_commands.go#L520-L609))

`asc builds uploads list` maps the exact version/build/platform filters to Apple's `GET /v1/apps/{id}/buildUploads` endpoint and supports exhaustive pagination. Apple's endpoint has a maximum page size of 200. ([CLI implementation](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/cli/builds/builds_uploads.go#L93-L140), [Apple endpoint](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-apps-_id_-builduploads))

Relevant JSON fields are:

```text
build:       .data[].id
             .data[].attributes.processingState
upload:      .data[].id
             .data[].attributes.state.state
             .data[].attributes.state.errors[]?.code
             .data[].attributes.state.errors[]?.message
```

The upload state is an object rather than a plain string; it carries errors, warnings, and informational details. ([`asc` response types](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/asc/client_builds.go#L107-L139), [state detail shape](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/asc/client_builds.go#L223-L235))

Once an upload ID is known, refresh it directly rather than depending only on repeated list visibility:

```bash
asc builds uploads view --id "$UPLOAD_ID" --output json
```

This calls Apple's `GET /v1/buildUploads/{id}` endpoint. ([CLI implementation](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/cli/builds/builds_uploads.go#L145-L183), [Apple endpoint](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builduploads-_id_))

## State decisions

| Exact resource | State | ReleaseKit decision |
| --- | --- | --- |
| Build | `VALID` | Reuse and succeed. |
| Build | `PROCESSING` | Reuse. If waiting was requested, wait by its exact build ID. |
| Build | `FAILED` or `INVALID` | Fail with the build ID and state; do not attempt another upload of that exact immutable build identity. |
| Upload, no build visible yet | `PROCESSING` or `COMPLETE` | Reuse. These states prove that the file was committed; `COMPLETE` means upload processing succeeded. If waiting was requested, keep reconciling until the exact build appears, then wait on its build ID. |
| Upload, no build visible yet | `AWAITING_UPLOAD` | Do not report success. It may be an active concurrent transfer or an abandoned reservation. Recheck within the bounded window, then fail closed with the upload ID if it never advances; blindly creating another reservation is not concurrency-safe. |
| Upload, no build visible yet | `FAILED` | It is not reusable, but it does not necessarily consume the build number: Apple permits reusing the same number after a failed upload. Preserve every structured error. Retry once only when every error code is explicitly transient and the bounded reconciliation window confirms there is no build or active/complete upload; fail closed for permanent, mixed, or unclassified errors. |
| Either resource | unknown state, or multiple active exact matches | Fail closed and print IDs/states; never resolve ambiguity by choosing the newest item. |

The build terminal-state behavior matches `asc builds wait`: `VALID` succeeds, `FAILED` fails, and `INVALID` fails when `--fail-on-invalid` is supplied. ([CLI contract](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/cli/builds/builds_wait.go#L23-L65), [terminal handling](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/cli/builds/builds_wait.go#L319-L363)) Apple documents `PROCESSING`, `FAILED`, and `COMPLETE` upload meanings and explicitly says a failed upload may reuse the same build number. ([Apple build upload statuses](https://developer.apple.com/help/app-store-connect/reference/app-uploads/build-upload-statuses/))

## Waiting

For an already-visible exact build:

```bash
asc builds wait \
  --build-id "$BUILD_ID" \
  --poll-interval "$POLL_INTERVAL" \
  --fail-on-invalid \
  --output json
```

For build discovery, `asc builds wait` also supports the exact app-scoped selector below and polls until discovery, but it does not know the pre-existing upload ID and therefore cannot fail early when that upload changes to `FAILED`. ReleaseKit should poll the known upload with `asc builds uploads view` until a build ID appears, then switch to the build-ID wait above. ([selector implementation](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/cli/builds/builds_wait.go#L27-L38), [discovery loop](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/cli/builds/builds_wait.go#L224-L279))

```bash
asc builds wait \
  --app "$APP_ID" \
  --version "$MARKETING_VERSION" \
  --build-number "$BUILD_NUMBER" \
  --platform IOS \
  --poll-interval "$POLL_INTERVAL" \
  --fail-on-invalid \
  --output json
```

For a fresh upload, `asc builds upload --wait --poll-interval "$POLL_INTERVAL"` already watches its own upload ID for early `FAILED` state, resolves the resulting exact build, and then fails on `FAILED` or `INVALID` build processing. ([upload wait flow](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/cli/builds/builds_commands.go#L344-L358), [upload-aware discovery](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/cli/shared/build_wait.go#L32-L83), [build terminal handling](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/asc/client_publish.go#L10-L36))

## Recommended bounded reconciliation

Apple and `asc` expose polling primitives but publish no short visibility SLA for the transition from upload record to build resource. The exact duration is therefore a ReleaseKit policy, not an Apple guarantee. Apple only states that processing must complete before a build appears and advises escalation when upload processing remains stuck for 24 hours. ([Apple upload guidance](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/), [Apple upload-status guidance](https://developer.apple.com/help/app-store-connect/reference/app-uploads/build-upload-statuses/))

A deterministic action-level policy:

1. Extract and validate the IPA identity and verify its bundle ID against the selected app before any mutation.
2. Perform three exact reconciliation passes, sleeping `poll_interval` between passes (three reads, two sleeps). On each pass, query both commands above and apply the state table immediately.
3. If an active/complete upload is found, remember its ID and refresh it directly on later passes. Never select the newest upload as a proxy for identity.
4. On every pass, prioritize a reusable exact build or active/complete upload over older failed-upload history. After the final empty/failed-only pass, invoke `asc builds upload` at most once only when every failed-upload error code is explicitly transient; fail closed for permanent, mixed, or unclassified failures.
5. If the upload command returns nonzero, perform one final exact reconciliation before failing. Convert the result to `reused` only if an exact build or `PROCESSING`/`COMPLETE` upload now exists; this covers an ambiguous client-side failure after App Store Connect accepted the commit. Otherwise return the original upload failure.
6. If `wait_for_processing=true`, use `--wait` on the fresh path. On a reused path, monitor the known upload until its exact build appears and then run `asc builds wait --build-id ... --fail-on-invalid` with the configured poll interval.

The final reconciliation after a nonzero upload is necessary because `asc` itself treats some commit-response failures as ambiguous and reads the upload record back, accepting `PROCESSING` or `COMPLETE` as committed. ([commit reconciliation](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/cli/shared/build_uploads.go#L62-L125))

## Output contract implication

The native fresh-upload JSON contains `uploadId`, `fileId`, `fileName`, `fileSize`, and optional upload/checksum fields. ([output type](https://github.com/rorkai/App-Store-Connect-CLI/blob/4ce50f1165145e3ce829bd6b689ef8aee224de1b/internal/asc/output_builds.go#L9-L20)) On a ReleaseKit reuse path, return `outcome=reused` and keep `upload_id`, `file_id`, and `asc_result_json` empty rather than fabricating a fresh `asc builds upload` response. `ipa_path` remains the resolved input path. This preserves the meaning of the existing mutation outputs while making reuse explicit.
