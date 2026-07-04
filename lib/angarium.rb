require "angarium/version"
require "angarium/engine"
require "angarium/configuration"

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
