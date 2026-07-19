# frozen_string_literal: true

# Boots the dummy app with config.database set (via ENV, read by the dummy's
# angarium initializer before boot finishes) and proves Angarium's models
# really connect to the secondary database. The connects_to wiring in
# Angarium::ApplicationRecord runs once, at class load, so it is only
# coverable this way. Runs in its own process via `rake test:multi_db`; the
# file name avoids the *_test.rb suffix so `bin/rails test` never pulls it
# into the main suite's process.
ENV["ANGARIUM_TEST_DATABASE"] = "angarium"
require_relative "../test_helper"

class DatabaseBootCheck < Minitest::Test
  MODELS = [
    Angarium::Endpoint, Angarium::Event, Angarium::Delivery, Angarium::DeliveryAttempt
  ].freeze

  def test_models_route_to_the_secondary_database
    MODELS.each do |model|
      assert_equal "angarium", model.connection_db_config.name,
        "#{model} should connect to the secondary database"
    end

    conn = Angarium::ApplicationRecord.connection
    refute conn.table_exists?(:angarium_endpoints),
      "the in-memory secondary starts schemaless — a table here means the " \
      "models are actually talking to the primary database"

    ActiveRecord::Migration.suppress_messages do
      Dir[Angarium::Engine.root.join("db/angarium_migrate/*.rb").to_s].sort.each do |file|
        require file
        File.basename(file, ".rb").sub(/\A\d+_/, "").camelize.constantize
          .new.exec_migration(conn, :up)
      end
    end

    assert_equal 0, Angarium::Endpoint.count,
      "models should query the freshly migrated secondary database"
  end
end
