# Angarium

Outbound webhooks for Rails: signed, retried, subscription-based delivery.

Angarium is a mountable Rails engine that delivers outbound webhooks with HMAC
request signing, automatic retries with exponential backoff, per-endpoint event
subscriptions, and SSRF protection. It works with any ActiveJob backend and any
Rails 7.1+ app.

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

The signature is computed over `"{timestamp}.{body}"` with HMAC-SHA256, and
`verify` also enforces a timestamp tolerance (default 300s) to resist replay.

The secret is stored encrypted at rest and is only decrypted in memory when
signing; `endpoint.signing_secret` returns the plaintext, so deliver it to
receivers over a secure channel.

### Rotating a signing secret (zero-downtime)

Rotate a secret with `endpoint.regenerate_signing_secret!` (returns the new
plaintext). During a grace window (`config.signing_secret_grace_period`, default
`24.hours`) every delivery is signed with **both** the new and the previous
secret — the header carries multiple `v1=` values:

```
X-Angarium-Signature: t=<ts>,v1=<new_hmac>,v1=<previous_hmac>
```

`Angarium::Signature.verify` succeeds if the payload matches **any** signature
in the header, so a receiver still holding the old secret keeps validating while
you roll it over, and one holding the new secret validates immediately. Once the
grace period elapses, deliveries are signed with the new secret only. This lets
receivers update their copy of the secret with zero downtime and no rejected
deliveries.

### Per-endpoint custom headers

Attach static headers (e.g. an `Authorization` bearer token the receiver
expects) to every request from an endpoint:

```ruby
endpoint.update!(custom_headers: { "Authorization" => "Bearer abc123" })
```

`custom_headers` must be a hash of string keys and values. The signature header
always wins, so a custom header can never override or spoof it.

## Retries

Failed deliveries (non-2xx or connection errors) are retried on the schedule in
`config.retry_schedule` (default `[1m, 5m, 30m, 2h, 5h]` — five retries). Every
attempt is recorded as an `Angarium::DeliveryAttempt`. After the schedule is
exhausted the delivery is marked `exhausted`.

Each `DeliveryAttempt` stores the response body, truncated to
`config.max_response_body_bytes` bytes (default `65_536`; set `nil` to store the
full body).

### Backoff jitter

Each retry delay gets a small amount of additive positive jitter
(`config.retry_jitter`, default `0.15` → up to +15%) so many deliveries failing
at once don't retry in lockstep and stampede the receiver.

### Retry-After

When a failed response carries a `Retry-After` header (seconds or an HTTP-date),
Angarium honors it for the next attempt instead of the schedule's delay. This is
capped at `config.max_retry_after` (default `3600` seconds) and can be turned off
with `config.respect_retry_after = false`.

### Manual redelivery

Re-send any delivery — including an exhausted one — with:

```ruby
delivery.redeliver!
```

This resets the retry cycle (`state` → `pending`, `attempt_count` → 0) and
enqueues a fresh `DeliverJob`, while keeping the prior `DeliveryAttempt` history.

### Auto-disabling failing endpoints

Set `config.auto_disable_endpoint_after` to a number of **consecutive** failed
deliveries after which an endpoint is automatically disabled (`active` → `false`,
`disabled_at` timestamped). `endpoint.consecutive_failures` tracks the running
count and resets to `0` on the next successful delivery. Left `nil` (the
default), endpoints are never auto-disabled.

### Sending a test event

Verify an endpoint end-to-end by delivering a synthetic `angarium.test` event
(subscription matching is bypassed — a test event is always sent):

```ruby
delivery = endpoint.send_test_event!
# optionally: endpoint.send_test_event!(message: "hello")
```

### At-least-once delivery

Delivery is **at-least-once**: a webhook may arrive more than once — a retry
after a receiver processed the request but the response was lost, or a rare
duplicate job enqueue. **Make your receivers idempotent**: dedupe on the
envelope's `id` (stable across every attempt of the same delivery) and treat a
repeat as a no-op.

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
`retry_schedule`, `signature_header`, `block_private_ips`, `primary_key_type`,
`max_response_body_bytes`, `auto_disable_endpoint_after`, `respect_retry_after`,
`max_retry_after`, `retry_jitter`, and `signing_secret_grace_period`.

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

## License

MIT.
