require "rails/generators/base"

module Angarium
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates the Angarium initializer. Pass --database=NAME to run Angarium " \
           "in its own database (multi-db)."

      class_option :database, type: :string, aliases: "-d", default: nil, banner: "NAME",
        desc: "Place Angarium in its own database: sets config.connects_to and installs " \
              "migrations into db/NAME_migrate instead of db/migrate"

      def copy_initializer
        template "initializer.rb", "config/initializers/angarium.rb"
      end

      # With --database, wire up multi-db: point config.connects_to at the named
      # database and install the engine's migrations into that database's own
      # migrations_paths (db/NAME_migrate) so `db:migrate:NAME` targets them.
      # Without it, Angarium stays on the primary connection and migrations are
      # installed the usual way (`bin/rails angarium:install:migrations`).
      def configure_database
        return unless database

        enable_connects_to
        install_migrations
        print_next_steps
      end

      private

      def database = options[:database]

      def enable_connects_to
        gsub_file "config/initializers/angarium.rb", /^\s*#?\s*config\.connects_to\s*=.*$/,
          %(  config.connects_to = { database: { writing: :#{database}, reading: :#{database} } })
      end

      def install_migrations
        Angarium::Engine.root.join("db/migrate").glob("*.rb").sort.each do |path|
          create_file "db/#{database}_migrate/#{path.basename}", path.read
        end
      end

      def print_next_steps
        say <<~MSG
          Add the '#{database}' database to config/database.yml (per environment), e.g.:

              #{database}:
                <<: *default
                database: myapp_#{database}
                migrations_paths: db/#{database}_migrate

          then run:  bin/rails db:migrate:#{database}
        MSG
      end
    end
  end
end
