module Angarium
  class DeliveryAttempt < ApplicationRecord
    belongs_to :delivery, class_name: "Angarium::Delivery"
  end
end
