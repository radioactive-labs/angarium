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

      # With --database, wire up multi-db: record config.database in the
      # initializer (so a later `angarium:migrations` run without the flag still
      # targets the right place) and install the migrations into db/NAME_migrate.
      # Without it, Angarium stays on the primary connection and migrations are
      # installed the usual way (`bin/rails g angarium:migrations`).
      def configure_database
        return unless database

        set_database_config
        invoke "angarium:migrations", [], database: database
        print_next_steps
      end

      private

      def database = options[:database]

      def set_database_config
        gsub_file "config/initializers/angarium.rb", /^\s*#?\s*config\.database\s*=.*$/,
          %(  config.database = :#{database})
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
