module Angarium
  class Configuration
    attr_accessor :job_queue, :http_timeout, :open_timeout, :user_agent,
                  :retry_schedule, :block_private_ips,
                  :primary_key_type, :max_response_body_bytes,
                  :auto_disable_endpoint_after, :respect_retry_after,
                  :max_retry_after, :retry_jitter, :signing_secret_grace_period,
                  :delivery_attempt_retention, :delivering_timeout,
                  :on_delivery_exhausted, :on_endpoint_disabled,
                  :parent_controller, :current_user, :policy_class

    def initialize
      @job_queue        = :default
      @http_timeout     = 10
      @open_timeout     = 5
      @user_agent       = "Angarium/#{Angarium::VERSION}"
      # Standard Webhooks recommended schedule (delays between retries; the
      # first delivery is immediate). Spans ~10 days with exponential-ish
      # backoff; jitter is added per attempt (see config.retry_jitter).
      @retry_schedule   = [
        5.seconds, 5.minutes, 30.minutes, 2.hours, 5.hours,
        10.hours, 14.hours, 20.hours, 24.hours, 36.hours, 48.hours, 72.hours
      ]
      @block_private_ips = true
      @primary_key_type = nil
      @max_response_body_bytes     = 65_536
      @auto_disable_endpoint_after = nil
      @respect_retry_after         = true
      @max_retry_after             = 3600
      @retry_jitter                = 0.15
      @signing_secret_grace_period = 24.hours
      @delivery_attempt_retention  = nil
      @delivering_timeout          = 15.minutes
      @on_delivery_exhausted       = nil # ->(delivery) { ... }
      @on_endpoint_disabled        = nil # ->(endpoint, reason) { ... } reason: :consecutive_failures | :gone

      # --- Headless JSON API (only used if you mount Angarium::Engine) ---------
      # Base controller the API inherits from, so your app's authentication
      # (Devise/Rodauth/etc.) applies to Angarium's endpoints too.
      @parent_controller = "ApplicationController"
      # Resolves the current user from the controller (your current-user convention).
      @current_user      = ->(controller) { controller.current_user }
      # Authorization: scope, create-owner, and per-action permissions, all in one
      # class. Subclass Angarium::Api::Policy to customize any of them.
      @policy_class      = "Angarium::Api::Policy"
    end
  end
end
