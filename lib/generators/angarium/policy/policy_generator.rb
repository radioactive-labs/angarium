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

      def show_instructions
        say ""
        say "Enable it in config/initializers/angarium.rb:", :green
        say %(  config.policy_class = "#{class_name}")
      end

      private

      def class_name = policy_name.camelize
    end
  end
end
