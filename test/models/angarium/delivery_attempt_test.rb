require "test_helper"

class Angarium::DeliveryAttemptTest < ActiveSupport::TestCase
  setup do
    @owner = Owner.create!(name: "Acme")
    @endpoint = Angarium::Endpoint.create!(
      owner: @owner, name: "prod", url: "https://example.test/hook",
      signing_secret: "s3cr3t", subscribed_events: ["*"]
    )
    @event = Angarium::Event.create!(name: "invoice.paid", payload: {id: 1})
    @delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
  end

  def attempt_at(time)
    Angarium::DeliveryAttempt.create!(delivery: @delivery, response_code: 200, created_at: time)
  end

  test "normalizes an invalid-encoding response body to valid UTF-8" do
    bad = ("caf" + 233.chr).b # 0xE9 alone is not valid UTF-8
    attempt = Angarium::DeliveryAttempt.create!(delivery: @delivery, response_body: bad)

    assert_equal Encoding::UTF_8, attempt.response_body.encoding
    assert attempt.response_body.valid_encoding?, "assigned value must be valid UTF-8"
    assert attempt.reload.response_body.valid_encoding?, "stored value round-trips"
  end

  test "strips NUL bytes from response_body and error" do
    # NUL is valid UTF-8 (scrub keeps it) but PostgreSQL rejects it in text columns.
    attempt = Angarium::DeliveryAttempt.create!(
      delivery: @delivery,
      response_body: "ok" + 0.chr + "bye",
      error: "err" + 0.chr + "or"
    )

    assert_equal "okbye", attempt.response_body
    assert_equal "error", attempt.error
  end

  test "caps the error to the column limit when the adapter sets one" do
    limit = Angarium::DeliveryAttempt.columns_hash["error"].limit
    long = "x" * 1_000
    attempt = Angarium::DeliveryAttempt.create!(delivery: @delivery, error: long)

    if limit
      assert_operator attempt.error.length, :<=, limit
    else
      assert_equal long, attempt.error, "no column limit means the error is stored verbatim"
    end
  end

  test "prune deletes attempts older than the cutoff and returns the count" do
    old_one = attempt_at(10.days.ago)
    old_two = attempt_at(3.days.ago)
    recent = attempt_at(1.hour.ago)

    deleted = Angarium::DeliveryAttempt.prune(older_than: 1.day)

    assert_equal 2, deleted
    assert_equal [recent.id], Angarium::DeliveryAttempt.pluck(:id)
    refute Angarium::DeliveryAttempt.exists?(old_one.id)
    refute Angarium::DeliveryAttempt.exists?(old_two.id)
  end

  test "prune accepts an absolute Time cutoff" do
    old_one = attempt_at(10.days.ago)
    recent = attempt_at(1.hour.ago)

    deleted = Angarium::DeliveryAttempt.prune(older_than: 2.days.ago)

    assert_equal 1, deleted
    assert_equal [recent.id], Angarium::DeliveryAttempt.pluck(:id)
    refute Angarium::DeliveryAttempt.exists?(old_one.id)
  end
end
