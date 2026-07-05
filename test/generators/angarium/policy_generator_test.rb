require "test_helper"
require "rails/generators"
require "generators/angarium/policy/policy_generator"

class Angarium::PolicyGeneratorTest < Rails::Generators::TestCase
  tests Angarium::Generators::PolicyGenerator
  destination File.expand_path("../../tmp/generator", __dir__)
  setup :prepare_destination

  test "creates the default policy" do
    run_generator
    assert_file "app/policies/webhook_endpoint_policy.rb",
      /class WebhookEndpointPolicy < Angarium::Api::Policy/
  end

  test "creates a named policy" do
    run_generator ["AdminWebhookPolicy"]
    assert_file "app/policies/admin_webhook_policy.rb",
      /class AdminWebhookPolicy < Angarium::Api::Policy/
  end
end
