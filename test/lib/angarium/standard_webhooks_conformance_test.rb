require "test_helper"
require "standardwebhooks"
require "base64"

# Standard Webhooks CONFORMANCE suite.
#
# Unlike standard_webhooks_interop_test.rb (which round-trips Angarium::Signature
# directly), this drives the REAL delivery pipeline end to end —
# `Angarium.dispatch` -> DeliverJob -> Delivery#deliver! — and verifies the
# ACTUAL emitted body + headers with the OFFICIAL standardwebhooks library. So
# it catches drift the round-trip can't: a job that serializes the envelope
# differently than what gets signed, a header-name change, base64/whsec_ form,
# or the multi-token rotation header.
#
# Capture boundary: we record at Angarium::Client (via FakeAngariumClient), not
# via WebMock. The delivery path always pins the socket to the validated IP, and
# httpx 1.8's WebMock adapter hangs on teardown for a pinned request (see the
# note in test_helper.rb). The captured body/headers are exactly what
# Client#post hands to HTTPX, so this is still a full-pipeline conformance check.
# The endpoint URL uses a reserved public IP (203.0.113.10, RFC 5737) so the
# SSRF layer resolves it to itself and permits it without any DNS in CI.
class Angarium::StandardWebhooksConformanceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @owner = Owner.create!(name: "Acme")
    @endpoint = Angarium::Endpoint.create!(
      owner: @owner, name: "Conformance",
      url: "https://203.0.113.10/webhooks",
      subscribed_events: ["*"]
    )
  end

  # Run the real pipeline for one event and return the captured Client call
  # (the exact body + headers Angarium put on the wire).
  def deliver!(event = "conformance.test", payload = { "hello" => "world" })
    result = Angarium::Client::Result.new(success: true, code: 200, body: "", headers: {})
    fake = FakeAngariumClient.new(result)
    Angarium::Client.stub(:new, fake) do
      perform_enqueued_jobs { Angarium.dispatch(event, payload, owner: @owner) }
    end
    fake.last
  end

  def verifier(secret) = StandardWebhooks::Webhook.new(secret)

  # WebMock-style capitalized keys aren't in play here (we capture raw), but the
  # official library reads exact lowercase keys, so normalize defensively.
  def sw_headers(call)
    call.headers.transform_keys { |k| k.to_s.downcase }
      .slice("webhook-id", "webhook-timestamp", "webhook-signature")
  end

  test "emitted request verifies with the official standardwebhooks library" do
    call = deliver!
    # Conformance = the official library accepts our request. verify's RETURN
    # shape differs across gem versions (1.0.1 symbolizes keys, 1.1.0 doesn't),
    # so assert it doesn't raise, and check envelope contents by parsing the
    # body ourselves rather than relying on verify's return.
    assert_nothing_raised { verifier(@endpoint.signing_secret).verify(call.body, sw_headers(call)) }
    envelope = JSON.parse(call.body)
    assert_equal "conformance.test", envelope["event"]
    assert_equal({ "hello" => "world" }, envelope["data"])
  end

  test "webhook-id header equals the envelope id" do
    call = deliver!
    envelope = JSON.parse(call.body)
    assert_equal envelope["id"].to_s, sw_headers(call)["webhook-id"]
  end

  test "signs the raw bytes: a non-ASCII payload still verifies" do
    call = deliver!("conformance.unicode", { "note" => "héllo — ünïcode ✓" })
    assert_nothing_raised { verifier(@endpoint.signing_secret).verify(call.body, sw_headers(call)) }
  end

  test "a tampered body is rejected" do
    call = deliver!
    tampered = call.body.sub("world", "w0rld")
    assert_raises(StandardWebhooks::WebhookVerificationError) do
      verifier(@endpoint.signing_secret).verify(tampered, sw_headers(call))
    end
  end

  test "the wrong secret is rejected" do
    call = deliver!
    wrong = "whsec_#{Base64.strict_encode64(SecureRandom.bytes(24))}"
    assert_raises(StandardWebhooks::WebhookVerificationError) do
      verifier(wrong).verify(call.body, sw_headers(call))
    end
  end

  test "dual-signs during the rotation grace window: both secrets verify" do
    old_secret = @endpoint.signing_secret
    new_secret = @endpoint.rotate_secret!

    call = deliver!("conformance.rotated")
    headers = sw_headers(call)

    # The official library iterates the space-delimited v1 tokens, so a receiver
    # holding EITHER secret must succeed.
    assert_nothing_raised { verifier(new_secret).verify(call.body, headers) }
    assert_nothing_raised { verifier(old_secret).verify(call.body, headers) }
    assert_equal 2, headers["webhook-signature"].split(" ").length
  end

  test "signs with only the new secret after the grace period" do
    old_secret = @endpoint.signing_secret
    new_secret = @endpoint.rotate_secret!

    # The grace cutoff is evaluated at signing time (active_signing_secrets checks
    # secret_rotated_at > grace_period.ago), so traveling past the window flips it.
    travel(Angarium.config.signing_secret_grace_period + 1.minute) do
      call = deliver!("conformance.post_grace")
      headers = sw_headers(call)

      assert_nothing_raised { verifier(new_secret).verify(call.body, headers) }
      assert_raises(StandardWebhooks::WebhookVerificationError) do
        verifier(old_secret).verify(call.body, headers)
      end
      assert_equal 1, headers["webhook-signature"].split(" ").length
    end
  end
end
