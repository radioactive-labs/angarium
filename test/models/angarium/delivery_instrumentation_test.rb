require "test_helper"

class Angarium::DeliveryInstrumentationTest < ActiveSupport::TestCase
  setup do
    @owner = Owner.create!(name: "Acme")
    @endpoint = Angarium::Endpoint.create!(
      owner: @owner, name: "e", url: "https://203.0.113.10/hook",
      signing_secret: "whsec_c2VjcmV0", subscribed_events: ["*"]
    )
    @event = Angarium::Event.create!(name: "invoice.paid", payload: {"id" => 1})
  end

  def create_delivery
    Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
  end

  def client_returning(success:, code:, body: "ok", headers: {})
    FakeAngariumClient.new(
      Angarium::Client::Result.new(success: success, code: code, body: body, duration: 0.05, headers: headers)
    )
  end

  def capture_deliver
    events = []
    sub = ->(_name, _start, _finish, _id, payload) { events << payload }
    ActiveSupport::Notifications.subscribed(sub, "deliver.angarium") { yield }
    events
  end

  test "delivered: 2xx emits outcome delivered with code and http_duration" do
    events = capture_deliver { create_delivery.deliver!(client: client_returning(success: true, code: 200)) }
    assert_equal 1, events.size
    p = events.first
    assert_equal :delivered, p[:outcome]
    assert_equal 200, p[:code]
    assert_equal 0.05, p[:http_duration]
    assert_equal 1, p[:attempt]
    assert_equal "invoice.paid", p[:event]
    assert_equal @endpoint.id, p[:endpoint_id]
  end

  test "failed: non-2xx emits outcome failed" do
    events = capture_deliver { create_delivery.deliver!(client: client_returning(success: false, code: 500, body: "boom")) }
    assert_equal :failed, events.first[:outcome]
    assert_equal 500, events.first[:code]
  end

  test "gone: 410 emits outcome gone" do
    events = capture_deliver { create_delivery.deliver!(client: client_returning(success: false, code: 410)) }
    assert_equal :gone, events.first[:outcome]
    assert_equal 410, events.first[:code]
  end

  test "held: paused endpoint emits outcome held with no attempt or code" do
    @endpoint.pause!
    events = capture_deliver { create_delivery.deliver!(client: client_returning(success: true, code: 200)) }
    p = events.first
    assert_equal :held, p[:outcome]
    assert_nil p[:attempt]
    assert_nil p[:code]
  end

  test "canceled: disabled endpoint emits outcome canceled" do
    @endpoint.update!(status: "disabled")
    events = capture_deliver { create_delivery.deliver!(client: client_returning(success: true, code: 200)) }
    assert_equal :canceled, events.first[:outcome]
    assert_nil events.first[:code]
  end

  test "blocked: disallowed resolved address emits outcome blocked, no code" do
    events = capture_deliver do
      Angarium::AddressPolicy.stub(:resolve, [IPAddr.new("10.0.0.1")]) do
        create_delivery.deliver!(client: client_returning(success: true, code: 200))
      end
    end
    p = events.first
    assert_equal :blocked, p[:outcome]
    assert_equal 1, p[:attempt]
    assert_nil p[:code]
    assert_match(/not permitted/, p[:error])
  end

  test "unresolvable: empty resolution emits outcome unresolvable" do
    events = capture_deliver do
      Angarium::AddressPolicy.stub(:resolve, []) do
        create_delivery.deliver!(client: client_returning(success: true, code: 200))
      end
    end
    assert_equal :unresolvable, events.first[:outcome]
    assert_nil events.first[:code]
  end

  test "payload never leaks the signing secret or response body" do
    events = capture_deliver { create_delivery.deliver!(client: client_returning(success: true, code: 200, body: "secret-body")) }
    dumped = events.first.inspect
    refute_match(/whsec_/, dumped)
    refute_match(/secret-body/, dumped)
  end

  test "return value is unchanged: held returns nil, delivered returns the attempt" do
    @endpoint.pause!
    assert_nil create_delivery.deliver!(client: client_returning(success: true, code: 200))
    @endpoint.enable!
    result = create_delivery.deliver!(client: client_returning(success: true, code: 200))
    assert_kind_of Angarium::DeliveryAttempt, result
  end
end
