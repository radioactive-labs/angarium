# frozen_string_literal: true

# Proves config.connects_to wins over config.database in
# Angarium::ApplicationRecord, through the real class-body wiring: the dummy
# initializer points database at a config that does not exist, so this check
# only passes if connects_to decides the connection. Own process via
# `rake test:multi_db`; named *_check.rb to stay out of `bin/rails test`.
ENV["ANGARIUM_TEST_CONNECTS_TO"] = "1"
require_relative "../test_helper"

class ConnectsToBootCheck < Minitest::Test
  def test_connects_to_hash_wins_over_database_for_the_connection
    assert_equal "angarium", Angarium::Endpoint.connection_db_config.name,
      "connects_to should win over the (nonexistent) config.database"
    assert Angarium::ApplicationRecord.connection.select_value("SELECT 1"),
      "the connects_to-routed connection should be usable"
  end
end
