require "test_helper"

class Angarium::DeliverJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @owner = Owner.create!(name: "Acme")
    @endpoint = Angarium::Endpoint.create!(
      owner: @owner, name: "e", url: "https://example.test/hook",
      signing_secret: "shh", subscribed_events: ["*"]
    )
    @event = Angarium::Event.create!(name: "invoice.paid", payload: { "id" => 1 })
  end

  test "creating a delivery enqueues the deliver job" do
    assert_enqueued_with(job: Angarium::DeliverJob) do
      Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
    end
  end

  test "successful 2xx delivery marks succeeded and records an attempt" do
    stub = stub_request(:post, "https://example.test/hook").to_return(status: 200, body: "ok")
    delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)

    perform_enqueued_jobs

    delivery.reload
    assert delivery.succeeded?, "expected succeeded, was #{delivery.state}"
    assert_equal 1, delivery.attempt_count
    attempt = delivery.delivery_attempts.sole
    assert_equal 200, attempt.response_code
    assert_requested stub
  end

  test "request carries signature header and json envelope" do
    body = nil
    headers = nil
    stub_request(:post, "https://example.test/hook").to_return(status: 200).with do |req|
      body = req.body
      headers = req.headers
      true
    end

    Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
    perform_enqueued_jobs

    assert headers["X-Angarium-Signature"].present?
    envelope = JSON.parse(body)
    assert_equal "invoice.paid", envelope["event"]
    assert_equal({ "id" => 1 }, envelope["data"])
    assert envelope["id"].present?
    assert Angarium::Signature.verify(
      payload: body, header: headers["X-Angarium-Signature"], secret: "shh"
    )
  end

  test "failed delivery with empty retry schedule is exhausted" do
    Angarium.config.stub(:retry_schedule, []) do
      stub_request(:post, "https://example.test/hook").to_return(status: 500, body: "boom")
      delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
      perform_enqueued_jobs
      delivery.reload
      assert delivery.exhausted?, "expected exhausted, was #{delivery.state}"
      assert_equal 1, delivery.attempt_count
      assert_equal 500, delivery.delivery_attempts.sole.response_code
    end
  end

  test "blocks delivery to a disallowed destination without making a request" do
    stub = stub_request(:post, "https://example.test/hook")
    delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)

    Angarium::AddressPolicy.stub(:host_permitted_for_validation?, false) do
      perform_enqueued_jobs
    end

    delivery.reload
    assert delivery.blocked?, "expected blocked, was #{delivery.state}"
    assert_not_requested stub
    assert_match(/blocked/i, delivery.delivery_attempts.sole.error)
  end
end
