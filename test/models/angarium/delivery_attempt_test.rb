require "test_helper"

class Angarium::DeliveryAttemptTest < ActiveSupport::TestCase
  setup do
    @owner = Owner.create!(name: "Acme")
    @endpoint = Angarium::Endpoint.create!(
      owner: @owner, name: "prod", url: "https://example.test/hook",
      signing_secret: "s3cr3t", subscribed_events: ["*"]
    )
    @event = Angarium::Event.create!(name: "invoice.paid", payload: { id: 1 })
    @delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
  end

  def attempt_at(time)
    Angarium::DeliveryAttempt.create!(delivery: @delivery, response_code: 200, created_at: time)
  end

  test "prune deletes attempts older than the cutoff and returns the count" do
    old_one = attempt_at(10.days.ago)
    old_two = attempt_at(3.days.ago)
    recent  = attempt_at(1.hour.ago)

    deleted = Angarium::DeliveryAttempt.prune(older_than: 1.day)

    assert_equal 2, deleted
    assert_equal [recent.id], Angarium::DeliveryAttempt.pluck(:id)
    refute Angarium::DeliveryAttempt.exists?(old_one.id)
    refute Angarium::DeliveryAttempt.exists?(old_two.id)
  end

end
