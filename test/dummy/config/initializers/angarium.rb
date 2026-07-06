# E2E-only tuning for the dummy app (development). Tests run in :test and stub
# their own config, so guard on env to avoid changing their defaults.
if Rails.env.development?
  Angarium.configure do |c|
    # Multi-db demo: Angarium's tables live in their own database; the primary DB
    # keeps the host's Owner model and Solid Queue's tables.
    c.database = :angarium
    c.retry_schedule = [2.seconds, 3.seconds, 4.seconds] # fast backoff to watch a full cycle
    c.on_delivery_exhausted = ->(delivery) do
      Rails.logger.warn { "[E2E] delivery ##{delivery.id} EXHAUSTED after #{delivery.attempt_count} attempts" }
    end
  end
end
