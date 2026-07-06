module Angarium
  module Api
    class AttemptsController < BaseController
      # GET /deliveries/:delivery_id/attempts
      def index
        delivery = scoped_delivery(params[:delivery_id])
        authorize!(delivery)
        render_collection(:attempts, delivery.delivery_attempts.order(created_at: :desc)) { |a| attempt_json(a) }
      end
    end
  end
end
