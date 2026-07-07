require "test_helper"

# Guards the indexes the hot paths depend on: the retention prune
# (DeliveryAttempt.prune), the stalled-delivery reaper (Delivery.reap_stalled),
# and the FK-scoped + created_at ordered list endpoints. Without these the
# queries fall back to full table scans / filesorts as the tables grow.
class AngariumIndexesTest < ActiveSupport::TestCase
  def index_columns(table)
    ActiveRecord::Base.connection.indexes(table).map(&:columns)
  end

  test "delivery_attempts.created_at is indexed for the retention prune" do
    assert_includes index_columns("angarium_delivery_attempts"), ["created_at"]
  end

  test "deliveries has a [state, last_attempt_at] index for the reaper" do
    assert_includes index_columns("angarium_deliveries"), ["state", "last_attempt_at"]
  end

  test "list endpoints have created_at-covering indexes for pagination" do
    assert_includes index_columns("angarium_deliveries"), ["endpoint_id", "created_at"]
    assert_includes index_columns("angarium_delivery_attempts"), ["delivery_id", "created_at"]
    assert_includes index_columns("angarium_endpoints"), ["owner_type", "owner_id", "created_at"]
  end
end
