# Angarium

[![CI](https://github.com/radioactive-labs/angarium/actions/workflows/ci.yml/badge.svg)](https://github.com/radioactive-labs/angarium/actions/workflows/ci.yml)
[![Standard Webhooks](https://img.shields.io/badge/Standard%20Webhooks-compliant-3068b7)](https://www.standardwebhooks.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](MIT-LICENSE)

**Everything your hand-rolled webhook job is missing**: HMAC signing, retries
with backoff, zero-downtime secret rotation, SSRF protection, and a queryable log
of every delivery attempt.

The moment "just POST from a background job" ships to production, the gaps start
showing: your customers need signatures they can verify, failed deliveries need
to back off and retry for hours, secrets need to rotate without downtime, an
endpoint URL shouldn't be able to reach your internal network, and sooner or
later someone asks "did we actually send it?". Angarium is a Rails engine that
handles all of it, and signs to the [Standard Webhooks](https://www.standardwebhooks.com)
spec, so your receivers verify with off-the-shelf libraries in any language and
you never write verification docs of your own. That conformance is enforced in
CI: any drift from the spec fails the build.

Headless by design: models, jobs, and an optional [JSON API](#http-api). Works
with any ActiveJob backend on Rails 7.1+.

### 30-second tour

Any model can own endpoints (an account, team, or user):

```ruby
class Account < ApplicationRecord
  has_many :webhook_endpoints, as: :owner, class_name: "Angarium::Endpoint"
end

# Register an endpoint; the signing secret is generated for you
account.webhook_endpoints.create!(
  name: "Production",
  url: "https://example.com/webhooks",
  subscribed_events: ["invoice.*", "user.created"] # exact, "prefix.*", or "*"
)

# Fan an event out to every subscribed endpoint
Angarium.dispatch("invoice.paid", { id: 123, total: 4200 }, owner: account)
```

Angarium handles the rest: signing, retries with backoff, `Retry-After`,
dedup-friendly delivery IDs, SSRF checks, and a full attempt log. See
[Delivery guarantees](#delivery-guarantees) for the specifics receivers care about.

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

### Active Record Encryption

Angarium encrypts each endpoint's `signing_secret` and `custom_headers` at rest,
so it needs Active Record Encryption keys. If you haven't set them up, it's one
command:

```bash
bin/rails db:encryption:init
```

Add the generated keys to your credentials (`config/credentials.yml.enc`) or
set `config.active_record.encryption.{primary_key,deterministic_key,key_derivation_salt}`.
See the [Rails guide on Active Record Encryption](https://guides.rubyonrails.org/active_record_encryption.html).

```bash
bin/rails db:migrate
```

## Dispatching events

`Angarium.dispatch` fans a single event out to every enabled, subscribed
endpoint, creating one delivery each and one ActiveJob per delivery:

```ruby
Angarium.dispatch("invoice.paid", { id: 123, total: 4200 }, owner: account)
```

Each request is delivered as a JSON envelope:

```json
{ "id": 42, "event": "invoice.paid", "created_at": "2026-07-04T12:00:00Z", "data": { "id": 123, "total": 4200 } }
```

## Verifying signatures (receiver side)

**Angarium signs webhooks using the [Standard Webhooks](https://www.standardwebhooks.com)
specification**, so receivers can verify them with the official
[`standardwebhooks` libraries](https://github.com/standard-webhooks/standard-webhooks/tree/main/libraries)
in any language (Ruby, Python, JavaScript, Go, Rust, PHP, Java, and more), with no
Angarium-specific code required. Conformance is enforced in CI: signed requests
are verified with the official `standardwebhooks` Ruby library, so any drift from
the spec fails the build.

Every request carries three headers:

| Header | Value |
| --- | --- |
| `webhook-id` | Unique, retry-stable message id: the delivery's `id`, the **same value** as the envelope's `id`. It is unique per *delivery*, not per event, so the same event delivered to two endpoints has two different ids. |
| `webhook-timestamp` | Unix seconds when the request was signed. |
| `webhook-signature` | Space-delimited list of `v1,<base64 HMAC-SHA256>` tokens (one per active signing secret). |

The signature is `HMAC-SHA256(secret_key, "{webhook-id}.{webhook-timestamp}.{body}")`,
base64-encoded, where `secret_key` is the base64-decoded portion of the
`whsec_`-prefixed `signing_secret`.

You can verify with any Standard Webhooks library, or with Angarium's own helper.
Pass a Rails `request:` and it reads the raw body and `webhook-*` headers for you:

```ruby
Angarium::Signature.verify(request: request, secret: endpoint.signing_secret)
# => true / false
```

Or pass the fields explicitly:

```ruby
Angarium::Signature.verify(
  payload:   request.raw_post,
  id:        request.headers["webhook-id"],
  timestamp: request.headers["webhook-timestamp"],
  signature: request.headers["webhook-signature"],
  secret:    endpoint.signing_secret
)
```

`verify` also enforces a timestamp tolerance (default 300s) to resist replay.

The secret (a `whsec_...` string) is stored encrypted at rest and is only
decrypted in memory when signing; `endpoint.signing_secret` returns the
plaintext, so deliver it to receivers over a secure channel.

### Rotating a signing secret (zero-downtime)

Rotate a secret with `endpoint.rotate_secret!` (returns the new
plaintext). During a grace window (`config.signing_secret_grace_period`, default
`24.hours`) every delivery is signed with **both** the new and the previous
secret. The `webhook-signature` header carries multiple space-delimited `v1,`
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

`custom_headers` must be a hash of string keys and values. Because it commonly
carries a receiver credential (like the bearer token above), it's **encrypted at
rest** with Active Record Encryption, same as the signing secret. The
`webhook-id`, `webhook-timestamp`, and `webhook-signature` headers always win, so
a custom header can never override or spoof them. In the same spirit, reserved
and transport headers (`webhook-id`, `webhook-timestamp`, `webhook-signature`,
`host`, `content-length`, `content-type`, `transfer-encoding`, `connection`)
are rejected at validation (case-insensitively) and can't be overridden.

## Retries

Failed deliveries (non-2xx or connection errors) are retried on the schedule in
`config.retry_schedule`. The default follows the [Standard Webhooks](https://www.standardwebhooks.com)
recommendation of a multi-day schedule with exponential backoff and jitter: our
instantiation is twelve retries spanning ~10 days (`5s, 5m, 30m, 2h, 5h, 10h,
14h, 20h, 24h, 36h, 48h, 72h`, after an immediate first delivery). Every attempt
is recorded as an `Angarium::DeliveryAttempt`. After the schedule is exhausted
the delivery is marked `exhausted`.

Each `DeliveryAttempt` stores the response body, truncated to
`config.max_response_body_bytes` bytes (default `65_536`; set `nil` to store the
full body).

### Status-code handling

Angarium follows the Standard Webhooks receiver-etiquette guidance:

| Response | Handling |
| --- | --- |
| `2xx` | Success. |
| `410 Gone` | The receiver wants no more webhooks. The **endpoint status becomes `gone`** and the delivery is marked `gone`, with no retries. |
| `429`, `502`, `504` | Retryable failure, retried with backoff, honoring `Retry-After` when present (the recommended way to throttle). |
| `3xx` and everything else | Retryable failure. Redirects are **not** followed (following them loads both sides); update the endpoint URL instead. |

### Backoff jitter

Each retry delay gets a small amount of additive positive jitter
(`config.retry_jitter`, default `0.15` → up to +15%) so many deliveries failing
at once don't retry in lockstep and stampede the receiver.

### Retry-After

When a failed response carries a `Retry-After` header (seconds or an HTTP-date),
Angarium honors it, but only when it asks for a **longer** wait than the
scheduled backoff. It takes the later of the two, so a receiver's `Retry-After`
can *delay* the next attempt but never pull it *earlier* than our schedule. This
keeps a malicious or misconfigured receiver from using a tiny `Retry-After` to
defeat our backoff and make us retry aggressively. The honored value is capped at
`config.max_retry_after` (default `3600` seconds), and the whole behavior can be
disabled with `config.respect_retry_after = false`.

One interaction to note with the default schedule: because the cap is one hour,
`Retry-After` can only ever extend the wait during the early steps (up to the
`30m` step). Once backoff reaches `2h` and beyond, a capped `Retry-After` is
always shorter than the scheduled delay, so it has no effect. If you need
receivers to push back harder late in the schedule, raise `config.max_retry_after`.

### Manual redelivery

Re-send any delivery, including an exhausted one, with:

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
| `enabled` | Delivering normally. | n/a |
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

  # An endpoint was deactivated. reason is :consecutive_failures (status becomes
  # `disabled`) or :gone (HTTP 410, status becomes `gone`).
  config.on_endpoint_deactivated = ->(endpoint, reason) do
    AdminMailer.endpoint_deactivated(endpoint, reason).deliver_later
  end
end
```

Both are optional. A callback that raises is logged and swallowed, so a broken
notifier never breaks delivery.

### Recovering interrupted deliveries

If a worker dies mid-delivery (crash, deploy, OOM) after a delivery is marked
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
(subscription matching is bypassed, so a ping is always sent). Returns the
`Angarium::Delivery`, so you can reload it to inspect the outcome:

```ruby
delivery = endpoint.ping!
# optionally: endpoint.ping!(message: "hello")
delivery.reload.succeeded? # => true once delivered
```

### At-least-once delivery

Delivery is **at-least-once**: a webhook may arrive more than once, from a retry
after a receiver processed the request but the response was lost, or a rare
duplicate job enqueue. **Make your receivers idempotent**: dedupe on the
envelope's `id` (stable across every attempt of the same delivery) and treat a
repeat as a no-op.

## Data retention

Every delivery attempt stores the receiver's response body (capped at
`config.max_response_body_bytes`, 64KB by default). Because
`angarium_delivery_attempts` grows with delivery volume × retries, a busy app
talking to a flapping receiver can accumulate rows quickly. You have three
options to keep it bounded:

```ruby
# 1. Set a retention window and prune on a schedule (cron / your scheduler):
Angarium.config.delivery_attempt_retention = 90.days
#    then run periodically:  bin/rails angarium:prune

# 2. Or prune inline, wherever you like:
Angarium::DeliveryAttempt.prune(older_than: 90.days)

# 3. Or store less per attempt by lowering the response-body cap:
Angarium.config.max_response_body_bytes = 4_096
```

## HTTP API

Angarium ships an optional **JSON API** for managing endpoints and browsing
deliveries. It has no HTML views or UI of its own. Mount the engine wherever you
like:

```ruby
# config/routes.rb
mount Angarium::Engine => "/webhooks"
```

### Authentication

The API has no auth of its own; it uses yours. Its controllers inherit from
`config.parent_controller` (default `"ApplicationController"`), so every
`before_action` your app already runs (Devise, Rodauth, etc.) applies here too.
Angarium reads the signed-in user via your current-user convention:

```ruby
config.parent_controller = "ApplicationController"   # or your API base controller
config.current_user = ->(controller) { controller.current_user }
```

Requests without a resolved current user get a `401`.

### Authorization

Authorization lives in one place: a **policy** class, `config.policy_class`
(default `Angarium::Api::Policy`). Generate one to start from (it creates the
class and points `config.policy_class` at it in your initializer):

```bash
bin/rails g angarium:policy        # app/policies/webhook_endpoint_policy.rb
```

Angarium instantiates the policy per request with the controller and (for member
actions) the target record, and runs it in the controller's context, so
`current_user`, `params`, `controller`, and `record` are all available. Its
methods:

| Method | Default | Purpose |
| --- | --- | --- |
| `scope(relation)` | `relation.where(owner: current_user)` | Narrows a base relation to the endpoints this user may see and act on. Reads, finds, and delivery/attempt access all go through it. |
| `owner` | `current_user` | The owner assigned to a newly-created endpoint. Set before `create?` runs, so you can gate the target owner there via `record.owner`. |
| `permit_allow_private_network?` | `false` | Whether `allow_private_network` (relax the private-IP block) is API-writable. Dangerous; trusted operators only. |
| `permit_allowed_networks?` | `false` | Whether `allowed_networks` (a restrictive CIDR allowlist) is API-writable. |
| `index?` `show?` `create?` `update?` `destroy?` | `true` | Whether each action is allowed. |
| `rotate_secret?` `pause?` `enable?` `ping?` `redeliver?` | `update?` | Member actions; default to the `update?` capability. |

Override only what you need; the defaults are single-owner (you see and manage
your own endpoints). A denied action returns `403`; anything outside `scope` is a
`404`.

```ruby
class WebhookEndpointPolicy < Angarium::Api::Policy
  # Multi-tenant visibility: compose on top of the relation you're given.
  def scope(relation) = relation.where(owner_id: current_user.account.owner_ids)

  # Admins may create for any owner in their account (via an owner_id param);
  # everyone else creates for themselves.
  def owner
    id = params[:owner_id]
    id && current_user.admin? ? current_user.account.owners.find(id) : current_user
  end

  # Restrict individual actions (members default to update?, which defaults true).
  def update?  = current_user.can?(:manage_webhooks)
  def destroy? = current_user.admin?
end

config.policy_class = "WebhookEndpointPolicy"
```

### Objects

Responses wrap these objects. `signing_secret` and `custom_headers` are never
included (see the note below):

```json
// endpoint
{ "id": 1, "name": "Production", "url": "https://example.com/webhooks",
  "status": "enabled", "subscribed_events": ["invoice.*"], "allow_private_network": false,
  "allowed_networks": [], "consecutive_failures": 0, "status_changed_at": null,
  "created_at": "2026-07-04T12:00:00Z", "updated_at": "2026-07-04T12:00:00Z" }

// delivery
{ "id": 42, "endpoint_id": 1, "event": "invoice.paid", "state": "succeeded",
  "attempt_count": 1, "next_attempt_at": null, "last_attempt_at": "2026-07-04T12:00:01Z",
  "created_at": "2026-07-04T12:00:00Z", "updated_at": "2026-07-04T12:00:01Z" }

// attempt
{ "id": 7, "delivery_id": 42, "response_code": 200, "response_body": "ok",
  "error": null, "duration": 0.12, "created_at": "2026-07-04T12:00:01Z" }

// pagination (on every list response)
{ "limit": 50, "offset": 0, "count": 20, "total": 137 }
```

### Routes

| Method & path | Request body | Response |
| --- | --- | --- |
| `GET /endpoints?limit=&offset=` | none | `200 { "endpoints": [endpoint, ...], "pagination": pagination }` |
| `POST /endpoints` | `{ "endpoint": { "name", "url", "subscribed_events": [...] } }` | `201 { "endpoint": {...endpoint, "signing_secret": "whsec_..."} }` |
| `GET /endpoints/:id` | none | `200 { "endpoint": endpoint }` |
| `PATCH /endpoints/:id` | `{ "endpoint": { "name": "New name" } }` | `200 { "endpoint": endpoint }` |
| `DELETE /endpoints/:id` | none | `204` (no body) |
| `POST /endpoints/:id/rotate_secret` | none | `200 { "endpoint": endpoint, "signing_secret": "whsec_..." }` |
| `POST /endpoints/:id/pause`, `/enable` | none | `200 { "endpoint": endpoint }` |
| `POST /endpoints/:id/ping` | none | `202 { "delivery": delivery }` |
| `GET /endpoints/:id/deliveries?limit=&offset=` | none | `200 { "deliveries": [delivery, ...], "pagination": pagination }` |
| `GET /deliveries/:id` | none | `200 { "delivery": delivery }` |
| `POST /deliveries/:id/redeliver` | none | `202 { "delivery": delivery }` |
| `GET /deliveries/:id/attempts?limit=&offset=` | none | `200 { "attempts": [attempt, ...], "pagination": pagination }` |

- **Secrets are never echoed.** `signing_secret` is returned only by `create` and
  `rotate_secret`; `custom_headers` (which may hold a credential) is write-only.
- **Pagination.** List endpoints take `?limit=` (default 50, max 200) and
  `?offset=`, and each list response carries a `pagination` object (`limit`,
  `offset`, `count` in this page, `total` overall); there are more when
  `offset + count < total`.
- **Errors are JSON.** `422 { "error": "validation failed", "details": [...] }`
  for an invalid body, plus `401` (unauthenticated), `403` (policy denied), and
  `404` (out of scope).

### Permitted attributes

`POST`/`PATCH /endpoints` accept these keys under `endpoint`; anything else is
ignored (strong parameters). The exception is the two privileged controls below:
when your policy hasn't permitted them, they are **rejected with a `422`, not
silently ignored**, so an attempt to enable one never looks like it succeeded.

| Attribute | Type | Notes |
| --- | --- | --- |
| `name` | string | |
| `url` | string | the receiver URL (SSRF-validated on every change) |
| `subscribed_events` | array of strings | event patterns: exact, `"prefix.*"`, or `"*"` |
| `custom_headers` | object | write-only; sent with each delivery, never echoed back |
| `allow_private_network` | boolean | privileged; **not writable by default**, see below |
| `allowed_networks` | array of CIDRs | privileged; **not writable by default**, see below |

`status` is not writable (use the `pause` / `enable` actions), and the owner of a
created endpoint comes from the policy's `owner`, not the request.

`allow_private_network` and `allowed_networks` are **independent** SSRF controls,
each gated by its own policy predicate (default off), because they do opposite
things:

- `allow_private_network` **relaxes** protection: it lets an endpoint deliver to
  private and loopback addresses. This is the dangerous one; an end user who can
  set it can point a webhook at your internal network.
- `allowed_networks` **restricts** delivery to a CIDR allowlist (both it and the
  private-IP denylist must still pass), so it's safe to expose more widely.

You can always set them from trusted code, regardless of the API:

```ruby
endpoint.update!(allow_private_network: true, allowed_networks: ["10.0.5.0/24"])
```

To permit either through the API, override its predicate. Being independent, you
can allow the safe one without the dangerous one:

```ruby
class WebhookEndpointPolicy < Angarium::Api::Policy
  def permit_allow_private_network? = current_user.operator?   # dangerous: operators only
  def permit_allowed_networks?      = true                     # restrictive: safe to expose
end
```

A request that tries to **change** a control it isn't permitted to set gets a
`422` naming the attribute, rather than the change being silently dropped, so a
misconfigured client fails loudly instead of appearing to work. (Sending a
control's current value is a no-op.)

## Security (SSRF protection)

Because endpoint URLs are user-supplied, Angarium guards against Server-Side
Request Forgery. Three controls, validated when an endpoint is created or when
its `url`, `allow_private_network`, or `allowed_networks` change, and re-checked
at delivery time:

- **`config.block_private_ips`** (default `true`) blocks delivery to
  private, loopback, and link-local addresses (e.g. `127.0.0.1`, `10.0.0.0/8`,
  `169.254.169.254`), including IPv4-mapped IPv6 forms (e.g. `::ffff:127.0.0.1`)
  and the unspecified address (`0.0.0.0` / `::`).
- **`endpoint.allow_private_network`** (default `false`) is the per-endpoint opt-in
  required to deliver to a private address. An allowlist entry alone does **not**
  unlock a private address.
- **`endpoint.allowed_networks`** (CIDR array), when set, restricts this
  endpoint's deliveries to those CIDRs. It only narrows; to allow a private range
  you must also set `allow_private_network`.

> **Note:** `allow_private_network` is a privileged control. Expose it only to
> trusted operators, never to end users; otherwise it becomes an SSRF opt-in.

**Connect-time IP pinning:** the delivery-time check re-resolves the host,
rejects disallowed addresses, and then pins the connection to exactly the
validated IP(s), so HTTPX does not re-resolve or connect elsewhere, while TLS
SNI and certificate verification still use the original hostname. This closes
the DNS-rebinding window between resolution and connection. Angarium's own
resolver is the single source of truth: if it can't resolve a host, the
delivery fails (retryable) rather than falling back to an unvalidated HTTPX
resolution, so there is no unpinned path. The only cost is that hosts
resolvable *only* via non-DNS mechanisms Angarium's resolver doesn't use
(e.g. mDNS `.local`) won't be delivered to, which is not a concern for real
webhook endpoints. HTTPX does not follow redirects, so redirect-based
bypasses are already closed.

Found a gap in any of this? Report it privately: see [SECURITY.md](SECURITY.md)
for the disclosure process (GitHub's private advisory workflow) and the surfaces
we hold ourselves to.

## Delivery guarantees

What Angarium actually promises about delivery, so a receiver knows what it can
rely on:

- **At-least-once, not exactly-once.** A delivery is retried until it succeeds or
  the schedule is exhausted, so the same event can arrive more than once (for
  example, a retry after your `200` was lost in transit). Every request carries a
  `webhook-id` that stays constant across a delivery's retries: dedupe on it and
  treat repeats as no-ops.
- **No ordering.** Deliveries are independent jobs and each retries on its own
  schedule, so events can arrive out of order. If order matters, put a sequence
  number or timestamp in the payload and sort on the receiver.
- **Durable; nothing is silently dropped.** Every attempt is persisted as an
  `Angarium::DeliveryAttempt` (response code, body, error, duration), and a
  delivery that exhausts its retries is kept in the `exhausted` state, not
  deleted. You can always tell whether an event was delivered, and re-send with
  `delivery.redeliver!`.
- **Authenticated per request.** Every request is signed and timestamped per the
  [Standard Webhooks](https://www.standardwebhooks.com) spec (HMAC-SHA256 over
  `{id}.{timestamp}.{body}`, 5-minute tolerance), so a receiver can confirm it
  came from you and reject replays, independent of transport.

Secret rotation, SSRF protection, and encryption harden delivery but aren't
delivery-semantics guarantees; they have their own sections above.

## Configuration

Run `bin/rails g angarium:install` to generate `config/initializers/angarium.rb`,
which documents every option inline. The delivery and retry settings:

| Option | Default | What it controls |
| --- | --- | --- |
| `job_queue` | `:default` | ActiveJob queue used for deliveries. |
| `http_timeout` | `10` | HTTP read timeout (seconds) per attempt. |
| `open_timeout` | `5` | TCP connect timeout (seconds) per attempt. |
| `user_agent` | `"Angarium/<version>"` | User-Agent header on each delivery. |
| `retry_schedule` | 12 delays over ~10 days | Backoff between retries; its length is the retry count. |
| `retry_jitter` | `0.15` | Fraction of additive positive jitter on each backoff delay. |
| `respect_retry_after` | `true` | Honor a receiver's `Retry-After` header (delay-only). |
| `max_retry_after` | `3600` | Cap (seconds) on a honored `Retry-After`; `nil` is uncapped. |
| `auto_disable_endpoint_after` | `nil` | Deactivate an endpoint after N consecutive failures; `nil` never does. |
| `signing_secret_grace_period` | `24.hours` | How long a rotated endpoint's previous secret stays valid. |
| `block_private_ips` | `true` | Reject endpoint URLs resolving to private/loopback addresses (SSRF). |
| `max_response_body_bytes` | `65_536` | Truncate the stored response body; `nil` stores it whole. |
| `delivery_attempt_retention` | `nil` | Age past which `angarium:prune` deletes attempts; `nil` keeps all. |
| `delivering_timeout` | `15.minutes` | Age after which `angarium:reap` requeues a stuck `delivering` delivery. |
| `primary_key_type` | `nil` | Primary key type for Angarium's tables (see below). |
| `on_delivery_exhausted` | `nil` | Callback `->(delivery)` when a delivery exhausts its retries. |
| `on_endpoint_deactivated` | `nil` | Callback `->(endpoint, reason)` when an endpoint is disabled or gone. |

Mounting the JSON API adds `parent_controller`, `current_user`, and
`policy_class` (see [Authentication](#authentication) and
[Authorization](#authorization)).

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
transparently with any owner primary key (integer, UUID, or a mix) without
any configuration.

## Why not just POST from a job?

`HTTP.post(endpoint.url, body: payload)` in a background job works right up
until it's in front of customers. Then the edge cases arrive one at a time, and
each is a small project:

- **Signatures.** Receivers won't (and shouldn't) trust an unsigned POST. Roll
  your own and you now own an HMAC scheme, a header format, and the verification
  docs your customers need in every language they use. Angarium signs to
  [Standard Webhooks](https://www.standardwebhooks.com), so they verify with an
  off-the-shelf library and you write none.
- **Retries that don't stampede.** A receiver has a bad 30 minutes; a naive retry
  either gives up too early or hammers them in lockstep. Angarium retries on a
  backoff schedule (~10 days by default) with jitter, and honors `Retry-After`,
  but only to *delay* a retry, never to pull it earlier than your schedule.
- **Duplicate suppression.** Retries mean the same event lands more than once.
  Without a stable ID that's invariant across a delivery's retries, receivers
  can't dedupe. Angarium gives every delivery exactly that.
- **SSRF.** An endpoint URL is user input. POST to it blindly and a customer can
  point it at `169.254.169.254` or `10.0.0.1` and read your internal network.
  Angarium blocks private ranges, pins the connection to the validated IP, and
  fails closed on hosts it can't resolve.
- **Secret rotation.** Rotating a signing secret through a single POST path means
  a window where the old or new secret gets rejected. Angarium signs with both
  during a grace window, so receivers roll over without dropping a webhook.
- **Stranded deliveries.** A worker crashes mid-send and the delivery is stuck
  half-done, with no retry and no record. Angarium reaps deliveries stranded in
  `delivering` and re-queues them.
- **"Did we actually send it?"** When support asks, you need the answer. Angarium
  persists every attempt (response code, body, error, duration) and never
  silently drops a delivery.

None of these is hard on its own. Building and maintaining all of them together,
as Rails and your receivers change, is the work Angarium takes off your plate.

## How Angarium compares

There are several ways to send outbound webhooks from a Rails app. Angarium aims
to be the maintained middle ground between rolling your own delivery system and
adopting external webhook infrastructure.

| | Angarium | ActionHook | bullet_train-outgoing_webhooks | active_webhook | Svix / Hookdeck Outpost |
|---|---|---|---|---|---|
| Type | Rails engine (headless + JSON API) | Ruby delivery library | Rails engine (Bullet Train) | Ruby library | Hosted / self-hosted service |
| [Persisted endpoints & subscriptions](#30-second-tour) | ✅ per-endpoint event subscriptions | ❌ bring your own model | ✅ (tied to BT teams) | ✅ topics | ✅ |
| [Endpoint-management JSON API](#http-api) | ✅ auth + policy | ❌ | ❌ | ❌ | ✅ |
| [HMAC request signing](#verifying-signatures-receiver-side) | ✅ | ✅ (SHA256 fingerprint) | ✅ | ✅ | ✅ |
| [Standard Webhooks](https://www.standardwebhooks.com) compliant | ✅ | ❌ | ❌ | ❌ | ✅ (Svix initiated the spec) |
| [Automatic retries with backoff](#retries) | ✅ jitter + `Retry-After` | ❌ (delegates to your job runner) | ✅ | ✅ (via queue adapter) | ✅ |
| [Manual redelivery](#manual-redelivery) | ✅ | ❌ | ✅ `deliver(force:)` | ❌ | ✅ |
| [Auto-disable failing endpoints](#auto-disabling-failing-endpoints) | ✅ (opt-in) | ❌ | ✅ (opt-in) | ❌ | ✅ |
| [SSRF protection](#security-ssrf-protection) | ✅ block + pin + fail-closed | ✅ private-IP blocking | ❌ | ❌ | ✅ |
| [Signing secrets encrypted at rest](#active-record-encryption) | ✅ Active Record Encryption | n/a (you store secrets) | ❌ | ❌ | ✅ |
| [Zero-downtime secret rotation](#rotating-a-signing-secret-zero-downtime) | ✅ dual-signing grace window | ❌ | ❌ | ❌ | ✅ |
| Job backend | Any ActiveJob backend | n/a | ActiveJob | Multiple adapters | Managed workers |
| Runs inside your app | ✅ | ✅ | ✅ | ✅ | ❌ separate service |
| Framework requirements | Rails 7.1+ | Any Ruby | Bullet Train | Rails 5+ | Any (HTTP API) |

<sub>All columns verified by reading each project's source: actionhook 1.0.2,
active_webhook 1.0.0, bullet_train-outgoing_webhooks 1.45.1, as of July 2026;
Svix / Hookdeck Outpost cells reflect their published docs. Corrections welcome
via issue or PR.</sub>

### When to choose Angarium

- You want customer-facing webhooks (endpoints, subscriptions, signing, retries)
  without standing up separate infrastructure like Svix or Outpost.
- You want SSRF protection and encrypted signing secrets out of the box instead
  of remembering to build them.
- You want receivers to verify with an off-the-shelf library, since Angarium is
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

## Development

After cloning the repo, install dependencies and generate the per-Rails-version
gemfiles:

```bash
bundle install
bundle exec appraisal install   # writes gemfiles/*.gemfile for each Rails version
```

Tests run through a `test/dummy` app against the supported Rails versions via
[Appraisal](https://github.com/thoughtbot/appraisal) (there is no `rake test`
task; the runner is `bin/rails test`):

```bash
bundle exec appraisal bin/rails test               # all Rails versions
bundle exec appraisal rails-8.1 bin/rails test     # a single version
bin/rails test                                     # just your default bundle
bin/rails test test/lib/angarium/signature_test.rb # a single file
```

Available appraisals: `rails-7.1`, `rails-7.2`, `rails-8.0`, `rails-8.1`. CI runs
the same matrix across Ruby 3.2 and 3.3 (8 jobs). After changing a dependency or
the `Appraisals` file, re-run `bundle exec appraisal install` and commit the
updated `gemfiles/`.

### Linting and security

CI also runs [Standard](https://github.com/standardrb/standard) and
[Brakeman](https://brakemanscanner.org):

```bash
bundle exec rake standard        # lint (rake standard:fix to autocorrect)
bundle exec brakeman -q -z       # static security analysis
```

### Cutting a release

Publishing runs from a laptop; CI only cuts the GitHub Release when the tag
lands. Version math and the changelog come from [git-cliff](https://git-cliff.org)
over your [Conventional Commits](https://www.conventionalcommits.org)
(`brew install git-cliff`):

```bash
rake release:prepare        # bump version.rb + regenerate CHANGELOG.md, then STAGE (nothing committed)
git diff --cached           # review
rake release:publish        # commit, gem build + push, tag + push (idempotent/resumable)
```

`rake release:prepare[1.2.3]` forces a version instead of computing it. The bare
`rake release` is disabled in favor of this two-step flow.

## License

Angarium is released under the [MIT License](MIT-LICENSE).
