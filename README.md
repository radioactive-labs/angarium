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

## Retries

Failed deliveries (non-2xx or connection errors) are retried on the schedule in
`config.retry_schedule` (default `[1m, 5m, 30m, 2h, 5h]` — five retries). Every
attempt is recorded as an `Angarium::DeliveryAttempt`. After the schedule is
exhausted the delivery is marked `exhausted`.

## Security (SSRF protection)

Because endpoint URLs are user-supplied, Angarium guards against Server-Side
Request Forgery. Three controls, checked at endpoint-save time and re-checked at
delivery time:

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

**Known limitation (v1):** the delivery-time check re-resolves the host and
rejects disallowed addresses, but does not yet pin the connection to the
validated IP. A determined attacker controlling DNS could exploit a sub-second
rebinding window between resolution and connection. Full IP-pinning (connect to
the validated address with Host/SNI preserved) is planned for a future release.
HTTPX does not follow redirects, so redirect-based bypasses are already closed.

## Configuration

Run `bin/rails g angarium:install` to generate `config/initializers/angarium.rb`
with all options: `job_queue`, `http_timeout`, `open_timeout`, `user_agent`,
`retry_schedule`, `signature_header`, and `block_private_ips`.

## License

MIT.
