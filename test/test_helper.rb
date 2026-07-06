# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [File.expand_path("../test/dummy/db/migrate", __dir__)]
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

# Pin the whole suite to the :test queue adapter. The dummy app defaults to
# :async, so any test that creates a Delivery without including
# ActiveJob::TestHelper would have its after_create_commit DeliverJob run in a
# background thread — delivering (or fail-closing) mid-test and creating stray
# DeliveryAttempt rows that race the assertions. With :test, jobs only run under
# perform_enqueued_jobs, keeping every test deterministic.
ActiveJob::Base.queue_adapter = :test

# Test double for Angarium::Client.
#
# The delivery path now always pins the connection to the validated resolved
# IP(s) (addresses is guaranteed non-empty — the fail-closed branch returns
# early otherwise). httpx 1.8.0's WebMock adapter mocks the *response* for a
# pinned request but then hangs on session teardown: the pinned real socket
# stays registered in the selector and `close` blocks in `select`. So real HTTP
# can't be exercised through WebMock once a request pins — the repo's existing
# "pins the connection" test already sidesteps this with a hand-rolled double
# for the same reason. This double records each call so tests can assert a
# request was made to the resolved+pinned address, and returns a canned Result.
class FakeAngariumClient
  Call = Struct.new(:url, :body, :headers, :addresses)

  attr_reader :calls

  def initialize(result)
    @result = result
    @calls = []
  end

  def post(url, body:, headers:, addresses: nil)
    @calls << Call.new(url, body, headers, addresses)
    @result
  end

  def requested? = @calls.any?

  def last = @calls.last
end

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [File.expand_path("fixtures", __dir__)]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = File.expand_path("fixtures", __dir__) + "/files"
  ActiveSupport::TestCase.fixtures :all
end
