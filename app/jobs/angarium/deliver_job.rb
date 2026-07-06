module Angarium
  class DeliverJob < ApplicationJob
    def perform(delivery_id)
      delivery = Delivery.find_by(id: delivery_id)
      return unless delivery
      return unless delivery.pending?

      delivery.deliver!
    end
  end
end
