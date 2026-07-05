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

# create? inspects the resolved target owner on the unsaved record.
class OwnEndpointsOnlyPolicy < Angarium::Api::Policy
  def create? = record.owner == current_user
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

  def with_config(attr, value)
    previous = Angarium.config.public_send(attr)
    Angarium.config.public_send("#{attr}=", value)
    yield
  ensure
    Angarium.config.public_send("#{attr}=", previous)
  end

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

  test "create? authorizes the resolved target owner" do
    with_config(:resolve_owner, ->(controller) { Owner.find(controller.params[:owner_id]) }) do
      Angarium.config.stub(:policy_class, "OwnEndpointsOnlyPolicy") do
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
  end
end
