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

  test "supports a string/uuid-keyed owner alongside an integer-keyed owner" do
    int_owner = Owner.create!(name: "IntCo")
    uuid_owner = UuidOwner.create!(name: "UuidCo")

    int_ep = Angarium::Endpoint.create!(owner: int_owner, name: "a", url: "https://example.test/hook", subscribed_events: ["*"])
    uuid_ep = Angarium::Endpoint.create!(owner: uuid_owner, name: "b", url: "https://example.test/hook", subscribed_events: ["*"])

    assert_equal int_ep, int_owner.webhook_endpoints.sole
    assert_equal uuid_ep, uuid_owner.webhook_endpoints.sole
    assert_equal int_owner, int_ep.reload.owner
    assert_equal uuid_owner, uuid_ep.reload.owner
    # owner_id is stored as a string in both cases
    assert_kind_of String, uuid_ep.owner_id
  end
end
