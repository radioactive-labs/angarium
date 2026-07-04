Angarium.configure do |config|
  # ActiveJob queue used for webhook deliveries.
  # config.job_queue = :default

  # HTTP read timeout (seconds) per delivery attempt.
  # config.http_timeout = 10

  # Backoff schedule between retries. Length = number of retries.
  # config.retry_schedule = [1.minute, 5.minutes, 30.minutes, 2.hours, 5.hours]

  # Header used to carry the HMAC signature.
  # config.signature_header = "X-Angarium-Signature"

  # Reject endpoint URLs that resolve to private/loopback addresses (SSRF guard).
  # Per-endpoint overrides: endpoint.allow_private_network and endpoint.allowed_networks.
  # config.block_private_ips = true
end
