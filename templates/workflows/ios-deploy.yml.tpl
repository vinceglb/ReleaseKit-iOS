name: iOS Deploy

on:
  workflow_dispatch:
    inputs:
      destination:
        description: Where to deploy this build
        required: true
        default: testflight
        type: choice
        options:
          - testflight
          - appstore
      testflight_group:
        description: TestFlight group name (used only for destination=testflight)
        required: false
        default: Internal Testers
      submit_for_review:
        description: Submit App Store release for review
        required: false
        type: boolean
        default: false

jobs:
  build:
    uses: ./.github/workflows/ios-build.yml
    secrets: inherit

  deploy:
    runs-on: __RUNNER_LABEL__
    timeout-minutes: 60
    needs: build

    steps:
      - name: Select Xcode
        uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: "26.2"

      - name: Install asc CLI
        run: |
          curl -fsSL https://raw.githubusercontent.com/rudrankriyam/App-Store-Connect-CLI/main/install.sh | bash
          echo "$HOME/.local/bin" >> "$GITHUB_PATH"

      - name: Configure ASC auth
        env:
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          ASC_PRIVATE_KEY_B64: ${{ secrets.ASC_PRIVATE_KEY_B64 }}
          ASC_BYPASS_KEYCHAIN: '1'
        run: |
          echo "$ASC_PRIVATE_KEY_B64" | base64 --decode > /tmp/AuthKey.p8
          chmod 600 /tmp/AuthKey.p8

          asc auth login --skip-validation --name "CI" \
            --key-id "$ASC_KEY_ID" \
            --issuer-id "$ASC_ISSUER_ID" \
            --private-key /tmp/AuthKey.p8 \
            --bypass-keychain

          rm /tmp/AuthKey.p8

      - name: Download IPA artifact
        uses: actions/download-artifact@v4
        with:
          name: Marmalade.ipa
          path: ./ipa

      - name: Resolve IPA path
        id: ipa
        run: |
          ipa_path=$(find ./ipa -type f -name "*.ipa" -print -quit)
          if [[ -z "$ipa_path" ]]; then
            echo "No IPA found in ./ipa"
            exit 1
          fi
          echo "path=$ipa_path" >> "$GITHUB_OUTPUT"

      - name: Deploy to TestFlight
        if: ${{ inputs.destination == 'testflight' }}
        env:
          ASC_BYPASS_KEYCHAIN: '1'
        run: |
          asc publish testflight \
            --app "${{ vars.ASC_APP_ID }}" \
            --ipa "${{ steps.ipa.outputs.path }}" \
            --group "${{ inputs.testflight_group }}" \
            --notify \
            --wait \
            --timeout 30m

      - name: Deploy to App Store
        if: ${{ inputs.destination == 'appstore' }}
        env:
          ASC_BYPASS_KEYCHAIN: '1'
        run: |
          submit_flag=""
          if [[ "${{ inputs.submit_for_review }}" == "true" ]]; then
            submit_flag="--submit --confirm"
          fi

          asc publish appstore \
            --app "${{ vars.ASC_APP_ID }}" \
            --ipa "${{ steps.ipa.outputs.path }}" \
            $submit_flag \
            --wait \
            --timeout 30m

      - name: Deploy summary
        run: |
          echo "## iOS Deploy Summary" >> "$GITHUB_STEP_SUMMARY"
          echo "" >> "$GITHUB_STEP_SUMMARY"
          echo "- **Destination**: ${{ inputs.destination }}" >> "$GITHUB_STEP_SUMMARY"
          echo "- **Artifact**: \`${{ steps.ipa.outputs.path }}\`" >> "$GITHUB_STEP_SUMMARY"
          echo "- **ASC App ID**: \`${{ vars.ASC_APP_ID }}\`" >> "$GITHUB_STEP_SUMMARY"
