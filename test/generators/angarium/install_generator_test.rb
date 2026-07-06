require "test_helper"
require "rails/generators"
require "generators/angarium/install/install_generator"

class Angarium::InstallGeneratorTest < Rails::Generators::TestCase
  tests Angarium::Generators::InstallGenerator
  destination File.expand_path("../../tmp/generator", __dir__)
  setup :prepare_destination

  test "creates the initializer" do
    run_generator
    assert_file "config/initializers/angarium.rb", /Angarium.configure/
  end
end
