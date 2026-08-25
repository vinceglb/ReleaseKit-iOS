# Keep archive export local

ReleaseKit's archive action performs a local export that preserves the exact IPA identity without creating or modifying an App Store Connect delivery attempt. The upload action alone owns delivery creation and reconciliation. ReleaseKit therefore disables Xcode's automatic version and build-number management as an invariant rather than a public option, keeps incomplete deliveries fail-closed, and requires an archive-only App Store Connect canary before publishing this change.

The archive action receives a base64-encoded Apple Distribution `.p12`, its password, and a base64-encoded App Store provisioning profile. It validates the certificate and profile against the Developer Team ID and bundle ID, imports the identity into an ephemeral keychain, installs the profile, and signs manually. ReleaseKit does not pass App Store Connect authentication or provisioning-update flags to either `xcodebuild archive` or `xcodebuild -exportArchive`.

The action restores the runner's original keychain search list and provisioning profiles before it exits. App Store Connect credentials remain limited to upload and release actions.

`developer_team_id` names the signing team. The previous `asc_team_id` input remains as a deprecated compatibility alias and must match when callers provide both names.
