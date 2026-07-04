require "securerandom"

module Angarium
  class Endpoint < ApplicationRecord
    belongs_to :owner, polymorphic: true
    has_many :deliveries, class_name: "Angarium::Delivery", dependent: :destroy

    encrypts :signing_secret

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

    def self.generate_signing_secret
      SecureRandom.hex(32)
    end

    def subscribed_to?(event_name)
      Array(subscribed_events).any? { |pattern| EventMatcher.match?(pattern, event_name) }
    end

    # Rotate the signing secret and persist. Returns the new plaintext secret.
    # Subsequent deliveries sign with the new secret immediately, so update the
    # receiver's copy in the same window (or run a dual-secret grace period at
    # the receiver).
    def regenerate_signing_secret!
      update!(signing_secret: self.class.generate_signing_secret)
      signing_secret
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
  end
end
