require "test_helper"
require "ipaddr"

class Angarium::DeliverJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @owner = Owner.create!(name: "Acme")
    @endpoint = Angarium::Endpoint.create!(
      owner: @owner, name: "e", url: "https://203.0.113.10/hook",
      signing_secret: "shh", subscribed_events: ["*"]
    )
    @event = Angarium::Event.create!(name: "invoice.paid", payload: {"id" => 1})
  end

  test "creating a delivery enqueues the deliver job" do
    assert_enqueued_with(job: Angarium::DeliverJob) do
      Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
    end
  end

  test "successful 2xx delivery marks succeeded and records an attempt" do
    fake = FakeAngariumClient.new(
      Angarium::Client::Result.new(success: true, code: 200, body: "ok", duration: 0.0)
    )
    delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)

    Angarium::Client.stub(:new, fake) { perform_enqueued_jobs }

    delivery.reload
    assert delivery.succeeded?, "expected succeeded, was #{delivery.state}"
    assert_equal 1, delivery.attempt_count
    attempt = delivery.delivery_attempts.sole
    assert_equal 200, attempt.response_code
    # Confirms the resolvable + pinned path was taken (not fail-closed): a
    # request was made, pinned to exactly the validated resolved IP.
    assert fake.requested?, "expected a request to be made"
    assert_equal "https://203.0.113.10/hook", fake.last.url
    assert_equal ["203.0.113.10"], fake.last.addresses
  end

  test "request carries the Standard Webhooks headers and json envelope" do
    fake = FakeAngariumClient.new(
      Angarium::Client::Result.new(success: true, code: 200, body: "ok", duration: 0.0)
    )

    delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
    Angarium::Client.stub(:new, fake) { perform_enqueued_jobs }

    call = fake.last
    assert call, "expected a request to be made"
    assert_equal delivery.id.to_s, call.headers["webhook-id"]
    assert_match(/\A\d+\z/, call.headers["webhook-timestamp"])
    assert call.headers["webhook-signature"].present?

    envelope = JSON.parse(call.body)
    assert_equal "invoice.paid", envelope["event"]
    assert_equal({"id" => 1}, envelope["data"])
    assert envelope["id"].present?

    assert Angarium::Signature.verify(
      payload: call.body,
      id: call.headers["webhook-id"],
      timestamp: call.headers["webhook-timestamp"],
      signature: call.headers["webhook-signature"],
      secret: @endpoint.signing_secret
    )
  end

  test "failed delivery with empty retry schedule is exhausted" do
    Angarium.config.stub(:retry_schedule, []) do
      fake = FakeAngariumClient.new(
        Angarium::Client::Result.new(success: false, code: 500, body: "boom", duration: 0.0)
      )
      delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
      Angarium::Client.stub(:new, fake) { perform_enqueued_jobs }
      delivery.reload
      assert delivery.exhausted?, "expected exhausted, was #{delivery.state}"
      assert_equal 1, delivery.attempt_count
      assert_equal 500, delivery.delivery_attempts.sole.response_code
      assert fake.requested?, "expected a request to be made"
    end
  end

  test "blocks delivery to a disallowed destination without making a request" do
    stub = stub_request(:post, "https://203.0.113.10/hook")
    delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)

    Angarium::AddressPolicy.stub(:resolve, [IPAddr.new("127.0.0.1")]) do
      perform_enqueued_jobs
    end

    delivery.reload
    assert delivery.blocked?, "expected blocked, was #{delivery.state}"
    assert_not_requested stub
    assert_match(/blocked/i, delivery.delivery_attempts.sole.error)
  end

  test "pins the connection to the validated resolved IP" do
    capturing = Class.new do
      attr_reader :captured
      def post(url, body:, headers:, addresses: nil)
        @captured = {url: url, addresses: addresses}
        Angarium::Client::Result.new(success: true, code: 200, body: "ok", duration: 0.0)
      end
    end.new

    delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
    Angarium::AddressPolicy.stub(:resolve, [IPAddr.new("203.0.113.10")]) do
      delivery.deliver!(client: capturing)
    end

    assert_equal ["203.0.113.10"], capturing.captured[:addresses]
    assert delivery.reload.succeeded?
  end

  test "fails closed (retryable) when the host cannot be resolved" do
    Angarium.config.stub(:retry_schedule, []) do
      stub = stub_request(:post, "https://nope.invalid/hook")
      endpoint = Angarium::Endpoint.create!(
        owner: @owner, name: "u", url: "https://nope.invalid/hook",
        signing_secret: "shh", subscribed_events: ["*"]
      )
      delivery = Angarium::Delivery.create!(event: @event, endpoint: endpoint)

      perform_enqueued_jobs

      delivery.reload
      assert delivery.exhausted?, "expected exhausted, was #{delivery.state}"
      assert_not_requested stub
      assert_match(/unresolvable/i, delivery.delivery_attempts.sole.error)
    end
  end
end
