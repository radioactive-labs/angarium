# Angarium Instrumentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Emit two Rails-native `ActiveSupport::Notifications` events (`deliver.angarium`, `dispatch.angarium`) so hosts can wire delivery metrics/tracing into their own backend.

**Architecture:** Wrap the body of `Angarium::Delivery#deliver!` and `Angarium::Dispatch.call` in `ActiveSupport::Notifications.instrument`, mutating a payload hash to record the outcome and fields before each return. Purely additive — the existing callbacks and `DeliveryAttempt` rows are untouched. No new config, no new dependency.

**Tech Stack:** Rails 7.1–8.1, `ActiveSupport::Notifications`, Minitest.

**User Verification:** NO — no user verification required.

**Spec:** `docs/superpowers/specs/2026-07-06-instrumentation-design.md`

---

## File Structure

- `app/models/angarium/delivery.rb` — wrap `deliver!` (the only behavior change for event #1).
- `lib/angarium/dispatch.rb` — wrap `Dispatch.call` (event #2).
- `test/models/angarium/delivery_instrumentation_test.rb` — new; asserts one `deliver.angarium` per outcome + payload safety.
- `test/lib/angarium/dispatch_instrumentation_test.rb` — new; asserts `dispatch.angarium` fan-out count.
- `README.md` — new `## Instrumentation` section.

---

### Task 1: Instrument `deliver.angarium`

**Goal:** `Delivery#deliver!` emits one `deliver.angarium` event per call, carrying the outcome and per-attempt fields, for all seven outcomes.

**Files:**
- Modify: `app/models/angarium/delivery.rb` (the `deliver!` method, currently lines 44–124)
- Test: `test/models/angarium/delivery_instrumentation_test.rb` (create)

**Acceptance Criteria:**
- [ ] `deliver.angarium` fires exactly once per `deliver!` call.
- [ ] `outcome` is one of `delivered|failed|gone|held|canceled|blocked|unresolvable`, matching the branch taken.
- [ ] `code`/`http_duration` present only when an HTTP request went out; `attempt` present except for `held`/`canceled`.
- [ ] Payload never contains the signing secret or response body.
- [ ] The method's return values are unchanged (nil for held; the `DeliveryAttempt` otherwise).

**Verify:** `bin/rails test test/models/angarium/delivery_instrumentation_test.rb` → all pass

**Steps:**

- [ ] **Step 1: Write the failing test**

Create `test/models/angarium/delivery_instrumentation_test.rb`:

```ruby
require "test_helper"

class Angarium::DeliveryInstrumentationTest < ActiveSupport::TestCase
  setup do
    @owner = Owner.create!(name: "Acme")
    @endpoint = Angarium::Endpoint.create!(
      owner: @owner, name: "e", url: "https://203.0.113.10/hook",
      signing_secret: "whsec_c2VjcmV0", subscribed_events: ["*"]
    )
    @event = Angarium::Event.create!(name: "invoice.paid", payload: {"id" => 1})
  end

  def create_delivery
    Angarium::Delivery.create!(event: @event, endpoint: @endpoint)
  end

  def client_returning(success:, code:, body: "ok", headers: {})
    FakeAngariumClient.new(
      Angarium::Client::Result.new(success: success, code: code, body: body, duration: 0.05, headers: headers)
    )
  end

  # Capture every deliver.angarium payload emitted while the block runs.
  def capture_deliver
    events = []
    sub = ->(_name, _start, _finish, _id, payload) { events << payload }
    ActiveSupport::Notifications.subscribed(sub, "deliver.angarium") { yield }
    events
  end

  test "delivered: 2xx emits outcome delivered with code and http_duration" do
    events = capture_deliver { create_delivery.deliver!(client: client_returning(success: true, code: 200)) }
    assert_equal 1, events.size
    p = events.first
    assert_equal :delivered, p[:outcome]
    assert_equal 200, p[:code]
    assert_equal 0.05, p[:http_duration]
    assert_equal 1, p[:attempt]
    assert_equal "invoice.paid", p[:event]
    assert_equal @endpoint.id, p[:endpoint_id]
  end

  test "failed: non-2xx emits outcome failed" do
    events = capture_deliver { create_delivery.deliver!(client: client_returning(success: false, code: 500, body: "boom")) }
    assert_equal :failed, events.first[:outcome]
    assert_equal 500, events.first[:code]
  end

  test "gone: 410 emits outcome gone" do
    events = capture_deliver { create_delivery.deliver!(client: client_returning(success: false, code: 410)) }
    assert_equal :gone, events.first[:outcome]
    assert_equal 410, events.first[:code]
  end

  test "held: paused endpoint emits outcome held with no attempt or code" do
    @endpoint.pause!
    events = capture_deliver { create_delivery.deliver!(client: client_returning(success: true, code: 200)) }
    p = events.first
    assert_equal :held, p[:outcome]
    assert_nil p[:attempt]
    assert_nil p[:code]
  end

  test "canceled: disabled endpoint emits outcome canceled" do
    @endpoint.update!(status: "disabled")
    events = capture_deliver { create_delivery.deliver!(client: client_returning(success: true, code: 200)) }
    assert_equal :canceled, events.first[:outcome]
    assert_nil events.first[:code]
  end

  test "blocked: disallowed resolved address emits outcome blocked, no code" do
    events = capture_deliver do
      Angarium::AddressPolicy.stub(:resolve, [IPAddr.new("10.0.0.1")]) do
        create_delivery.deliver!(client: client_returning(success: true, code: 200))
      end
    end
    p = events.first
    assert_equal :blocked, p[:outcome]
    assert_equal 1, p[:attempt]
    assert_nil p[:code]
    assert_match(/not permitted/, p[:error])
  end

  test "unresolvable: empty resolution emits outcome unresolvable" do
    events = capture_deliver do
      Angarium::AddressPolicy.stub(:resolve, []) do
        create_delivery.deliver!(client: client_returning(success: true, code: 200))
      end
    end
    assert_equal :unresolvable, events.first[:outcome]
    assert_nil events.first[:code]
  end

  test "payload never leaks the signing secret or response body" do
    events = capture_deliver { create_delivery.deliver!(client: client_returning(success: true, code: 200, body: "secret-body")) }
    dumped = events.first.inspect
    refute_match(/whsec_/, dumped)
    refute_match(/secret-body/, dumped)
  end

  test "return value is unchanged: held returns nil, delivered returns the attempt" do
    @endpoint.pause!
    assert_nil create_delivery.deliver!(client: client_returning(success: true, code: 200))
    @endpoint.enable!
    result = create_delivery.deliver!(client: client_returning(success: true, code: 200))
    assert_kind_of Angarium::DeliveryAttempt, result
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/angarium/delivery_instrumentation_test.rb`
Expected: FAIL — no `deliver.angarium` events captured (`events` empty), so `assert_equal 1, events.size` fails.

- [ ] **Step 3: Wrap `deliver!` in instrumentation**

In `app/models/angarium/delivery.rb`, replace the `deliver!` method body with the version below. Only additions are the `payload` hash, the `instrument` block, and the `payload[:...] =` assignments; the existing logic is unchanged.

```ruby
    def deliver!(client: Client.new, force: false)
      payload = {delivery_id: id, endpoint_id: endpoint_id, event: event.name, force: force}
      ActiveSupport::Notifications.instrument("deliver.angarium", payload) do
        unless force
          if endpoint.paused?
            payload[:outcome] = :held
            return hold_for_pause!
          end
          unless endpoint.enabled?
            payload[:outcome] = :canceled
            return cancel!(reason: endpoint.status)
          end
        end

        update!(state: "delivering", attempt_count: attempt_count + 1, last_attempt_at: Time.current)
        payload[:attempt] = attempt_count

        addresses = AddressPolicy.resolve(destination_host)

        if addresses.any? { |ip| !AddressPolicy.ip_allowed?(ip, endpoint) }
          payload[:outcome] = :blocked
          payload[:error] = "blocked: destination address not permitted"
          attempt = delivery_attempts.create!(error: payload[:error])
          update!(state: "blocked", next_attempt_at: nil)
          endpoint.record_delivery_failure!
          return attempt
        end

        if addresses.empty?
          payload[:outcome] = :unresolvable
          payload[:error] = "unresolvable host: #{destination_host}"
          attempt = delivery_attempts.create!(error: payload[:error])
          handle_failure!
          return attempt
        end

        body = request_body
        ts = Time.now.to_i
        webhook_id = id.to_s
        signature = Signature.sign(payload: body, id: webhook_id, timestamp: ts, secret: endpoint.active_signing_secrets)
        headers = (endpoint.custom_headers || {}).merge(
          "webhook-id" => webhook_id,
          "webhook-timestamp" => ts.to_s,
          "webhook-signature" => signature
        )
        result = client.post(endpoint.url, body: body, headers: headers, addresses: addresses.map(&:to_s))

        attempt = delivery_attempts.create!(
          response_code: result.code,
          response_body: result.body,
          error: result.error,
          duration: result.duration
        )
        payload[:code] = result.code
        payload[:http_duration] = result.duration
        payload[:error] = result.error

        if result.success?
          payload[:outcome] = :delivered
          succeed!
        elsif result.code == 410
          payload[:outcome] = :gone
          handle_gone!
        else
          payload[:outcome] = :failed
          handle_failure!(retry_after: retry_after_seconds(result.headers))
        end
        attempt
      end
    end
```

Note: keep the existing explanatory comments from the current method (the DNS-rebinding, fail-closed, and status-handling notes) — reattach them to the corresponding branches inside the block.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/models/angarium/delivery_instrumentation_test.rb`
Expected: PASS (all 9 tests).

- [ ] **Step 5: Run the full delivery suite to confirm no regressions**

Run: `bin/rails test test/models/angarium/delivery_features_test.rb test/models/angarium/delivery_retry_test.rb test/jobs/angarium/deliver_job_test.rb`
Expected: PASS (return values and behavior unchanged).

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/models/angarium/delivery.rb test/models/angarium/delivery_instrumentation_test.rb
git add app/models/angarium/delivery.rb test/models/angarium/delivery_instrumentation_test.rb
git commit -m "feat: emit deliver.angarium instrumentation per delivery attempt"
```

---

### Task 2: Instrument `dispatch.angarium`

**Goal:** `Angarium::Dispatch.call` emits one `dispatch.angarium` event carrying the event name, created event id, and fan-out count (including 0 when nothing matched).

**Files:**
- Modify: `lib/angarium/dispatch.rb`
- Test: `test/lib/angarium/dispatch_instrumentation_test.rb` (create)

**Acceptance Criteria:**
- [ ] `dispatch.angarium` fires once per `Angarium.dispatch` call.
- [ ] `deliveries` equals the number of subscribed endpoints fanned out to.
- [ ] On no match, `deliveries` is `0` and `event_id` is `nil` (and `dispatch` still returns `nil`).

**Verify:** `bin/rails test test/lib/angarium/dispatch_instrumentation_test.rb` → all pass

**Steps:**

- [ ] **Step 1: Write the failing test**

Create `test/lib/angarium/dispatch_instrumentation_test.rb`:

```ruby
require "test_helper"

class Angarium::DispatchInstrumentationTest < ActiveSupport::TestCase
  setup { @owner = Owner.create!(name: "Acme") }

  def make_endpoint(events)
    Angarium::Endpoint.create!(
      owner: @owner, name: "e#{events.hash}", url: "https://203.0.113.10/hook",
      signing_secret: "whsec_c2VjcmV0", subscribed_events: events
    )
  end

  def capture_dispatch
    events = []
    sub = ->(_n, _s, _f, _i, payload) { events << payload }
    ActiveSupport::Notifications.subscribed(sub, "dispatch.angarium") { yield }
    events
  end

  test "emits deliveries count equal to the fan-out size" do
    make_endpoint(["*"])
    make_endpoint(["invoice.paid"])
    make_endpoint(["other.event"]) # not subscribed -> excluded

    events = capture_dispatch { Angarium.dispatch("invoice.paid", {"id" => 1}, owner: @owner) }

    assert_equal 1, events.size
    p = events.first
    assert_equal "invoice.paid", p[:event]
    assert_equal 2, p[:deliveries]
    assert_not_nil p[:event_id]
  end

  test "emits deliveries 0 and nil event_id when nothing matches" do
    make_endpoint(["other.event"])
    result = nil
    events = capture_dispatch { result = Angarium.dispatch("invoice.paid", {"id" => 1}, owner: @owner) }

    assert_nil result, "dispatch still returns nil on no match"
    assert_equal 0, events.first[:deliveries]
    assert_nil events.first[:event_id]
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/angarium/dispatch_instrumentation_test.rb`
Expected: FAIL — no `dispatch.angarium` events captured.

- [ ] **Step 3: Wrap `Dispatch.call` in instrumentation**

Replace the `call` method in `lib/angarium/dispatch.rb`:

```ruby
    def call(event_name, payload, owner:)
      notify_payload = {event: event_name, event_id: nil, deliveries: 0}
      ActiveSupport::Notifications.instrument("dispatch.angarium", notify_payload) do
        endpoints = Endpoint.enabled.where(owner: owner).select do |endpoint|
          endpoint.subscribed_to?(event_name)
        end
        next nil if endpoints.empty?

        Event.transaction do
          event = Event.create!(name: event_name, payload: payload)
          endpoints.each { |endpoint| event.deliveries.create!(endpoint: endpoint) }
          notify_payload[:event_id] = event.id
          notify_payload[:deliveries] = endpoints.size
          event
        end
      end
    end
```

Note: use `next nil` (not `return nil`) inside the `instrument` block so the block yields `nil` as the dispatch result while the event still finishes with `deliveries: 0`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/angarium/dispatch_instrumentation_test.rb`
Expected: PASS (both tests).

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb lib/angarium/dispatch.rb test/lib/angarium/dispatch_instrumentation_test.rb
git add lib/angarium/dispatch.rb test/lib/angarium/dispatch_instrumentation_test.rb
git commit -m "feat: emit dispatch.angarium instrumentation with fan-out count"
```

---

### Task 3: Document instrumentation in the README

**Goal:** A `## Instrumentation` section listing both events, their payloads, and a `subscribe` example, framed as the metrics leg beside callbacks and the audit trail.

**Files:**
- Modify: `README.md` (add a section; place it after `## Delivery guarantees`, before `## Configuration`)

**Acceptance Criteria:**
- [ ] Both events and all payload keys are documented.
- [ ] A runnable `ActiveSupport::Notifications.subscribe` example is shown.
- [ ] No em-dash / en-dash / ellipsis characters (repo convention).

**Verify:** `grep -n "—\|–\|…" README.md` → no matches; `grep -n "deliver.angarium" README.md` → present

**Steps:**

- [ ] **Step 1: Add the section**

Insert into `README.md` after the `## Delivery guarantees` section:

````markdown
## Instrumentation

Angarium emits `ActiveSupport::Notifications` events so you can feed delivery
metrics and traces into your own backend (StatsD, Prometheus, OpenTelemetry, or
structured logs). This is the metrics leg beside the notification callbacks
(alerting) and the `DeliveryAttempt` rows (audit); it is off unless you subscribe.

**`deliver.angarium`** fires once per delivery attempt:

| Key | Notes |
| --- | --- |
| `delivery_id`, `endpoint_id` | ids |
| `event` | the event name being delivered |
| `outcome` | `delivered` \| `failed` \| `gone` \| `held` \| `canceled` \| `blocked` \| `unresolvable` |
| `attempt` | attempt number (absent for `held`/`canceled`) |
| `code` | HTTP status, when a response was received |
| `http_duration` | wire time in seconds, when a request went out |
| `error` | exception class + message, on `failed`/`blocked`/`unresolvable` |
| `force` | whether the status guard was bypassed |

**`dispatch.angarium`** fires once per `Angarium.dispatch`: `event`, `event_id`,
and `deliveries` (fan-out count).

Payloads carry ids, codes, and timings only, never the signing secret or the
request/response body, so they are safe to ship to third-party backends.

```ruby
ActiveSupport::Notifications.subscribe("deliver.angarium") do |*, payload|
  StatsD.increment("webhooks.delivery.#{payload[:outcome]}")
  StatsD.histogram("webhooks.delivery.ms", payload[:http_duration] * 1000) if payload[:http_duration]
end
```
````

- [ ] **Step 2: Verify formatting and commit**

```bash
grep -n "—\|–\|…" README.md || echo "clean"
git add README.md
git commit -m "docs: document ActiveSupport::Notifications instrumentation"
```

---

## Self-Review

**1. Spec coverage:** `deliver.angarium` (Task 1) and `dispatch.angarium` (Task 2) with the exact payloads from the spec; all 7 outcomes tested; secret/body exclusion tested; README section (Task 3). Covered.

**2. Placeholder scan:** No TBD/TODO; every code block is complete.

**3. Type consistency:** `outcome` symbols, payload keys (`delivery_id`, `endpoint_id`, `event`, `outcome`, `attempt`, `code`, `http_duration`, `error`, `force`; `event_id`, `deliveries`) are identical across spec, implementation, tests, and README.

**4. Verification requirement scan:** The prompt ("add rails instrumentation") requests no user verification, confirmation, or human sign-off. Answer: NO. No verification task required.
