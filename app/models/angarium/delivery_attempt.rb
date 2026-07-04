module Angarium
  class DeliveryAttempt < ApplicationRecord
    belongs_to :delivery, class_name: "Angarium::Delivery"

    # Delete delivery attempts older than the cutoff. `older_than` may be a
    # duration (e.g. 90.days) or an absolute Time. Returns the number deleted.
    def self.prune(older_than:)
      cutoff = older_than.respond_to?(:ago) ? older_than.ago : older_than
      where(created_at: ...cutoff).delete_all
    end
  end
end
