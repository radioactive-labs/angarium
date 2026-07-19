# frozen_string_literal: true

module Angarium
  module Generators
    # Shared migration-copy logic for the install and upgrade generators.
    #
    # Copying is idempotent: a migration whose name already exists in the host
    # application's db/migrate is skipped, so it is safe to re-run either
    # generator. `install` copies the full set (a fresh app has none yet);
    # `upgrade` copies only the migrations a previously-installed app is missing.
    # Both share this method — the difference is purely which migrations already
    # exist in the target app.
    #
    # MIGRATIONS is listed in application order; copying preserves that order
    # because each migration_template assigns the next sequential version number.
    module MigrationActions
      MIGRATIONS = %w[
        create_angarium_endpoints
        create_angarium_events
        create_angarium_deliveries
        create_angarium_delivery_attempts
      ].freeze

      # Both generators take --database so a multi-db install/upgrade can be
      # driven from the command line; without it they fall back to the
      # configured database (config.database / connects_to writing role).
      def self.included(base)
        base.class_option :database, type: :string, aliases: "-d", default: nil, banner: "NAME",
          desc: "Install migrations into db/NAME_migrate for this database " \
                "(defaults to config.database / connects_to; 'primary' means " \
                "the default connection and db/migrate)"
      end

      def copy_angarium_migrations
        MIGRATIONS.each do |name|
          if angarium_migration_exists?(name)
            say_status :skip, "#{name} (migration already exists)", :yellow
          else
            migration_template "#{name}.rb", "#{angarium_migrations_dir}/#{name}.rb"
          end
        end
      end

      # db/migrate on the primary connection; db/<name>_migrate when Angarium
      # lives in its own database.
      def angarium_migrations_dir
        db = angarium_database
        db.nil? ? "db/migrate" : "db/#{db}_migrate"
      end

      # The database Angarium should be installed into, nil when it stays on
      # the primary connection. "primary" is normalized to nil here so every
      # consumer (migration dir, initializer recording, next-steps message)
      # agrees that it means the default.
      def angarium_database
        db = options[:database].presence || Angarium.config.migrations_database
        (db.to_s == "primary") ? nil : db
      end

      # Legacy installs (before this generator existed) copied migrations with
      # Rails' native ActiveRecord::Migration.copy, which tags the filename
      # with the engine name before the extension: `<ts>_name.angarium.rb`.
      # Match both that legacy suffix and the plain form this generator writes,
      # so an app installed the old way isn't re-copied — which would attempt
      # to create the same tables twice and fail.
      # Anchored to `<digits>_name.rb` / `<digits>_name.angarium.rb` exactly:
      # a bare `*_name` glob lets `*` swallow underscores, so any migration
      # merely ENDING in `_name.rb` (a host's own, or a sibling whose name
      # extends this one) would count as installed and silently suppress the
      # copy.
      def angarium_migration_exists?(name)
        pattern = /\A\d+_#{Regexp.escape(name)}(\.angarium)?\.rb\z/
        Dir.glob(File.join(destination_root, angarium_migrations_dir, "*.rb"))
          .any? { |file| File.basename(file).match?(pattern) }
      end
    end
  end
end
