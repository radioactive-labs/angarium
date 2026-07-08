require "test_helper"

class Angarium::DeliveryRetryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @owner = Owner.create!(name: "Acme")
    @endpoint = Angarium::Endpoint.create!(
      owner: @owner, name: "e", url: "https://203.0.113.10/hook",
      signing_secret: "shh", subscribed_events: ["*"]
    )
    @event = Angarium::Event.create!(name: "invoice.paid", payload: {})
    # 203.0.113.10 resolves to itself, so delivery takes the resolvable + pinned
    # path (not fail-closed). The fake client stands in for the pinned HTTP call
    # returning a real 500 (see FakeAngariumClient for why WebMock can't).
    @fake = FakeAngariumClient.new(
      Angarium::Client::Result.new(success: false, code: 500, body: "boom", duration: 0.0)
    )
  end

  test "first failure reschedules with backoff and returns to pending" do
    Angarium.config.stub(:retry_schedule, [60, 300]) do
      delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
      assert_enqueued_with(job: Angarium::DeliverJob) do
        Angarium::Client.stub(:new, @fake) { perform_enqueued_jobs_once }
      end
      delivery.reload
      assert delivery.pending?, "expected pending, was #{delivery.state}"
      assert_equal 1, delivery.attempt_count
      assert delivery.next_attempt_at.present?
    end
  end

  test "exhausts after the schedule is used up" do
    Angarium.config.stub(:retry_schedule, [60]) do
      delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
      # Drive the attempts directly: the test job adapter performs a scheduled
      # retry immediately (ignoring its wait), but the claim now refuses an attempt
      # before next_attempt_at, so we advance the clock to make each retry due.
      delivery.deliver!(client: @fake) # attempt 1 fails, reschedules 60s out
      assert delivery.reload.pending?, "expected pending after first failure"
      assert_equal 1, delivery.attempt_count

      # Well past base + jitter so the retry is unambiguously due.
      travel 10.minutes do
        delivery.deliver!(client: @fake) # attempt 2 fails, no schedule left
      end
      delivery.reload
      assert delivery.exhausted?, "expected exhausted, was #{delivery.state}"
      assert_equal 2, delivery.attempt_count
    end
  end

  test "a stale duplicate job cannot attempt a delivery before next_attempt_at" do
    # A pending delivery mid-backoff (a future next_attempt_at, as after a failure).
    # An at-least-once adapter redelivering a stale enqueue now must not pull the
    # attempt earlier than the schedule allows.
    delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
    delivery.update!(state: "pending", attempt_count: 1, next_attempt_at: 2.hours.from_now)
    ok = FakeAngariumClient.new(Angarium::Client::Result.new(success: true, code: 200, body: "ok", duration: 0.0))

    assert_nil delivery.deliver!(client: ok), "the early claim should be refused"
    refute ok.requested?, "no HTTP request should happen before next_attempt_at"
    delivery.reload
    assert delivery.pending?, "expected pending, was #{delivery.state}"
    assert_equal 1, delivery.attempt_count, "attempt_count must not advance on a refused claim"
  end

  test "a scheduled retry is claimed once next_attempt_at is due" do
    delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
    delivery.update!(state: "pending", attempt_count: 1, next_attempt_at: 1.hour.ago)
    ok = FakeAngariumClient.new(Angarium::Client::Result.new(success: true, code: 200, body: "ok", duration: 0.0))

    delivery.deliver!(client: ok)
    assert ok.requested?, "a due retry should be attempted"
    assert delivery.reload.succeeded?, "expected succeeded, was #{delivery.state}"
  end

  test "redeliver! stays immediately claimable under the due-time claim guard" do
    delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
    delivery.update!(state: "exhausted", attempt_count: 3, next_attempt_at: nil)
    ok = FakeAngariumClient.new(Angarium::Client::Result.new(success: true, code: 200, body: "ok", duration: 0.0))

    delivery.redeliver! # resets to pending, attempt_count 0, next_attempt_at nil
    # next_attempt_at: nil satisfies the "IS NULL" branch of the claim guard, so
    # the re-enqueued attempt fires now rather than waiting out any backoff.
    delivery.deliver!(client: ok)
    assert ok.requested?, "a redelivered attempt should fire immediately"
    delivery.reload
    assert delivery.succeeded?, "expected succeeded, was #{delivery.state}"
    assert_equal 1, delivery.attempt_count
  end

  private

  # Perform only the jobs currently enqueued, not ones they enqueue in turn.
  def perform_enqueued_jobs_once
    jobs = enqueued_jobs.dup
    clear_enqueued_jobs
    jobs.each do |job|
      ActiveJob::Base.execute(job.except("provider_job_id"))
    end
  end
end
