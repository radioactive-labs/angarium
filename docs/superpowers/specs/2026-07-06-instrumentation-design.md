# Angarium Instrumentation (ActiveSupport::Notifications)

- **Date:** 2026-07-06
- **Status:** Approved (design)
- **Scope:** Add Rails-native instrumentation to the delivery pipeline.

## Context

Angarium already exposes two observability legs:

- **Audit trail** — every `Angarium::DeliveryAttempt` persists `response_code`, `response_body`, `error`, and `duration`, so success rates and latencies are queryable after the fact.
- **Alerting hooks** — `on_delivery_exhausted`, `on_endpoint_deactivated`, and `on_endpoint_verified` fire on terminal business events.

The missing leg is **aggregate, real-time metrics**: throughput, latency histograms, success/failure/retry rates, and fan-out size, streamed into a host's metrics/tracing backend (StatsD, Prometheus, Datadog, OpenTelemetry) without polling the database or hand-rolling counters inside the callbacks.

`ActiveSupport::Notifications` is the Rails-idiomatic answer. The engine already lives alongside libraries that instrument this way (`sql.active_record`, `perform.active_job`, Solid Queue), so hosts have subscribers wired for the `<action>.<namespace>` shape.

## Goals

- Emit two `ActiveSupport::Notifications` events covering the delivery lifecycle.
- Keep payloads free of secrets and PII.
- Stay purely additive: callbacks and `DeliveryAttempt` rows are untouched.

## Non-goals

- No built-in metrics adapter (StatsD/Prometheus/OTel) — headless, the host wires its own backend, mirroring how the callbacks leave notification delivery to the host.
- No per-endpoint counters/gauges inside the gem (cardinality is the host backend's concern).
- No instrumentation of endpoint state transitions or signing — those are already covered by the callbacks, and adding them would duplicate that surface.

## Events

### `deliver.angarium`

Wraps the body of `Angarium::Delivery#deliver!` in `ActiveSupport::Notifications.instrument`, firing **once per call** regardless of outcome.

| Key | Type | Notes |
| --- | --- | --- |
| `delivery_id` | id | |
| `endpoint_id` | id | |
| `event` | string | the event name being delivered |
| `outcome` | symbol | see the outcome enum below |
| `attempt` | integer | attempt number; present once an attempt is consumed, `nil` for `held`/`canceled` (they return before the counter increments) |
| `code` | integer | HTTP status; present only when a response was received (`delivered`/`gone`/`failed`-with-response) |
| `http_duration` | float | client-measured wire time in seconds; present when an HTTP request was attempted (absent for `held`/`canceled`/`blocked`/`unresolvable`) |
| `error` | string | exception class + message, on `failed`/`blocked`/`unresolvable` |
| `force` | boolean | whether the guard was bypassed (manual ping/redeliver) |

**Outcome enum** (this attempt's result, not the delivery's terminal state — a `failed`/`unresolvable` attempt may retry and emit again):

| `outcome` | Meaning | HTTP made? |
| --- | --- | --- |
| `delivered` | 2xx response | yes |
| `failed` | non-2xx (not 410) or transport error; will retry per schedule | yes (or transport error) |
| `gone` | 410 response; endpoint moved to `gone` | yes |
| `held` | endpoint `paused`; parked, no attempt consumed | no |
| `canceled` | endpoint `disabled`/`gone` at guard time; delivery `canceled` | no |
| `blocked` | resolved address not permitted (SSRF guard) | no |
| `unresolvable` | host did not resolve; retryable | no |

`blocked` and `unresolvable` still consume an attempt and write a `DeliveryAttempt` row (so `attempt` and `error` are set), but make no HTTP call (so `code`/`http_duration` are absent). `held` and `canceled` return before an attempt is consumed.

The event's own start/finish duration measures total processing (guard + DB writes + wire); `http_duration` isolates the network. Subscribers use whichever they need.

### `dispatch.angarium`

Wraps `Angarium.dispatch`, firing once per call.

| Key | Type | Notes |
| --- | --- | --- |
| `event` | string | event name dispatched |
| `event_id` | id | the created `Angarium::Event` |
| `deliveries` | integer | number of deliveries fanned out to subscribed endpoints |

## Implementation

- **`deliver.angarium`:** wrap the `deliver!` method body in `ActiveSupport::Notifications.instrument("deliver.angarium", payload) do ... end`, seeding `payload` with `delivery_id`, `endpoint_id`, `event`, and `force` up front. Set `payload[:outcome]` (and `code`/`http_duration`/`error`/`attempt` where applicable) before each return path. `instrument`'s `ensure` fires the event even on the guard's early returns, and captures/re-raises any unexpected exception into `payload[:exception]` automatically.
- **`dispatch.angarium`:** wrap the fan-out in `Angarium.dispatch`, recording the created event and the count of deliveries produced, and set the payload before returning.
- Instrumentation adds no new configuration and no dependency (`ActiveSupport::Notifications` ships with Rails).

## Security

Payloads carry ids, event name, status code, error string, and timings only. They never include the signing secret, custom headers, or the request/response body — `error` is the exception message, not the response payload. This keeps subscriber output (logs, traces) safe to ship to third-party backends.

## Testing

- Subscribe via `ActiveSupport::Notifications.subscribed` in tests and assert exactly one `deliver.angarium` event per outcome, with the expected `outcome` and fields:
  - `delivered` (2xx), `failed` (500), `gone` (410), `held` (paused endpoint), `canceled` (disabled endpoint), `blocked` (SSRF-disallowed address), `unresolvable` (DNS failure).
- Assert `dispatch.angarium` fires with the correct `deliveries` fan-out count (e.g., two subscribed endpoints → `deliveries: 2`).
- Assert payloads never contain the signing secret or response body.
- Reuse the existing client stubbing used elsewhere in the suite.

## Documentation

Add a `## Instrumentation` section to the README:
- The two event names and their payload tables.
- A `subscribe` example feeding a metrics backend / structured log.
- Framed as the metrics leg beside the callbacks (alerting) and `DeliveryAttempt` rows (audit).

## Out of scope / future

- Optional shipped subscribers (a log subscriber, an OTel bridge) could be a fast-follow if demand appears, but the default stays notifications-only.
