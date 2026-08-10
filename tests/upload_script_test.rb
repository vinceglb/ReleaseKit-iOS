# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

class UploadScriptTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "scripts/upload.sh")

  def setup
    @tmp = Dir.mktmpdir("releasekit-upload-test-")
    @runner_temp = File.join(@tmp, "runner-temp")
    @bin_dir = File.join(@tmp, "bin")
    @outputs_path = File.join(@tmp, "outputs")
    @asc_log = File.join(@tmp, "asc.log")
    @asc_state_dir = File.join(@tmp, "asc-state")
    FileUtils.mkdir_p([@runner_temp, @bin_dir, @asc_state_dir])
    write_ipa(File.join(@tmp, "Molkky.ipa"))
    write_fake_asc
    write_fake_sleep
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_uploads_once_when_no_exact_build_or_upload_exists
    result = run_upload

    assert result[:status].success?, result[:stderr]
    outputs = parse_github_outputs
    assert_equal File.join(@tmp, "Molkky.ipa"), outputs.fetch("ipa_path")
    assert_equal "upload-new", outputs.fetch("upload_id")
    assert_equal "file-new", outputs.fetch("file_id")
    assert_equal "uploaded", outputs.fetch("outcome")
    assert_equal "upload-new", JSON.parse(outputs.fetch("asc_result_json")).fetch("uploadId")

    commands = File.read(@asc_log)
    assert_includes commands, "apps view --id 123456789 --output json"
    assert_includes commands, "builds list --app 123456789 --version 1.2.3 --build-number 42 --platform IOS"
    assert_includes commands, "builds uploads list --app 123456789 --cf-bundle-short-version 1.2.3 --cf-bundle-version 42 --platform IOS"
    assert_equal 3, commands.scan("builds uploads list").length
    assert_equal 1, commands.scan("builds upload ").length
    assert_includes commands, "builds upload --app 123456789 --ipa #{@tmp}/Molkky.ipa --version 1.2.3 --build-number 42"
    refute_includes commands, "--latest"
    assert_empty Dir.glob(File.join(@runner_temp, "releasekit-ios-upload.*"))
  end

  def test_reuses_the_exact_existing_build_without_uploading_again
    result = run_upload("FAKE_ASC_MODE" => "existing-valid-build")

    assert result[:status].success?, result[:stderr]
    outputs = parse_github_outputs
    assert_equal "reused", outputs.fetch("outcome")
    assert_equal "", outputs.fetch("upload_id")
    assert_equal "", outputs.fetch("file_id")
    assert_equal "", outputs.fetch("asc_result_json")

    commands = File.read(@asc_log)
    assert_includes commands, "builds list --app 123456789 --version 1.2.3 --build-number 42 --platform IOS"
    refute_includes commands, "builds upload "
    refute_includes commands, "--latest"
  end

  def test_reuses_an_exact_upload_that_is_still_processing
    result = run_upload("FAKE_ASC_MODE" => "existing-processing-upload")

    assert result[:status].success?, result[:stderr]
    outputs = parse_github_outputs
    assert_equal "reused", outputs.fetch("outcome")
    assert_equal "", outputs.fetch("upload_id")
    assert_equal "", outputs.fetch("file_id")
    assert_equal "", outputs.fetch("asc_result_json")

    commands = File.read(@asc_log)
    assert_includes commands, "builds uploads list --app 123456789 --cf-bundle-short-version 1.2.3 --cf-bundle-version 42 --platform IOS"
    refute_includes commands, "builds upload "
  end

  def test_reconciles_eventual_consistency_before_uploading
    result = run_upload("FAKE_ASC_MODE" => "upload-appears-on-second-pass")

    assert result[:status].success?, result[:stderr]
    assert_equal "reused", parse_github_outputs.fetch("outcome")
    commands = File.read(@asc_log)
    assert_operator commands.scan("builds uploads list").length, :>=, 2
    refute_includes commands, "builds upload "
  end

  def test_waits_for_processing_after_a_fresh_upload
    result = run_upload("INPUT_WAIT_FOR_PROCESSING" => "true", "INPUT_POLL_INTERVAL" => "7s")

    assert result[:status].success?, result[:stderr]
    assert_equal "uploaded", parse_github_outputs.fetch("outcome")
    commands = File.read(@asc_log)
    assert_includes commands, "builds upload --app 123456789 --ipa #{@tmp}/Molkky.ipa --version 1.2.3 --build-number 42 --wait --poll-interval 7s"
  end

  def test_waits_for_processing_when_reusing_an_upload
    result = run_upload(
      "FAKE_ASC_MODE" => "existing-processing-upload",
      "INPUT_WAIT_FOR_PROCESSING" => "true",
      "INPUT_POLL_INTERVAL" => "7s"
    )

    assert result[:status].success?, result[:stderr]
    assert_equal "reused", parse_github_outputs.fetch("outcome")
    commands = File.read(@asc_log)
    assert_includes commands, "builds uploads view --id upload-existing --output json"
    assert_includes commands, "builds wait --build-id build-after-upload"
    assert_includes commands, "--poll-interval 7s --fail-on-invalid --output json"
    refute_includes commands, "builds wait --app"
    refute_includes commands, "builds upload "
  end

  def test_does_not_reuse_a_different_marketing_version
    result = run_upload("FAKE_ASC_MODE" => "wrong-marketing-version")

    assert result[:status].success?, result[:stderr]
    assert_equal "uploaded", parse_github_outputs.fetch("outcome")
    commands = File.read(@asc_log)
    assert_equal 1, commands.scan("builds upload ").length
  end

  def test_does_not_reuse_a_different_build_number
    result = run_upload("FAKE_ASC_MODE" => "wrong-build-number")

    assert result[:status].success?, result[:stderr]
    assert_equal "uploaded", parse_github_outputs.fetch("outcome")
    commands = File.read(@asc_log)
    assert_equal 1, commands.scan("builds upload ").length
  end

  def test_fails_for_an_invalid_exact_build_without_uploading_again
    result = run_upload("FAKE_ASC_MODE" => "invalid-build")

    refute result[:status].success?
    assert_includes result[:stderr], "terminal invalid state 'INVALID'"
    assert_includes result[:stderr], "Increment the immutable build number"
    refute_includes File.read(@asc_log), "builds upload "
  end

  def test_validates_the_ipa_before_authentication
    invalid_ipa = File.join(@tmp, "Invalid.ipa")
    File.write(invalid_ipa, "not a zip")

    result = run_upload("INPUT_IPA_PATH" => invalid_ipa)

    refute result[:status].success?
    assert_includes result[:stderr], "Unable to inspect IPA"
    refute File.exist?(@asc_log), "asc should not run for an invalid IPA"
  end

  def test_rejects_a_bundle_id_mismatch_before_reconciliation_or_upload
    result = run_upload("FAKE_ASC_MODE" => "bundle-mismatch")

    refute result[:status].success?
    assert_includes result[:stderr], "Bundle ID mismatch"
    commands = File.read(@asc_log)
    refute_includes commands, "builds list"
    refute_includes commands, "builds uploads list"
    refute_includes commands, "builds upload "
  end

  def test_masks_decoded_credentials_and_cleans_up_when_authentication_fails
    result = run_upload("FAKE_ASC_MODE" => "auth-failure")

    refute result[:status].success?
    assert_includes result[:stdout], "::add-mask::test-key-material"
    assert_includes result[:stderr], "asc auth login failed"
    assert_includes File.read(@asc_log), "private-key-present"
    assert_empty Dir.glob(File.join(@runner_temp, "releasekit-ios-upload.*"))
  end

  def test_preserves_artifact_mode_source_resolution
    artifact_dir = File.join(@tmp, "artifact")
    FileUtils.mkdir_p(artifact_dir)
    artifact_ipa = File.join(artifact_dir, "Downloaded.ipa")
    FileUtils.cp(File.join(@tmp, "Molkky.ipa"), artifact_ipa)

    result = run_upload(
      "INPUT_IPA_PATH" => "",
      "INPUT_ARTIFACT_NAME" => "Smoke.ipa",
      "INPUT_ARTIFACT_DOWNLOAD_PATH" => artifact_dir
    )

    assert result[:status].success?, result[:stderr]
    assert_equal artifact_ipa, parse_github_outputs.fetch("ipa_path")
  end

  def test_rechecks_an_awaiting_upload_then_fails_closed
    result = run_upload("FAKE_ASC_MODE" => "awaiting-upload")

    refute result[:status].success?
    assert_includes result[:stderr], "still awaiting file upload"
    commands = File.read(@asc_log)
    assert_equal 3, commands.scan("builds uploads list").length
    refute_includes commands, "builds upload "
  end

  def test_fails_for_an_unrecoverable_failed_upload
    result = run_upload("FAKE_ASC_MODE" => "failed-upload")

    refute result[:status].success?
    assert_includes result[:stderr], "unrecoverable error"
    assert_includes result[:stderr], "Invalid bundle"
    refute_includes File.read(@asc_log), "builds upload "
  end

  def test_mixed_transient_and_permanent_upload_errors_fail_closed
    result = run_upload("FAKE_ASC_MODE" => "mixed-failed-upload")

    refute result[:status].success?
    assert_includes result[:stderr], "unrecoverable error"
    assert_includes result[:stderr], "Invalid bundle"
    refute_includes File.read(@asc_log), "builds upload "
  end

  def test_error_messages_cannot_make_a_permanent_code_retryable
    result = run_upload("FAKE_ASC_MODE" => "validation-error-mentions-network")

    refute result[:status].success?
    assert_includes result[:stderr], "unrecoverable error"
    refute_includes File.read(@asc_log), "builds upload "
  end

  def test_reuses_a_valid_build_even_when_failed_upload_history_exists
    result = run_upload("FAKE_ASC_MODE" => "valid-build-with-failed-history")

    assert result[:status].success?, result[:stderr]
    assert_equal "reused", parse_github_outputs.fetch("outcome")
    refute_includes File.read(@asc_log), "builds upload "
  end

  def test_reuses_an_active_upload_even_when_failed_upload_history_exists
    result = run_upload("FAKE_ASC_MODE" => "active-upload-with-failed-history")

    assert result[:status].success?, result[:stderr]
    assert_equal "reused", parse_github_outputs.fetch("outcome")
    refute_includes File.read(@asc_log), "builds upload "
  end

  def test_retries_once_after_only_transient_failed_uploads_remain
    result = run_upload("FAKE_ASC_MODE" => "transient-failed-upload")

    assert result[:status].success?, result[:stderr]
    assert_equal "uploaded", parse_github_outputs.fetch("outcome")
    commands = File.read(@asc_log)
    assert_equal 3, commands.scan("builds uploads list").length
    assert_equal 1, commands.scan("builds upload ").length
  end

  def test_retains_an_observed_upload_when_later_lists_temporarily_omit_it
    result = run_upload("FAKE_ASC_MODE" => "awaiting-upload-disappears")

    refute result[:status].success?
    assert_includes result[:stderr], "still awaiting file upload"
    commands = File.read(@asc_log)
    assert_includes commands, "builds uploads view --id upload-awaiting --output json"
    refute_includes commands, "builds upload "
  end

  def test_fails_closed_for_an_unknown_exact_upload_state
    result = run_upload("FAKE_ASC_MODE" => "unknown-upload-state")

    refute result[:status].success?
    assert_includes result[:stderr], "unsupported state 'MYSTERY'"
    refute_includes File.read(@asc_log), "builds upload "
  end

  def test_upload_action_does_not_require_jq
    result = run_upload("PATH" => "#{@bin_dir}:/usr/bin:/bin")

    assert result[:status].success?, result[:stderr]
    assert_equal "uploaded", parse_github_outputs.fetch("outcome")
  end

  def test_reconciles_an_ambiguous_upload_failure_to_reused
    result = run_upload("FAKE_ASC_MODE" => "ambiguous-upload-failure")

    assert result[:status].success?, result[:stderr]
    outputs = parse_github_outputs
    assert_equal "reused", outputs.fetch("outcome")
    assert_equal "", outputs.fetch("upload_id")
    assert_equal "", outputs.fetch("file_id")
    assert_equal "", outputs.fetch("asc_result_json")
    assert_equal 1, File.read(@asc_log).scan("builds upload ").length
  end

  private

  def run_upload(extra_env = {})
    env = {
      "PATH" => "#{@bin_dir}:#{ENV.fetch("PATH")}",
      "RUNNER_TEMP" => @runner_temp,
      "GITHUB_OUTPUT" => @outputs_path,
      "FAKE_ASC_LOG" => @asc_log,
      "FAKE_ASC_STATE_DIR" => @asc_state_dir,
      "INPUT_APP_ID" => "123456789",
      "INPUT_ASC_KEY_ID" => "KEY123",
      "INPUT_ASC_ISSUER_ID" => "ISSUER123",
      "INPUT_ASC_PRIVATE_KEY_B64" => Base64.strict_encode64(<<~PEM),
        -----BEGIN PRIVATE KEY-----
        test-key-material
        -----END PRIVATE KEY-----
      PEM
      "INPUT_IPA_PATH" => File.join(@tmp, "Molkky.ipa"),
      "INPUT_ARTIFACT_NAME" => "",
      "INPUT_ARTIFACT_DOWNLOAD_PATH" => File.join(@tmp, "artifact"),
      "INPUT_WAIT_FOR_PROCESSING" => "false",
      "INPUT_POLL_INTERVAL" => "1s"
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
      echo "$*" >> "${FAKE_ASC_LOG}"
      if [[ "${1:-} ${2:-}" == "auth login" ]]; then
        key_path=""
        while (($#)); do
          if [[ "$1" == "--private-key" ]]; then key_path="$2"; break; fi
          shift
        done
        [[ -f "${key_path}" ]] && echo "private-key-present" >> "${FAKE_ASC_LOG}"
        [[ "${FAKE_ASC_MODE:-}" != "auth-failure" ]]
      elif [[ "${1:-} ${2:-}" == "apps view" ]]; then
        if [[ "${FAKE_ASC_MODE:-}" == "bundle-mismatch" ]]; then
          echo '{"data":{"type":"apps","id":"123456789","attributes":{"bundleId":"com.example.other"}}}'
        else
          echo '{"data":{"type":"apps","id":"123456789","attributes":{"bundleId":"com.vinceglb.molkky"}}}'
        fi
      elif [[ "${1:-} ${2:-}" == "builds list" ]]; then
        if [[ "${FAKE_ASC_MODE:-}" == "existing-valid-build" || "${FAKE_ASC_MODE:-}" == "valid-build-with-failed-history" ]]; then
          echo '{"data":[{"type":"builds","id":"build-existing","attributes":{"version":"42","processingState":"VALID"}}]}'
        elif [[ "${FAKE_ASC_MODE:-}" == "existing-processing-upload" && -f "${FAKE_ASC_STATE_DIR}/upload-viewed" ]]; then
          echo '{"data":[{"type":"builds","id":"build-after-upload","attributes":{"version":"42","processingState":"PROCESSING"}}]}'
        elif [[ "${FAKE_ASC_MODE:-}" == "invalid-build" ]]; then
          echo '{"data":[{"type":"builds","id":"build-invalid","attributes":{"version":"42","processingState":"INVALID"}}]}'
        elif [[ "${FAKE_ASC_MODE:-}" == "wrong-build-number" ]]; then
          echo '{"data":[{"type":"builds","id":"build-wrong","attributes":{"version":"43","processingState":"VALID"}}]}'
        else
          echo '{"data":[]}'
        fi
      elif [[ "${1:-} ${2:-} ${3:-}" == "builds uploads list" ]]; then
        if [[ "${FAKE_ASC_MODE:-}" == "existing-processing-upload" ]]; then
          echo '{"data":[{"type":"buildUploads","id":"upload-existing","attributes":{"cfBundleShortVersionString":"1.2.3","cfBundleVersion":"42","platform":"IOS","state":{"state":"PROCESSING","errors":[]}}}]}'
        elif [[ "${FAKE_ASC_MODE:-}" == "awaiting-upload" ]]; then
          echo '{"data":[{"type":"buildUploads","id":"upload-awaiting","attributes":{"cfBundleShortVersionString":"1.2.3","cfBundleVersion":"42","platform":"IOS","state":{"state":"AWAITING_UPLOAD","errors":[]}}}]}'
        elif [[ "${FAKE_ASC_MODE:-}" == "awaiting-upload-disappears" ]]; then
          counter_path="${FAKE_ASC_STATE_DIR}/awaiting-list-count"
          count=0
          [[ -f "${counter_path}" ]] && count="$(<"${counter_path}")"
          count=$((count + 1))
          echo "${count}" > "${counter_path}"
          if [[ "${count}" -eq 1 ]]; then
            echo '{"data":[{"type":"buildUploads","id":"upload-awaiting","attributes":{"cfBundleShortVersionString":"1.2.3","cfBundleVersion":"42","platform":"IOS","state":{"state":"AWAITING_UPLOAD","errors":[]}}}]}'
          else
            echo '{"data":[]}'
          fi
        elif [[ "${FAKE_ASC_MODE:-}" == "unknown-upload-state" ]]; then
          echo '{"data":[{"type":"buildUploads","id":"upload-unknown","attributes":{"cfBundleShortVersionString":"1.2.3","cfBundleVersion":"42","platform":"IOS","state":{"state":"MYSTERY","errors":[]}}}]}'
        elif [[ "${FAKE_ASC_MODE:-}" == "failed-upload" ]]; then
          echo '{"data":[{"type":"buildUploads","id":"upload-failed","attributes":{"cfBundleShortVersionString":"1.2.3","cfBundleVersion":"42","platform":"IOS","state":{"state":"FAILED","errors":[{"code":"STATE_ERROR.VALIDATION_ERROR.90061","message":"Invalid bundle"}]}}}]}'
        elif [[ "${FAKE_ASC_MODE:-}" == "mixed-failed-upload" ]]; then
          echo '{"data":[{"type":"buildUploads","id":"upload-failed","attributes":{"cfBundleShortVersionString":"1.2.3","cfBundleVersion":"42","platform":"IOS","state":{"state":"FAILED","errors":[{"code":"UPLOAD_ERROR.NETWORK_TIMEOUT","message":"Connection timed out"},{"code":"STATE_ERROR.VALIDATION_ERROR.90061","message":"Invalid bundle"}]}}}]}'
        elif [[ "${FAKE_ASC_MODE:-}" == "validation-error-mentions-network" ]]; then
          echo '{"data":[{"type":"buildUploads","id":"upload-failed","attributes":{"cfBundleShortVersionString":"1.2.3","cfBundleVersion":"42","platform":"IOS","state":{"state":"FAILED","errors":[{"code":"STATE_ERROR.VALIDATION_ERROR.90061","message":"Invalid network configuration in bundle"}]}}}]}'
        elif [[ "${FAKE_ASC_MODE:-}" == "valid-build-with-failed-history" ]]; then
          echo '{"data":[{"type":"buildUploads","id":"upload-failed","attributes":{"cfBundleShortVersionString":"1.2.3","cfBundleVersion":"42","platform":"IOS","state":{"state":"FAILED","errors":[{"code":"STATE_ERROR.VALIDATION_ERROR.90061","message":"Invalid bundle"}]}}}]}'
        elif [[ "${FAKE_ASC_MODE:-}" == "active-upload-with-failed-history" ]]; then
          echo '{"data":[{"type":"buildUploads","id":"upload-failed","attributes":{"cfBundleShortVersionString":"1.2.3","cfBundleVersion":"42","platform":"IOS","state":{"state":"FAILED","errors":[{"code":"STATE_ERROR.VALIDATION_ERROR.90061","message":"Invalid bundle"}]} }},{"type":"buildUploads","id":"upload-active","attributes":{"cfBundleShortVersionString":"1.2.3","cfBundleVersion":"42","platform":"IOS","state":{"state":"PROCESSING","errors":[]}}}]}'
        elif [[ "${FAKE_ASC_MODE:-}" == "transient-failed-upload" ]]; then
          echo '{"data":[{"type":"buildUploads","id":"upload-failed","attributes":{"cfBundleShortVersionString":"1.2.3","cfBundleVersion":"42","platform":"IOS","state":{"state":"FAILED","errors":[{"code":"UPLOAD_ERROR.NETWORK_TIMEOUT","message":"Connection timed out"}]}}}]}'
        elif [[ "${FAKE_ASC_MODE:-}" == "ambiguous-upload-failure" && -f "${FAKE_ASC_STATE_DIR}/committed" ]]; then
          echo '{"data":[{"type":"buildUploads","id":"upload-ambiguous","attributes":{"cfBundleShortVersionString":"1.2.3","cfBundleVersion":"42","platform":"IOS","state":{"state":"PROCESSING","errors":[]}}}]}'
        elif [[ "${FAKE_ASC_MODE:-}" == "upload-appears-on-second-pass" ]]; then
          counter_path="${FAKE_ASC_STATE_DIR}/upload-list-count"
          count=0
          [[ -f "${counter_path}" ]] && count="$(<"${counter_path}")"
          count=$((count + 1))
          echo "${count}" > "${counter_path}"
          if [[ "${count}" -ge 2 ]]; then
            echo '{"data":[{"type":"buildUploads","id":"upload-eventual","attributes":{"cfBundleShortVersionString":"1.2.3","cfBundleVersion":"42","platform":"IOS","state":{"state":"PROCESSING","errors":[]}}}]}'
          else
            echo '{"data":[]}'
          fi
        elif [[ "${FAKE_ASC_MODE:-}" == "wrong-marketing-version" ]]; then
          echo '{"data":[{"type":"buildUploads","id":"upload-wrong","attributes":{"cfBundleShortVersionString":"9.9.9","cfBundleVersion":"42","platform":"IOS","state":{"state":"PROCESSING","errors":[]}}}]}'
        elif [[ "${FAKE_ASC_MODE:-}" == "wrong-build-number" ]]; then
          echo '{"data":[{"type":"buildUploads","id":"upload-wrong","attributes":{"cfBundleShortVersionString":"1.2.3","cfBundleVersion":"99","platform":"IOS","state":{"state":"PROCESSING","errors":[]}}}]}'
        else
          echo '{"data":[]}'
        fi
      elif [[ "${1:-} ${2:-}" == "builds upload" ]]; then
        if [[ "${FAKE_ASC_MODE:-}" == "ambiguous-upload-failure" ]]; then
          touch "${FAKE_ASC_STATE_DIR}/committed"
          echo '{"error":"connection closed after commit"}'
          exit 1
        fi
        echo '{"uploadId":"upload-new","fileId":"file-new","state":"UPLOAD_COMPLETE"}'
      elif [[ "${1:-} ${2:-} ${3:-}" == "builds uploads view" ]]; then
        if [[ "${FAKE_ASC_MODE:-}" == "awaiting-upload" || "${FAKE_ASC_MODE:-}" == "awaiting-upload-disappears" ]]; then
          echo '{"data":{"type":"buildUploads","id":"upload-awaiting","attributes":{"state":{"state":"AWAITING_UPLOAD","errors":[]}}}}'
        else
          touch "${FAKE_ASC_STATE_DIR}/upload-viewed"
          echo '{"data":{"type":"buildUploads","id":"upload-existing","attributes":{"state":{"state":"COMPLETE","errors":[]}}}}'
        fi
      elif [[ "${1:-} ${2:-}" == "builds wait" ]]; then
        echo '{"data":{"type":"builds","id":"build-existing","attributes":{"version":"42","processingState":"VALID"}}}'
      else
        echo "Unexpected asc command: $*" >&2
        exit 64
      fi
    BASH
    FileUtils.chmod(0o755, path)
  end

  def write_fake_sleep
    path = File.join(@bin_dir, "sleep")
    File.write(path, "#!/usr/bin/env bash\nexit 0\n")
    FileUtils.chmod(0o755, path)
  end
end
