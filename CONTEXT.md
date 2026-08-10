# ReleaseKit iOS

ReleaseKit iOS packages and publishes iOS builds through App Store Connect.

## Language

**Exact IPA identity**:
The bundle identifier, marketing version, and build number that together identify one iOS build.
_Avoid_: Latest build, matching IPA

**Upload retry**:
A later, non-overlapping upload request for the same exact IPA identity. Simultaneous upload requests are not upload retries.
_Avoid_: Concurrent upload

**Retry-safe upload**:
An upload request that preserves the effective App Store Connect result of an earlier confirmed upload for the same exact IPA identity.
_Avoid_: Concurrent-safe upload

**Confirmed upload**:
A delivery attempt for which the upload command returned success. An upload with an ambiguous command result is not confirmed.
_Avoid_: Possibly uploaded, ambiguous upload

**Delivery attempt**:
An App Store Connect record of an IPA transfer that may exist before an App Store build is created. A failed delivery attempt does not prevent a later attempt for the same exact IPA identity.
_Avoid_: Build, processed build

**App Store build**:
App Store Connect's processed representation of a delivered IPA. It is distinct from the delivery attempt that preceded it.
_Avoid_: Upload, delivery attempt

**Reusable upload**:
An exact App Store build or delivery attempt proving that delivery is processing or complete. A reusable upload does not require another delivery attempt.
_Avoid_: Latest upload, similar build

**Incomplete delivery**:
A delivery attempt that is still awaiting its file transfer. It is neither a reusable upload nor proof that another delivery attempt is safe.
_Avoid_: Processing upload, failed upload

**Ambiguous upload state**:
An exact IPA identity with multiple active records or an unrecognized App Store Connect state. It has no safe automatic reconciliation.
_Avoid_: Latest match, best match

**Upload outcome**:
Whether ReleaseKit created a new delivery attempt (`uploaded`) or accepted a reusable upload (`reused`).
_Avoid_: Upload status, processing state
