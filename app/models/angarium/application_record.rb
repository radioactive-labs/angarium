module Angarium
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    # Multi-database support. When the host sets config.connects_to (a hash passed
    # straight to Rails' connects_to, e.g. { database: { writing: :angarium } }),
    # every Angarium table lives in that database instead of the app's primary
    # connection. Read once here at class load: config/initializers run before the
    # models are first used or eager-loaded, so the setting is in place by then.
    connects_to(**Angarium.config.connects_to) if Angarium.config.connects_to
  end
end
