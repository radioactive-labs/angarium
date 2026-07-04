require "rails/generators/base"

module Angarium
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates an Angarium initializer in config/initializers."

      def copy_initializer
        template "initializer.rb", "config/initializers/angarium.rb"
      end
    end
  end
end
