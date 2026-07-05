module Angarium
  module Api
    # Raised by a controller when the configured policy denies an action.
    # Rendered as 403 by Angarium::Api::BaseController.
    class NotAuthorized < StandardError; end
  end
end
