module Angarium
  class DeliveryAttempt < ApplicationRecord
    belongs_to :delivery, class_name: "Angarium::Delivery"

    # response_body and error are partly receiver-controlled. Sanitize them on
    # assignment (so every write path is covered, not just the delivery happy
    # path) into something a text column always accepts — otherwise the INSERT
    # raises, and mid-#deliver! that raise lands after the row is already
    # `delivering`, stranding the delivery for the reaper to redeliver forever.
    # For each: coerce to UTF-8 and scrub invalid bytes (an upstream byte cap can
    # split a multibyte char; a receiver may return non-UTF-8 outright), then drop
    # NUL — it is valid UTF-8 (so scrub keeps it) but PostgreSQL rejects it in text
    # columns, surfacing via the pg driver as an ArgumentError, not even a
    # StatementInvalid. `error` is additionally capped to its column limit (only
    # MySQL sets one) since a client error message can overflow varchar(255).
    normalizes :response_body, with: ->(value) { sanitize_text(value) }
    normalizes :error, with: ->(value) {
      text = sanitize_text(value)
      limit = columns_hash["error"]&.limit
      limit ? text.truncate(limit) : text
    }

    def self.sanitize_text(value)
      value.dup.force_encoding(Encoding::UTF_8).scrub.delete("\u0000")
    end

    # Delete delivery attempts older than the cutoff. `older_than` may be a
    # duration (e.g. 90.days) or an absolute Time. Returns the number deleted.
    # (A Time also responds to #ago but requires an argument, so branch on the
    # type rather than duck-typing #ago.)
    def self.prune(older_than:)
      cutoff = older_than.is_a?(ActiveSupport::Duration) ? older_than.ago : older_than
      where(created_at: ...cutoff).delete_all
    end
  end
end
