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

    def subscribed_to?(event_name)
      Array(subscribed_events).any? { |pattern| EventMatcher.match?(pattern, event_name) }
    end

    private

    def ensure_signing_secret
      self.signing_secret ||= SecureRandom.hex(32)
    end
  end
end
