require "test_helper"

class Angarium::DispatchInstrumentationTest < ActiveSupport::TestCase
  setup { @owner = Owner.create!(name: "Acme") }

  def make_endpoint(events)
    Angarium::Endpoint.create!(
      owner: @owner, name: "e#{events.hash}", url: "https://203.0.113.10/hook",
      signing_secret: "whsec_c2VjcmV0", subscribed_events: events
    )
  end

  def capture_dispatch
    events = []
    sub = ->(_n, _s, _f, _i, payload) { events << payload }
    ActiveSupport::Notifications.subscribed(sub, "dispatch.angarium") { yield }
    events
  end

  test "emits deliveries count equal to the fan-out size" do
    make_endpoint(["*"])
    make_endpoint(["invoice.paid"])
    make_endpoint(["other.event"]) # not subscribed -> excluded

    events = capture_dispatch { Angarium.dispatch("invoice.paid", {"id" => 1}, owner: @owner) }

    assert_equal 1, events.size
    p = events.first
    assert_equal "invoice.paid", p[:event]
    assert_equal 2, p[:deliveries]
    assert_not_nil p[:event_id]
  end

  test "emits deliveries 0 and nil event_id when nothing matches" do
    make_endpoint(["other.event"])
    result = nil
    events = capture_dispatch { result = Angarium.dispatch("invoice.paid", {"id" => 1}, owner: @owner) }

    assert_nil result, "dispatch still returns nil on no match"
    assert_equal 0, events.first[:deliveries]
    assert_nil events.first[:event_id]
  end
end
