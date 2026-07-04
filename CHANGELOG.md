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
