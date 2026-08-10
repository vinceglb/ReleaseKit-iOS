# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

class UploadActionContractTest < Minitest::Test
  ACTION_PATH = File.expand_path("../actions/upload/action.yml", __dir__)
  CI_PATH = File.expand_path("../.github/workflows/ci.yml", __dir__)
  SMOKE_PATH = File.expand_path("../.github/workflows/smoke.yml", __dir__)

  EXISTING_INPUTS = %w[
    app_id
    asc_key_id
    asc_issuer_id
    asc_private_key_b64
    ipa_path
    artifact_name
    artifact_download_path
    asc_version
    wait_for_processing
    poll_interval
  ].freeze

  REQUIRED_OUTPUTS = %w[
    ipa_path
    upload_id
    file_id
    asc_result_json
    outcome
  ].freeze

  def setup
    @action = YAML.load_file(ACTION_PATH)
  end

  def test_preserves_inputs_and_exposes_the_idempotent_outcome
    assert_equal EXISTING_INPUTS, @action.fetch("inputs").keys
    assert_equal REQUIRED_OUTPUTS, @action.fetch("outputs").keys

    assert_equal "false", @action.dig("inputs", "wait_for_processing", "default")
    assert_equal "30s", @action.dig("inputs", "poll_interval", "default")
    assert_equal "latest", @action.dig("inputs", "asc_version", "default")
    assert_equal "${{ steps.upload.outputs.outcome }}", @action.dig("outputs", "outcome", "value")
  end

  def test_documents_reused_output_values_without_misrepresenting_a_new_upload
    assert_includes @action.dig("outputs", "outcome", "description"), "uploaded"
    assert_includes @action.dig("outputs", "outcome", "description"), "reused"

    %w[upload_id file_id asc_result_json].each do |output|
      description = @action.dig("outputs", output, "description")
      assert_includes description, "empty when reused", output
    end
  end

  def test_wires_every_existing_input_to_the_upload_script
    upload_step = @action.fetch("runs").fetch("steps").find { |step| step["id"] == "upload" }
    refute_nil upload_step
    assert_equal "bash", upload_step.fetch("shell")
    assert_includes upload_step.fetch("run"), "scripts/upload.sh"

    expected_env = EXISTING_INPUTS.reject { |input| input == "asc_version" }.to_h do |input|
      ["INPUT_#{input.upcase}", "${{ inputs.#{input} }}"]
    end
    assert_equal expected_env, upload_step.fetch("env")
  end

  def test_ci_runs_the_upload_contract_and_script_tests
    ci = File.read(CI_PATH)
    assert_includes ci, "ruby tests/upload_action_contract_test.rb"
    assert_includes ci, "ruby tests/upload_script_test.rb"
  end

  def test_happy_path_smoke_reuses_the_same_ipa_on_a_second_invocation
    smoke = File.read(SMOKE_PATH)
    assert_operator smoke.scan("uses: ./actions/upload").length, :>=, 2
    assert_includes smoke, "id: upload_retry_step"
    assert_includes smoke, 'ipa_path: ${{ steps.upload_step.outputs.ipa_path }}'
    assert_includes smoke, 'steps.upload_retry_step.outputs.outcome'
    assert_includes smoke, '"reused"'
  end
end
