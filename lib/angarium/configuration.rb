module Angarium
  class Configuration
    attr_accessor :job_queue, :http_timeout, :open_timeout, :user_agent,
                  :retry_schedule, :block_private_ips,
                  :primary_key_type, :max_response_body_bytes,
                  :auto_disable_endpoint_after, :respect_retry_after,
                  :max_retry_after, :retry_jitter, :signing_secret_grace_period,
                  :delivery_attempt_retention, :delivering_timeout,
                  :on_delivery_exhausted, :on_endpoint_disabled,
                  :parent_controller, :current_user, :endpoint_scope,
                  :resolve_owner, :policy_class

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
      # The set of endpoints a user may see/act on. Deliveries and attempts are
      # scoped through their endpoint. Override for multi-tenancy.
      @endpoint_scope    = ->(current_user) { Angarium::Endpoint.where(owner: current_user) }
      # Owner for a newly-created endpoint (POST /endpoints). Defaults to the
      # current user (you create endpoints for yourself). Override to let an admin
      # act on behalf of another owner by reading a param; policy #create? then
      # authorizes the resolved owner (available as `record.owner`).
      @resolve_owner     = ->(controller) { controller.angarium_current_user }
      # Optional per-action authorization policy (subclass Angarium::Api::Policy).
      # nil = allow every action within the scope above.
      @policy_class      = nil
    end
  end
end
