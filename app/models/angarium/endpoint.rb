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
    validates :url, presence: true, "angarium/endpoint_url": true
    validates :active, inclusion: { in: [true, false] }
    validate :allowed_networks_are_valid_cidrs

    def subscribed_to?(event_name)
      Array(subscribed_events).any? { |pattern| EventMatcher.match?(pattern, event_name) }
    end

    private

    def ensure_signing_secret
      self.signing_secret ||= SecureRandom.hex(32)
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
