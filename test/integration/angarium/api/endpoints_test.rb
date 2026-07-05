require "test_helper"

# Resolves the create-owner from a param (admin acting on behalf of another owner).
class DelegatingPolicy < Angarium::Api::Policy
  def create_owner = Owner.find(params[:owner_id])
end

class Angarium::Api::EndpointsTest < ActionDispatch::IntegrationTest
  setup do
    @owner = Owner.create!(name: "Acme")
    @other = Owner.create!(name: "Other")
    @endpoint = @owner.webhook_endpoints.create!(
      name: "e", url: "https://203.0.113.10/hook", subscribed_events: ["*"]
    )
  end

  def auth(owner) = { "X-Owner-Id" => owner.id.to_s }

  test "requires authentication" do
    get "/angarium/endpoints"
    assert_response :unauthorized
  end

  test "index returns only the current user's endpoints and never the secret" do
    @other.webhook_endpoints.create!(name: "x", url: "https://203.0.113.30/h", subscribed_events: ["*"])

    get "/angarium/endpoints", headers: auth(@owner)
    assert_response :ok
    endpoints = JSON.parse(response.body)["endpoints"]
    assert_equal [@endpoint.id], endpoints.map { |e| e["id"] }
    refute endpoints.first.key?("signing_secret")
    refute endpoints.first.key?("custom_headers")
  end

  test "show finds within scope and 404s across scope" do
    get "/angarium/endpoints/#{@endpoint.id}", headers: auth(@owner)
    assert_response :ok

    get "/angarium/endpoints/#{@endpoint.id}", headers: auth(@other)
    assert_response :not_found
  end

  test "create owns to the current user by default and reveals the secret once" do
    assert_difference -> { @owner.webhook_endpoints.count }, 1 do
      post "/angarium/endpoints",
        params: { endpoint: { name: "New", url: "https://203.0.113.20/hook", subscribed_events: ["invoice.*"] } },
        headers: auth(@owner), as: :json
    end
    assert_response :created
    body = JSON.parse(response.body)["endpoint"]
    assert body["signing_secret"].to_s.start_with?("whsec_"), "create should reveal the signing secret"
    assert_equal @owner, Angarium::Endpoint.find(body["id"]).owner
  end

  test "a policy's create_owner can create on behalf of another owner" do
    Angarium.config.stub(:policy_class, "DelegatingPolicy") do
      post "/angarium/endpoints",
        params: { owner_id: @other.id,
                  endpoint: { name: "Deleg", url: "https://203.0.113.40/hook", subscribed_events: ["*"] } },
        headers: auth(@owner), as: :json
    end
    assert_response :created
    assert_equal @other, Angarium::Endpoint.find(JSON.parse(response.body)["endpoint"]["id"]).owner
  end

  test "create with invalid params returns 422 with details" do
    post "/angarium/endpoints", params: { endpoint: { url: "" } }, headers: auth(@owner), as: :json
    assert_response :unprocessable_entity
    assert JSON.parse(response.body)["details"].present?
  end

  test "update changes attributes" do
    patch "/angarium/endpoints/#{@endpoint.id}",
      params: { endpoint: { name: "Renamed" } }, headers: auth(@owner), as: :json
    assert_response :ok
    assert_equal "Renamed", @endpoint.reload.name
  end

  test "destroy removes the endpoint" do
    delete "/angarium/endpoints/#{@endpoint.id}", headers: auth(@owner)
    assert_response :no_content
    refute Angarium::Endpoint.exists?(@endpoint.id)
  end

  test "rotate_secret returns a fresh secret" do
    old = @endpoint.signing_secret
    post "/angarium/endpoints/#{@endpoint.id}/rotate_secret", headers: auth(@owner)
    assert_response :ok
    secret = JSON.parse(response.body)["signing_secret"]
    assert secret.start_with?("whsec_")
    refute_equal old, secret
  end

  test "pause and enable transition status" do
    post "/angarium/endpoints/#{@endpoint.id}/pause", headers: auth(@owner)
    assert_response :ok
    assert @endpoint.reload.paused?

    post "/angarium/endpoints/#{@endpoint.id}/enable", headers: auth(@owner)
    assert_response :ok
    assert @endpoint.reload.enabled?
  end

  test "ping creates an angarium.ping delivery" do
    assert_difference -> { @endpoint.deliveries.count }, 1 do
      post "/angarium/endpoints/#{@endpoint.id}/ping", headers: auth(@owner)
    end
    assert_response :accepted
    delivery = Angarium::Delivery.find(JSON.parse(response.body)["delivery"]["id"])
    assert_equal "angarium.ping", delivery.event.name
  end

  test "actions on another user's endpoint 404 (out of scope)" do
    post "/angarium/endpoints/#{@endpoint.id}/pause", headers: auth(@other)
    assert_response :not_found
    assert @endpoint.reload.enabled?
  end
end
