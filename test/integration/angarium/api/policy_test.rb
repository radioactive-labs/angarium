require "test_helper"

# Read-only: reads allowed, writes and member actions (which default to update?)
# forbidden. Subclasses the base policy to prove the override path.
class ReadOnlyPolicy < Angarium::Api::Policy
  def create? = false
  def update? = false
  def destroy? = false
end

# Uses current_user inside the policy, proving the policy runs in the controller's
# context (current_user is resolved via the controller).
class DenyAcmePolicy < Angarium::Api::Policy
  def show? = current_user.name != "Acme"
end

# Resolves the owner from a param, then gates who may act on behalf of another
# owner in create? (record.owner is the resolved target).
class DelegateOwnOnlyPolicy < Angarium::Api::Policy
  def owner = Owner.find(params[:owner_id])
  def create? = record.owner == current_user
end

# A broad scope (multi-tenant admin who sees everything): don't narrow the base.
class AllEndpointsPolicy < Angarium::Api::Policy
  def scope(relation) = relation
end

class Angarium::Api::PolicyTest < ActionDispatch::IntegrationTest
  setup do
    @owner = Owner.create!(name: "Acme")
    @other = Owner.create!(name: "Other")
    @endpoint = @owner.webhook_endpoints.create!(
      name: "e", url: "https://203.0.113.10/h", subscribed_events: ["*"]
    )
  end

  def auth = { "X-Owner-Id" => @owner.id.to_s }

  test "policy permits reads and forbids writes and member actions" do
    Angarium.config.stub(:policy_class, "ReadOnlyPolicy") do
      get "/angarium/endpoints/#{@endpoint.id}", headers: auth
      assert_response :ok

      post "/angarium/endpoints",
        params: { endpoint: { name: "n", url: "https://203.0.113.20/h" } }, headers: auth, as: :json
      assert_response :forbidden

      patch "/angarium/endpoints/#{@endpoint.id}",
        params: { endpoint: { name: "x" } }, headers: auth, as: :json
      assert_response :forbidden

      delete "/angarium/endpoints/#{@endpoint.id}", headers: auth
      assert_response :forbidden

      # member action inherits update? => forbidden
      post "/angarium/endpoints/#{@endpoint.id}/rotate_secret", headers: auth
      assert_response :forbidden
    end
  end

  test "policy runs in the controller's context (can read current_user)" do
    Angarium.config.stub(:policy_class, "DenyAcmePolicy") do
      get "/angarium/endpoints/#{@endpoint.id}", headers: auth
      assert_response :forbidden
    end
  end

  test "owner and create? together gate acting on behalf of another owner" do
    Angarium.config.stub(:policy_class, "DelegateOwnOnlyPolicy") do
      post "/angarium/endpoints",
        params: { owner_id: @other.id, endpoint: { name: "n", url: "https://203.0.113.20/h" } },
        headers: auth, as: :json
      assert_response :forbidden, "creating for another owner should be denied"

      post "/angarium/endpoints",
        params: { owner_id: @owner.id, endpoint: { name: "n", url: "https://203.0.113.21/h" } },
        headers: auth, as: :json
      assert_response :created, "creating for yourself should be allowed"
    end
  end

  test "policy #scope controls which endpoints are visible" do
    other_endpoint = @other.webhook_endpoints.create!(
      name: "x", url: "https://203.0.113.50/h", subscribed_events: ["*"]
    )

    # Default policy scopes to the current user: another owner's endpoint is a 404.
    get "/angarium/endpoints/#{other_endpoint.id}", headers: auth
    assert_response :not_found

    # A policy with a broad scope can see it.
    Angarium.config.stub(:policy_class, "AllEndpointsPolicy") do
      get "/angarium/endpoints/#{other_endpoint.id}", headers: auth
      assert_response :ok
    end
  end
end
