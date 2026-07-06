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
    assert_nil config.connects_to, "defaults to the app's primary connection"
  end

  test "connects_to is settable for multi-database setups" do
    Angarium.configure { |c| c.connects_to = {database: {writing: :angarium}} }
    assert_equal({database: {writing: :angarium}}, Angarium.config.connects_to)
  end

  test "configure yields the config for mutation" do
    Angarium.configure { |c| c.http_timeout = 5 }
    assert_equal 5, Angarium.config.http_timeout
  end
end
