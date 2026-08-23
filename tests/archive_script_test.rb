# frozen_string_literal: true

require "base64"
require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class ArchiveScriptTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPT = File.join(ROOT, "scripts/archive.sh")

  def setup
    @tmp = Dir.mktmpdir("releasekit-archive-test-")
    @runner_temp = File.join(@tmp, "runner-temp")
    @bin_dir = File.join(@tmp, "bin")
    @workspace = File.join(@tmp, "Molkky.xcworkspace")
    @archive_path = File.join(@tmp, "Molkky.xcarchive")
    @export_path = File.join(@tmp, "export")
    @captured_export_options = File.join(@tmp, "ExportOptions.plist")
    @outputs_path = File.join(@tmp, "outputs")
    FileUtils.mkdir_p([@runner_temp, @bin_dir, @workspace])
    write_archive_info_plist
    write_fake_xcodebuild
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_forces_xcode_to_export_locally_before_the_separate_upload_step
    result = run_archive

    assert result[:status].success?, result[:stderr]
    export_options = File.read(@captured_export_options)
    assert_match(%r{<key>destination</key>\s*<string>export</string>}, export_options)
  end

  private

  def run_archive
    env = {
      "PATH" => "#{@bin_dir}:#{ENV.fetch("PATH")}",
      "RUNNER_TEMP" => @runner_temp,
      "GITHUB_OUTPUT" => @outputs_path,
      "FAKE_ARCHIVE_INFO_PLIST" => File.join(@tmp, "ArchiveInfo.plist"),
      "FAKE_CAPTURED_EXPORT_OPTIONS" => @captured_export_options,
      "INPUT_WORKSPACE" => @workspace,
      "INPUT_SCHEME" => "Molkky",
      "INPUT_BUNDLE_ID" => "io.github.vinceglb.molkky",
      "INPUT_ASC_KEY_ID" => "KEY123",
      "INPUT_ASC_ISSUER_ID" => "ISSUER123",
      "INPUT_ASC_PRIVATE_KEY_B64" => Base64.strict_encode64(<<~PEM),
        -----BEGIN PRIVATE KEY-----
        test-key-material
        -----END PRIVATE KEY-----
      PEM
      "INPUT_ASC_TEAM_ID" => "TEAM123",
      "INPUT_CONFIGURATION" => "Release",
      "INPUT_ARCHIVE_PATH" => @archive_path,
      "INPUT_EXPORT_PATH" => @export_path,
      "INPUT_XCODEBUILD_EXTRA_ARGS" => ""
    }
    stdout, stderr, status = Open3.capture3(env, "bash", SCRIPT, chdir: ROOT)
    { stdout: stdout, stderr: stderr, status: status }
  end

  def write_archive_info_plist
    File.write(File.join(@tmp, "ArchiveInfo.plist"), <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
        <key>ApplicationProperties</key><dict>
          <key>CFBundleIdentifier</key><string>io.github.vinceglb.molkky</string>
        </dict>
      </dict></plist>
    PLIST
  end

  def write_fake_xcodebuild
    path = File.join(@bin_dir, "xcodebuild")
    File.write(path, <<~'BASH')
      #!/usr/bin/env bash
      set -euo pipefail

      value_after() {
        local expected="$1"
        shift
        while (($#)); do
          if [[ "$1" == "${expected}" ]]; then
            echo "$2"
            return 0
          fi
          shift
        done
        return 1
      }

      if [[ "${1:-}" == "archive" ]]; then
        archive_path="$(value_after -archivePath "$@")"
        mkdir -p "${archive_path}"
        cp "${FAKE_ARCHIVE_INFO_PLIST}" "${archive_path}/Info.plist"
      elif [[ "${1:-}" == "-exportArchive" ]]; then
        export_path="$(value_after -exportPath "$@")"
        export_options_path="$(value_after -exportOptionsPlist "$@")"
        mkdir -p "${export_path}"
        cp "${export_options_path}" "${FAKE_CAPTURED_EXPORT_OPTIONS}"
        touch "${export_path}/Molkky.ipa"
      else
        echo "Unexpected xcodebuild command: $*" >&2
        exit 1
      fi
    BASH
    FileUtils.chmod(0o755, path)
  end
end
