# Security Policy

## Supported versions

Angarium is pre-release. Security fixes are provided for the `0.1.x` series
during this phase. Once a stable line is released, this policy will be updated to
list the versions that receive security updates.

| Version | Supported |
| ------- | --------- |
| 0.1.x   | ✅        |

## Reporting a vulnerability

Please report security vulnerabilities **privately**. Do **not** open a public
issue, pull request, or discussion for a suspected vulnerability.

Use GitHub's private vulnerability reporting for the
[`radioactive-labs/angarium`](https://github.com/radioactive-labs/angarium)
repository: go to the **Security** tab and choose **Report a vulnerability**
(this opens a private draft advisory visible only to the maintainers).

We aim to acknowledge new reports within a few business days, and we'll keep you
informed as we investigate and prepare a fix. Please give us a reasonable window
to release a patch before any public disclosure.

## Security surfaces Angarium hardens

Angarium is designed to send user-configured webhooks safely. The intended
security guarantees, and the surfaces you can hold us to, are:

- **SSRF protection.** Endpoint URLs are user-supplied, so delivery is guarded by
  an address policy that blocks private/loopback/link-local addresses by default,
  requires an explicit per-endpoint opt-in for private networks, and **fails
  closed** on hosts it can't resolve.
- **Connect-time IP pinning.** Deliveries pin the connection to the validated
  resolved address, closing the DNS-rebinding window between resolution and
  connect (TLS SNI and certificate verification still use the original hostname).
- **Encrypted secrets at rest.** Endpoint signing secrets (current and
  in-rotation previous) and `custom_headers` (which commonly carries a receiver
  credential such as an Authorization bearer token) are encrypted at rest with
  Active Record Encryption.
- **Standard Webhooks HMAC signing.** Requests are signed per the
  [Standard Webhooks](https://www.standardwebhooks.com) spec (HMAC-SHA256 over
  `{id}.{timestamp}.{body}`) with a timestamp tolerance enforced on verification
  to resist replay.
- **Custom-header denylist.** Per-endpoint custom headers cannot override the
  signature headers or dangerous transport headers (request-smuggling and
  receiver-confusion surface).

If you find a gap in any of these guarantees, we especially want to hear about it.
