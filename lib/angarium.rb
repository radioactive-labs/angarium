require "angarium/version"
require "angarium/engine"
require "angarium/configuration"
require "angarium/event_matcher"
require "angarium/signature"

module Angarium
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end
  end
end
