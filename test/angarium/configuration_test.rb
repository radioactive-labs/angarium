require "test_helper"

class Angarium::ConfigurationTest < ActiveSupport::TestCase
  setup { @original = Angarium.config.dup }
  teardown { Angarium.instance_variable_set(:@config, @original) }

  test "has sensible defaults" do
    config = Angarium::Configuration.new
    assert_equal :default, config.job_queue
    assert_equal 10, config.http_timeout
    assert_equal true, config.block_private_ips
    assert_equal 12, config.retry_schedule.length
    assert_equal 5.seconds, config.retry_schedule.first
    assert_match(/Angarium/, config.user_agent)
    assert_nil config.database, "defaults to the app's primary connection"
    assert_nil config.connects_to, "defaults to the app's primary connection"
    assert_equal [1, 3], config.dns_timeout
    assert_equal true, config.resolve_dns_with_hosts_file
    assert_equal 2048, config.max_url_length
    assert_equal 100, config.max_subscribed_events
  end

  test "connects_to is settable for multi-database setups" do
    Angarium.configure { |c| c.connects_to = {database: {writing: :angarium}} }
    assert_equal({database: {writing: :angarium}}, Angarium.config.connects_to)
  end

  test "migrations_database resolves from database, then connects_to, else nil" do
    assert_nil Angarium::Configuration.new.migrations_database

    from_database = Angarium::Configuration.new
    from_database.database = :billing
    assert_equal :billing, from_database.migrations_database

    from_connects_to = Angarium::Configuration.new
    from_connects_to.connects_to = {database: {writing: :angarium, reading: :angarium}}
    assert_equal :angarium, from_connects_to.migrations_database
  end

  test "configure yields the config for mutation" do
    Angarium.configure { |c| c.http_timeout = 5 }
    assert_equal 5, Angarium.config.http_timeout
  end
end
