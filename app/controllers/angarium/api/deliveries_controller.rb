module Angarium
  module Api
    class DeliveriesController < BaseController
      # GET /endpoints/:endpoint_id/deliveries
      def index
        endpoint = endpoint_scope.find(params[:endpoint_id])
        authorize!(endpoint)
        deliveries = paginate(endpoint.deliveries.includes(:event).order(created_at: :desc))
        render json: { deliveries: deliveries.map { |d| delivery_json(d) } }
      end

      # GET /deliveries/:id
      def show
        delivery = scoped_delivery(params[:id])
        authorize!(delivery)
        render json: {
          delivery: delivery_json(delivery),
          attempts: delivery.delivery_attempts.order(created_at: :desc).map { |a| attempt_json(a) }
        }
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
