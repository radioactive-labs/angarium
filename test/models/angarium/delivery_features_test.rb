require "test_helper"

class Angarium::DeliveryFeaturesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @owner = Owner.create!(name: "Acme")
    @endpoint = Angarium::Endpoint.create!(
      owner: @owner, name: "e", url: "https://203.0.113.10/hook",
      signing_secret: "shh", subscribed_events: ["*"]
    )
    @event = Angarium::Event.create!(name: "invoice.paid", payload: { "id" => 1 })
  end

  def create_delivery
    Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
  end

  def failing_client(headers: {})
    FakeAngariumClient.new(
      Angarium::Client::Result.new(success: false, code: 500, body: "boom", duration: 0.0, headers: headers)
    )
  end

  def succeeding_client
    FakeAngariumClient.new(
      Angarium::Client::Result.new(success: true, code: 200, body: "ok", duration: 0.0, headers: {})
    )
  end

  # --- Custom headers ---------------------------------------------------------

  test "delivery sends per-endpoint custom headers" do
    @endpoint.update!(custom_headers: { "Authorization" => "Bearer x" })
    fake = succeeding_client
    create_delivery.deliver!(client: fake)

    assert_equal "Bearer x", fake.last.headers["Authorization"]
    assert fake.last.headers["webhook-signature"].present?
  end

  test "a custom header cannot override the webhook-signature header" do
    @endpoint.update!(custom_headers: { "webhook-signature" => "evil" })
    fake = succeeding_client
    delivery = create_delivery
    delivery.deliver!(client: fake)

    call = fake.last
    sig = call.headers["webhook-signature"]
    refute_equal "evil", sig
    assert Angarium::Signature.verify(
      payload: call.body,
      id: call.headers["webhook-id"],
      timestamp: call.headers["webhook-timestamp"],
      signature: sig,
      secret: @endpoint.signing_secret
    )
  end

  # --- Retry-After ------------------------------------------------------------

  test "respects a numeric Retry-After header" do
    freeze_time do
      Angarium.config.stub(:retry_schedule, [60]) do
        create_delivery.deliver!(client: failing_client(headers: { "retry-after" => "120" }))
      end
      delivery = Angarium::Delivery.last
      assert delivery.pending?
      assert_in_delta Time.current + 120, delivery.next_attempt_at, 1
    end
  end

  test "respects an HTTP-date Retry-After header" do
    freeze_time do
      Angarium.config.stub(:retry_schedule, [60]) do
        create_delivery.deliver!(client: failing_client(headers: { "retry-after" => (Time.now + 90).httpdate }))
      end
      delivery = Angarium::Delivery.last
      assert delivery.pending?
      assert_in_delta Time.current + 90, delivery.next_attempt_at, 2
    end
  end

  test "clamps a Retry-After above max_retry_after" do
    freeze_time do
      Angarium.config.stub(:retry_schedule, [60]) do
        create_delivery.deliver!(client: failing_client(headers: { "retry-after" => "999999" }))
      end
      delivery = Angarium::Delivery.last
      assert_in_delta Time.current + Angarium.config.max_retry_after, delivery.next_attempt_at, 1
    end
  end

  test "ignores Retry-After when respect_retry_after is false" do
    freeze_time do
      Angarium.config.stub(:respect_retry_after, false) do
        Angarium.config.stub(:retry_schedule, [60]) do
          create_delivery.deliver!(client: failing_client(headers: { "retry-after" => "120" }))
        end
      end
      delivery = Angarium::Delivery.last
      # Falls back to the schedule base (60), jittered up to +15%.
      assert_operator delivery.next_attempt_at, :>=, Time.current + 60
      assert_operator delivery.next_attempt_at, :<=, Time.current + 60 * 1.15 + 1
    end
  end

  # --- Jitter -----------------------------------------------------------------

  test "backoff is jittered within the configured band" do
    freeze_time do
      Angarium.config.stub(:retry_schedule, [60]) do
        create_delivery.deliver!(client: failing_client)
      end
      delivery = Angarium::Delivery.last
      assert_operator delivery.next_attempt_at, :>=, Time.current + 60
      assert_operator delivery.next_attempt_at, :<=, Time.current + 60 * (1 + Angarium.config.retry_jitter) + 0.001
    end
  end

  # --- Auto-disable -----------------------------------------------------------

  test "auto-disables an endpoint after consecutive exhausted deliveries and resets on success" do
    Angarium.config.stub(:auto_disable_endpoint_after, 2) do
      Angarium.config.stub(:retry_schedule, []) do
        create_delivery.deliver!(client: failing_client)
        @endpoint.reload
        assert_equal 1, @endpoint.consecutive_failures
        assert @endpoint.active?, "endpoint should still be active after one failure"

        create_delivery.deliver!(client: failing_client)
        @endpoint.reload
        assert_equal 2, @endpoint.consecutive_failures
        refute @endpoint.active?, "endpoint should be disabled after threshold failures"
        assert @endpoint.disabled_at.present?

        create_delivery.deliver!(client: succeeding_client)
        @endpoint.reload
        assert_equal 0, @endpoint.consecutive_failures
      end
    end
  end

  # --- Redeliver --------------------------------------------------------------

  test "redeliver! resets an exhausted delivery and re-enqueues" do
    delivery = create_delivery
    Angarium.config.stub(:retry_schedule, []) do
      delivery.deliver!(client: failing_client)
    end
    assert delivery.reload.exhausted?

    assert_enqueued_with(job: Angarium::DeliverJob) do
      assert_equal delivery, delivery.redeliver!
    end
    delivery.reload
    assert delivery.pending?
    assert_equal 0, delivery.attempt_count
    assert_nil delivery.next_attempt_at
  end

  # --- Test event -------------------------------------------------------------

  test "send_test_event! creates a delivery, enqueues, and delivers to the endpoint" do
    delivery = nil
    assert_enqueued_with(job: Angarium::DeliverJob) do
      delivery = @endpoint.send_test_event!
    end
    assert_equal "angarium.test", delivery.event.name
    assert_equal @endpoint, delivery.endpoint

    fake = succeeding_client
    Angarium::Client.stub(:new, fake) { perform_enqueued_jobs }
    assert fake.requested?, "expected the test event to be delivered"
    assert_equal @endpoint.url, fake.last.url
  end

  test "ping! is an alias of send_test_event!" do
    delivery = nil
    assert_enqueued_with(job: Angarium::DeliverJob) do
      delivery = @endpoint.ping!
    end
    assert_equal "angarium.test", delivery.event.name
    assert_equal @endpoint, delivery.endpoint
  end

  # --- Dual-secret rotation ---------------------------------------------------

  test "within the grace window a delivery verifies with both old and new secrets" do
    old_secret = @endpoint.signing_secret
    new_secret = @endpoint.regenerate_signing_secret!
    refute_equal old_secret, new_secret

    fake = succeeding_client
    create_delivery.deliver!(client: fake)
    call = fake.last
    sig = call.headers["webhook-signature"]

    # Two space-delimited v1 tokens during the grace window.
    assert_equal 2, sig.split(" ").size

    assert Angarium::Signature.verify(
      payload: call.body, id: call.headers["webhook-id"],
      timestamp: call.headers["webhook-timestamp"], signature: sig, secret: old_secret
    )
    assert Angarium::Signature.verify(
      payload: call.body, id: call.headers["webhook-id"],
      timestamp: call.headers["webhook-timestamp"], signature: sig, secret: new_secret
    )
  end

  test "past the grace window only the new secret verifies" do
    old_secret = @endpoint.signing_secret
    new_secret = @endpoint.regenerate_signing_secret!
    @endpoint.update!(secret_rotated_at: 2.days.ago)

    fake = succeeding_client
    create_delivery.deliver!(client: fake)
    call = fake.last
    sig = call.headers["webhook-signature"]

    # Only the new secret signs past the grace window.
    assert_equal 1, sig.split(" ").size

    refute Angarium::Signature.verify(
      payload: call.body, id: call.headers["webhook-id"],
      timestamp: call.headers["webhook-timestamp"], signature: sig, secret: old_secret
    )
    assert Angarium::Signature.verify(
      payload: call.body, id: call.headers["webhook-id"],
      timestamp: call.headers["webhook-timestamp"], signature: sig, secret: new_secret
    )
  end
end
