require "securerandom"

module Angarium
  class Endpoint < ApplicationRecord
    belongs_to :owner, polymorphic: true
    has_many :deliveries, class_name: "Angarium::Delivery", dependent: :destroy

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
