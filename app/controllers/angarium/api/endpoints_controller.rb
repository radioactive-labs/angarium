module Angarium
  module Api
    class EndpointsController < BaseController
      before_action :set_endpoint, only: %i[show update destroy rotate_secret pause enable ping]

      def index
        authorize!
        endpoints = paginate(endpoint_scope.order(created_at: :desc))
        render json: { endpoints: endpoints.map { |e| endpoint_json(e) } }
      end

      def show
        authorize!(@endpoint)
        render json: { endpoint: endpoint_json(@endpoint) }
      end

      def create
        # The owner comes from config.resolve_owner (default: current_user), not
        # the read scope, so an admin can create on behalf of another owner. The
        # owner is set before authorize!, so policy #create? sees record.owner.
        endpoint = Angarium::Endpoint.new(endpoint_params)
        endpoint.owner = Angarium.config.resolve_owner.call(self)
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
        params.require(:endpoint).permit(
          :name, :url, :allow_private_network,
          subscribed_events: [], allowed_networks: [], custom_headers: {}
        )
      end
    end
  end
end
