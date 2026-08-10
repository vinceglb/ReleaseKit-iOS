# Keep upload idempotency narrow

ReleaseKit treats an upload as retry-safe when a later, non-overlapping invocation uses the same exact IPA identity after a confirmed upload. It reuses an exact build or delivery that is processing or complete, retries after a failed delivery, and fails on processed rejection, incomplete delivery, or ambiguous remote state. Simultaneous invocations and ambiguous upload-command failures are excluded because supporting them would require coordination and recovery machinery beyond the downstream-retry problem ReleaseKit needs to solve.
