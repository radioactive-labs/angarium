source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

# Specify your gem's dependencies in angarium.gemspec.
gemspec

gem "sqlite3"

# Postgres and MySQL are each exercised by a dedicated CI job
# (BUNDLE_WITH=postgresql / mysql); the suite otherwise runs on SQLite. Optional
# so a plain `bundle install` for SQLite development needs neither libpq nor a
# MySQL client. trilogy is a pure client (no libmysqlclient) and is Rails 8's
# MySQL adapter.
group :postgresql, optional: true do
  gem "pg"
end

group :mysql, optional: true do
  gem "trilogy"
end

gem "webmock"
gem "minitest-mock"

# Verify our Standard Webhooks signatures interoperate with the official library.
gem "standardwebhooks"

# Chaos-test the delivery job (interruption/idempotency).
gem "chaotic_job"

gem "puma"
gem "solid_queue"

gem "sprockets-rails"

# Start debugger with binding.b [https://github.com/ruby/debug]
# gem "debug", ">= 1.0.0"

gem "appraisal"

# Linter / formatter and static security analysis.
gem "standard"
gem "brakeman"
