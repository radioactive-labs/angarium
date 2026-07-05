module Angarium
  module Api
    class EndpointsController < BaseController
      before_action :set_endpoint, only: %i[show update destroy rotate_secret pause enable ping]

      def index
        authorize!
        render_collection(:endpoints, endpoint_scope.order(created_at: :desc)) { |e| endpoint_json(e) }
      end

      def show
        authorize!(@endpoint)
        render json: { endpoint: endpoint_json(@endpoint) }
      end

      def create
        # The owner comes from the policy's #owner (default: current_user), set
        # before authorize! so policy #create? can gate the target owner.
        endpoint = Angarium::Endpoint.new(endpoint_params)
        endpoint.owner = angarium_policy.owner
        authorize!(endpoint)
        endpoint.save!
        # The signing secret is revealed once, on creation.
        render json: { endpoint: endpoint_json(endpoint, include_secret: true) }, status: :created
      end

      def update
        authorize!(@endpoint)
        @endpoint.update!(endpoint_params)
        render json: { endpoint: endpoint_json(@endpoint) }
      end

      def destroy
        authorize!(@endpoint)
        @endpoint.destroy!
        head :no_content
      end

      def rotate_secret
        authorize!(@endpoint)
        secret = @endpoint.rotate_signing_secret!
        render json: { endpoint: endpoint_json(@endpoint), signing_secret: secret }
      end

      def pause
        authorize!(@endpoint)
        @endpoint.pause!
        render json: { endpoint: endpoint_json(@endpoint) }
      end

      def enable
        authorize!(@endpoint)
        @endpoint.enable!
        render json: { endpoint: endpoint_json(@endpoint) }
      end

      def ping
        authorize!(@endpoint)
        delivery = @endpoint.ping!
        render json: { delivery: delivery_json(delivery) }, status: :accepted
      end

      private

      def set_endpoint
        @endpoint = endpoint_scope.find(params[:id])
      end

      # SSRF-relevant controls, each gated by its own policy predicate. They are
      # independent: allow_private_network relaxes the private-IP denylist
      # (dangerous), while allowed_networks only restricts delivery to a CIDR
      # allowlist. permit shape per attribute (scalar vs array).
      NETWORK_CONTROLS = {
        allow_private_network: :permit_allow_private_network?,
        allowed_networks: :permit_allowed_networks?
      }.freeze

      def endpoint_params
        policy = angarium_policy
        permitted = [:name, :url, {subscribed_events: [], custom_headers: {}}]

        NETWORK_CONTROLS.each do |attr, predicate|
          if policy.public_send(predicate)
            permitted << ((attr == :allowed_networks) ? {allowed_networks: []} : attr)
          else
            reject_network_control_change!(attr)
          end
        end

        params.require(:endpoint).permit(*permitted)
      end

      # A request may not change a network control the policy doesn't permit.
      # Attempting to (a submitted value that differs from the record's current
      # value) is a 422 naming the attribute, so an escalation attempt fails
      # loudly rather than being silently ignored. Echoing the current value is a
      # no-op and allowed, so a client can round-trip the serialized endpoint.
      def reject_network_control_change!(attr)
        body = params.fetch(:endpoint, ActionController::Parameters.new)
        return unless body.key?(attr)

        current = (@endpoint || Angarium::Endpoint.new).public_send(attr)
        submitted = body[attr]
        submitted = Array(submitted).map(&:to_s) if attr == :allowed_networks

        raise Angarium::Api::UnpermittedParameter, attr unless submitted == current
      end
    end
  end
end
