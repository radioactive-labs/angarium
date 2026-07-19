require "test_helper"
require "rails/generators"
require "generators/angarium/upgrade/upgrade_generator"

class Angarium::UpgradeGeneratorTest < Rails::Generators::TestCase
  tests Angarium::UpgradeGenerator
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

  test "a bare app copies all four migrations, in order" do
    run_generator

    assert_equal MIGRATIONS.map { |n| "#{n}.rb" }, migrations_in("db/migrate")
  end

  test "a partially-installed app copies only the missing migrations" do
    FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
    File.write(File.join(destination_root, "db/migrate", "20260704000001_create_angarium_endpoints.rb"), "# existing\n")
    File.write(File.join(destination_root, "db/migrate", "20260704000002_create_angarium_events.rb"), "# existing\n")

    run_generator

    assert_equal MIGRATIONS.map { |n| "#{n}.rb" }, migrations_in("db/migrate")
    # The two pre-existing files were left alone, not overwritten.
    assert_equal "# existing\n",
      File.read(File.join(destination_root, "db/migrate", "20260704000001_create_angarium_endpoints.rb"))
  end

  test "a fully-installed app copies nothing" do
    FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
    MIGRATIONS.each_with_index do |name, i|
      File.write(File.join(destination_root, "db/migrate", format("2026070400000%d_%s.rb", i + 1, name)), "# existing\n")
    end

    run_generator

    MIGRATIONS.each do |name|
      assert_equal 1, Dir[File.join(destination_root, "db/migrate", "*_#{name}.rb")].size
    end
  end

  test "a legacy-suffixed install (native ActiveRecord::Migration.copy) copies nothing" do
    FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
    MIGRATIONS.each_with_index do |name, i|
      File.write(
        File.join(destination_root, "db/migrate", format("2026070603531%d_%s.angarium.rb", i + 9, name)),
        "# legacy install\n"
      )
    end

    run_generator

    MIGRATIONS.each do |name|
      matches = Dir[File.join(destination_root, "db/migrate", "*_#{name}{,.angarium}.rb")]
      assert_equal 1, matches.size, "#{name} must not be re-copied alongside its legacy-suffixed file"
      assert_match(/\.angarium\.rb\z/, matches.first)
    end
  end

  test "with --database copies missing migrations into db/NAME_migrate" do
    run_generator ["--database=angarium"]

    assert_equal MIGRATIONS.map { |n| "#{n}.rb" }, migrations_in("db/angarium_migrate")
    assert_empty Dir[File.join(destination_root, "db/migrate/*.rb")]
  end

  test "falls back to config.database when no flag is given" do
    Angarium.config.database = :billing
    run_generator
    assert_equal MIGRATIONS.map { |n| "#{n}.rb" }, migrations_in("db/billing_migrate")
  ensure
    Angarium.config.database = nil
  end
end
