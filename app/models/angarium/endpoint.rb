require "securerandom"
require "base64"

module Angarium
  class Endpoint < ApplicationRecord
    belongs_to :owner, polymorphic: true
    has_many :deliveries, class_name: "Angarium::Delivery", dependent: :destroy

    encrypts :signing_secret, :previous_signing_secret

    # Rails < 8.1's SQLite adapter doesn't parse the `DEFAULT TRUE`/`DEFAULT
    # FALSE` literals SQLite reports back for boolean columns (fixed in
    # ActiveRecord::ConnectionAdapters::SQLite3::SchemaStatements
    # #extract_value_from_default starting in Rails 8.1), leaving these
    # attributes nil on a new record instead of the schema default.
    # Declaring the defaults here keeps behavior correct on every supported
    # Rails version.
    attribute :active, :boolean, default: true
    attribute :allow_private_network, :boolean, default: false

    scope :active, -> { where(active: true) }

    before_validation :ensure_signing_secret, on: :create

    validates :name, presence: true
    validates :url, presence: true
    validates :url, "angarium/endpoint_url": true, if: :verify_url_address?
    validates :active, inclusion: { in: [true, false] }
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
    def regenerate_signing_secret!
      update!(
        previous_signing_secret: signing_secret,
        signing_secret: self.class.generate_signing_secret,
        secret_rotated_at: Time.current
      )
      signing_secret
    end

    def record_delivery_success!
      update!(consecutive_failures: 0) unless consecutive_failures.zero?
    end

    def record_delivery_failure!
      new_count = consecutive_failures + 1
      attrs = { consecutive_failures: new_count }
      threshold = Angarium.config.auto_disable_endpoint_after
      if threshold && new_count >= threshold && active?
        attrs[:active] = false
        attrs[:disabled_at] = Time.current
      end
      update!(attrs)
    end

    # Deliver a synthetic event to this endpoint, bypassing subscription
    # matching (a test event is always sent). Returns the created delivery,
    # whose after_create_commit enqueues the DeliverJob.
    def send_test_event!(payload = { message: "Angarium test event" })
      event = Angarium::Event.create!(name: "angarium.test", payload: payload)
      deliveries.create!(event: event)
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
      end
    end
  end
end
