module Angarium
  class DeliverJob < ApplicationJob
    def perform(delivery_id, force = false)
      delivery = Delivery.find_by(id: delivery_id)
      return unless delivery
      return unless delivery.pending?

      delivery.deliver!(force: force)
    end
  end
end
