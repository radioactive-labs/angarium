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
      # attempt 1 (fails, reschedules), attempt 2 (fails, no schedule left -> exhausted).
      # perform_enqueued_jobs (no block) snapshots the queue once and does not
      # process jobs enqueued during that flush, so loop until it's drained.
      Angarium::Client.stub(:new, @fake) do
        perform_enqueued_jobs while enqueued_jobs.any?
      end
      delivery.reload
      assert delivery.exhausted?, "expected exhausted, was #{delivery.state}"
      assert_equal 2, delivery.attempt_count
    end
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
