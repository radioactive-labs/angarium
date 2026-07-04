require "uri"

module Angarium
  class Delivery < ApplicationRecord
    STATES = %w[pending delivering succeeded exhausted blocked].freeze

    belongs_to :event, class_name: "Angarium::Event"
    belongs_to :endpoint, class_name: "Angarium::Endpoint"
    has_many :delivery_attempts, class_name: "Angarium::DeliveryAttempt", dependent: :destroy

    after_create_commit { DeliverJob.perform_later(id) }

    STATES.each do |state_name|
      define_method("#{state_name}?") { state == state_name }
    end

    # Performs one attempt. Records a DeliveryAttempt, then transitions to
    # succeeded, blocked (SSRF), schedules a retry, or exhausts. Returns the attempt.
    def deliver!(client: Client.new)
      update!(state: "delivering", attempt_count: attempt_count + 1, last_attempt_at: Time.current)

      # Re-resolve at delivery time (rather than trusting the save-time check)
      # to catch DNS rebinding: a host that now resolves to a private/disallowed
      # IP is blocked even if it was fine when the endpoint was saved. Any
      # disallowed resolved address is a terminal block.
      addresses = AddressPolicy.resolve(destination_host)

      if addresses.any? { |ip| !AddressPolicy.ip_allowed?(ip, endpoint) }
        attempt = delivery_attempts.create!(error: "blocked: destination address not permitted")
        update!(state: "blocked", next_attempt_at: nil)
        endpoint.record_delivery_failure!
        return attempt
      end

      # Fail closed: our resolver is the single source of truth. If we can't
      # resolve the host, do NOT let HTTPX resolve it unvalidated — record a
      # retryable failure. A transient DNS blip is retried; a persistently
      # unresolvable host eventually exhausts.
      if addresses.empty?
        attempt = delivery_attempts.create!(error: "unresolvable host: #{destination_host}")
        handle_failure!
        return attempt
      end

      body = request_body
      result = client.post(
        endpoint.url,
        body: body,
        headers: (endpoint.custom_headers || {}).merge(Angarium.config.signature_header => sign(body)),
        # Pin the connection to exactly the IP(s) we just validated, so HTTPX
        # can't re-resolve and connect somewhere else after our check (the
        # rebinding window). TLS SNI/cert verification still uses the URL's
        # host. `addresses` is guaranteed non-empty here (the fail-closed
        # branch above returned early otherwise), so the connection always pins.
        addresses: addresses.map(&:to_s)
      )

      attempt = delivery_attempts.create!(
        response_code: result.code,
        response_body: result.body,
        error: result.error,
        duration: result.duration
      )

      result.success? ? succeed! : handle_failure!(retry_after: retry_after_seconds(result.headers))
      attempt
    end

    # Reset the retry cycle and re-enqueue immediately. Keeps prior
    # DeliveryAttempt history. Returns self.
    def redeliver!
      update!(state: "pending", next_attempt_at: nil, attempt_count: 0)
      DeliverJob.perform_later(id)
      self
    end

    private

    def succeed!
      update!(state: "succeeded", next_attempt_at: nil)
      endpoint.record_delivery_success!
    end

    def handle_failure!(retry_after: nil)
      schedule = Array(Angarium.config.retry_schedule)
      base = schedule[attempt_count - 1] # attempt_count already incremented for this attempt

      if base.nil?
        update!(state: "exhausted")
        endpoint.record_delivery_failure!
      else
        wait = retry_after || jittered(base)
        update!(state: "pending", next_attempt_at: Time.current + wait)
        DeliverJob.set(wait: wait).perform_later(id)
      end
    end

    # Additive positive jitter to spread retries and avoid thundering herds.
    def jittered(base)
      base + (rand * base.to_f * Angarium.config.retry_jitter)
    end

    # Honor a receiver's Retry-After header (seconds or an HTTP-date), capped by
    # config.max_retry_after. Returns nil when disabled, absent, or invalid.
    def retry_after_seconds(headers)
      return nil unless Angarium.config.respect_retry_after && headers.present?

      value = headers["retry-after"]
      return nil unless value

      seconds =
        if value.match?(/\A\d+\z/)
          value.to_i
        else
          begin
            Time.httpdate(value) - Time.now
          rescue ArgumentError
            nil
          end
        end

      return nil if seconds.nil? || seconds.negative?

      cap = Angarium.config.max_retry_after
      cap ? [seconds, cap].min : seconds
    end

    def destination_host
      URI.parse(endpoint.url).host
    end

    def request_body
      {
        id: id,
        event: event.name,
        created_at: created_at.iso8601,
        data: event.payload
      }.to_json
    end

    def sign(body)
      Signature.sign(payload: body, secret: endpoint.active_signing_secrets)
    end
  end
end
