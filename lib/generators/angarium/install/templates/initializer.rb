Angarium.configure do |config|
  # ActiveJob queue used for webhook deliveries.
  # config.job_queue = :default

  # HTTP read timeout (seconds) per delivery attempt.
  # config.http_timeout = 10

  # TCP connect timeout (seconds) per delivery attempt.
  # config.open_timeout = 5

  # User-Agent header sent with each delivery.
  # config.user_agent = "Angarium/#{Angarium::VERSION}"

  # Backoff schedule between retries. Length = number of retries.
  # Delays between retries (the first delivery is immediate). Standard Webhooks
  # recommended default spans ~10 days; jitter is added per attempt.
  # config.retry_schedule = [5.seconds, 5.minutes, 30.minutes, 2.hours, 5.hours,
  #                          10.hours, 14.hours, 20.hours, 24.hours, 36.hours, 48.hours, 72.hours]

  # Reject endpoint URLs that resolve to private/loopback addresses (SSRF guard).
  # Per-endpoint overrides: endpoint.allow_private_network and endpoint.allowed_networks.
  # config.block_private_ips = true

  # Primary key type for Angarium's own tables.
  # config.primary_key_type = nil # nil = use the app's default (bigint unless overridden); set :uuid etc. to force

  # Truncate the stored response body to this many bytes. nil = store the full body.
  # config.max_response_body_bytes = 65_536

  # Auto-disable an endpoint after this many consecutive failed deliveries. nil = never.
  # config.auto_disable_endpoint_after = nil

  # Honor a receiver's Retry-After header (seconds or HTTP-date) for the next attempt.
  # config.respect_retry_after = true

  # Cap (seconds) applied to a honored Retry-After value. nil = uncapped.
  # config.max_retry_after = 3600

  # Fraction of additive positive jitter applied to each backoff delay.
  # config.retry_jitter = 0.15

  # Grace window during which a rotated endpoint's previous signing secret stays
  # valid (deliveries are signed with both), so receivers can roll over with no downtime.
  # config.signing_secret_grace_period = 24.hours

  # Notification callbacks fire on terminal delivery events so you can alert
  # consumers out of band (email, Slack, PagerDuty). A raised callback is logged
  # and swallowed, so it never breaks delivery.
  # config.on_delivery_exhausted = ->(delivery) { }         # retry schedule exhausted
  # config.on_endpoint_deactivated = ->(endpoint, reason) { } # reason: :consecutive_failures | :gone (HTTP 410)
  # config.on_endpoint_verified = ->(endpoint) { }          # an `unverified` endpoint passed its first delivery

  # --- Headless JSON API (only used if you `mount Angarium::Engine`) -----------
  # Base controller the API inherits from, so your app's authentication applies.
  # config.parent_controller = "ApplicationController"

  # Resolve the current user from the controller (your current-user convention).
  # config.current_user = ->(controller) { controller.current_user }

  # Authorization, all in one class: #scope(relation) (what a user may see),
  # #owner (who a new endpoint belongs to), and #<action>? predicates. Generate a
  # starting point with `bin/rails g angarium:policy`, then override only what you
  # need. Defaults are permissive and single-owner (you manage your own endpoints).
  # config.policy_class = "WebhookEndpointPolicy"
end
