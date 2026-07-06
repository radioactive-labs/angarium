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

  test "without --database leaves config.database commented and installs into db/migrate" do
    run_generator
    assert_file "config/initializers/angarium.rb", /^\s*#\s*config\.database\s*=/
    assert Dir[File.join(destination_root, "db/migrate/*_create_angarium_endpoints.angarium.rb")].any?,
      "installs migrations into the primary db/migrate"
    assert_empty Dir[File.join(destination_root, "db/angarium_migrate/*.rb")]
  end

  test "with --database sets config.database and installs migrations into db/NAME_migrate" do
    run_generator ["--database=angarium"]
    assert_file "config/initializers/angarium.rb", /^\s*config\.database = :angarium/

    migrations = Dir[File.join(destination_root, "db/angarium_migrate/*.rb")].sort
    assert_equal 4, migrations.size, "invokes the migrations generator for all four migrations"
    # Native copy re-timestamps and adds the `.angarium` engine scope suffix.
    endpoints = migrations.find { |f| File.basename(f).match?(/\A\d+_create_angarium_endpoints\.angarium\.rb\z/) }
    assert endpoints, "copies the endpoints migration (re-timestamped, scope-tagged)"
    body = File.read(endpoints)
    assert_match(/create_table :angarium_endpoints/, body)
    assert_match(/This migration comes from angarium/, body, "native copy tags the origin")
  end
end
