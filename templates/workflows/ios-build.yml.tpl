name: iOS Build

on:
  workflow_dispatch:
    inputs:
      wait_for_processing:
        description: Wait for App Store Connect processing before this workflow completes
        required: false
        type: boolean
        default: false
      asc_version:
        description: asc CLI version installed by the shared action
        required: false
        default: 0.28.8
  workflow_call:
    inputs:
      wait_for_processing:
        description: Wait for App Store Connect processing before this workflow completes
        required: false
        type: boolean
        default: false
      asc_version:
        description: asc CLI version installed by the shared action
        required: false
        type: string
        default: 0.28.8
    outputs:
      ipa-artifact-name:
        description: Uploaded IPA artifact name
        value: Marmalade.ipa

env:
  WORKSPACE: __WORKSPACE__
  SCHEME: __SCHEME__
  BUNDLE_ID: __BUNDLE_ID__
  TEAM_ID: __TEAM_ID__

jobs:
  build:
    runs-on: __RUNNER_LABEL__
    timeout-minutes: 60

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Select Xcode
        uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: "26.2"

      - name: ReleaseKit-iOS archive, export, and upload
        id: ios_upload
        uses: vinceglb/releasekit-ios@__ACTION_REF__
        with:
          workspace: ${{ env.WORKSPACE }}
          scheme: ${{ env.SCHEME }}
          app_id: ${{ vars.ASC_APP_ID }}
          bundle_id: ${{ env.BUNDLE_ID }}
          asc_key_id: ${{ secrets.ASC_KEY_ID }}
          asc_issuer_id: ${{ secrets.ASC_ISSUER_ID }}
          asc_private_key_b64: ${{ secrets.ASC_PRIVATE_KEY_B64 }}
          asc_team_id: ${{ secrets.ASC_TEAM_ID }}
          configuration: Release
          asc_version: ${{ inputs.asc_version }}
          wait_for_processing: ${{ inputs.wait_for_processing }}
          poll_interval: 30s

      - name: Upload IPA artifact
        uses: actions/upload-artifact@v4
        with:
          name: Marmalade.ipa
          path: ${{ steps.ios_upload.outputs.ipa_path }}
          if-no-files-found: error

      - name: Build summary
        run: |
          echo "## iOS Build Summary" >> "$GITHUB_STEP_SUMMARY"
          echo "" >> "$GITHUB_STEP_SUMMARY"
          echo "- **Archive Path**: \`${{ steps.ios_upload.outputs.archive_path }}\`" >> "$GITHUB_STEP_SUMMARY"
          echo "- **IPA Path**: \`${{ steps.ios_upload.outputs.ipa_path }}\`" >> "$GITHUB_STEP_SUMMARY"
          echo "- **ASC Upload ID**: \`${{ steps.ios_upload.outputs.upload_id }}\`" >> "$GITHUB_STEP_SUMMARY"
