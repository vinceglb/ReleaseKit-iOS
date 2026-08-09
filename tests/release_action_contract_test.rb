# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class ReleaseActionContractTest < Minitest::Test
  ACTION_PATH = File.expand_path("../actions/release/action.yml", __dir__)

  REQUIRED_INPUTS = %w[
    app_id
    ipa_path
    release_notes_dir
    asc_key_id
    asc_issuer_id
    asc_private_key_b64
    submit_for_review
    release_type
    processing_timeout
    poll_interval
    asc_version
  ].freeze

  REQUIRED_OUTPUTS = %w[
    bundle_id
    marketing_version
    build_number
    app_store_version_id
    build_id
    submission_id
    submission_state
    app_store_connect_url
    result_json
  ].freeze

  def setup
    @action = YAML.load_file(ACTION_PATH)
  end

  def test_declares_the_approved_public_contract
    assert_equal REQUIRED_INPUTS, @action.fetch("inputs").keys
    assert_equal REQUIRED_OUTPUTS, @action.fetch("outputs").keys

    assert_equal "false", @action.dig("inputs", "submit_for_review", "default")
    assert_equal "MANUAL", @action.dig("inputs", "release_type", "default")
    assert_equal "latest", @action.dig("inputs", "asc_version", "default")
  end

  def test_wires_every_input_to_the_release_script
    release_step = @action.fetch("runs").fetch("steps").find { |step| step["id"] == "release" }
    refute_nil release_step
    assert_equal "bash", release_step.fetch("shell")
    assert_includes release_step.fetch("run"), "scripts/release.sh"

    expected_env = REQUIRED_INPUTS.to_h do |input|
      ["INPUT_#{input.upcase}", "${{ inputs.#{input} }}"]
    end
    assert_equal expected_env, release_step.fetch("env")
  end

  def test_reports_the_selected_asc_version_in_the_job_summary
    summary_step = @action.fetch("runs").fetch("steps").find { |step| step["name"] == "Summarize asc version" }
    refute_nil summary_step
    assert_includes summary_step.fetch("run"), "asc version"
    assert_includes summary_step.fetch("run"), "GITHUB_STEP_SUMMARY"
  end
end
