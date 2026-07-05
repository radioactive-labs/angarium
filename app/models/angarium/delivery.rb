require "uri"

module Angarium
  class Delivery < ApplicationRecord
    STATES = %w[pending delivering succeeded exhausted blocked gone].freeze

    belongs_to :event, class_name: "Angarium::Event"
    belongs_to :endpoint, class_name: "Angarium::Endpoint"
    has_many :delivery_attempts, class_name: "Angarium::DeliveryAttempt", dependent: :destroy

    after_create_commit { DeliverJob.perform_later(id) }

    STATES.each do |state_name|
      define_method("#{state_name}?") { state == state_name }
    end

    # Recover deliveries stranded in "delivering": a worker set the state to
    # "delivering" (in #deliver!) but died — crash, deploy, OOM — before
    # recording the attempt or rescheduling, so the job's `pending?` guard never
    # re-runs it. Anything still "delivering" whose last attempt started before
    # `older_than.ago` is presumed abandoned and reset to "pending" + re-enqueued.
    # Returns the number requeued. Keep `older_than` well above a single attempt's
    # worst-case duration (open_timeout + http_timeout) so a live-but-slow worker
    # isn't reaped; a redelivery is at-least-once-safe regardless.
    def self.reap_stalled(older_than: Angarium.config.delivering_timeout)
      return 0 unless older_than

      ids = where(state: "delivering").where(last_attempt_at: ..older_than.ago).pluck(:id)
      return 0 if ids.empty?

      where(id: ids).update_all(state: "pending", next_attempt_at: Time.current, updated_at: Time.current)
      ids.each { |id| DeliverJob.perform_later(id) }
      ids.size
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
      ts = Time.now.to_i
      webhook_id = id.to_s
      signature = Signature.sign(payload: body, id: webhook_id, timestamp: ts, secret: endpoint.active_signing_secrets)
      headers = (endpoint.custom_headers || {}).merge(
        "webhook-id" => webhook_id,
        "webhook-timestamp" => ts.to_s,
        "webhook-signature" => signature
      )
      result = client.post(
        endpoint.url,
        body: body,
        headers: headers,
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

      # Status handling follows the Standard Webhooks receiver-etiquette guidance:
      #   2xx           -> success
      #   410 Gone      -> the receiver wants no more webhooks: disable + stop (terminal)
      #   everything else (3xx, 429, 5xx, ...) -> retryable failure. 429/502/504
      #     ("throttle" codes) are retried with backoff and honor Retry-After.
      if result.success?
        succeed!
      elsif result.code == 410
        handle_gone!
      else
        handle_failure!(retry_after: retry_after_seconds(result.headers))
      end
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

    # HTTP 410 Gone: the receiver is explicitly done with this endpoint. Per the
    # Standard Webhooks guidance, disable the endpoint (no further deliveries) and
    # mark this delivery terminal — no retries.
    def handle_gone!
      update!(state: "gone", next_attempt_at: nil)
      endpoint.disable!(reason: :gone)
    end

    def handle_failure!(retry_after: nil)
      schedule = Array(Angarium.config.retry_schedule)
      base = schedule[attempt_count - 1] # attempt_count already incremented for this attempt

      if base.nil?
        update!(state: "exhausted")
        endpoint.record_delivery_failure!
        Angarium.notify(:on_delivery_exhausted, self)
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
  end
end
