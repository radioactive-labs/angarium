require "angarium/version"
require "angarium/engine"
require "angarium/configuration"
require "angarium/event_matcher"
require "angarium/signature"
require "angarium/address_policy"
require "angarium/dispatch"

module Angarium
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    def dispatch(event_name, payload, owner:)
      Dispatch.call(event_name, payload, owner: owner)
    end
  end
end
