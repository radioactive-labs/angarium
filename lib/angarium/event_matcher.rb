module Angarium
  module EventMatcher
    module_function

    # pattern: "*" (all), "prefix.*" (prefix), or an exact event name
    def match?(pattern, event_name)
      return true if pattern == "*"

      if pattern.end_with?(".*")
        prefix = pattern[0..-3] # strip ".*"
        event_name == prefix || event_name.start_with?("#{prefix}.")
      else
        pattern == event_name
      end
    end
  end
end
