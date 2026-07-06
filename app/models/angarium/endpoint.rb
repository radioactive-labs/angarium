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

    validates :name, presence: true
    validates :url, presence: true
    validates :url, "angarium/endpoint_url": true, if: :verify_url_address?
    validate :allowed_networks_are_valid_cidrs
    validate :custom_headers_are_strings

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
    #   :consecutive_failures -> disabled (auto-disable threshold)
    #   :gone                 -> gone     (receiver returned HTTP 410)
    def deactivate!(reason:)
      target = (reason == :gone) ? :gone : :disabled
      return if status.to_sym == target

      # Atomic, fire-once transition: only the call that actually flips the status
      # (exactly one row updated) runs the callback, so concurrent threshold
      # crossings can't double-fire it. Auto-disable only transitions an `enabled`
      # endpoint, while `gone` (a terminal 410) can override any non-gone status,
      # so a 410 is never clobbered by a racing auto-disable.
      scope = self.class.where(id: id)
      scope = (target == :gone) ? scope.where.not(status: "gone") : scope.where(status: "enabled")
      changed = scope.update_all(status: target.to_s, status_changed_at: Time.current, updated_at: Time.current)
      return if changed.zero?

      reload
      Angarium.notify(:on_endpoint_deactivated, self, reason)
    end

    # Pause deliveries manually. Resumable via #enable!.
    def pause!
      update!(status: :paused, status_changed_at: Time.current)
    end

    # (Re-)enable deliveries and clear the failure counter. Works from any state,
    # including `gone` (an explicit operator override of a receiver's 410).
    def enable!
      update!(status: :enabled, status_changed_at: Time.current, consecutive_failures: 0)
      # Resume deliveries parked while this endpoint was paused (pending with no
      # scheduled attempt). Dispatch creates none while paused, so this only
      # re-enqueues the held ones.
      deliveries.where(state: "pending", next_attempt_at: nil).find_each { |d| DeliverJob.perform_later(d.id) }
    end

    # Promote an `unverified` endpoint to `enabled` once it has proven it can
    # receive webhooks. A no-op on any other status: a `disabled`/`gone` endpoint
    # is revived with #enable!, not verified. Called automatically when a delivery
    # to an unverified endpoint succeeds (a forced #ping!), or manually. The
    # atomic conditional update fires on_endpoint_verified exactly once even if
    # two deliveries verify concurrently.
    def verify!
      return unless unverified?

      changed = self.class.where(id: id, status: "unverified")
        .update_all(status: "enabled", status_changed_at: Time.current, updated_at: Time.current)
      return if changed.zero?

      reload
      Angarium.notify(:on_endpoint_verified, self)
    end

    # Deliver a synthetic `angarium.ping` event to this endpoint, bypassing
    # subscription matching (a ping is always sent). By default a ping also
    # ignores the endpoint's status, so you can test an endpoint that is paused,
    # disabled, or not yet enabled; pass `force: false` to respect the status
    # guard instead. Returns the created Angarium::Delivery, whose
    # after_create_commit enqueues the DeliverJob; reload it to inspect the outcome.
    def ping!(payload = {message: "Angarium ping"}, force: true)
      event = Angarium::Event.create!(name: "angarium.ping", payload: payload)
      deliveries.create!(event: event) { |d| d.force_send = force }
    end

    private

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
    end
  end
end
