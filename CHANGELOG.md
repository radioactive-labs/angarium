# Changelog

## [0.1.0] - Unreleased

### Added
- Mountable engine with `Angarium::Endpoint`, `Event`, `Delivery`, `DeliveryAttempt`.
- `Angarium.dispatch` event fan-out to active, subscribed endpoints.
- HMAC request signing and `Angarium::Signature.verify` helper.
- ActiveJob-based delivery with retries and exponential backoff.
- SSRF protection: global private-IP block, per-endpoint `allow_private_network`
  and `allowed_networks` controls, enforced at validation and delivery time.
- Install generator and migrations.
- Connect-time IP pinning: deliveries pin to the validated resolved address,
  closing the DNS-rebinding window.
- Endpoint `signing_secret` is encrypted at rest with Active Record Encryption
  (requires the host app to configure encryption keys).
- `Endpoint#regenerate_signing_secret!` to rotate an endpoint's signing secret.
- Endpoint URL/SSRF validation re-runs when `url`, `allow_private_network`, or
  `allowed_networks` change (and skips the DNS lookup on unrelated updates).
- Configurable `config.primary_key_type` for Angarium's own tables (defaults
  to the host app's generator setting, or bigint); polymorphic `owner_id` is
  now a string column so owners with any primary key type (bigint, UUID, or a
  mix) can be associated.
