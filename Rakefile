require "bundler/setup"

APP_RAKEFILE = File.expand_path("test/dummy/Rakefile", __dir__)
load "rails/tasks/engine.rake"

load "rails/tasks/statistics.rake"

require "bundler/gem_tasks"

# `rake standard` / `rake standard:fix` when the linter is in the bundle (dev).
# `bin/rails test` loads this Rakefile too, and the test-matrix bundles omit
# standard, so only require it when present. Release tasks live in rakelib/.
require "standard/rake" if Gem.loaded_specs.key?("standard")
