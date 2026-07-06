module Angarium
  class Engine < ::Rails::Engine
    isolate_namespace Angarium

    # Angarium owns migration placement through `bin/rails g angarium:migrations`
    # (multi-db aware, invoked by angarium:install). Unregister the engine's
    # db/migrate path so Rails neither auto-appends the migrations onto the host's
    # primary connection nor generates the angarium:install:migrations task, which
    # can only ever target db/migrate and would misplace them in a multi-database
    # setup. The generator reads the migrations off disk directly, so this is a
    # no-op for it.
    paths["db/migrate"] = []
  end
end
