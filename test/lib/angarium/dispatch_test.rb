require "test_helper"

class Angarium::DispatchTest < ActiveSupport::TestCase
  setup do
    @owner = Owner.create!(name: "Acme")
    @subscribed = endpoint(subscribed_events: ["invoice.*"])
    @other = endpoint(subscribed_events: ["user.created"])
    @inactive = endpoint(subscribed_events: ["*"], status: :disabled)
  end

  def endpoint(attrs)
    Angarium::Endpoint.create!({
      owner: @owner, name: "e", url: "https://example.test/hook"
    }.merge(attrs))
  end

  test "creates an event and a delivery per matching endpoint" do
    event = nil
    assert_difference -> { Angarium::Event.count } => 1,
      -> { Angarium::Delivery.count } => 1 do
      event = Angarium.dispatch("invoice.paid", {id: 1}, owner: @owner)
    end
    assert_equal "invoice.paid", event.name
    assert_equal [@subscribed], event.deliveries.map(&:endpoint)
  end

  test "returns nil and creates nothing when no endpoint matches" do
    assert_no_difference -> { Angarium::Event.count } do
      assert_nil Angarium.dispatch("nothing.matches", {}, owner: @owner)
    end
  end
end
