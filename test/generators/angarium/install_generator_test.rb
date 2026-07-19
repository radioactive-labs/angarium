require "test_helper"
require "rails/generators"
require "generators/angarium/install/install_generator"

class Angarium::InstallGeneratorTest < Rails::Generators::TestCase
  tests Angarium::InstallGenerator
  destination File.expand_path("../../tmp/generator", __dir__)
  setup :prepare_destination

  MIGRATIONS = %w[
    create_angarium_endpoints
    create_angarium_events
    create_angarium_deliveries
    create_angarium_delivery_attempts
  ].freeze

  def migrations_in(dir)
    Dir[File.join(destination_root, dir, "*.rb")]
      .sort
      .map { |f| File.basename(f).sub(/\A\d+_/, "") }
  end

  test "creates the initializer" do
    run_generator
    assert_file "config/initializers/angarium.rb", /Angarium.configure/
  end

  test "without --database leaves config.database commented and installs all four migrations into db/migrate, in order" do
    run_generator
    assert_file "config/initializers/angarium.rb", /^\s*#\s*config\.database\s*=/
    assert_equal MIGRATIONS.map { |n| "#{n}.rb" }, migrations_in("db/migrate")
    assert_empty Dir[File.join(destination_root, "db/angarium_migrate/*.rb")]
  end

  test "with --database sets config.database and installs all four migrations into db/NAME_migrate" do
    run_generator ["--database=angarium"]
    assert_file "config/initializers/angarium.rb", /^\s*config\.database = :angarium/

    assert_equal MIGRATIONS.map { |n| "#{n}.rb" }, migrations_in("db/angarium_migrate")
    assert_empty Dir[File.join(destination_root, "db/migrate/*.rb")]
  end

  test "--database=primary behaves like no flag" do
    run_generator ["--database=primary"]

    assert_file "config/initializers/angarium.rb" do |content|
      refute_match(/^\s*config\.database\s*=/, content,
        "--database=primary must not activate config.database (it would trigger connects_to at boot)")
    end
    assert_equal MIGRATIONS.map { |n| "#{n}.rb" }, migrations_in("db/migrate")
  end

  test "falls back to config.database when no flag is given" do
    Angarium.config.database = :billing
    run_generator
    assert_equal MIGRATIONS.map { |n| "#{n}.rb" }, migrations_in("db/billing_migrate")
  ensure
    Angarium.config.database = nil
  end

  test "is idempotent" do
    run_generator
    run_generator

    MIGRATIONS.each do |name|
      assert_equal 1, Dir[File.join(destination_root, "db/migrate", "*_#{name}.rb")].size,
        "re-running install must not duplicate #{name}"
    end
  end

  test "with --database is idempotent" do
    run_generator ["--database=angarium"]
    run_generator ["--database=angarium"]

    MIGRATIONS.each do |name|
      assert_equal 1, Dir[File.join(destination_root, "db/angarium_migrate", "*_#{name}.rb")].size,
        "re-running install --database must not duplicate #{name}"
    end
  end

  test "a legacy .angarium-suffixed migration suppresses the copy" do
    # Existing apps installed via the old ActiveRecord::Migration.copy path,
    # whose files carry the engine's `.angarium` scope suffix. Re-running (or
    # upgrading) must recognize those as already installed rather than
    # re-copying and duplicating the table.
    FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
    File.write(
      File.join(destination_root, "db/migrate", "20260706035319_create_angarium_endpoints.angarium.rb"),
      "# legacy install\n"
    )

    run_generator

    endpoints = Dir[File.join(destination_root, "db/migrate", "*create_angarium_endpoints*.rb")]
    assert_equal 1, endpoints.size, "the legacy-suffixed file must not be duplicated"
    assert_match(/\.angarium\.rb\z/, endpoints.first, "the pre-existing legacy file is left untouched")
  end
end
