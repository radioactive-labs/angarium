require "test_helper"

class Angarium::PrimaryKeyTypeTest < ActiveSupport::TestCase
  teardown { Angarium.config.primary_key_type = nil }

  test "defaults to bigint when nothing is configured" do
    Angarium.config.primary_key_type = nil
    # dummy app sets no global generators primary_key_type
    assert_equal :bigint, Angarium.primary_key_type
  end

  test "explicit config wins" do
    Angarium.config.primary_key_type = :uuid
    assert_equal :uuid, Angarium.primary_key_type
  end

  test "falls back to the app's global generators setting" do
    Angarium.config.primary_key_type = nil
    Rails.application.config.generators.options[:active_record] ||= {}
    Rails.application.config.generators.options[:active_record][:primary_key_type] = :uuid
    assert_equal :uuid, Angarium.primary_key_type
  ensure
    Rails.application.config.generators.options[:active_record]&.delete(:primary_key_type)
  end
end
