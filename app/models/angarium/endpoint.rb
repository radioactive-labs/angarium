require "securerandom"
require "base64"

module Angarium
  class Endpoint < ApplicationRecord
    # Headers a user-supplied custom header may never set: the Standard Webhooks
    # signature headers (which must not be spoofable) and transport/hop-by-hop
    # headers whose override invites request smuggling or receiver confusion.
    RESERVED_HEADERS = %w[
      webhook-id webhook-timestamp webhook-signature
      host content-length content-type transfer-encoding connection
    ].freeze

    belongs_to :owner, polymorphic: true
    has_many :deliveries, class_name: "Angarium::Delivery", dependent: :destroy

    # Encrypted at rest: the signing secret(s) and custom_headers; the latter
    # commonly carries a receiver credential (e.g. an Authorization bearer token),
    # so it gets the same protection as the signing secret.
    encrypts :signing_secret, :previous_signing_secret
    encrypts :custom_headers

    # Lifecycle status. `enabled` endpoints receive deliveries; the rest don't.
    #   unverified: created but not yet proven; verified by a successful delivery
    #               (a forced #ping!) or #verify!, which moves it to `enabled`
    #   paused:     turned off manually (resumable via #enable!)
    #   disabled:   auto-disabled after too many consecutive failures (resumable)
    #   gone:       the receiver returned HTTP 410; treat as terminal
    enum :status, {enabled: "enabled", paused: "paused", disabled: "disabled", gone: "gone", unverified: "unverified"},
      default: :enabled

    # Rails < 8.1's SQLite adapter doesn't parse the `DEFAULT FALSE` literal
    # SQLite reports back for boolean columns (fixed in
    # ActiveRecord::ConnectionAdapters::SQLite3::SchemaStatements
    # #extract_value_from_default starting in Rails 8.1), leaving this attribute
    # nil on a new record instead of the schema default. Declaring the default
    # here keeps behavior correct on every supported Rails version.
    attribute :allow_private_network, :boolean, default: false

    before_validation :ensure_signing_secret, on: :create

    validates :name, presence: true, length: {maximum: 255}
    validates :url, presence: true
    validates :url, "angarium/endpoint_url": true, if: :verify_url_address?
    validate :url_within_length_limit
    validate :allowed_networks_are_valid_cidrs
    validate :custom_headers_are_strings
    validate :subscribed_events_are_bounded

    def self.generate_signing_secret
      "whsec_#{Base64.strict_encode64(SecureRandom.bytes(32))}"
    end

    def subscribed_to?(event_name)
      Array(subscribed_events).any? { |pattern| EventMatcher.match?(pattern, event_name) }
    end

    # Secrets a receiver may currently hold: always the active secret, plus the
    # previous one while it's still within the rotation grace window. Deliveries
    # sign with every returned secret so receivers can roll over with zero
    # downtime.
    def active_signing_secrets
      secrets = [signing_secret]
      if previous_signing_secret.present? && secret_rotated_at.present? &&
          secret_rotated_at > Angarium.config.signing_secret_grace_period.ago
        secrets << previous_signing_secret
      end
      secrets
    end

    # Rotate the signing secret and persist. Returns the new plaintext secret.
    # The previous secret stays valid for `config.signing_secret_grace_period`
    # (deliveries are signed with both during that window), so receivers can
    # roll over to the new secret with zero downtime.
    def rotate_secret!
      update!(
        previous_signing_secret: signing_secret,
        signing_secret: self.class.generate_signing_secret,
        secret_rotated_at: Time.current
      )
      signing_secret
    end

    def record_delivery_success!
      # Reset from the database, not this (possibly stale) in-memory copy: a
      # concurrent failed delivery may have raised the counter since we loaded.
      # The WHERE skips a write when it is already zero.
      self.class.where(id: id).where.not(consecutive_failures: 0).update_all(consecutive_failures: 0)
      self.consecutive_failures = 0
    end

    def record_delivery_failure!
      # Atomic increment. Without it, concurrent deliveries to the same endpoint
      # each read a stale counter and lose increments (last write wins), so
      # auto-disable would undercount. Reload to read the true post-increment
      # count before deciding whether to disable.
      self.class.update_counters(id, consecutive_failures: 1)
      reload

      threshold = Angarium.config.auto_disable_endpoint_after
      deactivate!(reason: :consecutive_failures) if threshold && consecutive_failures >= threshold
    end

    # Move to a non-delivering state (no further deliveries) and fire the
    # on_endpoint_deactivated callback once. `reason` maps to the target status:
    #   :consecutive_failures -> disabled (auto-disable, only from `enabled`)
    #   :gone                 -> gone     (receiver returned HTTP 410; overrides
    #                                       any non-gone status, so a racing
    #                                       auto-disable can't clobber a 410)
    def deactivate!(reason:)
      target, from = (reason == :gone) ? [:gone, nil] : [:disabled, :enabled]
      transition_status!(target, from: from) { Angarium.notify(:on_endpoint_deactivated, self, reason) }
    end

    # Pause deliveries manually. Resumable via #enable!.
    def pause!
      transition_status!(:paused)
    end

    # (Re-)enable deliveries and clear the failure counter. Works from any state,
    # including `gone` (an explicit operator override of a receiver's 410).
    def enable!
      return false unless transition_status!(:enabled, consecutive_failures: 0)
      # Resume deliveries parked while this endpoint was paused (pending with no
      # scheduled attempt). This predicate can also match a delivery that already
      # has an in-flight job (a forced ping, a just-redelivered row), but a stray
      # re-enqueue is harmless: the atomic pending->delivering claim in
      # Delivery#deliver! guarantees only one worker ever sends a given delivery.
      deliveries.where(state: "pending", next_attempt_at: nil).find_each { |d| DeliverJob.perform_later(d.id) }
      true
    end

    # Promote an `unverified` endpoint to `enabled` once it has proven it can
    # receive webhooks. A no-op on any other status: a `disabled`/`gone` endpoint
    # is revived with #enable!, not verified. Called automatically when a delivery
    # to an unverified endpoint succeeds (a forced #ping!), or manually. Fires
    # on_endpoint_verified exactly once, even under concurrent verification.
    def verify!
      transition_status!(:enabled, from: :unverified) { Angarium.notify(:on_endpoint_verified, self) }
    end

    # Deliver a synthetic ping event (name from config.ping_event_name, default
    # "ping") to this endpoint, bypassing subscription matching (a ping is always
    # sent). By default a ping also ignores the endpoint's status, so you can test
    # an endpoint that is paused, disabled, or not yet enabled; pass `force: false`
    # to respect the status guard instead. Returns the created Angarium::Delivery,
    # whose after_create_commit enqueues the DeliverJob; reload it to inspect the outcome.
    def ping!(payload = {message: "ping"}, force: true)
      event = Angarium::Event.create!(name: Angarium.config.ping_event_name, payload: payload)
      deliveries.create!(event: event, forced: force)
    end

    private

    # Atomically move to `target` status, stamping status_changed_at (and any
    # `extra` columns) only on a real change, so a no-op transition writes nothing.
    # With `from:` the change applies only from those source statuses; otherwise
    # from any status but the target. Returns true iff this call made the change,
    # so a caller's block runs exactly once even under concurrent transitions (no
    # double callback). All status transitions go through here to stay consistent.
    def transition_status!(target, from: nil, **extra)
      target = target.to_s
      from &&= Array(from).map(&:to_s)
      # Two independent guards, both always applied: skip if we're already at the
      # target (no redundant write / no spurious callback), and skip if we're not
      # in a permitted source status. The atomic update enforces both at the DB
      # level, so a concurrent transition can't slip past either.
      return false if status == target || from&.exclude?(status)

      scope = self.class.where(id: id).where.not(status: target)
      scope = scope.where(status: from) if from
      changed = scope.update_all({status: target, status_changed_at: Time.current, updated_at: Time.current}.merge(extra))
      return false if changed.zero?

      reload
      yield if block_given?
      true
    end

    def ensure_signing_secret
      self.signing_secret ||= self.class.generate_signing_secret
    end

    # Re-run the URL + SSRF address check only when something that affects the
    # decision changes: the URL itself, or the SSRF controls (allow_private_network,
    # allowed_networks). This avoids a DNS lookup on unrelated updates (e.g.
    # toggling `active`), while still catching a URL that a tightened policy now
    # disallows. (Reassign allowed_networks to a new array to trigger dirty
    # tracking; in-place mutation isn't detected.)
    def verify_url_address?
      return false if url.blank?

      new_record? ||
        will_save_change_to_url? ||
        will_save_change_to_allow_private_network? ||
        will_save_change_to_allowed_networks?
    end

    def allowed_networks_are_valid_cidrs
      Array(allowed_networks).reject(&:blank?).each do |cidr|
        IPAddr.new(cidr.to_s)
      rescue IPAddr::InvalidAddressError
        errors.add(:allowed_networks, "contains an invalid CIDR: #{cidr}")
      end
    end

    def url_within_length_limit
      max = Angarium.config.max_url_length
      return if url.blank? || max.nil? || url.length <= max

      errors.add(:url, "is too long (maximum is #{max} characters)")
    end

    def subscribed_events_are_bounded
      return if subscribed_events.blank?

      unless subscribed_events.is_a?(Array)
        errors.add(:subscribed_events, "must be an array of event patterns")
        return
      end

      max = Angarium.config.max_subscribed_events
      if max && subscribed_events.length > max
        errors.add(:subscribed_events, "cannot have more than #{max} subscribed events")
      end

      unless subscribed_events.all? { |e| e.is_a?(String) && !e.empty? && e.length <= 255 }
        errors.add(:subscribed_events, "must be non-empty strings of at most 255 characters")
      end
    end

    def custom_headers_are_strings
      return if custom_headers.blank?

      unless custom_headers.is_a?(Hash) &&
          custom_headers.all? { |k, v| k.is_a?(String) && v.is_a?(String) }
        errors.add(:custom_headers, "must be a hash of string keys and values")
        return
      end

      if custom_headers.keys.any? { |k| RESERVED_HEADERS.include?(k.downcase) }
        errors.add(:custom_headers, "cannot override reserved or transport headers (#{RESERVED_HEADERS.join(", ")})")
      end

      # Reject CR/LF/NUL in any key or value. The outbound HTTP client writes
      # headers verbatim, so a CRLF in a value would inject an extra header line
      # — smuggling e.g. a forged webhook-signature past the RESERVED_HEADERS
      # denylist (which only guards whole keys). Fail closed instead.
      if custom_headers.any? { |k, v| k.match?(/[\r\n\0]/) || v.match?(/[\r\n\0]/) }
        errors.add(:custom_headers, "must not contain control characters (CR, LF, or NUL)")
      end
    end
  end
end
