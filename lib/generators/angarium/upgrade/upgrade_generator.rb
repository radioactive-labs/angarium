# frozen_string_literal: true

require "rails/generators/active_record/migration"
require_relative "../migration_actions"

module Angarium
  # Brings an existing Angarium installation up to the current schema by
  # copying any migrations the application does not already have. Applications
  # created with `angarium:install` on the current version already have
  # everything; older installs pick up any additive migrations added since.
  #
  #   rails generate angarium:upgrade
  #   rails db:migrate
  #
  # Multi-database aware: with --database (or config.database set in the
  # initializer), missing migrations are copied into db/NAME_migrate.
  class UpgradeGenerator < Rails::Generators::Base
    include ::ActiveRecord::Generators::Migration
    include Angarium::Generators::MigrationActions

    source_root File.expand_path("../templates", __dir__)

    def start
      copy_angarium_migrations
    rescue => err
      say "#{err.class}: #{err}\n#{err.backtrace.join("\n")}", :red
      exit 1
    end
  end
end
