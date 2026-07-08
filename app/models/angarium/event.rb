module Angarium
  class Event < ApplicationRecord
    has_many :deliveries, class_name: "Angarium::Delivery", dependent: :destroy

    # Default at the model layer, not the column: the payload column is JSON and
    # MySQL forbids a DB default there. A proc yields a fresh hash per record.
    attribute :payload, default: -> { {} }

    validates :name, presence: true
  end
end
