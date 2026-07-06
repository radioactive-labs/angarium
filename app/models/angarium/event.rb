module Angarium
  class Event < ApplicationRecord
    has_many :deliveries, class_name: "Angarium::Delivery", dependent: :destroy

    validates :name, presence: true
  end
end
