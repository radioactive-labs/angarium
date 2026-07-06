module Angarium
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    # Multi-database support: point every Angarium table at a separate database
    # instead of the app's primary connection. The host sets either config.database
    # (a database name; the common case) or config.connects_to (a raw hash for
    # custom roles/shards, which wins if both are set). Read once here at class
    # load: config/initializers run before the models are first used or
    # eager-loaded, so the setting is in place by then.
    if Angarium.config.connects_to
      connects_to(**Angarium.config.connects_to)
    elsif (db = Angarium.config.database)
      connects_to database: {writing: db, reading: db}
    end
  end
end
