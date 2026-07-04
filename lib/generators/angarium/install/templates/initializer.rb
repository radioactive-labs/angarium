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
  # config.retry_schedule = [1.minute, 5.minutes, 30.minutes, 2.hours, 5.hours]

  # Header used to carry the HMAC signature.
  # config.signature_header = "X-Angarium-Signature"

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
end
