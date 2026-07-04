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
        return attempt
      end

      body = request_body
      result = client.post(
        endpoint.url,
        body: body,
        headers: { Angarium.config.signature_header => sign(body) },
        # Pin the connection to exactly the IP(s) we just validated, so HTTPX
        # can't re-resolve and connect somewhere else after our check (the
        # rebinding window). TLS SNI/cert verification still uses the URL's
        # host. When we can't resolve (addresses == []), there's no rebinding
        # risk to guard against (nothing resolved to a disallowed IP), so we
        # pass no addresses and let HTTPX resolve normally.
        addresses: addresses.map(&:to_s)
      )

      attempt = delivery_attempts.create!(
        response_code: result.code,
        response_body: result.body,
        error: result.error,
        duration: result.duration
      )

      result.success? ? succeed! : handle_failure!
      attempt
    end

    private

    def succeed!
      update!(state: "succeeded", next_attempt_at: nil)
    end

    def handle_failure!
      schedule = Array(Angarium.config.retry_schedule)
      wait = schedule[attempt_count - 1] # attempt_count already incremented for this attempt

      if wait
        update!(state: "pending", next_attempt_at: Time.current + wait)
        DeliverJob.set(wait: wait).perform_later(id)
      else
        update!(state: "exhausted")
      end
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
      Signature.sign(payload: body, secret: endpoint.signing_secret)
    end
  end
end
