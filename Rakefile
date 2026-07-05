require "bundler/setup"

APP_RAKEFILE = File.expand_path("test/dummy/Rakefile", __dir__)
load "rails/tasks/engine.rake"

load "rails/tasks/statistics.rake"

require "bundler/gem_tasks"

# `rake standard` / `rake standard:fix`. Release tasks live in rakelib/ (auto-loaded).
require "standard/rake"
