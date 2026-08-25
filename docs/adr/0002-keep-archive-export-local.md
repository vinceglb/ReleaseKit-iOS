# Keep archive export local

ReleaseKit's archive action performs a local export that preserves the exact IPA identity without creating or modifying an App Store Connect delivery attempt. The upload action alone owns delivery creation and reconciliation. ReleaseKit therefore disables Xcode's automatic version and build-number management as an invariant rather than a public option, keeps incomplete deliveries fail-closed, and requires an archive-only App Store Connect canary before publishing this change.

App Store Connect credentials and provisioning updates are available to the archive phase so Xcode can resolve signing assets. The export phase must consume those resolved assets locally: ReleaseKit does not pass authentication or provisioning-update flags to `xcodebuild -exportArchive`.
