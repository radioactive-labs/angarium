appraise "rails-7.1" do
  gem "rails", "~> 7.1.0"
  # Rails' test_unit line filtering only understands Minitest 5's `run`
  # signature until railties 8.0; Minitest 6 renamed/changed the hook to
  # `run_suite`, which breaks `bin/rails test` on 7.1/7.2 otherwise.
  gem "minitest", "~> 5.25"
  # sqlite3 2.x bundles a newer libsqlite3 that reports boolean column
  # defaults as the `TRUE`/`FALSE` keywords; Rails 7.1's sqlite3 adapter
  # doesn't parse that form, so new records silently get a nil default
  # (e.g. Endpoint#active) instead of the schema default. Pin to the 1.x
  # series, which bundles an older libsqlite3 that reports numeric defaults.
  gem "sqlite3", "~> 1.4"
end

appraise "rails-7.2" do
  gem "rails", "~> 7.2.0"
  gem "minitest", "~> 5.25"
end

appraise "rails-8.0" do
  gem "rails", "~> 8.0.0"
end

appraise "rails-8.1" do
  gem "rails", "~> 8.1.0"
end
