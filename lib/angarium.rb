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
    # on_endpoint_disabled). A callback raising must never break the delivery
    # pipeline, so errors are logged and swallowed.
    def notify(callback_name, *args)
      callback = config.public_send(callback_name)
      return unless callback

      callback.call(*args)
    rescue => e
      Rails.logger.error { "[Angarium] #{callback_name} callback raised: #{e.class}: #{e.message}" }
    end
  end
end
