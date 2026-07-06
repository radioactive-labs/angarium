# Angarium — Outbound Webhooks Engine

**Status:** Design approved · **Date:** 2026-07-04 · **Author:** TheDumbTechGuy (sfroelich01@gmail.com)

Angarium is a standalone, sellable Rails engine for **outbound webhooks**. It is
extracted from the in-repo `packages/webhooks` Plutonium package of the Vulcan
app, then decoupled from Plutonium and the host application so that *any* Rails
app can install it.

The name is the [angarium](https://en.wikipedia.org/wiki/Angarium) — the ancient
Persian royal courier-relay network, history's first large-scale event-dispatch
system.

## Goals

- A framework-agnostic, mountable Rails engine any Rails ≥ 7.1 app can install.
- Headless v1: models + dispatch pipeline + HTTP delivery + retries + signing.
  **No UI in v1**, but structured (mountable, `isolate_namespace`, asset path)
  so a UI add-on drops in later with no rework.
- Reliable, secure delivery: HMAC request signing, automatic retries with
  exponential backoff, and per-endpoint event subscriptions.
- The gem **owns its own endpoint model** (unlike the origin, which relied on the
  host's `ClientWebhookEndpoint`), attached to the buyer's app via a polymorphic
  `owner`.

## Non-goals (v1)

- No UI / admin screens (deferred; engine is structured to accept one later).
- No Plutonium dependency, no policies/presenters/query-objects/resource-controllers.
- No inbound webhooks (receiving) — outbound only.
- Not converting the Vulcan host app to consume the gem this round. Deliverable
  is the standalone gem only; `packages/webhooks` in Vulcan is left untouched.

## Decisions (locked)

| Decision | Choice |
|----------|--------|
| Target market | Any Rails ≥ 7.1 app (Ruby ≥ 3.2) |
| Engine style | Mountable, `isolate_namespace Angarium` |
| Background jobs | **ActiveJob** (buyer's adapter), not Sidekiq |
| HTTP client | HTTPX |
| State handling | Plain `state` string column + explicit transitions — **drop the `state_machine` gem** |
| Endpoint owner | Polymorphic `owner` |
| Test framework | **Minitest** + WebMock, against `test/dummy` |
| SSRF protection | On by default (validator + delivery-time guard) |
| Location | `/Users/stefan/Documents/radioactive_labs/angarium` (own git repo) |

## Architecture

### Data model

Four tables, all `angarium_`-prefixed (free via `isolate_namespace`):

| Model | Origin | Key columns |
|-------|--------|-------------|
| `Angarium::Endpoint` | host `ClientWebhookEndpoint` | `owner_type`, `owner_id` (polymorphic), `name`, `url`, `active`, `signing_secret`, `subscribed_events` (jsonb array) |
| `Angarium::Event` | `Webhooks::Outbound::Event` | `name` (was `event`), `payload` (jsonb) |
| `Angarium::Delivery` | `Webhooks::Outbound::EventDispatch` | `event_id` (FK), `endpoint_id` (FK, real not polymorphic), `state`, `attempt_count`, `last_attempt_at`, `next_attempt_at` |
| `Angarium::DeliveryAttempt` | `Webhooks::Outbound::EventDispatchAttempt` | `delivery_id` (FK), `response_code`, `response_body` (truncated), `error`, `duration` |

- `Endpoint` `belongs_to :owner, polymorphic: true`. Buyer adds
  `has_many :webhook_endpoints, as: :owner, class_name: "Angarium::Endpoint"` to
  any model (Account, Client, User).
- `signing_secret` auto-generates on create (`SecureRandom`).
- `Event has_many :deliveries`; `Delivery has_many :delivery_attempts`;
  `Delivery belongs_to :event, :endpoint`.

### Base classes

- `Angarium::ApplicationRecord` (abstract) — the engine's own AR base, replacing
  the origin's `Webhooks::ResourceRecord < ::ResourceRecord`. No Plutonium.
- `Angarium::ApplicationJob < ActiveJob::Base`.

### Public API (the entire surface a buyer touches)

```ruby
# Fire an event. Resolves this owner's active endpoints subscribed to the event
# name, creates one Event + N Deliveries, enqueues a delivery job per Delivery.
Angarium.dispatch("invoice.paid", { id: 123, total: 4200 }, owner: current_account)

# Receiver-side verification helper, shipped in the gem:
Angarium::Signature.verify(
  payload: request.raw_post,
  header:  request.headers["X-Angarium-Signature"],
  secret:  endpoint_signing_secret
) # => true / false
```

Retries, signing, and backoff are automatic — not part of the caller's surface.

### Delivery pipeline

`Angarium.dispatch` →
1. Resolve the owner's `active` endpoints whose `subscribed_events` match the
   event name.
2. In a transaction: create the `Event`, then a `Delivery` per matching endpoint.
3. Each `Delivery`, on `after_create_commit`, enqueues `Angarium::DeliverJob`
   (ActiveJob) on the configured queue.

`Angarium::DeliverJob#perform(delivery_id)`:
1. Transition `Delivery` `pending → delivering`.
2. POST the JSON payload to `endpoint.url` via HTTPX with the signature header
   `X-Angarium-Signature: t=<ts>,v1=<hex(hmac_sha256(secret, "#{ts}.#{body}"))>`.
3. Record a `DeliveryAttempt` (response code, truncated body, duration, or error).
4. On 2xx → `Delivery` → `succeeded`.
   On failure → if attempts remain, set `next_attempt_at`, transition back to
   `pending`, and re-enqueue with `wait:` = next backoff interval; else →
   `exhausted`.

**State machine** (plain column, explicit methods):
`pending → delivering → succeeded | exhausted`, with `delivering → pending`
between retries.

**Retry/backoff:** configurable schedule, default
`[1.minute, 5.minutes, 30.minutes, 2.hours, 5.hours]` (5 retries). Driven
explicitly by the job (self-reschedule) rather than ActiveJob `retry_on`, so the
full attempt history lives in the DB and is inspectable.

### Security

- **HMAC signing:** per-endpoint `signing_secret`; signature over
  `"#{timestamp}.#{body}"` with `hmac_sha256`. `Angarium::Signature.verify`
  ships for receivers, with a timestamp-tolerance check to resist replay.
- **SSRF protection:** the endpoint URL validator (ported from the origin's
  `webhook_url_validator`) enforces `https` and, when `block_private_ips` is on
  (default), rejects private/loopback/link-local ranges at both validation time
  and delivery time.

### Event subscriptions

`endpoint.subscribed_events` is a jsonb array supporting:
- exact names (`"invoice.paid"`),
- prefix wildcards (`"invoice.*"`),
- catch-all (`"*"`).

Dispatch delivers only to `active` endpoints whose subscriptions match.

### Configuration

```ruby
Angarium.configure do |c|
  c.job_queue         = :default
  c.http_timeout      = 10
  c.user_agent        = "Angarium/#{Angarium::VERSION}"
  c.retry_schedule    = [1.minute, 5.minutes, 30.minutes, 2.hours, 5.hours]
  c.signature_header  = "X-Angarium-Signature"
  c.block_private_ips = true
end
```

## Packaging & install

- Mountable-engine install flow:
  - `bin/rails angarium:install:migrations` to copy migrations.
  - An `angarium:install` generator that writes the initializer (and mounts the
    engine — needed only once a UI exists; v1 requires no routes).
- Gemspec modeled on the `ahoy_matey` / `dspy.rb` convention (author
  `TheDumbTechGuy`, MIT license, private `allowed_push_host`).
- `Angarium::VERSION` starts at `0.1.0`.
- **Runtime deps:** `rails (>= 7.1)`, `httpx`.
- **Dev deps:** `test/dummy` app (SQLite; `json` columns, Ruby-side subscription
  matching), `minitest`, `webmock`.

## Testing strategy

Minitest against a `test/dummy` Rails app (SQLite). WebMock stubs endpoint
HTTP. Coverage of the public API and pipeline:
- `dispatch` fan-out (event + N deliveries for matching endpoints only),
- subscription matching (exact / prefix / catch-all / non-match),
- signature header correctness + `Signature.verify` round-trip,
- retry rescheduling and backoff, exhaustion after max attempts,
- SSRF rejection (validation + delivery),
- state transitions,
- `DeliveryAttempt` recording (success, non-2xx, network error).

## Scaffold status

The mountable engine has already been generated at the target path with
`isolate_namespace Angarium`, Minitest, and skipped
ActionCable/ActiveStorage/ActionMailer/JavaScript. The dummy app was
reconfigured to use SQLite. Remaining work is captured in the implementation
plan.

## Origin mapping (for reference)

| Origin (`packages/webhooks`) | Angarium |
|------------------------------|----------|
| `Webhooks::Outbound::Event` | `Angarium::Event` |
| `Webhooks::Outbound::EventDispatch` | `Angarium::Delivery` |
| `Webhooks::Outbound::EventDispatchAttempt` | `Angarium::DeliveryAttempt` |
| host `ClientWebhookEndpoint` (polymorphic target) | `Angarium::Endpoint` (owned, polymorphic `owner`) |
| `Webhooks::Outbound::Dispatcher` (HTTPX) | delivery logic in `Angarium::DeliverJob` + `Angarium::Delivery` |
| `Webhooks::ProcessEventDispatchJob` (Sidekiq) | `Angarium::DeliverJob` (ActiveJob) |
| `webhook_url_validator` | `Angarium::EndpointUrlValidator` (+ SSRF guard) |
| `state_machine` gem | plain `state` column + explicit transitions |
| Plutonium policies/presenters/query-objects/controllers | **dropped** (UI deferred) |
