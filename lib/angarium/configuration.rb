module Angarium
  class Configuration
    attr_accessor :job_queue, :http_timeout, :open_timeout, :user_agent,
      :retry_schedule, :block_private_ips,
      :primary_key_type, :database, :connects_to, :max_response_body_bytes,
      :auto_disable_endpoint_after, :respect_retry_after,
      :max_retry_after, :retry_jitter, :signing_secret_grace_period,
      :delivery_attempt_retention, :delivering_timeout, :dns_timeout,
      :resolve_dns_with_hosts_file, :max_url_length, :max_subscribed_events,
      :on_delivery_exhausted, :on_endpoint_deactivated, :on_endpoint_verified,
      :parent_controller, :current_user, :policy_class

    def initialize
      @job_queue = :default
      @http_timeout = 10
      @open_timeout = 5
      @user_agent = "Angarium/#{Angarium::VERSION}"
      # Follows the Standard Webhooks recommendation of a multi-day schedule with
      # exponential backoff (delays between retries; the first delivery is
      # immediate). Spans ~10 days; jitter is added per attempt (see
      # config.retry_jitter).
      @retry_schedule = [
        5.seconds, 5.minutes, 30.minutes, 2.hours, 5.hours,
        10.hours, 14.hours, 20.hours, 24.hours, 36.hours, 48.hours, 72.hours
      ]
      @block_private_ips = true
      @primary_key_type = nil
      # Multi-database: the database (a key from config/database.yml) that
      # Angarium's tables live in. Drives both the connection and where the
      # migrations generator installs migrations (db/<database>_migrate).
      # nil (default) keeps Angarium on the app's primary connection.
      @database = nil
      # Advanced multi-database: a hash passed straight to Rails' connects_to for
      # custom roles/shards, e.g. { database: { writing: :angarium, reading: :angarium } }.
      # Takes precedence over @database for the connection.
      @connects_to = nil
      @max_response_body_bytes = 65_536
      # Disable an endpoint after this many consecutive *failed deliveries* (a
      # delivery that exhausts its whole retry schedule, or is blocked by the SSRF
      # guard) — NOT individual failed HTTP attempts. A single delivery that
      # retries and eventually gives up counts as one. nil disables auto-disable.
      @auto_disable_endpoint_after = nil
      @respect_retry_after = true
      @max_retry_after = 3600
      @retry_jitter = 0.15
      @signing_secret_grace_period = 24.hours
      @delivery_attempt_retention = nil
      @delivering_timeout = 15.minutes
      # Per-try timeout(s), in seconds, for resolving an endpoint host before
      # delivery. Bounds how long a hostile or misconfigured slow-resolving host
      # can stall a delivery worker (Resolv::DNS retries across the array). Set to
      # nil to use the resolver's own defaults.
      @dns_timeout = [1, 3]
      # Whether host resolution also consults the system hosts file (/etc/hosts),
      # not just DNS. Default true, so an internal endpoint pinned via /etc/hosts
      # resolves as expected. Set false to harden a deployment to DNS-only.
      @resolve_dns_with_hosts_file = true
      # Max length of an endpoint URL and the cap on how many event patterns an
      # endpoint may subscribe to (each pattern is replayed by EventMatcher on
      # every dispatch). Both bound user-supplied input.
      @max_url_length = 2048
      @max_subscribed_events = 100
      @on_delivery_exhausted = nil # ->(delivery) { ... }
      @on_endpoint_deactivated = nil # ->(endpoint, reason) { ... } reason: :consecutive_failures | :gone
      @on_endpoint_verified = nil # ->(endpoint) { ... } fired when an unverified endpoint is verified

      # --- Headless JSON API (only used if you mount Angarium::Engine) ---------
      # Base controller the API inherits from, so your app's authentication
      # (Devise/Rodauth/etc.) applies to Angarium's endpoints too.
      @parent_controller = "ApplicationController"
      # Resolves the current user from the controller (your current-user convention).
      @current_user = ->(controller) { controller.current_user }
      # Authorization: scope, create-owner, and per-action permissions, all in one
      # class. Subclass Angarium::Api::Policy to customize any of them.
      @policy_class = "Angarium::Api::Policy"
    end

    # The database Angarium's migrations belong in, for the migrations generator.
    # Prefers the explicit @database, else the writing role from a connects_to
    # hash. nil => the app's primary db/migrate.
    def migrations_database
      database || connects_to&.dig(:database, :writing)
    end
  end
end
