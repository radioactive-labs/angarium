# Angarium installs its migrations through one path only: the multi-db-aware
# `bin/rails g angarium:migrations` generator (invoked by angarium:install).
# Replace Rails' generic, auto-generated angarium:install:migrations task, which
# can only copy into the primary db/migrate and would misplace migrations in a
# multi-database setup. Engine lib/tasks files load after the rake_tasks blocks
# that define that task, so this runs after it exists.
if Rake::Task.task_defined?("angarium:install:migrations")
  Rake::Task["angarium:install:migrations"].clear

  namespace :angarium do
    namespace :install do
      # No desc, so it stays out of `rails -T`; it only redirects anyone who runs
      # the old command from memory instead of silently doing nothing.
      task :migrations do
        abort "angarium:install:migrations was removed. Install migrations with:\n" \
              "  bin/rails g angarium:migrations   (multi-db aware; reads config.database)"
      end
    end
  end
end
