# Angarium

[![CI](https://github.com/radioactive-labs/angarium/actions/workflows/ci.yml/badge.svg)](https://github.com/radioactive-labs/angarium/actions/workflows/ci.yml)
[![Standard Webhooks](https://img.shields.io/badge/Standard%20Webhooks-compliant-3068b7)](https://www.standardwebhooks.com)

Outbound webhooks for Rails: signed, retried, subscription-based delivery.

Angarium is a Rails engine that delivers outbound webhooks with HMAC
request signing, automatic retries with exponential backoff, per-endpoint event
subscriptions, and SSRF protection. It works with any ActiveJob backend and any
Rails 7.1+ app. It's headless in v1 — no routes or UI, just models and jobs —
but namespaced via `isolate_namespace`, so a UI can be mounted on top later.

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
```

### Required: Active Record Encryption

Angarium encrypts each endpoint's `signing_secret` at rest. Configure Active
Record Encryption keys before using the gem:

```bash
bin/rails db:encryption:init
```

Add the generated keys to your credentials (`config/credentials.yml.enc`) or
set `config.active_record.encryption.{primary_key,deterministic_key,key_derivation_salt}`.
See the [Rails guide on Active Record Encryption](https://guides.rubyonrails.org/active_record_encryption.html).

```bash
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

This creates one delivery per enabled, subscribed endpoint and enqueues an
ActiveJob per delivery. Each request is a JSON envelope:

```json
{ "id": 42, "event": "invoice.paid", "created_at": "2026-07-04T12:00:00Z", "data": { "id": 123, "total": 4200 } }
```

## Verifying signatures (receiver side)

**Angarium signs webhooks using the [Standard Webhooks](https://www.standardwebhooks.com)
specification**, so receivers can verify them with the official
[`standardwebhooks` libraries](https://github.com/standard-webhooks/standard-webhooks/tree/main/libraries)
in any language (Ruby, Python, JavaScript, Go, Rust, PHP, Java, …) — no
Angarium-specific code required. Conformance is enforced in CI: signed requests
are verified with the official `standardwebhooks` Ruby library, so any drift from
the spec fails the build.

Every request carries three headers:

| Header | Value |
| --- | --- |
| `webhook-id` | Unique, retry-stable message id — the delivery's `id`, the **same value** as the envelope's `id`. It is unique per *delivery*, not per event, so the same event delivered to two endpoints has two different ids. |
| `webhook-timestamp` | Unix seconds when the request was signed. |
| `webhook-signature` | Space-delimited list of `v1,<base64 HMAC-SHA256>` tokens (one per active signing secret). |

The signature is `HMAC-SHA256(secret_key, "{webhook-id}.{webhook-timestamp}.{body}")`,
base64-encoded, where `secret_key` is the base64-decoded portion of the
`whsec_`-prefixed `signing_secret`.

You can verify with any Standard Webhooks library, or with Angarium's own helper:

```ruby
Angarium::Signature.verify(
  payload:   request.raw_post,
  id:        request.headers["webhook-id"],
  timestamp: request.headers["webhook-timestamp"],
  signature: request.headers["webhook-signature"],
  secret:    endpoint.signing_secret
) # => true / false
```

`verify` also enforces a timestamp tolerance (default 300s) to resist replay.

The secret (a `whsec_…` string) is stored encrypted at rest and is only
decrypted in memory when signing; `endpoint.signing_secret` returns the
plaintext, so deliver it to receivers over a secure channel.

### Rotating a signing secret (zero-downtime)

Rotate a secret with `endpoint.rotate_signing_secret!` (returns the new
plaintext). During a grace window (`config.signing_secret_grace_period`, default
`24.hours`) every delivery is signed with **both** the new and the previous
secret — the `webhook-signature` header carries multiple space-delimited `v1,`
tokens:

```
webhook-signature: v1,<new_sig> v1,<previous_sig>
```

Verification succeeds if the payload matches **any** token in the header (the
Standard Webhooks libraries already do this), so a receiver still holding the
old secret keeps validating while you roll it over, and one holding the new
secret validates immediately. Once the grace period elapses, deliveries are
signed with the new secret only. This lets receivers update their copy of the
secret with zero downtime and no rejected deliveries.

### Per-endpoint custom headers

Attach static headers (e.g. an `Authorization` bearer token the receiver
expects) to every request from an endpoint:

```ruby
endpoint.update!(custom_headers: { "Authorization" => "Bearer abc123" })
```

`custom_headers` must be a hash of string keys and values. The `webhook-id`,
`webhook-timestamp`, and `webhook-signature` headers always win, so a custom
header can never override or spoof them. In the same spirit, reserved and
transport headers (`webhook-id`, `webhook-timestamp`, `webhook-signature`,
`host`, `content-length`, `content-type`, `transfer-encoding`, `connection`)
are rejected at validation (case-insensitively) and can't be overridden.

## Retries

Failed deliveries (non-2xx or connection errors) are retried on the schedule in
`config.retry_schedule`. The default is the [Standard Webhooks](https://www.standardwebhooks.com)
recommended schedule — twelve retries spanning ~10 days (`5s, 5m, 30m, 2h, 5h,
10h, 14h, 20h, 24h, 36h, 48h, 72h`, after an immediate first delivery). Every
attempt is recorded as an `Angarium::DeliveryAttempt`. After the schedule is
exhausted the delivery is marked `exhausted`.

Each `DeliveryAttempt` stores the response body, truncated to
`config.max_response_body_bytes` bytes (default `65_536`; set `nil` to store the
full body).

### Status-code handling

Angarium follows the Standard Webhooks receiver-etiquette guidance:

| Response | Handling |
| --- | --- |
| `2xx` | Success. |
| `410 Gone` | The receiver wants no more webhooks. The **endpoint status becomes `gone`** and the delivery is marked `gone` — no retries. |
| `429`, `502`, `504` | Retryable failure — retried with backoff, honoring `Retry-After` when present (the recommended way to throttle). |
| `3xx` and everything else | Retryable failure. Redirects are **not** followed (following them loads both sides); update the endpoint URL instead. |

### Backoff jitter

Each retry delay gets a small amount of additive positive jitter
(`config.retry_jitter`, default `0.15` → up to +15%) so many deliveries failing
at once don't retry in lockstep and stampede the receiver.

### Retry-After

When a failed response carries a `Retry-After` header (seconds or an HTTP-date),
Angarium honors it — but only when it asks for a **longer** wait than the
scheduled backoff. It takes the later of the two, so a receiver's `Retry-After`
can *delay* the next attempt but never pull it *earlier* than our schedule. This
keeps a malicious or misconfigured receiver from using a tiny `Retry-After` to
defeat our backoff and make us retry aggressively. The honored value is capped at
`config.max_retry_after` (default `3600` seconds), and the whole behavior can be
disabled with `config.respect_retry_after = false`.

### Manual redelivery

Re-send any delivery — including an exhausted one — with:

```ruby
delivery.redeliver!
```

This resets the retry cycle (`state` → `pending`, `attempt_count` → 0) and
enqueues a fresh `DeliverJob`, while keeping the prior `DeliveryAttempt` history.

### Endpoint status

Every endpoint has a lifecycle `status` (only `enabled` endpoints receive
deliveries):

| Status | Meaning | Resumable? |
| --- | --- | --- |
| `enabled` | Delivering normally. | — |
| `paused` | Turned off manually (`endpoint.pause!`). | `endpoint.enable!` |
| `disabled` | Auto-disabled after too many consecutive failures. | `endpoint.enable!` |
| `gone` | The receiver returned `410 Gone`. Treat as terminal. | `endpoint.enable!` (explicit override) |

Every transition stamps `status_changed_at`. `endpoint.enable!` also clears the
failure counter. Scope enabled endpoints with `Angarium::Endpoint.enabled`.

### Auto-disabling failing endpoints

Set `config.auto_disable_endpoint_after` to a number of **consecutive** failed
deliveries after which an endpoint is automatically moved to `disabled`.
`endpoint.consecutive_failures` tracks the running count and resets to `0` on the
next successful delivery. Left `nil` (the default), endpoints are never
auto-disabled. (A `410 Gone` response moves the endpoint to `gone` immediately,
regardless of this setting.)

### Notification callbacks

When delivery fails for good, the Standard Webhooks guidance is to notify the
consumer out of band (email, Slack, PagerDuty). Angarium is headless, so it hands
you the events and lets you do the notifying via two config callbacks:

```ruby
Angarium.configure do |config|
  # A delivery has exhausted its whole retry schedule.
  config.on_delivery_exhausted = ->(delivery) do
    AdminMailer.webhook_failed(delivery).deliver_later
  end

  # An endpoint was disabled. reason is :consecutive_failures or :gone (HTTP 410).
  config.on_endpoint_disabled = ->(endpoint, reason) do
    AdminMailer.endpoint_disabled(endpoint, reason).deliver_later
  end
end
```

Both are optional. A callback that raises is logged and swallowed, so a broken
notifier never breaks delivery.

### Recovering interrupted deliveries

If a worker dies mid-delivery — crash, deploy, OOM — after a delivery is marked
`delivering` but before the attempt is recorded or rescheduled, that delivery
would otherwise be stranded (the job only re-runs `pending` deliveries). Requeue
these with a periodic reaper:

```ruby
Angarium::Delivery.reap_stalled       # requeues deliveries stuck in `delivering`
# or from cron/scheduler:  bin/rails angarium:reap
```

Anything `delivering` whose last attempt began more than
`config.delivering_timeout` ago (default `15.minutes`) is presumed abandoned and
reset to `pending`. Keep the timeout well above a single attempt's worst case
(`open_timeout + http_timeout`) so a slow-but-alive worker isn't reaped; a
redelivery is at-least-once-safe either way. Set it to `nil` to disable reaping.

### Pinging an endpoint

Verify an endpoint end-to-end by delivering a synthetic `angarium.ping` event
(subscription matching is bypassed — a ping is always sent). Returns the
`Angarium::Delivery`, so you can reload it to inspect the outcome:

```ruby
delivery = endpoint.ping!
# optionally: endpoint.ping!(message: "hello")
delivery.reload.succeeded? # => true once delivered
```

### At-least-once delivery

Delivery is **at-least-once**: a webhook may arrive more than once — a retry
after a receiver processed the request but the response was lost, or a rare
duplicate job enqueue. **Make your receivers idempotent**: dedupe on the
envelope's `id` (stable across every attempt of the same delivery) and treat a
repeat as a no-op.

## Data retention

Every delivery attempt stores the receiver's response body (capped at
`config.max_response_body_bytes`, 64KB by default), so `angarium_delivery_attempts`
grows with delivery volume × retries — a busy app talking to a flapping receiver
can accumulate rows quickly. You have three options to keep it bounded:

```ruby
# 1. Set a retention window and prune on a schedule (cron / your scheduler):
Angarium.config.delivery_attempt_retention = 90.days
#    then run periodically:  bin/rails angarium:prune

# 2. Or prune inline, wherever you like:
Angarium::DeliveryAttempt.prune(older_than: 90.days)

# 3. Or store less per attempt by lowering the response-body cap:
Angarium.config.max_response_body_bytes = 4_096
```

## Security (SSRF protection)

Because endpoint URLs are user-supplied, Angarium guards against Server-Side
Request Forgery. Three controls, validated when an endpoint is created or when
its `url`, `allow_private_network`, or `allowed_networks` change, and re-checked
at delivery time:

- **`config.block_private_ips`** (default `true`) — blocks delivery to
  private, loopback, and link-local addresses (e.g. `127.0.0.1`, `10.0.0.0/8`,
  `169.254.169.254`), including IPv4-mapped IPv6 forms (e.g. `::ffff:127.0.0.1`)
  and the unspecified address (`0.0.0.0` / `::`).
- **`endpoint.allow_private_network`** (default `false`) — per-endpoint opt-in
  required to deliver to a private address. An allowlist entry alone does **not**
  unlock a private address.
- **`endpoint.allowed_networks`** (CIDR array) — when set, restricts this
  endpoint's deliveries to those CIDRs. It only narrows; to allow a private range
  you must also set `allow_private_network`.

> **Note:** `allow_private_network` is a privileged control. Expose it only to
> trusted operators, never to end users — otherwise it becomes an SSRF opt-in.

**Connect-time IP pinning:** the delivery-time check re-resolves the host,
rejects disallowed addresses, and then pins the connection to exactly the
validated IP(s) — HTTPX does not re-resolve or connect elsewhere, while TLS
SNI and certificate verification still use the original hostname. This closes
the DNS-rebinding window between resolution and connection. Angarium's own
resolver is the single source of truth: if it can't resolve a host, the
delivery fails (retryable) rather than falling back to an unvalidated HTTPX
resolution — so there is no unpinned path. The only cost is that hosts
resolvable *only* via non-DNS mechanisms Angarium's resolver doesn't use
(e.g. mDNS `.local`) won't be delivered to, which is not a concern for real
webhook endpoints. HTTPX does not follow redirects, so redirect-based
bypasses are already closed.

## Configuration

Run `bin/rails g angarium:install` to generate `config/initializers/angarium.rb`
with all options: `job_queue`, `http_timeout`, `open_timeout`, `user_agent`,
`retry_schedule`, `block_private_ips`, `primary_key_type`,
`max_response_body_bytes`, `auto_disable_endpoint_after`, `respect_retry_after`,
`max_retry_after`, `retry_jitter`, `signing_secret_grace_period`,
`delivery_attempt_retention`, `delivering_timeout`, `on_delivery_exhausted`,
and `on_endpoint_disabled`.

### Primary keys

Angarium's own tables (`angarium_endpoints`, `angarium_events`,
`angarium_deliveries`, `angarium_delivery_attempts`) follow
`config.primary_key_type`: leave it `nil` (the default) to inherit your app's
own default (its `config.generators.active_record.primary_key_type`, or
bigint if that's unset), or set it explicitly (e.g. `:uuid`) to force a type
regardless of the app's default.

`owner_id` on `angarium_endpoints` is always a string column, since a
polymorphic owner can point at models with different primary key types (an
integer-keyed `User` and a UUID-keyed `Account` in the same app). This works
transparently with any owner primary key — integer, UUID, or a mix — without
any configuration.

## How Angarium compares

There are several ways to send outbound webhooks from a Rails app. Angarium aims
to be the maintained middle ground between rolling your own delivery system and
adopting external webhook infrastructure.

| | Angarium | ActionHook | bullet_train-outgoing_webhooks | active_webhook | Svix / Hookdeck Outpost |
|---|---|---|---|---|---|
| Type | Rails engine (headless) | Ruby delivery library | Rails engine (Bullet Train) | Ruby library | Hosted / self-hosted service |
| [Persisted endpoints & subscriptions](#setup) | ✅ per-endpoint event subscriptions | ❌ bring your own model | ✅ (tied to BT teams) | ✅ topics | ✅ |
| [HMAC request signing](#verifying-signatures-receiver-side) | ✅ | ✅ (SHA256 fingerprint) | ✅ | ✅ | ✅ |
| [Standard Webhooks](https://www.standardwebhooks.com) compliant | ✅ | ❌ | ❌ | ❌ | ✅ (Svix initiated the spec) |
| [Automatic retries with backoff](#retries) | ✅ jitter + `Retry-After` | ❌ (delegates to your job runner) | ✅ | ✅ (via queue adapter) | ✅ |
| [Manual redelivery](#manual-redelivery) | ✅ | ❌ | ✅ `deliver(force:)` | ❌ | ✅ |
| [Auto-disable failing endpoints](#auto-disabling-failing-endpoints) | ✅ (opt-in) | ❌ | ✅ (opt-in) | ❌ | ✅ |
| [SSRF protection](#security-ssrf-protection) | ✅ block + pin + fail-closed | ✅ private-IP blocking | ❌ | ❌ | ✅ |
| [Signing secrets encrypted at rest](#required-active-record-encryption) | ✅ Active Record Encryption | n/a (you store secrets) | ❌ | ❌ | ✅ |
| [Zero-downtime secret rotation](#rotating-a-signing-secret-zero-downtime) | ✅ dual-signing grace window | ❌ | ❌ | ❌ | ✅ |
| Job backend | Any ActiveJob backend | n/a | ActiveJob | Multiple adapters | Own workers |
| Runs inside your app | ✅ | ✅ | ✅ | ✅ | ❌ separate service |
| Framework requirements | Rails 7.1+ | Any Ruby | Bullet Train | Rails 5+ (dated) | Any (HTTP API) |
| Actively maintained | ✅ | Low activity | ✅ | Last release 2021 | ✅ |

<sub>All columns verified by reading each project's source — actionhook 1.0.2,
active_webhook 1.0.0, bullet_train-outgoing_webhooks 1.45.1 — as of July 2026;
Svix / Hookdeck Outpost cells reflect their published docs. Corrections welcome
via issue or PR.</sub>

### When to choose Angarium

- You want customer-facing webhooks (endpoints, subscriptions, signing, retries)
  without standing up separate infrastructure like Svix or Outpost.
- You want SSRF protection and encrypted signing secrets out of the box instead
  of remembering to build them.
- You want receivers to verify with an off-the-shelf library — Angarium is
  [Standard Webhooks](https://www.standardwebhooks.com) compliant.
- You already run ActiveJob and don't want a Redis- or Sidekiq-specific dependency.

### When to choose something else

- **You need massive multi-tenant scale, a customer-facing delivery portal, or
  fan-out to queues (SQS, Kafka, EventBridge):** use [Svix](https://www.svix.com)
  or [Hookdeck Outpost](https://github.com/hookdeck/outpost). They are dedicated
  infrastructure and will outgrow any in-app gem.
- **You only need a hardened HTTP delivery primitive** and want to own the data
  model yourself: [ActionHook](https://github.com/smsohan/actionhook) is a solid
  low-level choice.
- **You're building on Bullet Train:** use
  [bullet_train-outgoing_webhooks](https://rubygems.org/gems/bullet_train-outgoing_webhooks),
  which integrates with its team and account model.

### Delivery guarantees

The specifics receivers use to decide whether to trust a webhook sender:

- **Signed, timestamped, replay-resistant.** Every request carries
  `webhook-id`, `webhook-timestamp`, and `webhook-signature` headers per the
  [Standard Webhooks](https://www.standardwebhooks.com) spec — HMAC-SHA256 over
  `{id}.{timestamp}.{body}`, with a 5-minute timestamp tolerance enforced on
  verification. Verify with the official `standardwebhooks` library in any
  language, or `Angarium::Signature.verify`.
- **Stable IDs for deduplication.** `webhook-id` is the delivery's ID (the same
  value as the envelope's `id`) and is identical across every retry of that
  delivery — but unique per *delivery*, not per event. Delivery is
  **at-least-once** — dedupe on that ID and treat repeats as no-ops.
- **Retries with backoff, jitter, and `Retry-After`.** Failures (non-2xx,
  timeouts, connection errors) retry on `config.retry_schedule` (default: the
  Standard Webhooks schedule, twelve retries over ~10 days), with +0–15% jitter;
  a receiver's `Retry-After` header is honored (capped by `config.max_retry_after`).
- **Nothing is silently dropped.** When retries are exhausted the delivery is
  persisted in an `exhausted` state (not deleted), and every attempt is recorded
  as an `Angarium::DeliveryAttempt` (response code, body, error, duration).
  Re-send any delivery manually with `delivery.redeliver!`.
- **Zero-downtime secret rotation.** `endpoint.rotate_signing_secret!` keeps
  the previous secret valid for `config.signing_secret_grace_period` (default
  24h); requests during that window are signed under both secrets, so receivers
  roll over without dropping a webhook.
- **Auto-disable dead endpoints (opt-in).** Set
  `config.auto_disable_endpoint_after` to deactivate an endpoint after N
  consecutive failed deliveries; a success resets the counter.
- **Secrets encrypted at rest** with Active Record Encryption (current and
  in-rotation previous secret).

## License

MIT.
