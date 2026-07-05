require "test_helper"

class Angarium::Api::DeliveriesTest < ActionDispatch::IntegrationTest
  setup do
    @owner = Owner.create!(name: "Acme")
    @other = Owner.create!(name: "Other")
    @endpoint = @owner.webhook_endpoints.create!(
      name: "e", url: "https://203.0.113.10/h", subscribed_events: ["*"]
    )
    @event = Angarium::Event.create!(name: "invoice.paid", payload: {"id" => 1})
    @delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
    @attempt = @delivery.delivery_attempts.create!(response_code: 500, error: "boom", duration: 0.1)
  end

  def auth(owner) = {"X-Owner-Id" => owner.id.to_s}

  test "lists deliveries for an endpoint in scope" do
    get "/angarium/endpoints/#{@endpoint.id}/deliveries", headers: auth(@owner)
    assert_response :ok
    assert_includes JSON.parse(response.body)["deliveries"].map { |d| d["id"] }, @delivery.id
  end

  test "shows a delivery (attempts are a separate endpoint)" do
    get "/angarium/deliveries/#{@delivery.id}", headers: auth(@owner)
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal @delivery.id, body["delivery"]["id"]
    assert_equal "invoice.paid", body["delivery"]["event"]
    refute body.key?("attempts"), "show should not embed attempts; use /attempts"
  end

  test "lists a delivery's attempts" do
    get "/angarium/deliveries/#{@delivery.id}/attempts", headers: auth(@owner)
    assert_response :ok
    assert_equal [@attempt.id], JSON.parse(response.body)["attempts"].map { |a| a["id"] }
  end

  test "list responses advertise pagination" do
    get "/angarium/deliveries/#{@delivery.id}/attempts?limit=1", headers: auth(@owner)
    assert_response :ok
    assert_equal({"limit" => 1, "offset" => 0, "count" => 1, "total" => 1},
      JSON.parse(response.body)["pagination"])
  end

  test "does not expose deliveries outside the caller's scope" do
    get "/angarium/deliveries/#{@delivery.id}", headers: auth(@other)
    assert_response :not_found

    get "/angarium/endpoints/#{@endpoint.id}/deliveries", headers: auth(@other)
    assert_response :not_found
  end

  test "redeliver resets and re-enqueues within scope" do
    @delivery.update!(state: "exhausted")
    post "/angarium/deliveries/#{@delivery.id}/redeliver", headers: auth(@owner)
    assert_response :accepted
    assert @delivery.reload.pending?
  end
end
