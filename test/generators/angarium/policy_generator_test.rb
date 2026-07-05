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

  test "uncomments and sets config.policy_class in an existing initializer" do
    FileUtils.mkdir_p(File.join(destination_root, "config/initializers"))
    File.write(File.join(destination_root, "config/initializers/angarium.rb"),
      %(Angarium.configure do |config|\n  # config.policy_class = "WebhookEndpointPolicy"\nend\n))

    run_generator ["AdminWebhookPolicy"]

    assert_file "config/initializers/angarium.rb" do |content|
      assert_match(/^\s*config\.policy_class = "AdminWebhookPolicy"$/, content)
      refute_match(/#\s*config\.policy_class/, content)
    end
  end

  test "does not fail when no initializer exists" do
    run_generator
    assert_no_file "config/initializers/angarium.rb"
  end
end
