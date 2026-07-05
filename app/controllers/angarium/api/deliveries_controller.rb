module Angarium
  module Api
    class DeliveriesController < BaseController
      # GET /endpoints/:endpoint_id/deliveries
      def index
        endpoint = endpoint_scope.find(params[:endpoint_id])
        authorize!(endpoint)
        render_collection(:deliveries, endpoint.deliveries.includes(:event).order(created_at: :desc)) { |d| delivery_json(d) }
      end

      # GET /deliveries/:id
      # Attempts are fetched separately (and paginated) via
      # GET /deliveries/:id/attempts.
      def show
        delivery = scoped_delivery(params[:id])
        authorize!(delivery)
        render json: { delivery: delivery_json(delivery) }
      end

      # POST /deliveries/:id/redeliver
      def redeliver
        delivery = scoped_delivery(params[:id])
        authorize!(delivery)
        delivery.redeliver!
        render json: { delivery: delivery_json(delivery) }, status: :accepted
      end
    end
  end
end
