# Changelog

## [0.1.0] - Unreleased

### Added
- Rails engine (headless) with `Angarium::Endpoint`, `Event`, `Delivery`, `DeliveryAttempt`.
- Optional JSON API (mount `Angarium::Engine`): endpoints CRUD +
  rotate_secret/pause/enable/ping, delivery browsing, and redeliver. Authenticated
  via your current-user convention (`config.parent_controller`/`config.current_user`),
  data-scoped per user (`config.endpoint_scope`), new-endpoint owner resolved by
  `config.resolve_owner` (default: current user; override for admin-on-behalf-of),
  and per-action authorized by an optional policy (`config.policy_class`, subclass
  `Angarium::Api::Policy`). The signing secret is revealed only on create/rotate;
  `custom_headers` is write-only.
- `Angarium::Signature.verify(request:, secret:)` reads the raw body and
  `webhook-*` headers from a Rails request, so receiver-side verification is a
  one-liner (explicit `payload:`/`id:`/`timestamp:`/`signature:` still supported).
- `Angarium::Delivery.reap_stalled` + `angarium:reap` rake task to recover
  deliveries stranded in `delivering` by a crashed worker (`config.delivering_timeout`).
- `Angarium.dispatch` event fan-out to active, subscribed endpoints.
- Webhook signatures follow the [Standard Webhooks](https://www.standardwebhooks.com)
  spec (`webhook-id`/`webhook-timestamp`/`webhook-signature` headers, `whsec_`
  secrets, HMAC-SHA256 over `id.timestamp.body`), so receivers can verify with
  off-the-shelf `standardwebhooks`/Svix libraries in any language.
  `Angarium::Signature.verify` is provided as a convenience.
- ActiveJob-based delivery with retries and exponential backoff. Default
  `retry_schedule` follows the Standard Webhooks recommendation (twelve retries
  over ~10 days: `5s, 5m, 30m, 2h, 5h, 10h, 14h, 20h, 24h, 36h, 48h, 72h`).
- SSRF protection: global private-IP block, per-endpoint `allow_private_network`
  and `allowed_networks` controls, enforced at validation and delivery time.
- Install generator and migrations.
- Connect-time IP pinning: deliveries pin to the validated resolved address,
  closing the DNS-rebinding window.
- Delivery fails closed on hosts it can't resolve (never falls back to an
  unvalidated HTTPX resolution), fully closing the DNS-rebinding
  resolver-divergence gap.
- Endpoint `signing_secret` and `custom_headers` are encrypted at rest with
  Active Record Encryption (custom_headers commonly carries a receiver credential
  such as a bearer token). Requires the host app to configure encryption keys.
- `Endpoint#rotate_signing_secret!` to rotate an endpoint's signing secret.
- Endpoint URL/SSRF validation re-runs when `url`, `allow_private_network`, or
  `allowed_networks` change (and skips the DNS lookup on unrelated updates).
- Configurable `config.primary_key_type` for Angarium's own tables (defaults
  to the host app's generator setting, or bigint); polymorphic `owner_id` is
  now a string column so owners with any primary key type (bigint, UUID, or a
  mix) can be associated.
- Configurable response-body truncation cap (`config.max_response_body_bytes`,
  default 64 KiB; `nil` stores the full body).
- Manual redelivery: `Delivery#redeliver!` resets the retry cycle and re-enqueues,
  keeping prior attempt history.
- Endpoint lifecycle `status` enum (`enabled`/`paused`/`disabled`/`gone`,
  replacing the old boolean `active`), with `pause!`/`enable!` transitions,
  `status_changed_at`, and an `Endpoint.enabled` scope. Only `enabled` endpoints
  receive deliveries.
- Endpoint auto-disable after `config.auto_disable_endpoint_after` consecutive
  failed deliveries (moves status to `disabled`), resetting the counter on success.
- Standard Webhooks status-code handling: `410 Gone` disables the endpoint
  immediately and marks the delivery `gone` (new terminal state, no retries);
  `429`/`502`/`504` and other non-2xx responses stay retryable with backoff and
  honor `Retry-After`; redirects are not followed.
- Notification callbacks `config.on_delivery_exhausted` (delivery) and
  `config.on_endpoint_disabled` (endpoint, reason: `:consecutive_failures` |
  `:gone`) for alerting consumers out of band; a raised callback is logged and
  swallowed.
- Honors a receiver's `Retry-After` header (seconds or HTTP-date) for the next
  attempt, capped by `config.max_retry_after` and toggleable via
  `config.respect_retry_after`.
- Per-endpoint `custom_headers` sent with every delivery (the signature header
  always takes precedence).
- `Endpoint#ping!` delivers a synthetic `angarium.ping` event, bypassing
  subscription matching; returns the `Angarium::Delivery`.
- Additive positive backoff jitter (`config.retry_jitter`) to avoid retry
  stampedes.
- Dual-secret rotation grace: after `rotate_signing_secret!`, deliveries are
  signed with both the new and previous secret for
  `config.signing_secret_grace_period`, and `Signature.verify` accepts any
  signature in the header, enabling zero-downtime secret rollover.
- Custom-header reserved/transport denylist: `custom_headers` can no longer set
  the Standard Webhooks signature headers or dangerous transport headers
  (`host`, `content-length`, `content-type`, `transfer-encoding`, `connection`),
  rejected case-insensitively at validation.
- Delivery-attempt retention: `config.delivery_attempt_retention`,
  `Angarium::DeliveryAttempt.prune(older_than:)`, and a `bin/rails angarium:prune`
  rake task to keep `angarium_delivery_attempts` bounded.
