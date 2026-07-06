# Angarium Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Angarium outbound-webhooks Rails engine — a headless, framework-agnostic, sellable gem with HMAC signing, retry-with-backoff, and event subscriptions.

**Architecture:** Mountable Rails engine (`isolate_namespace Angarium`) owning four models (`Endpoint`, `Event`, `Delivery`, `DeliveryAttempt`). A `dispatch` call fans an event out to an owner's matching endpoints, creating one `Delivery` per endpoint, each of which enqueues an ActiveJob that POSTs a signed JSON envelope via HTTPX and self-reschedules on failure using a configurable backoff schedule.

**Tech Stack:** Ruby 3.3, Rails 7.1 engine, ActiveJob, HTTPX, SQLite (dummy app), Minitest + WebMock, `test/dummy` app. JSON columns (`t.json`) hold arrays/hashes; subscription matching is done in Ruby, not SQL, so SQLite is sufficient.

**User Verification:** NO — no user verification required (building a library; correctness is proven by the test suite).

---

## Conventions for every task

- Work inside `/Users/stefan/Documents/radioactive_labs/angarium`.
- Run tests with: `bin/rails test` (or a single file: `bin/rails test test/path/to_test.rb`).
- The dummy app uses **SQLite** (already configured in `test/dummy/config/database.yml`). The DB file is created by `cd test/dummy && bin/rails db:prepare` (first run).
- JSON columns use `t.json` (not `t.jsonb`) for SQLite compatibility; arrays/hashes serialize transparently.
- Migrations live in the engine's `db/migrate` and are loaded into the dummy app by the engine; after adding a migration run `cd test/dummy && bin/rails db:migrate` (the dummy loads engine migrations via `Angarium::Engine`).
- Commit after each task with the message shown in its final step.
- No `state_machine` gem — state is a plain string column with explicit predicate/transition methods.

---

### Task 0: Gem metadata, dependencies, and configuration

**Goal:** Fill in the gemspec, add runtime/dev dependencies, and add a `Angarium.configure` configuration object. Test suite runs green.

**Files:**
- Modify: `angarium.gemspec`
- Modify: `Gemfile`
- Modify: `lib/angarium.rb`
- Create: `lib/angarium/configuration.rb`
- Modify: `test/test_helper.rb`
- Create: `test/angarium/configuration_test.rb`

**Acceptance Criteria:**
- [ ] `bundle install` succeeds.
- [ ] `Angarium.configure { |c| c.http_timeout = 5 }` sets and reads back config.
- [ ] Defaults are present for every config key.
- [ ] `bin/rails test` is green.

**Verify:** `bin/rails test test/angarium/configuration_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Fill in the gemspec**

Replace the TODO fields and dependencies in `angarium.gemspec`:

```ruby
require_relative "lib/angarium/version"

Gem::Specification.new do |spec|
  spec.name        = "angarium"
  spec.version     = Angarium::VERSION
  spec.authors     = ["TheDumbTechGuy"]
  spec.email       = ["sfroelich01@gmail.com"]
  spec.homepage    = "https://github.com/radioactive-labs/angarium"
  spec.summary     = "Outbound webhooks for Rails: signed, retried, subscription-based delivery."
  spec.description = "A mountable Rails engine that delivers outbound webhooks with HMAC signing, automatic retries with exponential backoff, and per-endpoint event subscriptions."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/radioactive-labs/angarium"
  spec.metadata["changelog_uri"] = "https://github.com/radioactive-labs/angarium/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 7.1"
  spec.add_dependency "httpx", "~> 1.0"
end
```

- [ ] **Step 2: Add dev dependencies to the Gemfile**

Append to `Gemfile` (below the existing `gemspec` line):

```ruby
gem "sqlite3"
gem "webmock"
```

- [ ] **Step 3: Run bundle install**

Run: `bundle install`
Expected: completes; `httpx`, `pg`, `webmock` installed.

- [ ] **Step 4: Write the failing test**

Create `test/angarium/configuration_test.rb`:

```ruby
require "test_helper"

class Angarium::ConfigurationTest < ActiveSupport::TestCase
  setup { @original = Angarium.config.dup }
  teardown { Angarium.instance_variable_set(:@config, @original) }

  test "has sensible defaults" do
    config = Angarium::Configuration.new
    assert_equal :default, config.job_queue
    assert_equal 10, config.http_timeout
    assert_equal "X-Angarium-Signature", config.signature_header
    assert_equal true, config.block_private_ips
    assert_equal 5, config.retry_schedule.length
    assert_match(/Angarium/, config.user_agent)
  end

  test "configure yields the config for mutation" do
    Angarium.configure { |c| c.http_timeout = 5 }
    assert_equal 5, Angarium.config.http_timeout
  end
end
```

- [ ] **Step 5: Run test to verify it fails**

Run: `bin/rails test test/angarium/configuration_test.rb`
Expected: FAIL — `NameError: uninitialized constant Angarium::Configuration`.

- [ ] **Step 6: Implement the configuration object**

Create `lib/angarium/configuration.rb`:

```ruby
module Angarium
  class Configuration
    attr_accessor :job_queue, :http_timeout, :user_agent,
                  :retry_schedule, :signature_header, :block_private_ips

    def initialize
      @job_queue        = :default
      @http_timeout     = 10
      @user_agent       = "Angarium/#{Angarium::VERSION}"
      @retry_schedule   = [1.minute, 5.minutes, 30.minutes, 2.hours, 5.hours]
      @signature_header = "X-Angarium-Signature"
      @block_private_ips = true
    end
  end
end
```

- [ ] **Step 7: Wire config into the top-level module**

Replace `lib/angarium.rb` with:

```ruby
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
```

- [ ] **Step 8: Ensure WebMock is loaded in tests**

Add to the top of `test/test_helper.rb` (after the existing requires):

```ruby
require "webmock/minitest"
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `bin/rails test test/angarium/configuration_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "Add gemspec metadata, deps, and Angarium configuration"
```

---

### Task 1: Schema, base record, and models with associations

**Goal:** Create the four migrations and the four models (plus abstract base) with associations. Schema loads and associations resolve.

**Files:**
- Create: `db/migrate/20260704000001_create_angarium_endpoints.rb`
- Create: `db/migrate/20260704000002_create_angarium_events.rb`
- Create: `db/migrate/20260704000003_create_angarium_deliveries.rb`
- Create: `db/migrate/20260704000004_create_angarium_delivery_attempts.rb`
- Modify: `app/models/angarium/application_record.rb`
- Create: `app/models/angarium/endpoint.rb`
- Create: `app/models/angarium/event.rb`
- Create: `app/models/angarium/delivery.rb`
- Create: `app/models/angarium/delivery_attempt.rb`
- Create: `test/dummy/app/models/owner.rb`
- Create: `test/models/angarium/associations_test.rb`

**Acceptance Criteria:**
- [ ] Migrations run cleanly against the dummy app.
- [ ] An `Endpoint` can be created for a polymorphic owner.
- [ ] `event.deliveries`, `delivery.event`, `delivery.endpoint`, `delivery.delivery_attempts` all resolve.

**Verify:** `bin/rails test test/models/angarium/associations_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Create the endpoints migration** (indexes inlined)

Create `db/migrate/20260704000001_create_angarium_endpoints.rb`:

```ruby
class CreateAngariumEndpoints < ActiveRecord::Migration[7.1]
  def change
    create_table :angarium_endpoints do |t|
      t.references :owner, polymorphic: true, null: false
      t.string :name, null: false
      t.string :url, null: false
      t.boolean :active, null: false, default: true
      t.string :signing_secret, null: false
      t.json :subscribed_events, null: false, default: []
      t.timestamps
    end
  end
end
```

- [ ] **Step 2: Create the events migration**

Create `db/migrate/20260704000002_create_angarium_events.rb`:

```ruby
class CreateAngariumEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :angarium_events do |t|
      t.string :name, null: false
      t.json :payload, null: false, default: {}
      t.timestamps
    end
  end
end
```

- [ ] **Step 3: Create the deliveries migration**

Create `db/migrate/20260704000003_create_angarium_deliveries.rb`:

```ruby
class CreateAngariumDeliveries < ActiveRecord::Migration[7.1]
  def change
    create_table :angarium_deliveries do |t|
      t.references :event, null: false, foreign_key: { to_table: :angarium_events }
      t.references :endpoint, null: false, foreign_key: { to_table: :angarium_endpoints }
      t.string :state, null: false, default: "pending"
      t.integer :attempt_count, null: false, default: 0
      t.datetime :last_attempt_at
      t.datetime :next_attempt_at
      t.timestamps
    end
  end
end
```

- [ ] **Step 4: Create the delivery attempts migration**

Create `db/migrate/20260704000004_create_angarium_delivery_attempts.rb`:

```ruby
class CreateAngariumDeliveryAttempts < ActiveRecord::Migration[7.1]
  def change
    create_table :angarium_delivery_attempts do |t|
      t.references :delivery, null: false, foreign_key: { to_table: :angarium_deliveries }
      t.integer :response_code
      t.text :response_body
      t.string :error
      t.float :duration
      t.timestamps
    end
  end
end
```

- [ ] **Step 5: Set the abstract base record**

Replace `app/models/angarium/application_record.rb`:

```ruby
module Angarium
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end
```

- [ ] **Step 6: Create the Endpoint model** (behaviors added in Task 2; associations only here)

Create `app/models/angarium/endpoint.rb`:

```ruby
module Angarium
  class Endpoint < ApplicationRecord
    belongs_to :owner, polymorphic: true
    has_many :deliveries, class_name: "Angarium::Delivery", dependent: :destroy

    scope :active, -> { where(active: true) }
  end
end
```

- [ ] **Step 7: Create the Event model**

Create `app/models/angarium/event.rb`:

```ruby
module Angarium
  class Event < ApplicationRecord
    has_many :deliveries, class_name: "Angarium::Delivery", dependent: :destroy

    validates :name, presence: true
  end
end
```

- [ ] **Step 8: Create the Delivery model** (state behavior added in Task 5)

Create `app/models/angarium/delivery.rb`:

```ruby
module Angarium
  class Delivery < ApplicationRecord
    belongs_to :event, class_name: "Angarium::Event"
    belongs_to :endpoint, class_name: "Angarium::Endpoint"
    has_many :delivery_attempts, class_name: "Angarium::DeliveryAttempt", dependent: :destroy
  end
end
```

- [ ] **Step 9: Create the DeliveryAttempt model**

Create `app/models/angarium/delivery_attempt.rb`:

```ruby
module Angarium
  class DeliveryAttempt < ApplicationRecord
    belongs_to :delivery, class_name: "Angarium::Delivery"
  end
end
```

- [ ] **Step 10: Create a dummy-app owner model for tests**

Create `test/dummy/app/models/owner.rb`:

```ruby
class Owner < ActiveRecord::Base
  has_many :webhook_endpoints, as: :owner, class_name: "Angarium::Endpoint"
end
```

Create the owners table via a dummy-app migration `test/dummy/db/migrate/20260704000100_create_owners.rb`:

```ruby
class CreateOwners < ActiveRecord::Migration[7.1]
  def change
    create_table :owners do |t|
      t.string :name
      t.timestamps
    end
  end
end
```

- [ ] **Step 11: Migrate the dummy app**

Run: `cd test/dummy && bin/rails db:prepare && bin/rails db:migrate && cd ../..`
Expected: all five tables created (four `angarium_*` + `owners`).

- [ ] **Step 12: Write the associations test**

Create `test/models/angarium/associations_test.rb`:

```ruby
require "test_helper"

class Angarium::AssociationsTest < ActiveSupport::TestCase
  setup do
    @owner = Owner.create!(name: "Acme")
    @endpoint = Angarium::Endpoint.create!(
      owner: @owner, name: "prod", url: "https://example.test/hook",
      signing_secret: "s3cr3t", subscribed_events: ["*"]
    )
    @event = Angarium::Event.create!(name: "invoice.paid", payload: { id: 1 })
    @delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
    @attempt = Angarium::DeliveryAttempt.create!(delivery: @delivery, response_code: 200)
  end

  test "owner has_many webhook_endpoints" do
    assert_equal [@endpoint], @owner.webhook_endpoints.to_a
  end

  test "delivery graph resolves" do
    assert_equal @event, @delivery.event
    assert_equal @endpoint, @delivery.endpoint
    assert_equal [@attempt], @delivery.delivery_attempts.to_a
    assert_equal [@delivery], @event.deliveries.to_a
  end

  test "active scope filters inactive endpoints" do
    @endpoint.update!(active: false)
    assert_empty Angarium::Endpoint.active
  end
end
```

- [ ] **Step 13: Run tests**

Run: `bin/rails test test/models/angarium/associations_test.rb`
Expected: PASS (3 runs, 0 failures).

- [ ] **Step 14: Commit**

```bash
git add -A
git commit -m "Add migrations and models with associations"
```

---

### Task 2: Endpoint behaviors — secret generation, URL/SSRF validation, subscription matching

**Goal:** Auto-generate `signing_secret`, validate the URL (https + SSRF block), and match events against `subscribed_events`.

**Files:**
- Create: `lib/angarium/event_matcher.rb`
- Modify: `lib/angarium.rb` (require event_matcher)
- Create: `app/validators/angarium/endpoint_url_validator.rb`
- Modify: `app/models/angarium/endpoint.rb`
- Create: `test/lib/angarium/event_matcher_test.rb`
- Create: `test/models/angarium/endpoint_test.rb`

**Acceptance Criteria:**
- [ ] `signing_secret` is set automatically on create when blank.
- [ ] `https` required; `http` and private/loopback hosts rejected when `block_private_ips` is on.
- [ ] `endpoint.subscribed_to?("invoice.paid")` honors exact, `prefix.*`, and `*`.

**Verify:** `bin/rails test test/models/angarium/endpoint_test.rb test/lib/angarium/event_matcher_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Write the matcher test**

Create `test/lib/angarium/event_matcher_test.rb`:

```ruby
require "test_helper"

class Angarium::EventMatcherTest < ActiveSupport::TestCase
  test "exact match" do
    assert Angarium::EventMatcher.match?("invoice.paid", "invoice.paid")
    refute Angarium::EventMatcher.match?("invoice.paid", "invoice.void")
  end

  test "catch-all" do
    assert Angarium::EventMatcher.match?("*", "anything.happened")
  end

  test "prefix wildcard" do
    assert Angarium::EventMatcher.match?("invoice.*", "invoice.paid")
    refute Angarium::EventMatcher.match?("invoice.*", "user.created")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/angarium/event_matcher_test.rb`
Expected: FAIL — uninitialized constant `Angarium::EventMatcher`.

- [ ] **Step 3: Implement the matcher**

Create `lib/angarium/event_matcher.rb`:

```ruby
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
```

Add to `lib/angarium.rb` requires (below `require "angarium/configuration"`):

```ruby
require "angarium/event_matcher"
```

- [ ] **Step 4: Run matcher test**

Run: `bin/rails test test/lib/angarium/event_matcher_test.rb`
Expected: PASS (3 runs).

- [ ] **Step 5: Write the endpoint behavior test**

Create `test/models/angarium/endpoint_test.rb`:

```ruby
require "test_helper"

class Angarium::EndpointTest < ActiveSupport::TestCase
  setup { @owner = Owner.create!(name: "Acme") }

  def build(attrs = {})
    Angarium::Endpoint.new({
      owner: @owner, name: "prod", url: "https://example.test/hook",
      subscribed_events: ["*"]
    }.merge(attrs))
  end

  test "generates a signing_secret on create when blank" do
    endpoint = build
    assert_nil endpoint.signing_secret
    endpoint.save!
    assert endpoint.signing_secret.present?
    assert_operator endpoint.signing_secret.length, :>=, 32
  end

  test "keeps a provided signing_secret" do
    endpoint = build(signing_secret: "explicit")
    endpoint.save!
    assert_equal "explicit", endpoint.signing_secret
  end

  test "requires https" do
    endpoint = build(url: "http://example.test/hook")
    refute endpoint.valid?
    assert_includes endpoint.errors[:url].join, "https"
  end

  test "rejects private/loopback hosts when block_private_ips is on" do
    endpoint = build(url: "https://127.0.0.1/hook")
    refute endpoint.valid?
  end

  test "allows private hosts when block_private_ips is off" do
    Angarium.config.stub(:block_private_ips, false) do
      endpoint = build(url: "https://127.0.0.1/hook")
      assert endpoint.valid?
    end
  end

  test "subscribed_to? honors patterns" do
    endpoint = build(subscribed_events: ["invoice.*", "user.created"])
    assert endpoint.subscribed_to?("invoice.paid")
    assert endpoint.subscribed_to?("user.created")
    refute endpoint.subscribed_to?("user.deleted")
  end
end
```

Note: `stub` comes from Minitest::Mock's `Object#stub`, available in Rails' `ActiveSupport::TestCase`.

- [ ] **Step 6: Run test to verify it fails**

Run: `bin/rails test test/models/angarium/endpoint_test.rb`
Expected: FAIL — no secret generation / validator.

- [ ] **Step 7: Implement the URL validator (with SSRF guard)**

Create `app/validators/angarium/endpoint_url_validator.rb`:

```ruby
require "resolv"

module Angarium
  class EndpointUrlValidator < ActiveModel::EachValidator
    def validate_each(record, attribute, value)
      uri = begin
        URI.parse(value.to_s)
      rescue URI::InvalidURIError
        nil
      end

      unless uri.is_a?(URI::HTTPS) && uri.host.present?
        record.errors.add(attribute, "must be a valid https URL")
        return
      end

      if Angarium.config.block_private_ips && private_host?(uri.host)
        record.errors.add(attribute, "must not point to a private or loopback address")
      end
    end

    private

    def private_host?(host)
      addresses(host).any? do |ip|
        ip.loopback? || ip.private? || ip.link_local? ||
          (ip.respond_to?(:unique_local?) && ip.unique_local?)
      end
    end

    def addresses(host)
      ([host] + resolve(host)).filter_map do |candidate|
        IPAddr.new(candidate)
      rescue IPAddr::InvalidAddressError
        nil
      end
    end

    def resolve(host)
      Resolv.getaddresses(host)
    rescue StandardError
      []
    end
  end
end
```

- [ ] **Step 8: Add behaviors to the Endpoint model**

Update `app/models/angarium/endpoint.rb`:

```ruby
require "securerandom"

module Angarium
  class Endpoint < ApplicationRecord
    belongs_to :owner, polymorphic: true
    has_many :deliveries, class_name: "Angarium::Delivery", dependent: :destroy

    scope :active, -> { where(active: true) }

    before_validation :ensure_signing_secret, on: :create

    validates :name, presence: true
    validates :url, presence: true, "angarium/endpoint_url": true
    validates :active, inclusion: { in: [true, false] }

    def subscribed_to?(event_name)
      Array(subscribed_events).any? { |pattern| EventMatcher.match?(pattern, event_name) }
    end

    private

    def ensure_signing_secret
      self.signing_secret ||= SecureRandom.hex(32)
    end
  end
end
```

Note the validation key `"angarium/endpoint_url": true` resolves to `Angarium::EndpointUrlValidator`.

- [ ] **Step 9: Run tests**

Run: `bin/rails test test/models/angarium/endpoint_test.rb`
Expected: PASS (6 runs).

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "Add endpoint secret generation, SSRF-aware URL validation, subscription matching"
```

---

### Task 3: Signature module (HMAC sign + verify)

**Goal:** Sign a payload with a per-endpoint secret and verify a signature header (with replay tolerance).

**Files:**
- Create: `lib/angarium/signature.rb`
- Modify: `lib/angarium.rb` (require signature)
- Create: `test/lib/angarium/signature_test.rb`

**Acceptance Criteria:**
- [ ] `sign` produces `t=<ts>,v1=<hexdigest>`.
- [ ] `verify` returns true for a matching payload/secret and false for a tampered payload, wrong secret, or stale timestamp.

**Verify:** `bin/rails test test/lib/angarium/signature_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Write the test**

Create `test/lib/angarium/signature_test.rb`:

```ruby
require "test_helper"

class Angarium::SignatureTest < ActiveSupport::TestCase
  test "sign then verify round-trips" do
    header = Angarium::Signature.sign(payload: "body", secret: "shh", timestamp: 1_000)
    assert_match(/\At=1000,v1=[0-9a-f]{64}\z/, header)
    assert Angarium::Signature.verify(payload: "body", header: header, secret: "shh", now: 1_100)
  end

  test "rejects tampered payload" do
    header = Angarium::Signature.sign(payload: "body", secret: "shh", timestamp: 1_000)
    refute Angarium::Signature.verify(payload: "TAMPERED", header: header, secret: "shh", now: 1_100)
  end

  test "rejects wrong secret" do
    header = Angarium::Signature.sign(payload: "body", secret: "shh", timestamp: 1_000)
    refute Angarium::Signature.verify(payload: "body", header: header, secret: "nope", now: 1_100)
  end

  test "rejects stale timestamp beyond tolerance" do
    header = Angarium::Signature.sign(payload: "body", secret: "shh", timestamp: 1_000)
    refute Angarium::Signature.verify(payload: "body", header: header, secret: "shh", now: 9_999, tolerance: 300)
  end

  test "rejects malformed header" do
    refute Angarium::Signature.verify(payload: "body", header: "garbage", secret: "shh", now: 1_000)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/angarium/signature_test.rb`
Expected: FAIL — uninitialized constant `Angarium::Signature`.

- [ ] **Step 3: Implement the signature module**

Create `lib/angarium/signature.rb`:

```ruby
require "openssl"

module Angarium
  module Signature
    module_function

    def sign(payload:, secret:, timestamp: Time.now.to_i)
      digest = hexdigest(secret, timestamp, payload)
      "t=#{timestamp},v1=#{digest}"
    end

    def verify(payload:, header:, secret:, tolerance: 300, now: Time.now.to_i)
      parsed = parse(header)
      return false unless parsed

      timestamp, signature = parsed
      return false if (now - timestamp).abs > tolerance

      expected = hexdigest(secret, timestamp, payload)
      secure_compare(expected, signature)
    end

    def hexdigest(secret, timestamp, payload)
      OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "#{timestamp}.#{payload}")
    end

    def parse(header)
      parts = header.to_s.split(",").map { |kv| kv.split("=", 2) }.to_h
      t = parts["t"]
      v1 = parts["v1"]
      return nil unless t&.match?(/\A\d+\z/) && v1&.match?(/\A[0-9a-f]{64}\z/)

      [t.to_i, v1]
    end

    def secure_compare(a, b)
      ActiveSupport::SecurityUtils.secure_compare(a, b)
    rescue ArgumentError
      false
    end
  end
end
```

Add to `lib/angarium.rb` requires:

```ruby
require "angarium/signature"
```

- [ ] **Step 4: Run tests**

Run: `bin/rails test test/lib/angarium/signature_test.rb`
Expected: PASS (5 runs).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add HMAC signature sign/verify with replay tolerance"
```

---

### Task 4: Dispatch API — fan an event out to matching endpoints

**Goal:** `Angarium.dispatch(name, payload, owner:)` creates one `Event` and one `Delivery` per active, subscribed endpoint, inside a transaction. Non-matching/inactive endpoints are excluded. No endpoints → no event created.

**Files:**
- Create: `lib/angarium/dispatch.rb`
- Modify: `lib/angarium.rb` (require + delegate)
- Create: `test/lib/angarium/dispatch_test.rb`

**Acceptance Criteria:**
- [ ] Creates an `Event` and a `Delivery` per matching endpoint.
- [ ] Skips inactive and non-subscribed endpoints.
- [ ] Returns `nil` and creates nothing when no endpoints match.
- [ ] Delivery enqueuing is deferred to Task 5 (here we assert only rows created; stub the job to a no-op via `perform_later` assertion).

**Verify:** `bin/rails test test/lib/angarium/dispatch_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Write the test**

Create `test/lib/angarium/dispatch_test.rb`:

```ruby
require "test_helper"

class Angarium::DispatchTest < ActiveSupport::TestCase
  setup do
    @owner = Owner.create!(name: "Acme")
    @subscribed = endpoint(subscribed_events: ["invoice.*"])
    @other = endpoint(subscribed_events: ["user.created"])
    @inactive = endpoint(subscribed_events: ["*"], active: false)
  end

  def endpoint(attrs)
    Angarium::Endpoint.create!({
      owner: @owner, name: "e", url: "https://example.test/hook"
    }.merge(attrs))
  end

  test "creates an event and a delivery per matching endpoint" do
    event = nil
    assert_difference -> { Angarium::Event.count } => 1,
                      -> { Angarium::Delivery.count } => 1 do
      event = Angarium.dispatch("invoice.paid", { id: 1 }, owner: @owner)
    end
    assert_equal "invoice.paid", event.name
    assert_equal [@subscribed], event.deliveries.map(&:endpoint)
  end

  test "returns nil and creates nothing when no endpoint matches" do
    assert_no_difference -> { Angarium::Event.count } do
      assert_nil Angarium.dispatch("nothing.matches", {}, owner: @owner)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/angarium/dispatch_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'dispatch'`.

- [ ] **Step 3: Implement dispatch**

Create `lib/angarium/dispatch.rb`:

```ruby
module Angarium
  module Dispatch
    module_function

    def call(event_name, payload, owner:)
      endpoints = Endpoint.active.where(owner: owner).select do |endpoint|
        endpoint.subscribed_to?(event_name)
      end
      return nil if endpoints.empty?

      Event.transaction do
        event = Event.create!(name: event_name, payload: payload)
        endpoints.each { |endpoint| event.deliveries.create!(endpoint: endpoint) }
        event
      end
    end
  end
end
```

Add to `lib/angarium.rb`: require and a delegating class method.

```ruby
require "angarium/dispatch"
```

Inside `module Angarium ... class << self`:

```ruby
    def dispatch(event_name, payload, owner:)
      Dispatch.call(event_name, payload, owner: owner)
    end
```

- [ ] **Step 4: Run tests**

Run: `bin/rails test test/lib/angarium/dispatch_test.rb`
Expected: PASS (2 runs). (The `Delivery` `after_create_commit` job enqueue is added in Task 5; until then no job fires.)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add Angarium.dispatch event fan-out to matching endpoints"
```

---

### Task 5: Deliver job — signed HTTP POST, attempt recording, success/fail transitions

**Goal:** On delivery creation, enqueue `Angarium::DeliverJob`, which POSTs a signed JSON envelope via HTTPX, records a `DeliveryAttempt`, and transitions the delivery to `succeeded` (2xx) or leaves it for retry (non-2xx / error). Retry scheduling itself is Task 6; here, a failed attempt with no retries left → `exhausted`.

**Files:**
- Create: `lib/angarium/client.rb`
- Modify: `lib/angarium.rb` (require client)
- Modify: `app/models/angarium/delivery.rb` (state predicates + `deliver!`)
- Create: `app/jobs/angarium/deliver_job.rb`
- Modify: `app/jobs/angarium/application_job.rb`
- Create: `test/jobs/angarium/deliver_job_test.rb`

**Acceptance Criteria:**
- [ ] Creating a `Delivery` enqueues `Angarium::DeliverJob`.
- [ ] A 2xx response → `Delivery#succeeded?`, one `DeliveryAttempt` with the response code.
- [ ] The POST includes the signature header and a JSON envelope `{id, event, created_at, data}`.
- [ ] A failing response with `retry_schedule = []` → `Delivery#exhausted?`.

**Verify:** `bin/rails test test/jobs/angarium/deliver_job_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Write the test**

Create `test/jobs/angarium/deliver_job_test.rb`:

```ruby
require "test_helper"

class Angarium::DeliverJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @owner = Owner.create!(name: "Acme")
    @endpoint = Angarium::Endpoint.create!(
      owner: @owner, name: "e", url: "https://example.test/hook",
      signing_secret: "shh", subscribed_events: ["*"]
    )
    @event = Angarium::Event.create!(name: "invoice.paid", payload: { "id" => 1 })
  end

  test "creating a delivery enqueues the deliver job" do
    assert_enqueued_with(job: Angarium::DeliverJob) do
      Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
    end
  end

  test "successful 2xx delivery marks succeeded and records an attempt" do
    stub = stub_request(:post, "https://example.test/hook").to_return(status: 200, body: "ok")
    delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)

    perform_enqueued_jobs

    delivery.reload
    assert delivery.succeeded?, "expected succeeded, was #{delivery.state}"
    assert_equal 1, delivery.attempt_count
    attempt = delivery.delivery_attempts.sole
    assert_equal 200, attempt.response_code
    assert_requested stub
  end

  test "request carries signature header and json envelope" do
    body = nil
    headers = nil
    stub_request(:post, "https://example.test/hook").to_return(status: 200).with do |req|
      body = req.body
      headers = req.headers
      true
    end

    Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
    perform_enqueued_jobs

    assert headers["X-Angarium-Signature"].present?
    envelope = JSON.parse(body)
    assert_equal "invoice.paid", envelope["event"]
    assert_equal({ "id" => 1 }, envelope["data"])
    assert envelope["id"].present?
    assert Angarium::Signature.verify(
      payload: body, header: headers["X-Angarium-Signature"], secret: "shh"
    )
  end

  test "failed delivery with empty retry schedule is exhausted" do
    Angarium.config.stub(:retry_schedule, []) do
      stub_request(:post, "https://example.test/hook").to_return(status: 500, body: "boom")
      delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
      perform_enqueued_jobs
      delivery.reload
      assert delivery.exhausted?, "expected exhausted, was #{delivery.state}"
      assert_equal 1, delivery.attempt_count
      assert_equal 500, delivery.delivery_attempts.sole.response_code
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/jobs/angarium/deliver_job_test.rb`
Expected: FAIL — no `DeliverJob` / `deliver!`.

- [ ] **Step 3: Implement the HTTPX client**

Create `lib/angarium/client.rb`:

```ruby
require "httpx"

module Angarium
  # Thin wrapper over HTTPX. Returns a plain result hash so callers/tests
  # never touch HTTPX response objects directly.
  class Client
    Result = Struct.new(:success, :code, :body, :error, :duration, keyword_init: true) do
      def success? = success
    end

    def post(url, body:, headers:)
      started = monotonic
      response = self.class.connection.post(url, body: body, headers: headers)
      duration = monotonic - started

      if response.is_a?(HTTPX::ErrorResponse)
        return Result.new(success: false, error: "#{response.error.class}: #{response.error.message}",
                          duration: duration)
      end

      Result.new(
        success: (200..299).cover?(response.status),
        code: response.status,
        body: response.body.to_s[0..1500],
        duration: duration
      )
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def self.connection
      HTTPX.with(
        headers: { "user-agent" => Angarium.config.user_agent, "content-type" => "application/json" },
        timeout: { read_timeout: Angarium.config.http_timeout }
      )
    end
  end
end
```

Add to `lib/angarium.rb` requires:

```ruby
require "angarium/client"
```

- [ ] **Step 4: Ensure ApplicationJob uses the configured queue**

Replace `app/jobs/angarium/application_job.rb`:

```ruby
module Angarium
  class ApplicationJob < ActiveJob::Base
    queue_as { Angarium.config.job_queue }
  end
end
```

- [ ] **Step 5: Implement state + delivery logic on the Delivery model**

Replace `app/models/angarium/delivery.rb`:

```ruby
module Angarium
  class Delivery < ApplicationRecord
    STATES = %w[pending delivering succeeded exhausted].freeze

    belongs_to :event, class_name: "Angarium::Event"
    belongs_to :endpoint, class_name: "Angarium::Endpoint"
    has_many :delivery_attempts, class_name: "Angarium::DeliveryAttempt", dependent: :destroy

    after_create_commit { DeliverJob.perform_later(id) }

    STATES.each do |state_name|
      define_method("#{state_name}?") { state == state_name }
    end

    # Performs one attempt. Records a DeliveryAttempt, then transitions to
    # succeeded, schedules a retry, or exhausts. Returns the DeliveryAttempt.
    def deliver!(client: Client.new)
      update!(state: "delivering", attempt_count: attempt_count + 1, last_attempt_at: Time.current)

      body = request_body
      result = client.post(
        endpoint.url,
        body: body,
        headers: { Angarium.config.signature_header => sign(body) }
      )

      attempt = delivery_attempts.create!(
        response_code: result.code,
        response_body: result.body,
        error: result.error,
        duration: result.duration
      )

      result.success? ? succeed! : handle_failure!
      attempt
    end

    private

    def succeed!
      update!(state: "succeeded", next_attempt_at: nil)
    end

    # Retry scheduling filled in by Task 6; base behavior = exhaust.
    def handle_failure!
      update!(state: "exhausted")
    end

    def request_body
      {
        id: id,
        event: event.name,
        created_at: created_at.iso8601,
        data: event.payload
      }.to_json
    end

    def sign(body)
      Signature.sign(payload: body, secret: endpoint.signing_secret)
    end
  end
end
```

- [ ] **Step 6: Implement the deliver job**

Create `app/jobs/angarium/deliver_job.rb`:

```ruby
module Angarium
  class DeliverJob < ApplicationJob
    def perform(delivery_id)
      delivery = Delivery.find_by(id: delivery_id)
      return unless delivery
      return if delivery.succeeded?

      delivery.deliver!
    end
  end
end
```

- [ ] **Step 7: Run tests**

Run: `bin/rails test test/jobs/angarium/deliver_job_test.rb`
Expected: PASS (4 runs).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Add signed HTTP delivery job with attempt recording and state transitions"
```

---

### Task 6: Retry with exponential backoff

**Goal:** A failed delivery reschedules itself using `config.retry_schedule` (indexed by prior attempt count), sets `next_attempt_at`, returns to `pending`, and re-enqueues with the right `wait`. After the schedule is exhausted, it transitions to `exhausted`.

**Files:**
- Modify: `app/models/angarium/delivery.rb` (`handle_failure!`)
- Create: `test/models/angarium/delivery_retry_test.rb`

**Acceptance Criteria:**
- [ ] First failure with a non-empty schedule → back to `pending`, `next_attempt_at` set, job re-enqueued with the scheduled `wait`.
- [ ] After N failures (N = schedule length + 1 attempts) → `exhausted`.

**Verify:** `bin/rails test test/models/angarium/delivery_retry_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Write the test**

Create `test/models/angarium/delivery_retry_test.rb`:

```ruby
require "test_helper"

class Angarium::DeliveryRetryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @owner = Owner.create!(name: "Acme")
    @endpoint = Angarium::Endpoint.create!(
      owner: @owner, name: "e", url: "https://example.test/hook",
      signing_secret: "shh", subscribed_events: ["*"]
    )
    @event = Angarium::Event.create!(name: "invoice.paid", payload: {})
    stub_request(:post, "https://example.test/hook").to_return(status: 500)
  end

  test "first failure reschedules with backoff and returns to pending" do
    Angarium.config.stub(:retry_schedule, [60, 300]) do
      delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
      assert_enqueued_with(job: Angarium::DeliverJob) do
        perform_enqueued_jobs_once
      end
      delivery.reload
      assert delivery.pending?, "expected pending, was #{delivery.state}"
      assert_equal 1, delivery.attempt_count
      assert delivery.next_attempt_at.present?
    end
  end

  test "exhausts after the schedule is used up" do
    Angarium.config.stub(:retry_schedule, [60]) do
      delivery = Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
      # attempt 1 (fails, reschedules), attempt 2 (fails, no schedule left -> exhausted)
      perform_enqueued_jobs
      delivery.reload
      assert delivery.exhausted?, "expected exhausted, was #{delivery.state}"
      assert_equal 2, delivery.attempt_count
    end
  end

  private

  # Perform only the jobs currently enqueued, not ones they enqueue in turn.
  def perform_enqueued_jobs_once
    jobs = enqueued_jobs.dup
    clear_enqueued_jobs
    jobs.each do |job|
      ActiveJob::Base.execute(job.except("provider_job_id"))
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/angarium/delivery_retry_test.rb`
Expected: FAIL — `exhausted` on first failure (current `handle_failure!` always exhausts) and no `next_attempt_at`.

- [ ] **Step 3: Implement backoff in `handle_failure!`**

In `app/models/angarium/delivery.rb`, replace the `handle_failure!` method:

```ruby
    def handle_failure!
      schedule = Array(Angarium.config.retry_schedule)
      wait = schedule[attempt_count - 1] # attempt_count already incremented for this attempt

      if wait
        update!(state: "pending", next_attempt_at: Time.current + wait)
        DeliverJob.set(wait: wait).perform_later(id)
      else
        update!(state: "exhausted")
      end
    end
```

- [ ] **Step 4: Run tests**

Run: `bin/rails test test/models/angarium/delivery_retry_test.rb`
Expected: PASS (2 runs).

- [ ] **Step 5: Run the whole suite**

Run: `bin/rails test`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add exponential backoff retry scheduling for failed deliveries"
```

---

### Task 7: Install generator, README, CHANGELOG

**Goal:** Ship a `angarium:install` generator that writes the initializer, document installation/usage in the README, and add a CHANGELOG. Buyer-facing polish.

**Files:**
- Create: `lib/generators/angarium/install/install_generator.rb`
- Create: `lib/generators/angarium/install/templates/initializer.rb`
- Modify: `README.md`
- Create: `CHANGELOG.md`
- Create: `test/generators/angarium/install_generator_test.rb`

**Acceptance Criteria:**
- [ ] `bin/rails g angarium:install` writes `config/initializers/angarium.rb` in a host app.
- [ ] README documents: install, `db:migrate` via `angarium:install:migrations`, adding the `has_many` on an owner, `Angarium.dispatch`, and receiver-side `Signature.verify`.
- [ ] Generator test passes.

**Verify:** `bin/rails test test/generators/angarium/install_generator_test.rb` → PASS

**Steps:**

- [ ] **Step 1: Write the generator test**

Create `test/generators/angarium/install_generator_test.rb`:

```ruby
require "test_helper"
require "rails/generators"
require "generators/angarium/install/install_generator"

class Angarium::InstallGeneratorTest < Rails::Generators::TestCase
  tests Angarium::Generators::InstallGenerator
  destination File.expand_path("../../tmp/generator", __dir__)
  setup :prepare_destination

  test "creates the initializer" do
    run_generator
    assert_file "config/initializers/angarium.rb", /Angarium.configure/
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/generators/angarium/install_generator_test.rb`
Expected: FAIL — cannot load `install_generator`.

- [ ] **Step 3: Implement the generator**

Create `lib/generators/angarium/install/install_generator.rb`:

```ruby
require "rails/generators/base"

module Angarium
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates an Angarium initializer in config/initializers."

      def copy_initializer
        template "initializer.rb", "config/initializers/angarium.rb"
      end
    end
  end
end
```

Create `lib/generators/angarium/install/templates/initializer.rb`:

```ruby
Angarium.configure do |config|
  # ActiveJob queue used for webhook deliveries.
  # config.job_queue = :default

  # HTTP read timeout (seconds) per delivery attempt.
  # config.http_timeout = 10

  # Backoff schedule between retries. Length = number of retries.
  # config.retry_schedule = [1.minute, 5.minutes, 30.minutes, 2.hours, 5.hours]

  # Header used to carry the HMAC signature.
  # config.signature_header = "X-Angarium-Signature"

  # Reject endpoint URLs that resolve to private/loopback addresses (SSRF guard).
  # config.block_private_ips = true
end
```

- [ ] **Step 4: Run generator test**

Run: `bin/rails test test/generators/angarium/install_generator_test.rb`
Expected: PASS (1 run).

- [ ] **Step 5: Write the README**

Replace `README.md` with:

````markdown
# Angarium

Outbound webhooks for Rails: signed, retried, subscription-based delivery.

Angarium is a mountable Rails engine that delivers outbound webhooks with HMAC
request signing, automatic retries with exponential backoff, and per-endpoint
event subscriptions.

## Installation

Add to your Gemfile:

```ruby
gem "angarium"
```

Then:

```bash
bundle install
bin/rails angarium:install:migrations
bin/rails g angarium:install
bin/rails db:migrate
```

## Setup

Associate webhook endpoints with any "owner" model (an account, team, or user):

```ruby
class Account < ApplicationRecord
  has_many :webhook_endpoints, as: :owner, class_name: "Angarium::Endpoint"
end
```

Create an endpoint (the `signing_secret` is generated automatically):

```ruby
account.webhook_endpoints.create!(
  name: "Production",
  url: "https://example.com/webhooks",
  subscribed_events: ["invoice.*", "user.created"] # exact, "prefix.*", or "*"
)
```

## Dispatching events

```ruby
Angarium.dispatch("invoice.paid", { id: 123, total: 4200 }, owner: account)
```

This creates one delivery per active, subscribed endpoint and enqueues an
ActiveJob per delivery. Each request is a JSON envelope:

```json
{ "id": 42, "event": "invoice.paid", "created_at": "2026-07-04T12:00:00Z", "data": { "id": 123, "total": 4200 } }
```

## Verifying signatures (receiver side)

Every request carries `X-Angarium-Signature: t=<ts>,v1=<hmac_sha256>`. Verify it
with the endpoint's `signing_secret`:

```ruby
Angarium::Signature.verify(
  payload: request.raw_post,
  header:  request.headers["X-Angarium-Signature"],
  secret:  endpoint.signing_secret
) # => true / false
```

## Configuration

See `config/initializers/angarium.rb` (written by the install generator) for all
options: `job_queue`, `http_timeout`, `retry_schedule`, `signature_header`, and
`block_private_ips`.

## License

MIT.
````

- [ ] **Step 6: Write the CHANGELOG**

Create `CHANGELOG.md`:

```markdown
# Changelog

## [0.1.0] - Unreleased

### Added
- Mountable engine with `Angarium::Endpoint`, `Event`, `Delivery`, `DeliveryAttempt`.
- `Angarium.dispatch` event fan-out to active, subscribed endpoints.
- HMAC request signing and `Angarium::Signature.verify` helper.
- ActiveJob-based delivery with retries and exponential backoff.
- SSRF-aware endpoint URL validation.
- Install generator and migrations.
```

- [ ] **Step 7: Run the whole suite**

Run: `bin/rails test`
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Add install generator, README, and CHANGELOG"
```

---

## Self-Review notes

- **Spec coverage:** owned polymorphic Endpoint (T1–2), HMAC signing (T3, T5), dispatch/subscriptions (T2, T4), retry+backoff (T6), ActiveJob delivery (T5), SSRF (T2), Minitest+WebMock (all), packaging/install (T0, T7). All spec sections map to a task.
- **Type consistency:** `Client::Result#success?`, `Delivery` states `%w[pending delivering succeeded exhausted]`, `Signature.sign/verify`, `EventMatcher.match?`, `Dispatch.call` used consistently across tasks.
- **Verification requirement scan:** the prompt asks to build/package a gem — no human-in-the-loop verification requested. **NO.** No verification task required.

---

## Addendum — mid-execution changes (2026-07-04)

Requested during execution; these supersede the original Task 2 SSRF text.

### DB switched to SQLite
Dummy app uses SQLite; JSON columns use `t.json`. Rebuild the dummy DB with
`bin/rails db:migrate` run from the **engine root** (not `test/dummy`) so engine
migrations are picked up.

### Task 3b — `Angarium::AddressPolicy` + per-endpoint SSRF controls
Two new endpoint columns (inlined in the endpoints `create_table`):
`allow_private_network:boolean default false`, `allowed_networks:json default []`.

`Angarium::AddressPolicy.ip_allowed?(ip, endpoint)` — **two independent gates,
both must pass:**
1. **Private denylist:** private/loopback/link-local IPs are blocked unless
   `endpoint.allow_private_network` is set (master switch: `config.block_private_ips`).
   An allowlist entry alone does NOT unlock a private IP.
2. **Allowlist:** when `endpoint.allowed_networks` is non-empty, the IP must fall
   within one of those CIDRs. The allowlist can only narrow, never widen past the
   private block.

To deliver to a private address you need **both** `allow_private_network: true`
**and** (if using an allowlist) that range in `allowed_networks`.

The save-time validator delegates to `AddressPolicy.host_permitted_for_validation?`
(lenient: unresolvable hosts pass, re-checked at delivery).

### Task 5 — delivery-time enforcement
The deliver path must enforce `AddressPolicy` on the destination at delivery
time (closing the DNS-rebinding TOCTOU gap left by save-time validation only).
Preferred mechanism: a custom HTTPX resolver that rejects disallowed IPs at
connect time (validate == pin); disable redirects on the delivery client. If the
resolver integration proves impractical, fall back to a pre-flight
`AddressPolicy` re-check in the job before POST and document the residual
sub-second window. A blocked destination records a `DeliveryAttempt` with an
error and does not deliver.

### Task 7 — README security section
Document the three controls (`config.block_private_ips`,
`endpoint.allow_private_network`, `endpoint.allowed_networks`), the precedence,
the "private needs the flag even if allowlisted" rule, and the DNS-rebinding /
IP-pinning limitation with the v2 hardening note.
