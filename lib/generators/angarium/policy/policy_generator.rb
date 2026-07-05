require "rails/generators/base"

module Angarium
  module Generators
    class PolicyGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates an Angarium API policy (a subclass of Angarium::Api::Policy)."

      argument :policy_name, type: :string, default: "WebhookEndpointPolicy",
        banner: "NAME", desc: "Policy class name (default: WebhookEndpointPolicy)"

      def create_policy
        template "policy.rb", File.join("app/policies", "#{policy_name.underscore}.rb")
      end

      # Point config.policy_class at the generated class, uncommenting (or
      # replacing) the line in the initializer so it takes effect immediately.
      def enable_policy
        initializer = "config/initializers/angarium.rb"

        unless File.exist?(File.join(destination_root, initializer))
          say_status :skip, %(#{initializer} not found; set config.policy_class = "#{class_name}" yourself), :yellow
          return
        end

        line = %r{^\s*#?\s*config\.policy_class\s*=.*$}
        if File.read(File.join(destination_root, initializer)).match?(line)
          gsub_file initializer, line, %(  config.policy_class = "#{class_name}")
        else
          say_status :skip, %(add config.policy_class = "#{class_name}" to #{initializer}), :yellow
        end
      end

      private

      def class_name = policy_name.camelize
    end
  end
end
