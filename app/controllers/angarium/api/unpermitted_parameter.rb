module Angarium
  module Api
    # Raised when a request tries to change an attribute the policy doesn't permit
    # (e.g. a privileged SSRF control), so the caller fails loudly with a 422
    # naming the attribute instead of the change being silently dropped.
    class UnpermittedParameter < StandardError
      attr_reader :attribute

      def initialize(attribute)
        @attribute = attribute
        super("#{attribute} is not permitted")
      end
    end
  end
end
