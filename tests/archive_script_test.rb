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
    @captured_xcodebuild_commands = File.join(@tmp, "xcodebuild-commands")
    @captured_security_commands = File.join(@tmp, "security-commands")
    @fake_profile_plist = File.join(@tmp, "Profile.plist")
    @fake_home = File.join(@tmp, "home")
    @existing_profile_path = File.join(@fake_home, "Library/Developer/Xcode/UserData/Provisioning Profiles/PROFILE-UUID.mobileprovision")
    @outputs_path = File.join(@tmp, "outputs")
    FileUtils.mkdir_p([@runner_temp, @bin_dir, @workspace, @fake_home])
    FileUtils.mkdir_p(File.dirname(@existing_profile_path))
    File.write(@existing_profile_path, "existing-profile")
    write_archive_info_plist
    write_profile_plist
    write_fake_security
    write_fake_xcodebuild
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_exports_locally_without_app_store_connect_access
    result = run_archive

    assert result[:status].success?, result[:stderr]
    export_options = File.read(@captured_export_options)
    assert_match(%r{<key>destination</key>\s*<string>export</string>}, export_options)
    assert_match(%r{<key>manageAppVersionAndBuildNumber</key>\s*<false\s*/>}, export_options)
    assert_match(%r{<key>signingStyle</key>\s*<string>manual</string>}, export_options)
    assert_match(%r{<key>io.github.vinceglb.molkky</key>\s*<string>PROFILE-UUID</string>}, export_options)

    commands = File.readlines(@captured_xcodebuild_commands, chomp: true)
    archive_command = commands.find { |command| command.start_with?("archive ") }
    export_command = commands.find { |command| command.start_with?("-exportArchive ") }

    refute_includes archive_command, "CODE_SIGN_STYLE="
    refute_includes archive_command, "CODE_SIGN_IDENTITY="
    refute_includes archive_command, "PROVISIONING_PROFILE_SPECIFIER="
    refute_includes archive_command, "DEVELOPMENT_TEAM="
    refute_includes archive_command, "-allowProvisioningUpdates"
    refute_includes archive_command, "-authenticationKeyPath"
    refute_includes archive_command, "-authenticationKeyID"
    refute_includes archive_command, "-authenticationKeyIssuerID"
    refute_includes export_command, "-allowProvisioningUpdates"
    refute_includes export_command, "-authenticationKeyPath"
    refute_includes export_command, "-authenticationKeyID"
    refute_includes export_command, "-authenticationKeyIssuerID"

    security_commands = File.readlines(@captured_security_commands, chomp: true)
    assert security_commands.any? { |command| command.start_with?("import ") }
    assert security_commands.any? { |command| command.start_with?("find-identity ") }
    assert security_commands.any? { |command| command.start_with?("delete-keychain ") }

    assert_equal "existing-profile", File.read(@existing_profile_path)
    refute File.exist?(File.join(@fake_home, "Library/MobileDevice/Provisioning Profiles/PROFILE-UUID.mobileprovision"))
  end

  private

  def run_archive
    env = {
      "PATH" => "#{@bin_dir}:#{ENV.fetch("PATH")}",
      "HOME" => @fake_home,
      "RUNNER_TEMP" => @runner_temp,
      "GITHUB_OUTPUT" => @outputs_path,
      "FAKE_ARCHIVE_INFO_PLIST" => File.join(@tmp, "ArchiveInfo.plist"),
      "FAKE_CAPTURED_EXPORT_OPTIONS" => @captured_export_options,
      "FAKE_CAPTURED_XCODEBUILD_COMMANDS" => @captured_xcodebuild_commands,
      "FAKE_CAPTURED_SECURITY_COMMANDS" => @captured_security_commands,
      "FAKE_PROFILE_PLIST" => @fake_profile_plist,
      "INPUT_WORKSPACE" => @workspace,
      "INPUT_SCHEME" => "Molkky",
      "INPUT_BUNDLE_ID" => "io.github.vinceglb.molkky",
      "INPUT_DISTRIBUTION_CERTIFICATE_P12_B64" => Base64.strict_encode64("test-p12"),
      "INPUT_DISTRIBUTION_CERTIFICATE_PASSWORD" => "test-password",
      "INPUT_PROVISIONING_PROFILE_B64" => Base64.strict_encode64("test-profile"),
      "INPUT_DEVELOPER_TEAM_ID" => "TEAM123",
      "INPUT_CONFIGURATION" => "Release",
      "INPUT_ARCHIVE_PATH" => @archive_path,
      "INPUT_EXPORT_PATH" => @export_path,
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

  def write_profile_plist
    File.write(@fake_profile_plist, <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
        <key>UUID</key><string>PROFILE-UUID</string>
        <key>TeamIdentifier</key><array><string>TEAM123</string></array>
        <key>Entitlements</key><dict>
          <key>application-identifier</key><string>TEAM123.io.github.vinceglb.molkky</string>
        </dict>
      </dict></plist>
    PLIST
  end

  def write_fake_security
    path = File.join(@bin_dir, "security")
    File.write(path, <<~'BASH')
      #!/usr/bin/env bash
      set -euo pipefail

      printf '%s\n' "$*" >> "${FAKE_CAPTURED_SECURITY_COMMANDS}"

      if [[ "${1:-}" == "cms" ]]; then
        cat "${FAKE_PROFILE_PLIST}"
      elif [[ "${1:-}" == "list-keychains" && "$*" == "list-keychains -d user" ]]; then
        printf '    "%s"\n' "${HOME}/Library/Keychains/login.keychain-db"
      elif [[ "${1:-}" == "find-identity" ]]; then
        echo '  1) ABCDEF "Apple Distribution: Example (TEAM123)"'
        echo '     1 valid identities found'
      fi
    BASH
    FileUtils.chmod(0o755, path)
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

      printf '%s\n' "$*" >> "${FAKE_CAPTURED_XCODEBUILD_COMMANDS}"

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
