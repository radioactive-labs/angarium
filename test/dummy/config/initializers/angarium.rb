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

# Multi-db boot checks (test/multi_db) opt in via ENV. The connects_to wiring
# in Angarium::ApplicationRecord runs once at class load — eager-loaded during
# boot in CI — so the config has to be in place here, before boot finishes;
# a test file can't set it later. Each check runs in its own process
# (rake test:multi_db), so the two flags never coexist.
if Rails.env.test?
  if (db = ENV["ANGARIUM_TEST_DATABASE"])
    Angarium.config.database = db.to_sym
  end
  if ENV["ANGARIUM_TEST_CONNECTS_TO"]
    # database deliberately points at a config that doesn't exist: the check
    # only passes if connects_to actually wins for the connection.
    Angarium.config.database = :nonexistent_database_proving_connects_to_wins
    Angarium.config.connects_to = {database: {writing: :angarium, reading: :angarium}}
  end
end
