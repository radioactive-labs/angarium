# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [File.expand_path("../test/dummy/db/migrate", __dir__)]
ActiveRecord::Migrator.migrations_paths << File.expand_path("../db/migrate", __dir__)
require "rails/test_help"
require "webmock/minitest"
require "minitest/mock"

# httpx auto-registers its WebMock adapter only if WebMock is already defined
# at the time httpx loads (see httpx.rb: `require "httpx/adapters/webmock" if
# defined?(WebMock)`). Since httpx loads earlier (via the dummy app booting
# the engine) than webmock/minitest above, that guard misses and the adapter
# never registers. Load it explicitly and enable it now that both are present.
require "httpx/adapters/webmock"
WebMock::HttpLibAdapters::HttpxAdapter.enable!

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [File.expand_path("fixtures", __dir__)]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = File.expand_path("fixtures", __dir__) + "/files"
  ActiveSupport::TestCase.fixtures :all
end
