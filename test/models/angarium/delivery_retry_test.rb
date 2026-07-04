require "test_helper"

class Angarium::DeliveryRetryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @owner = Owner.create!(name: "Acme")
    @endpoint = Angarium::Endpoint.create!(
      owner: @owner, name: "e", url: "https://example.test/hook",
      signing_secret: "shh", subscribed_events: ["*"]
    )
    @event = Angarium::Event.create!(name: "invoice.paid", payload: {})
    stub_request(:post, "https://example.test/hook").to_return(status: 500)
  end

  test "first failure reschedules with backoff and returns to pending" do
    Angarium.config.stub(:retry_schedule, [60, 300]) do
      delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
      assert_enqueued_with(job: Angarium::DeliverJob) do
        perform_enqueued_jobs_once
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
      perform_enqueued_jobs while enqueued_jobs.any?
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
