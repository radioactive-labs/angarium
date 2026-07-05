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

      def endpoint_params
        attrs = [:name, :url, {subscribed_events: [], custom_headers: {}}]
        # allow_private_network / allowed_networks can point an endpoint at private
        # or loopback addresses (SSRF), so they are not API-writable unless the
        # policy opts in for trusted operators.
        attrs.push(:allow_private_network, {allowed_networks: []}) if angarium_policy.permit_network_controls?
        params.require(:endpoint).permit(*attrs)
      end
    end
  end
end
