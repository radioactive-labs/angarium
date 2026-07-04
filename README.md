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

Rotate a secret with `endpoint.regenerate_signing_secret!` (returns the new
plaintext). Deliveries sign with the new secret immediately, so update the
receiver's copy in the same window.

## Retries

Failed deliveries (non-2xx or connection errors) are retried on the schedule in
`config.retry_schedule` (default `[1m, 5m, 30m, 2h, 5h]` — five retries). Every
attempt is recorded as an `Angarium::DeliveryAttempt`. After the schedule is
exhausted the delivery is marked `exhausted`.

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
the DNS-rebinding window between resolution and connection. The one narrow
residual: if Angarium's own resolver returns no answer for a host that HTTPX's
underlying resolver can still resolve, that request proceeds unpinned (nothing
resolved to a disallowed IP, so there's nothing to have blocked). HTTPX does
not follow redirects, so redirect-based bypasses are already closed.

## Configuration

Run `bin/rails g angarium:install` to generate `config/initializers/angarium.rb`
with all options: `job_queue`, `http_timeout`, `open_timeout`, `user_agent`,
`retry_schedule`, `signature_header`, `block_private_ips`, and `primary_key_type`.

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
