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
    # The denylist rejects a webhook-signature custom header at validation, so
    # bypass validation here (still writing through the encrypted attribute) to
    # prove the delivery-time defense (signature always wins) holds even if such
    # a header reached the row some other way.
    @endpoint.custom_headers = { "webhook-signature" => "evil" }
    @endpoint.save!(validate: false)
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

  test "ignores a Retry-After sooner than the scheduled backoff (no expedited retries)" do
    freeze_time do
      Angarium.config.stub(:retry_schedule, [300]) do
        create_delivery.deliver!(client: failing_client(headers: { "retry-after" => "10" }))
      end
      delivery = Angarium::Delivery.last
      assert delivery.pending?
      # 10s < our 300s backoff, so Retry-After can't pull the retry earlier; we
      # keep the schedule (jittered up to +15%).
      assert_operator delivery.next_attempt_at, :>=, Time.current + 300
      assert_operator delivery.next_attempt_at, :<=, Time.current + 300 * 1.15 + 1
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
        assert @endpoint.enabled?, "endpoint should still be enabled after one failure"

        create_delivery.deliver!(client: failing_client)
        @endpoint.reload
        assert_equal 2, @endpoint.consecutive_failures
        assert @endpoint.disabled?, "endpoint should be disabled after threshold failures"
        assert @endpoint.status_changed_at.present?

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

  # --- Reaping stalled deliveries ---------------------------------------------

  test "reap_stalled requeues deliveries stuck in delivering past the timeout" do
    delivery = create_delivery
    delivery.update_columns(state: "delivering", last_attempt_at: 20.minutes.ago)

    assert_enqueued_with(job: Angarium::DeliverJob) do
      assert_equal 1, Angarium::Delivery.reap_stalled(older_than: 15.minutes)
    end

    delivery.reload
    assert delivery.pending?
    assert_not_nil delivery.next_attempt_at
  end

  test "reap_stalled leaves a fresh delivering delivery alone" do
    delivery = create_delivery
    delivery.update_columns(state: "delivering", last_attempt_at: 1.minute.ago)

    assert_equal 0, Angarium::Delivery.reap_stalled(older_than: 15.minutes)
    assert delivery.reload.delivering?
  end

  test "reap_stalled is a no-op when the timeout is nil" do
    delivery = create_delivery
    delivery.update_columns(state: "delivering", last_attempt_at: 1.year.ago)

    assert_equal 0, Angarium::Delivery.reap_stalled(older_than: nil)
    assert delivery.reload.delivering?
  end

  # --- Status-code handling & callbacks ---------------------------------------

  def gone_client
    FakeAngariumClient.new(
      Angarium::Client::Result.new(success: false, code: 410, body: "", duration: 0.0, headers: {})
    )
  end

  # Set a config attribute for the block and restore it after. Used for the
  # callback attrs: Minitest's `stub` auto-invokes a value that responds to
  # :call, so it can't be used to install a Proc.
  def with_config(attr, value)
    previous = Angarium.config.public_send(attr)
    Angarium.config.public_send("#{attr}=", value)
    yield
  ensure
    Angarium.config.public_send("#{attr}=", previous)
  end

  test "410 Gone disables the endpoint and marks the delivery gone (no retry)" do
    delivery = create_delivery
    delivery.deliver!(client: gone_client)

    delivery.reload
    assert delivery.gone?
    assert_nil delivery.next_attempt_at

    @endpoint.reload
    assert @endpoint.gone?, "410 should mark the endpoint gone"
    assert @endpoint.status_changed_at.present?
  end

  test "410 Gone fires on_endpoint_deactivated with reason :gone" do
    deactivated = []
    with_config(:on_endpoint_deactivated, ->(ep, reason) { deactivated << [ep, reason] }) do
      create_delivery.deliver!(client: gone_client)
    end

    assert_equal [[@endpoint, :gone]], deactivated
  end

  test "exhausting a delivery fires on_delivery_exhausted" do
    exhausted = []
    with_config(:on_delivery_exhausted, ->(d) { exhausted << d }) do
      Angarium.config.stub(:retry_schedule, []) do
        create_delivery.deliver!(client: failing_client)
      end
    end

    assert_equal 1, exhausted.size
    assert exhausted.first.exhausted?
  end

  test "auto-disable fires on_endpoint_deactivated with reason :consecutive_failures" do
    reasons = []
    with_config(:on_endpoint_deactivated, ->(_ep, reason) { reasons << reason }) do
      Angarium.config.stub(:auto_disable_endpoint_after, 1) do
        Angarium.config.stub(:retry_schedule, []) do
          create_delivery.deliver!(client: failing_client)
        end
      end
    end

    assert_equal [:consecutive_failures], reasons
  end

  # --- Ping -------------------------------------------------------------------

  test "ping! creates an angarium.ping delivery, enqueues, and delivers to the endpoint" do
    delivery = nil
    assert_enqueued_with(job: Angarium::DeliverJob) do
      delivery = @endpoint.ping!
    end
    assert_kind_of Angarium::Delivery, delivery
    assert_equal "angarium.ping", delivery.event.name
    assert_equal @endpoint, delivery.endpoint

    fake = succeeding_client
    Angarium::Client.stub(:new, fake) { perform_enqueued_jobs }
    assert fake.requested?, "expected the ping to be delivered"
    assert_equal @endpoint.url, fake.last.url
  end

  # --- Dual-secret rotation ---------------------------------------------------

  test "within the grace window a delivery verifies with both old and new secrets" do
    old_secret = @endpoint.signing_secret
    new_secret = @endpoint.rotate_signing_secret!
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
    new_secret = @endpoint.rotate_signing_secret!
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
