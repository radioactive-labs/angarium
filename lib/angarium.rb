require "angarium/version"
require "angarium/engine"
require "angarium/configuration"
require "angarium/event_matcher"
require "angarium/signature"
require "angarium/address_policy"
require "angarium/dispatch"
require "angarium/client"

module Angarium
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    # Primary key type for Angarium's own tables. Explicit config wins; otherwise
    # respect the app's global generators setting; otherwise Rails' default (bigint).
    def primary_key_type
      config.primary_key_type ||
        Rails.application.config.generators.options.dig(:active_record, :primary_key_type) ||
        :bigint
    end

    def dispatch(event_name, payload, owner:)
      Dispatch.call(event_name, payload, owner: owner)
    end

    # Invoke a configured notification callback (e.g. on_delivery_exhausted,
    # on_endpoint_deactivated). A callback raising must never break the delivery
    # pipeline, so errors are logged and swallowed.
    def notify(callback_name, *args)
      callback = config.public_send(callback_name)
      return unless callback

      callback.call(*args)
    rescue => e
      # A raising callback must never break the pipeline, but swallowing it with
      # only a log hides a real bug from error tracking. Log and report it (handled,
      # so delivery continues) so it surfaces where the operator will see it.
      Rails.logger.error { "[Angarium] #{callback_name} callback raised: #{e.class}: #{e.message}" }
      Rails.error.report(e, handled: true, severity: :error, source: "angarium", context: {callback: callback_name})
    end
  end
end
