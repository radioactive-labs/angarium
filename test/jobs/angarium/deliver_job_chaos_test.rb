require "test_helper"
require "chaotic_job"

# Chaos test for the delivery job: inject a failure at an exact point in the
# execution flow (via ChaoticJob's TracePoint-based glitches) to prove the
# system survives a worker dying mid-delivery. This is the failure the reaper
# (Delivery.reap_stalled) exists to recover from.
class Angarium::DeliverJobChaosTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ChaoticJob::Helpers

  setup do
    @owner = Owner.create!(name: "Acme")
    @endpoint = Angarium::Endpoint.create!(
      owner: @owner, name: "e", url: "https://203.0.113.10/hook", subscribed_events: ["*"]
    )
    @event = Angarium::Event.create!(name: "invoice.paid", payload: { "id" => 1 })
  end

  test "a worker killed after the POST leaves the delivery recoverable by the reaper" do
    delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
    clear_enqueued_jobs # drop the after_create_commit job; we drive the job explicitly

    fake = FakeAngariumClient.new(
      Angarium::Client::Result.new(success: true, code: 200, body: "ok", duration: 0.0, headers: {})
    )

    Angarium::Client.stub(:new, fake) do
      # Glitch right as the client returns: the HTTP request has been sent (the
      # fake recorded the call) but deliver! never gets the result, so no attempt
      # is recorded and no retry is scheduled — exactly a crash after the POST.
      run_scenario(
        Angarium::DeliverJob.new(delivery.id),
        glitch: ChaoticJob::Glitch.before_return("FakeAngariumClient#post")
      )
    end

    # The webhook went out once, but the interrupted job stranded the delivery
    # in "delivering" — the job's pending? guard would never re-run it.
    assert_equal 1, fake.calls.size, "expected the webhook to have been sent once"
    assert delivery.reload.delivering?, "expected stranded in delivering, was #{delivery.state}"

    # The reaper requeues it, and redelivery completes it. At-least-once: the
    # receiver sees the webhook a second time (idempotency is the receiver's job).
    assert_equal 1, Angarium::Delivery.reap_stalled(older_than: 0.seconds)
    assert delivery.reload.pending?

    Angarium::Client.stub(:new, fake) { perform_all_jobs }

    assert delivery.reload.succeeded?, "expected succeeded after reaping, was #{delivery.state}"
    assert_equal 2, fake.calls.size, "expected exactly one redelivery (at-least-once)"
  end
end
