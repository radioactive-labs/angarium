require "bundler/setup"

APP_RAKEFILE = File.expand_path("test/dummy/Rakefile", __dir__)
load "rails/tasks/engine.rake"

load "rails/tasks/statistics.rake"

require "bundler/gem_tasks"

# `rake standard` / `rake standard:fix` when the linter is in the bundle (dev).
# `bin/rails test` loads this Rakefile too, and the test-matrix bundles omit
# standard, so only require it when present. Release tasks live in rakelib/.
require "standard/rake" if Gem.loaded_specs.key?("standard")

# Multi-db boot checks: each file boots the dummy app with a different
# Angarium database config, which Angarium::ApplicationRecord reads exactly
# once at class load (eager-loaded in CI) — so every file gets its own
# process. Named *_check.rb so `bin/rails test` never globs them.
desc "Run the multi-database boot checks, one process per file"
task "test:multi_db" do
  FileList["test/multi_db/*_check.rb"].each { |file| ruby "-Itest", file }
end
