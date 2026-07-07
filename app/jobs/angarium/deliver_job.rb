module Angarium
  class DeliverJob < ApplicationJob
    # The second positional arg is accepted only for backward compatibility with
    # jobs enqueued by an older version (force is now persisted on the delivery as
    # `forced` and read by #deliver!); new enqueues pass just the id.
    def perform(delivery_id, _legacy_force = nil)
      delivery = Delivery.find_by(id: delivery_id)
      return unless delivery
      return unless delivery.pending?

      delivery.deliver!
    end
  end
end
