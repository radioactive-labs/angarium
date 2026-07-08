require "uri"

module Angarium
  class Delivery < ApplicationRecord
    # Delivery lifecycle. Terminal: succeeded, exhausted, blocked (SSRF),
    # gone (410), canceled (endpoint no longer accepting deliveries at attempt time).
    enum :state, {
      pending: "pending", delivering: "delivering", succeeded: "succeeded",
      exhausted: "exhausted", blocked: "blocked", gone: "gone", canceled: "canceled"
    }, default: :pending

    belongs_to :event, class_name: "Angarium::Event"
    belongs_to :endpoint, class_name: "Angarium::Endpoint"
    has_many :delivery_attempts, class_name: "Angarium::DeliveryAttempt", dependent: :destroy

    after_create_commit { DeliverJob.perform_later(id) }

    # Recover deliveries stranded in "delivering": a worker set the state to
    # "delivering" (in #deliver!) but died (crash, deploy, OOM) before
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

      # Reset each id with a state-scoped compare-and-swap, not a blanket
      # `where(id: ids)`: a delivery can leave `delivering` (succeed, be marked
      # gone, etc.) between the pluck above and this reset. Re-asserting
      # `state: "delivering"` means we never drag a completed delivery back to
      # pending, and — since only the reaper that actually flipped the row
      # enqueues — two reapers racing the same snapshot can't double-enqueue.
      requeued = 0
      ids.each do |id|
        changed = where(id: id, state: "delivering")
          .update_all(state: "pending", next_attempt_at: Time.current, updated_at: Time.current)
        next if changed.zero?

        DeliverJob.perform_later(id)
        requeued += 1
      end
      requeued
    end

    # Performs one attempt. Records a DeliveryAttempt, then transitions to
    # succeeded, blocked (SSRF), schedules a retry, or exhausts. Returns the
    # attempt. `force` defaults to the persisted `forced` flag so a reaped or
    # redelivered forced attempt keeps bypassing the guard; pass it explicitly
    # only to override in tests.
    def deliver!(client: Client.new, force: forced)
      payload = {delivery_id: id, endpoint_id: endpoint_id, event: event.name, force: force}
      ActiveSupport::Notifications.instrument("deliver.angarium", payload) do
        # An endpoint's status can change after a delivery is queued: auto-disable
        # partway through a retry cycle, an operator pause!, or a 410 from a sibling
        # delivery. The dispatch-time `enabled` filter only gates delivery creation,
        # not queued retries, so re-check here before attempting. `force: true`
        # (a manual ping!/redeliver!) overrides the guard for this one attempt, so
        # you can test an endpoint before re-enabling it; any retry it schedules
        # follows the normal status rules again.
        unless force
          if endpoint.paused?
            payload[:outcome] = :held
            return hold_for_pause!
          end
          unless endpoint.enabled?
            payload[:outcome] = :canceled
            return cancel!(reason: endpoint.status)
          end
        end

        # Atomically claim this delivery (pending -> delivering) so only one
        # worker ever attempts it. Without the compare-and-swap, two jobs for the
        # same id (a reaper requeue racing a stale enqueue, an adapter retry, etc.)
        # would both pass the guard above, both POST, and both read the same stale
        # attempt_count. If the CAS changes no row, another worker owns it: bail.
        return nil unless claim_for_attempt!
        payload[:attempt] = attempt_count

        # Re-resolve at delivery time (rather than trusting the save-time check)
        # to catch DNS rebinding: a host that now resolves to a private/disallowed
        # IP is blocked even if it was fine when the endpoint was saved. Any
        # disallowed resolved address is a terminal block.
        addresses = AddressPolicy.resolve(destination_host)

        if addresses.any? { |ip| !AddressPolicy.ip_allowed?(ip, endpoint) }
          payload[:outcome] = :blocked
          payload[:error] = "blocked: destination address not permitted"
          attempt = record_attempt!(error: payload[:error])
          update!(state: "blocked", next_attempt_at: nil)
          endpoint.record_delivery_failure!
          return attempt
        end

        # Fail closed: our resolver is the single source of truth. If we can't
        # resolve the host, do NOT let HTTPX resolve it unvalidated; record a
        # retryable failure. A transient DNS blip is retried; a persistently
        # unresolvable host eventually exhausts.
        if addresses.empty?
          payload[:outcome] = :unresolvable
          payload[:error] = "unresolvable host: #{destination_host}"
          attempt = record_attempt!(error: payload[:error])
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

        attempt = record_attempt!(
          response_code: result.code,
          response_body: result.body,
          error: result.error,
          duration: result.duration
        )
        payload[:code] = result.code
        payload[:http_duration] = result.duration
        payload[:error] = result.error

        # Status handling follows the Standard Webhooks receiver-etiquette guidance:
        #   2xx           -> success
        #   410 Gone      -> the receiver wants no more webhooks: disable + stop (terminal)
        #   everything else (3xx, 429, 5xx, ...) -> retryable failure. 429/502/504
        #     ("throttle" codes) are retried with backoff and honor Retry-After.
        if result.success?
          payload[:outcome] = :delivered
          succeed!
        elsif result.code == 410
          payload[:outcome] = :gone
          handle_gone!
        else
          payload[:outcome] = :failed
          handle_failure!(retry_after: retry_after_seconds(result.headers))
        end
        attempt
      end
    end

    # Reset the retry cycle and re-enqueue immediately. Keeps prior
    # DeliveryAttempt history. `force: true` sends even if the endpoint is no
    # longer enabled (for the re-enqueued attempt); it is persisted so the reaper
    # honors it too. Returns self.
    def redeliver!(force: false)
      update!(state: "pending", next_attempt_at: nil, attempt_count: 0, forced: force)
      DeliverJob.perform_later(id)
      self
    end

    private

    # Atomic pending -> delivering claim: the single writer gate for an attempt.
    # Returns true if THIS caller won the row (and bumps attempt_count in the same
    # statement so concurrent claimers can't both read a stale count), false if
    # another worker already claimed it. Reload so in-memory state matches the
    # CAS (the rest of #deliver! reads attempt_count, and later update!s need a
    # clean dirty baseline to persist the delivering -> succeeded/pending move).
    def claim_for_attempt!
      now = Time.current
      # Also require the schedule to be due. Without this, a duplicate or stale
      # enqueue (an at-least-once adapter re-running a job whose retry is scheduled
      # for later) would claim and attempt EARLIER than next_attempt_at, defeating
      # the backoff the Retry-After defenses exist to protect. New, held, and
      # redelivered rows carry next_attempt_at: nil and so are always due; a
      # scheduled retry becomes claimable only once its time arrives; the reaper
      # stamps next_attempt_at = now on requeue, so a reaped row is due immediately.
      claimed = self.class.where(id: id, state: "pending")
        .where("next_attempt_at IS NULL OR next_attempt_at <= ?", now)
        .update_all(
          ["state = 'delivering', attempt_count = attempt_count + 1, last_attempt_at = ?, updated_at = ?", now, now]
        )
      return false if claimed.zero?

      reload
      true
    end

    # Endpoint was paused after this delivery was queued. Park it (no attempt
    # consumed, no failure recorded) by clearing the schedule and leaving it
    # pending; Endpoint#enable! re-enqueues parked deliveries so a pause/resume
    # cycle doesn't lose them. Returns nil (no attempt was made).
    def hold_for_pause!
      update!(state: "pending", next_attempt_at: nil)
      nil
    end

    # Endpoint reached a terminal state (disabled or gone) after this delivery was
    # queued. Stop retrying and log why. Recover with redeliver! if the endpoint is
    # later re-enabled. Returns the logged attempt.
    def cancel!(reason:)
      attempt = record_attempt!(error: "canceled: endpoint #{reason}")
      update!(state: "canceled", next_attempt_at: nil)
      attempt
    end

    # Persist a DeliveryAttempt. A raise here lands after the row is already
    # `delivering`, which would strand it for the reaper to redeliver forever (the
    # exact failure F1 exists to prevent), so this must not raise on anything the
    # receiver can influence. DeliveryAttempt#normalizes sanitizes the body and
    # error at assignment (UTF-8 scrub, NUL strip, length cap), so the create!
    # below should succeed; the rescue is a last-resort net for anything that slips
    # through (a transient DB error, a MySQL limit we cannot reproduce on SQLite).
    # We rescue broadly on purpose because any escape means a permanent loop.
    def record_attempt!(attributes)
      delivery_attempts.create!(attributes)
    rescue => e
      # The attempt's `error` is served to the webhook owner via the API, so we
      # must not leak the internal exception there: store a generic marker for
      # them, and surface the real cause internally so we can actually fix it.
      # Reported to Rails.error because a delivery we can't record is a correctness
      # problem, not a transient hiccup.
      Rails.logger.error { "[Angarium] failed to persist delivery attempt for delivery ##{id}: #{e.class}: #{e.message}" }
      Rails.error.report(e, handled: true, severity: :error, source: "angarium", context: {delivery_id: id})
      delivery_attempts.create!(
        response_code: attributes[:response_code],
        duration: attributes[:duration],
        error: "delivery attempt could not be recorded"
      )
    end

    def succeed!
      update!(state: "succeeded", next_attempt_at: nil)
      endpoint.record_delivery_success!
      # A successful delivery to an unverified endpoint (a forced ping!) proves it
      # can receive webhooks, so verify it. No-op for any other status.
      endpoint.verify!
    end

    # HTTP 410 Gone: the receiver is explicitly done with this endpoint. Per the
    # Standard Webhooks guidance, disable the endpoint (no further deliveries) and
    # mark this delivery terminal, with no retries.
    def handle_gone!
      update!(state: "gone", next_attempt_at: nil)
      endpoint.deactivate!(reason: :gone)
    end

    def handle_failure!(retry_after: nil)
      schedule = Array(Angarium.config.retry_schedule)
      base = schedule[attempt_count - 1] # attempt_count already incremented for this attempt

      if base.nil?
        update!(state: "exhausted")
        endpoint.record_delivery_failure!
        Angarium.notify(:on_delivery_exhausted, self)
      else
        wait = jittered(base)
        # Honor Retry-After only when it asks us to wait LONGER than our own
        # backoff: take the later of the two. A receiver must never be able to
        # pull retries EARLIER than our schedule; otherwise a malicious or
        # misconfigured receiver could send a tiny Retry-After to defeat our
        # backoff and make us hammer it. Retry-After can delay, never expedite.
        wait = [wait, retry_after].max if retry_after
        # Drop force: a recorded failure means the forced first attempt is spent,
        # and per the deliver! contract any scheduled retry follows normal rules.
        update!(state: "pending", next_attempt_at: Time.current + wait, forced: false)
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
