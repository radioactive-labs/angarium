require "test_helper"
require "rails/generators"
require "generators/angarium/migrations/migrations_generator"

class Angarium::MigrationsGeneratorTest < Rails::Generators::TestCase
  tests Angarium::Generators::MigrationsGenerator
  destination File.expand_path("../../tmp/generator", __dir__)
  setup :prepare_destination

  def endpoints_migration(dir)
    Dir[File.join(destination_root, dir, "*.rb")]
      .find { |f| File.basename(f).match?(/\A\d+_create_angarium_endpoints\.angarium\.rb\z/) }
  end

  test "installs into the primary db/migrate by default" do
    run_generator
    assert endpoints_migration("db/migrate"), "copies engine migrations to db/migrate"
    assert_empty Dir[File.join(destination_root, "db/angarium_migrate/*.rb")]
  end

  test "installs into db/NAME_migrate with --database" do
    run_generator ["--database=angarium"]
    assert endpoints_migration("db/angarium_migrate"), "copies into the database's own path"
    assert_empty Dir[File.join(destination_root, "db/migrate/*.rb")]
  end

  test "falls back to config.database when no flag is given" do
    Angarium.config.database = :billing
    run_generator
    assert endpoints_migration("db/billing_migrate"), "reads config so re-runs target the right db"
  ensure
    Angarium.config.database = nil
  end
end
