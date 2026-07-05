require "test_helper"

# Read-only: reads allowed, writes and member actions (which default to update?)
# forbidden. Subclasses the base policy to prove the override path.
class ReadOnlyPolicy < Angarium::Api::Policy
  def create? = false
  def update? = false
  def destroy? = false
end

# Uses current_user inside the policy — proves the policy runs in the controller's
# context (current_user is resolved via the controller).
class DenyAcmePolicy < Angarium::Api::Policy
  def show? = current_user.name != "Acme"
end

class Angarium::Api::PolicyTest < ActionDispatch::IntegrationTest
  setup do
    @owner = Owner.create!(name: "Acme")
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
end
