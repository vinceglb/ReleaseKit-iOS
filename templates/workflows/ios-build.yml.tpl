name: iOS Build

on:
  workflow_dispatch:
  workflow_call:
    outputs:
      ipa-artifact-name:
        description: Uploaded IPA artifact name
        value: ${{ jobs.archive.outputs['ipa-artifact-name'] }}
      upload-id:
        description: App Store Connect upload ID
        value: ${{ jobs.upload.outputs['upload-id'] }}

env:
  WORKSPACE: __WORKSPACE__
  SCHEME: __SCHEME__
  BUNDLE_ID: __BUNDLE_ID__
  TEAM_ID: __TEAM_ID__

jobs:
  archive:
    runs-on: __RUNNER_LABEL__
    timeout-minutes: 60
    outputs:
      ipa-artifact-name: ${{ steps.artifact_meta.outputs.name }}

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Select Xcode
        uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: "26.2"

      - name: ReleaseKit-iOS archive and export
        id: ios_archive
        uses: vinceglb/releasekit-ios/actions/archive@__ACTION_REF__
        with:
          workspace: ${{ env.WORKSPACE }}
          scheme: ${{ env.SCHEME }}
          bundle_id: ${{ env.BUNDLE_ID }}
          asc_key_id: ${{ secrets.ASC_KEY_ID }}
          asc_issuer_id: ${{ secrets.ASC_ISSUER_ID }}
          asc_private_key_b64: ${{ secrets.ASC_PRIVATE_KEY_B64 }}
          asc_team_id: ${{ secrets.ASC_TEAM_ID }}
          configuration: Release

      - name: Set artifact metadata
        id: artifact_meta
        run: echo "name=Marmalade.ipa" >> "$GITHUB_OUTPUT"

      - name: Upload IPA artifact
        uses: actions/upload-artifact@v4
        with:
          name: ${{ steps.artifact_meta.outputs.name }}
          path: ${{ steps.ios_archive.outputs.ipa_path }}
          if-no-files-found: error

      - name: Archive summary
        run: |
          echo "## iOS Archive Summary" >> "$GITHUB_STEP_SUMMARY"
          echo "" >> "$GITHUB_STEP_SUMMARY"
          echo "- **Archive Path**: \`${{ steps.ios_archive.outputs.archive_path }}\`" >> "$GITHUB_STEP_SUMMARY"
          echo "- **IPA Path**: \`${{ steps.ios_archive.outputs.ipa_path }}\`" >> "$GITHUB_STEP_SUMMARY"
          echo "- **Bundle ID**: \`${{ steps.ios_archive.outputs.archive_bundle_id }}\`" >> "$GITHUB_STEP_SUMMARY"

  upload:
    runs-on: __RUNNER_LABEL__
    timeout-minutes: 30
    needs: archive
    outputs:
      upload-id: ${{ steps.ios_upload.outputs.upload_id }}

    steps:
      - name: ReleaseKit-iOS upload to App Store Connect
        id: ios_upload
        uses: vinceglb/releasekit-ios/actions/upload@__ACTION_REF__
        with:
          app_id: ${{ vars.ASC_APP_ID }}
          asc_key_id: ${{ secrets.ASC_KEY_ID }}
          asc_issuer_id: ${{ secrets.ASC_ISSUER_ID }}
          asc_private_key_b64: ${{ secrets.ASC_PRIVATE_KEY_B64 }}
          artifact_name: ${{ needs.archive.outputs['ipa-artifact-name'] }}
          artifact_download_path: ${{ runner.temp }}/releasekit-upload
          wait_for_processing: "false"
          poll_interval: 30s

      - name: Upload summary
        run: |
          echo "## iOS Upload Summary" >> "$GITHUB_STEP_SUMMARY"
          echo "" >> "$GITHUB_STEP_SUMMARY"
          echo "- **ASC Upload ID**: \`${{ steps.ios_upload.outputs.upload_id }}\`" >> "$GITHUB_STEP_SUMMARY"
          echo "- **ASC File ID**: \`${{ steps.ios_upload.outputs.file_id }}\`" >> "$GITHUB_STEP_SUMMARY"
