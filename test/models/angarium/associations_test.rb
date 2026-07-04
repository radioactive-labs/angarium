require "test_helper"

class Angarium::AssociationsTest < ActiveSupport::TestCase
  setup do
    @owner = Owner.create!(name: "Acme")
    @endpoint = Angarium::Endpoint.create!(
      owner: @owner, name: "prod", url: "https://example.test/hook",
      signing_secret: "s3cr3t", subscribed_events: ["*"]
    )
    @event = Angarium::Event.create!(name: "invoice.paid", payload: { id: 1 })
    @delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
    @attempt = Angarium::DeliveryAttempt.create!(delivery: @delivery, response_code: 200)
  end

  test "owner has_many webhook_endpoints" do
    assert_equal [@endpoint], @owner.webhook_endpoints.to_a
  end

  test "delivery graph resolves" do
    assert_equal @event, @delivery.event
    assert_equal @endpoint, @delivery.endpoint
    assert_equal [@attempt], @delivery.delivery_attempts.to_a
    assert_equal [@delivery], @event.deliveries.to_a
  end

  test "active scope filters inactive endpoints" do
    @endpoint.update!(active: false)
    assert_empty Angarium::Endpoint.active
  end
end
