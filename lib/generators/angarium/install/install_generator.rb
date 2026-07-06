require "rails/generators/base"

module Angarium
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates the Angarium initializer and installs its migrations. Pass " \
           "--database=NAME to run Angarium in its own database (multi-db)."

      class_option :database, type: :string, aliases: "-d", default: nil, banner: "NAME",
        desc: "Place Angarium in its own database: sets config.database and installs " \
              "migrations into db/NAME_migrate instead of db/migrate"

      def copy_initializer
        template "initializer.rb", "config/initializers/angarium.rb"
      end

      # With --database, record config.database in the initializer so a later
      # `angarium:migrations` run (e.g. after a gem upgrade) still targets the
      # right place without the flag.
      def set_database_config
        return unless database

        gsub_file "config/initializers/angarium.rb", /^\s*#?\s*config\.database\s*=.*$/,
          %(  config.database = :#{database})
      end

      # The single migration path: delegate to the migrations generator, which
      # installs into db/NAME_migrate (multi-db) or db/migrate (primary).
      def install_migrations
        invoke "angarium:migrations", [], database: database
      end

      def print_next_steps
        if database
          say <<~MSG
            Add the '#{database}' database to config/database.yml (per environment), e.g.:

                #{database}:
                  <<: *default
                  database: myapp_#{database}
                  migrations_paths: db/#{database}_migrate

            then run:  bin/rails db:migrate:#{database}
          MSG
        else
          say "\nNext: run bin/rails db:migrate"
        end
      end

      private

      def database = options[:database]
    end
  end
end
