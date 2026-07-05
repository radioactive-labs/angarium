module Angarium
  module Api
    # Base controller for the headless JSON API. Inherits from your app's
    # controller (config.parent_controller, default "ApplicationController"), so
    # your existing authentication applies here too.
    class BaseController < Angarium.config.parent_controller.constantize
      # These endpoints authenticate via your current-user convention (a session
      # or token), not a form CSRF token. If we inherited a forgery-protecting
      # base (ActionController::Base), don't reject API POSTs for a missing token.
      protect_from_forgery with: :null_session if respond_to?(:protect_from_forgery)

      before_action :authenticate_angarium_user!

      rescue_from ActiveRecord::RecordNotFound, with: :angarium_render_not_found
      rescue_from ActiveRecord::RecordInvalid, with: :angarium_render_invalid
      rescue_from Angarium::Api::NotAuthorized, with: :angarium_render_forbidden

      # Resolved current user (via config.current_user). Public so policies can
      # read it as `controller.angarium_current_user`.
      def angarium_current_user
        return @angarium_current_user if defined?(@angarium_current_user)

        @angarium_current_user = Angarium.config.current_user.call(self)
      end

      private

      def authenticate_angarium_user!
        angarium_render_unauthorized unless angarium_current_user
      end

      # The endpoints this user may see/act on.
      def endpoint_scope
        Angarium.config.endpoint_scope.call(angarium_current_user)
      end

      # A delivery whose endpoint is within the caller's scope, or 404.
      def scoped_delivery(id)
        Angarium::Delivery.where(endpoint_id: endpoint_scope.select(:id)).find(id)
      end

      # Guard the current action with the configured policy (no-op if unset).
      def authorize!(record = nil)
        klass = Angarium.config.policy_class
        return unless klass

        policy = klass.to_s.constantize.new(self, record)
        raise Angarium::Api::NotAuthorized unless policy.public_send("#{action_name}?")
      end

      def paginate(relation)
        limit = params.fetch(:limit, 50).to_i.clamp(1, 200)
        offset = [params.fetch(:offset, 0).to_i, 0].max
        relation.limit(limit).offset(offset)
      end

      def render_error(status, message, **extra)
        render json: { error: message, **extra }, status: status
      end

      def angarium_render_unauthorized = render_error(:unauthorized, "authentication required")
      def angarium_render_forbidden = render_error(:forbidden, "not authorized")
      def angarium_render_not_found = render_error(:not_found, "not found")

      def angarium_render_invalid(error)
        render_error(:unprocessable_entity, "validation failed", details: error.record.errors.full_messages)
      end

      # --- serializers ----------------------------------------------------------
      # signing_secret and custom_headers are never echoed in responses (they're
      # encrypted at rest and may carry credentials); the secret is revealed only
      # on create and rotate_secret.

      def endpoint_json(endpoint, include_secret: false)
        json = {
          id: endpoint.id,
          name: endpoint.name,
          url: endpoint.url,
          status: endpoint.status,
          subscribed_events: endpoint.subscribed_events,
          allow_private_network: endpoint.allow_private_network,
          allowed_networks: endpoint.allowed_networks,
          consecutive_failures: endpoint.consecutive_failures,
          status_changed_at: endpoint.status_changed_at&.iso8601,
          created_at: endpoint.created_at.iso8601,
          updated_at: endpoint.updated_at.iso8601
        }
        json[:signing_secret] = endpoint.signing_secret if include_secret
        json
      end

      def delivery_json(delivery)
        {
          id: delivery.id,
          endpoint_id: delivery.endpoint_id,
          event: delivery.event.name,
          state: delivery.state,
          attempt_count: delivery.attempt_count,
          next_attempt_at: delivery.next_attempt_at&.iso8601,
          last_attempt_at: delivery.last_attempt_at&.iso8601,
          created_at: delivery.created_at.iso8601,
          updated_at: delivery.updated_at.iso8601
        }
      end

      def attempt_json(attempt)
        {
          id: attempt.id,
          delivery_id: attempt.delivery_id,
          response_code: attempt.response_code,
          response_body: attempt.response_body,
          error: attempt.error,
          duration: attempt.duration,
          created_at: attempt.created_at.iso8601
        }
      end
    end
  end
end
