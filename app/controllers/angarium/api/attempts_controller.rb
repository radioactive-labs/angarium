module Angarium
  module Api
    class AttemptsController < BaseController
      # GET /deliveries/:delivery_id/attempts
      def index
        delivery = scoped_delivery(params[:delivery_id])
        authorize!(delivery)
        attempts = paginate(delivery.delivery_attempts.order(created_at: :desc))
        render json: { attempts: attempts.map { |a| attempt_json(a) } }
      end
    end
  end
end
