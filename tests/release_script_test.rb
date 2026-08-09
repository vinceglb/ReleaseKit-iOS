# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

class ReleaseScriptTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "scripts/release.sh")

  def setup
    @tmp = Dir.mktmpdir("releasekit-release-test-")
    @runner_temp = File.join(@tmp, "runner-temp")
    @bin_dir = File.join(@tmp, "bin")
    @notes_dir = File.join(@tmp, "release-notes")
    @outputs_path = File.join(@tmp, "outputs")
    @summary_path = File.join(@tmp, "summary")
    @asc_log = File.join(@tmp, "asc.log")
    FileUtils.mkdir_p([@runner_temp, @bin_dir, @notes_dir])
    write_ipa(File.join(@tmp, "Molkky.ipa"))
    write_fake_asc
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_prepares_the_exact_ipa_build_and_exposes_structured_outputs
    File.write(File.join(@notes_dir, "en-US.txt"), "A polished new update.\n")
    File.write(File.join(@notes_dir, "fr-FR.txt"), "Une nouvelle mise à jour soignée.\n")

    result = run_release

    assert result[:status].success?, result[:stderr]
    outputs = parse_github_outputs
    assert_equal "com.vinceglb.molkky", outputs.fetch("bundle_id")
    assert_equal "1.2.3", outputs.fetch("marketing_version")
    assert_equal "42", outputs.fetch("build_number")
    assert_equal "version-123", outputs.fetch("app_store_version_id")
    assert_equal "build-123", outputs.fetch("build_id")

    structured = JSON.parse(outputs.fetch("result_json"))
    assert_equal "prepared", structured.fetch("status")
    assert_equal false, structured.fetch("submitted")

    commands = File.read(@asc_log)
    assert_includes commands, "builds info --app 123456789 --build-number 42 --version 1.2.3 --platform IOS"
    assert_includes commands, "builds wait --build-id build-123"
    refute_includes commands, "--latest"
    assert_includes commands, "localizations update --version version-123 --locale en-US"
    assert_includes commands, "versions attach-build --version-id version-123 --build-id build-123"
    assert_includes commands, "validate --app 123456789 --version-id version-123 --platform IOS"
    assert_operator commands.scan("versions view --version-id version-123").length, :>=, 2
    assert_operator commands.scan("localizations list --version version-123").length, :>=, 2
    assert_empty Dir.glob(File.join(@runner_temp, "releasekit-ios-release.*"))
  end

  def test_rejects_over_limit_notes_before_authentication
    File.write(File.join(@notes_dir, "en-US.txt"), "x" * 4001)
    File.write(File.join(@notes_dir, "fr-FR.txt"), "Notes valides")

    result = run_release

    refute result[:status].success?
    assert_includes result[:stderr], "exceeds Apple's 4,000-character limit"
    refute File.exist?(@asc_log), "asc should not run when local notes are invalid"
    assert_empty Dir.glob(File.join(@runner_temp, "releasekit-ios-release.*"))
  end

  def test_rejects_empty_invalid_utf8_and_malformed_note_files
    invalid_cases = {
      "empty" => ["en-US.txt", "   \n", "is empty"],
      "invalid UTF-8" => ["en-US.txt", "\xFF".b, "is not valid UTF-8"],
      "malformed filename" => ["english.md", "Release notes", "Malformed Store Release Note entry"]
    }

    invalid_cases.each do |label, (filename, content, expected_error)|
      Dir.children(@notes_dir).each { |entry| FileUtils.rm_f(File.join(@notes_dir, entry)) }
      File.binwrite(File.join(@notes_dir, filename), content)
      result = run_release

      refute result[:status].success?, "#{label} note unexpectedly succeeded"
      assert_includes result[:stderr], expected_error
    end
    refute File.exist?(@asc_log), "asc should not run when local notes are invalid"
  end

  def test_cleans_up_temporary_credentials_when_authentication_fails
    File.write(File.join(@notes_dir, "en-US.txt"), "Valid notes")
    File.write(File.join(@notes_dir, "fr-FR.txt"), "Notes valides")

    result = run_release("FAKE_ASC_MODE" => "auth-failure")

    refute result[:status].success?
    assert_includes result[:stderr], "asc authentication failed"
    assert_includes File.read(@asc_log), "private-key-present"
    assert_empty Dir.glob(File.join(@runner_temp, "releasekit-ios-release.*"))
  end

  def test_submits_with_the_modern_review_submission_flow
    File.write(File.join(@notes_dir, "en-US.txt"), "A polished new update.\n")
    File.write(File.join(@notes_dir, "fr-FR.txt"), "Une nouvelle mise à jour soignée.\n")

    result = run_release(
      "INPUT_SUBMIT_FOR_REVIEW" => "true",
      "INPUT_RELEASE_TYPE" => "AFTER_APPROVAL"
    )

    assert result[:status].success?, result[:stderr]
    outputs = parse_github_outputs
    assert_equal "ok", outputs.fetch("submission_id")
    assert_equal "WAITING_FOR_REVIEW", outputs.fetch("submission_state")
    assert_equal "submitted", JSON.parse(outputs.fetch("result_json")).fetch("status")

    commands = File.read(@asc_log)
    assert_includes commands, "auth login --bypass-keychain"
    assert_includes commands, "--network"
    assert_includes commands, "account status --app 123456789"
    assert_includes commands, "capabilities --area release --status cli-supported"
    assert_includes commands, "versions update --version-id version-123 --release-type AFTER_APPROVAL"
    assert_includes commands, "review submissions-create --app 123456789 --platform IOS"
    assert_includes commands, "review items add --submission ok --item-type appStoreVersions --item-id version-123"
    assert_includes commands, "review submissions-submit --id ok --confirm"
    assert_includes File.read(@summary_path), "does not claim the update is public yet"
  end

  def test_does_not_accept_a_failed_submission_state
    File.write(File.join(@notes_dir, "en-US.txt"), "A polished new update.\n")
    File.write(File.join(@notes_dir, "fr-FR.txt"), "Une nouvelle mise à jour soignée.\n")

    result = run_release(
      "FAKE_ASC_MODE" => "failed-submission",
      "INPUT_SUBMIT_FOR_REVIEW" => "true",
      "INPUT_RELEASE_TYPE" => "AFTER_APPROVAL"
    )

    refute result[:status].success?
    assert_includes result[:stderr], "is not an accepted state"
  end

  def test_accepts_matching_submitted_state_without_mutation
    File.write(File.join(@notes_dir, "en-US.txt"), "A polished new update.\n")
    File.write(File.join(@notes_dir, "fr-FR.txt"), "Une nouvelle mise à jour soignée.\n")

    result = run_release(
      "FAKE_ASC_MODE" => "already-submitted",
      "INPUT_SUBMIT_FOR_REVIEW" => "true",
      "INPUT_RELEASE_TYPE" => "AFTER_APPROVAL"
    )

    assert result[:status].success?, result[:stderr]
    outputs = parse_github_outputs
    assert_equal "submission-existing", outputs.fetch("submission_id")
    assert_equal "WAITING_FOR_REVIEW", outputs.fetch("submission_state")
    commands = File.read(@asc_log)
    refute_includes commands, "localizations update"
    refute_includes commands, "versions attach-build"
    refute_includes commands, "review submissions-create"
    refute_includes commands, "review submissions-submit"
  end

  def test_masks_decoded_private_key_material
    File.write(File.join(@notes_dir, "en-US.txt"), "Valid notes")
    File.write(File.join(@notes_dir, "fr-FR.txt"), "Notes valides")

    result = run_release("FAKE_ASC_MODE" => "auth-failure")

    assert_includes result[:stdout], "::add-mask::test-key-material"
  end

  def test_rejects_locale_drift_before_release_mutations
    File.write(File.join(@notes_dir, "en-US.txt"), "A polished new update.\n")
    File.write(File.join(@notes_dir, "fr-FR.txt"), "Une nouvelle mise à jour soignée.\n")
    File.write(File.join(@notes_dir, "de-DE.txt"), "Eine sorgfältige Aktualisierung.\n")

    result = run_release

    refute result[:status].success?
    assert_includes result[:stderr], "do not exactly match App Store Connect"
    assert_includes result[:stderr], "extra: de-DE"
    commands = File.read(@asc_log)
    refute_includes commands, "localizations update"
    refute_includes commands, "versions attach-build"
  end

  def test_fails_immediately_for_an_invalid_exact_build
    File.write(File.join(@notes_dir, "en-US.txt"), "A polished new update.\n")
    File.write(File.join(@notes_dir, "fr-FR.txt"), "Une nouvelle mise à jour soignée.\n")

    result = run_release("FAKE_ASC_MODE" => "invalid-build")

    refute result[:status].success?
    assert_includes result[:stderr], "terminal invalid state 'INVALID'"
    refute_includes File.read(@asc_log), "builds wait"
  end

  private

  def run_release(extra_env = {})
    env = {
      "PATH" => "#{@bin_dir}:#{ENV.fetch("PATH")}",
      "RUNNER_TEMP" => @runner_temp,
      "GITHUB_OUTPUT" => @outputs_path,
      "GITHUB_STEP_SUMMARY" => @summary_path,
      "FAKE_ASC_LOG" => @asc_log,
      "FAKE_ASC_STATE_DIR" => File.join(@tmp, "asc-state"),
      "INPUT_APP_ID" => "123456789",
      "INPUT_IPA_PATH" => File.join(@tmp, "Molkky.ipa"),
      "INPUT_RELEASE_NOTES_DIR" => @notes_dir,
      "INPUT_ASC_KEY_ID" => "KEY123",
      "INPUT_ASC_ISSUER_ID" => "ISSUER123",
      "INPUT_ASC_PRIVATE_KEY_B64" => Base64.strict_encode64(<<~PEM),
        -----BEGIN PRIVATE KEY-----
        test-key-material
        -----END PRIVATE KEY-----
      PEM
      "INPUT_SUBMIT_FOR_REVIEW" => "false",
      "INPUT_RELEASE_TYPE" => "MANUAL",
      "INPUT_PROCESSING_TIMEOUT" => "5m",
      "INPUT_POLL_INTERVAL" => "1s",
      "INPUT_ASC_VERSION" => "latest"
    }.merge(extra_env)
    stdout, stderr, status = Open3.capture3(env, "bash", SCRIPT, chdir: ROOT)
    { stdout: stdout, stderr: stderr, status: status }
  end

  def parse_github_outputs
    File.readlines(@outputs_path, chomp: true).to_h { |line| line.split("=", 2) }
  end

  def write_ipa(path)
    payload = File.join(@tmp, "ipa", "Payload", "Molkky.app")
    FileUtils.mkdir_p(payload)
    File.write(File.join(payload, "Info.plist"), <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.vinceglb.molkky</string>
        <key>CFBundleShortVersionString</key><string>1.2.3</string>
        <key>CFBundleVersion</key><string>42</string>
      </dict></plist>
    PLIST
    Dir.chdir(File.join(@tmp, "ipa")) do
      system("zip", "-qr", path, "Payload") || raise("failed to build IPA fixture")
    end
  end

  def write_fake_asc
    path = File.join(@bin_dir, "asc")
    File.write(path, <<~'BASH')
      #!/usr/bin/env bash
      set -euo pipefail
      mkdir -p "${FAKE_ASC_STATE_DIR}"
      echo "$*" >> "${FAKE_ASC_LOG}"
      if [[ "${1:-}" == "version" ]]; then
        echo "3.5.0"
      elif [[ "${1:-} ${2:-}" == "auth login" ]]; then
        key_path=""
        while (($#)); do
          if [[ "$1" == "--private-key" ]]; then key_path="$2"; break; fi
          shift
        done
        [[ -f "${key_path}" ]] && echo "private-key-present" >> "${FAKE_ASC_LOG}"
        [[ "${FAKE_ASC_MODE:-}" != "auth-failure" ]]
      elif [[ "${1:-} ${2:-}" == "account status" ]]; then
        echo '{"summary":{"health":"yellow","nextAction":"agreement status unavailable","errorCount":0,"warningCount":1},"checks":[{"name":"authentication","status":"ok","message":"healthy"},{"name":"api_access","status":"ok","message":"able to read app"},{"name":"agreements","status":"unavailable","message":"not exposed"}],"generatedAt":"2026-08-09T00:00:00Z"}'
      elif [[ "${1:-}" == "capabilities" ]]; then
        echo '{"summary":{"total":2,"schemaEndpointCount":1263,"statuses":{"cli-supported":2},"areas":{"release":2}},"capabilities":[{"area":"release","capability":"App Store release submission","status":"cli-supported"},{"area":"release","capability":"Release readiness validation","status":"cli-supported"}],"sources":["registered CLI command surface"]}'
      elif [[ "${1:-} ${2:-}" == "apps view" ]]; then
        echo '{"data":{"type":"apps","id":"123456789","attributes":{"bundleId":"com.vinceglb.molkky"}}}'
      elif [[ "${1:-} ${2:-}" == "builds info" ]]; then
        if [[ "${FAKE_ASC_MODE:-}" == "invalid-build" ]]; then
          echo '{"data":{"type":"builds","id":"build-123","attributes":{"version":"42","processingState":"INVALID"}}}'
        else
          echo '{"data":{"type":"builds","id":"build-123","attributes":{"version":"42","processingState":"PROCESSING"}}}'
        fi
      elif [[ "${1:-} ${2:-}" == "builds wait" ]]; then
        echo '{"data":{"type":"builds","id":"build-123","attributes":{"version":"42","processingState":"VALID"}}}'
      elif [[ "${1:-} ${2:-}" == "versions list" ]]; then
        if [[ "${FAKE_ASC_MODE:-}" == "already-submitted" || "${FAKE_ASC_MODE:-}" == "failed-submission" ]]; then
          echo '{"data":[{"type":"appStoreVersions","id":"version-123","attributes":{"versionString":"1.2.3","appStoreState":"WAITING_FOR_REVIEW","releaseType":"AFTER_APPROVAL"}}]}'
        elif [[ -f "${FAKE_ASC_STATE_DIR}/release-type-updated" ]]; then
          printf '{"data":[{"type":"appStoreVersions","id":"version-123","attributes":{"versionString":"1.2.3","appStoreState":"PREPARE_FOR_SUBMISSION","releaseType":"%s"}}]}\n' "${INPUT_RELEASE_TYPE}"
        else
          echo '{"data":[{"type":"appStoreVersions","id":"version-123","attributes":{"versionString":"1.2.3","appStoreState":"PREPARE_FOR_SUBMISSION","releaseType":"MANUAL"}}]}'
        fi
      elif [[ "${1:-} ${2:-}" == "versions view" ]]; then
        if [[ "${FAKE_ASC_MODE:-}" == "already-submitted" || "${FAKE_ASC_MODE:-}" == "failed-submission" ]]; then
          echo '{"id":"version-123","state":"WAITING_FOR_REVIEW","buildId":"build-123","submissionId":"submission-existing"}'
        elif [[ -f "${FAKE_ASC_STATE_DIR}/build-attached" ]]; then
          echo '{"id":"version-123","state":"PREPARE_FOR_SUBMISSION","buildId":"build-123","submissionId":""}'
        else
          echo '{"id":"version-123","state":"PREPARE_FOR_SUBMISSION","buildId":"","submissionId":""}'
        fi
      elif [[ "${1:-} ${2:-}" == "localizations list" ]]; then
        if [[ "${FAKE_ASC_MODE:-}" == "already-submitted" || "${FAKE_ASC_MODE:-}" == "failed-submission" || ( -f "${FAKE_ASC_STATE_DIR}/locale-en-US" && -f "${FAKE_ASC_STATE_DIR}/locale-fr-FR" ) ]]; then
          echo '{"data":[{"type":"appStoreVersionLocalizations","id":"loc-en","attributes":{"locale":"en-US","whatsNew":"A polished new update.\n"}},{"type":"appStoreVersionLocalizations","id":"loc-fr","attributes":{"locale":"fr-FR","whatsNew":"Une nouvelle mise à jour soignée.\n"}}]}'
        else
          echo '{"data":[{"type":"appStoreVersionLocalizations","id":"loc-en","attributes":{"locale":"en-US","whatsNew":"Old"}},{"type":"appStoreVersionLocalizations","id":"loc-fr","attributes":{"locale":"fr-FR","whatsNew":"Ancien"}}]}'
        fi
      elif [[ "${1:-} ${2:-}" == "localizations update" ]]; then
        locale=""
        while (($#)); do
          if [[ "$1" == "--locale" ]]; then locale="$2"; break; fi
          shift
        done
        touch "${FAKE_ASC_STATE_DIR}/locale-${locale}"
        echo '{"data":{"id":"localization-updated"}}'
      elif [[ "${1:-} ${2:-}" == "versions attach-build" ]]; then
        touch "${FAKE_ASC_STATE_DIR}/build-attached"
        echo '{"data":{"id":"version-123"}}'
      elif [[ "${1:-} ${2:-}" == "versions update" ]]; then
        touch "${FAKE_ASC_STATE_DIR}/release-type-updated"
        echo '{"data":{"id":"version-123"}}'
      elif [[ "${1:-} ${2:-}" == "review submissions-list" ]]; then
        if [[ "${FAKE_ASC_MODE:-}" == "already-submitted" || "${FAKE_ASC_MODE:-}" == "failed-submission" ]]; then
          if [[ "${FAKE_ASC_MODE:-}" == "failed-submission" ]]; then submission_state="UNRESOLVED_ISSUES"; else submission_state="WAITING_FOR_REVIEW"; fi
          printf '{"data":[{"type":"reviewSubmissions","id":"submission-existing","attributes":{"state":"%s"},"relationships":{"items":{"data":[{"type":"reviewSubmissionItems","id":"item-existing"}]}}}],"included":[{"type":"reviewSubmissionItems","id":"item-existing","attributes":{"state":"%s"},"relationships":{"appStoreVersion":{"data":{"type":"appStoreVersions","id":"version-123"}}}}]}\n' "${submission_state}" "${submission_state}"
        else
          echo '{"data":[],"included":[]}'
        fi
      elif [[ "${1:-} ${2:-}" == "review submissions-get" ]]; then
        echo '{"data":{"type":"reviewSubmissions","id":"submission-123","attributes":{"state":"WAITING_FOR_REVIEW"}}}'
      else
        echo '{"data":{"id":"ok","attributes":{"state":"READY"}}}'
      fi
    BASH
    FileUtils.chmod(0o755, path)
  end
end
