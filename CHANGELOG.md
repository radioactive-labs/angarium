# Changelog

## [0.1.0] - Unreleased

### Added
- Rails engine (headless) with `Angarium::Endpoint`, `Event`, `Delivery`, `DeliveryAttempt`.
- `Angarium::Delivery.reap_stalled` + `angarium:reap` rake task to recover
  deliveries stranded in `delivering` by a crashed worker (`config.delivering_timeout`).
- `Angarium.dispatch` event fan-out to active, subscribed endpoints.
- Webhook signatures follow the [Standard Webhooks](https://www.standardwebhooks.com)
  spec (`webhook-id`/`webhook-timestamp`/`webhook-signature` headers, `whsec_`
  secrets, HMAC-SHA256 over `id.timestamp.body`), so receivers can verify with
  off-the-shelf `standardwebhooks`/Svix libraries in any language.
  `Angarium::Signature.verify` is provided as a convenience.
- ActiveJob-based delivery with retries and exponential backoff.
- SSRF protection: global private-IP block, per-endpoint `allow_private_network`
  and `allowed_networks` controls, enforced at validation and delivery time.
- Install generator and migrations.
- Connect-time IP pinning: deliveries pin to the validated resolved address,
  closing the DNS-rebinding window.
- Delivery fails closed on hosts it can't resolve (never falls back to an
  unvalidated HTTPX resolution), fully closing the DNS-rebinding
  resolver-divergence gap.
- Endpoint `signing_secret` is encrypted at rest with Active Record Encryption
  (requires the host app to configure encryption keys).
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
- Endpoint auto-disable after `config.auto_disable_endpoint_after` consecutive
  failed deliveries (`consecutive_failures`/`disabled_at`), resetting on success.
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
