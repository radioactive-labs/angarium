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

  test "without --database leaves connects_to commented and installs no migrations" do
    run_generator
    assert_file "config/initializers/angarium.rb", /^\s*#\s*config\.connects_to\s*=/
    assert_no_file "db/angarium_migrate/20260704000001_create_angarium_endpoints.rb"
  end

  test "with --database enables connects_to and installs migrations into db/NAME_migrate" do
    run_generator ["--database=angarium"]
    assert_file "config/initializers/angarium.rb",
      /^\s*config\.connects_to = \{ database: \{ writing: :angarium, reading: :angarium \} \}/
    assert_file "db/angarium_migrate/20260704000001_create_angarium_endpoints.rb",
      /create_table :angarium_endpoints/
    assert_file "db/angarium_migrate/20260704000004_create_angarium_delivery_attempts.rb"
  end
end
