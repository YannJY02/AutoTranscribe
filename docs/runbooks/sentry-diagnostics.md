# Sentry diagnostics investigation

InsightKit telemetry is default-off. The runtime transport is created only when
`INSIGHTKIT_EXTERNAL_TELEMETRY_ENABLED=1` and a valid HTTPS `INSIGHTKIT_SENTRY_DSN`
are present. Delivery additionally requires the central privacy gate's persisted
opt-in; the environment never grants or restores consent, so a persisted opt-out
wins. Consent contract v2 explicitly covers both PostHog and Sentry; an older v1
PostHog-only grant fails closed and must be confirmed again. The DSN is
environment-specific. `SENTRY_AUTH_TOKEN`, organization,
and project values are release-administration inputs and must never enter the app,
repository, logs, or proof artifacts.

Sentry uses the same optional `INSIGHTKIT_ANALYTICS_ENVIRONMENT` override as
product analytics; debug builds default to `development` and release builds to
`release`.

The Settings control is deliberately unified with PostHog availability. A build
without a configured PostHog transport cannot enable external telemetry; if a
stale opt-in is present, initialization revokes it and purges both vendor queues.
Sentry-only deployment is not a supported state because it would leave the shared
consent unavailable for readback and revocation.

Set `INSIGHTKIT_EXTERNAL_TELEMETRY_ENABLED=0` to explicitly disable telemetry. On
the next launch this invokes the central gate's cryptographic purge, deletes its
bounded queue and queue key, and constructs no Sentry transport. An absent setting
also performs no network work but deliberately does not rewrite persisted consent.

## Privacy and failure boundary

All events first pass `ExternalTelemetryPrivacyGate`. Sentry receives only its
approved JSON envelope. The adapter has no automatic SDK collectors and therefore
does not enable PII, screenshots, replay, view hierarchy, attachments, raw
breadcrumbs/logs, request data, provider payloads, paths, messages, or local
variables. Delivery is best-effort on a utility queue with a ten-second request
and bounded-wait timeout; rejection or unavailability cannot block or crash a workflow.

Sentry uses its own environment-partitioned encrypted queue under
`InsightKit/Telemetry/Sentry/<environment>`; shared
consent and queue-key erasure still make one opt-out a cryptographic purge without
letting Sentry consume product-analytics records. Pending-write capacity is also
counted per durable queue, so a saturated product-analytics queue cannot reject a
Sentry diagnostic. On the first upgraded launch, any legacy unpartitioned Sentry
queue is purged and consent must be confirmed again before delivery. The app-level
consent control is delivered by YAN-54, so production opt-in remains blocked until
that dependency is merged.

Failure return addresses are captured at the workflow call site before the
asynchronous product-analytics submission hop and forwarded without local variables,
messages, paths, or other meeting content.

The local lifecycle marker reports clean exits and abandoned sessions. It does not
distinguish a crash from force-quit, so a vendor crash-free-rate claim remains
blocked until an owner-approved crash-safe Sentry SDK/session integration is
configured and read back remotely.

Startup drains the prior-session queue before recording the current release
session; failures during that window are retained and applied when the start is
persisted. The app uses an atomic per-user file lock for one lifecycle-owning
process, so a second launch activates the existing app instead of sharing the
Sentry session queue. If a full backlog cannot be delivered, the bounded queue
replaces only a non-session item and preserves both open and terminal session evidence;
the local `queueFull` diagnostic records that replacement. Workflow failures increment the
durable session error count even when the app later exits cleanly.

Delivery remains bounded to one in-flight request. When the slot frees, one
coalesced catch-up drain retries accepted durable envelopes without waiting for
restart. A delivered terminal marker clears retry state only for its matching
`app_session_id`, so another open session cannot emit a duplicate start marker.

## Local synthetic proof

Run:

```bash
cd macos/InsightKitApp
swift test --filter SentryDiagnosticsAdapterTests
swift test --filter ExternalTelemetryPrivacyGateTests
```

`testRawFailureContentIsScrubbedBeforeSyntheticTransportReceivesEnvelope` is the
matching deterministic readback. It injects meeting text, a user path, a bearer
token, breadcrumbs, contexts, and an attachment, then proves none reaches the
synthetic transport while release/build/environment and closed workflow fields do.

## Remote release and alert proof (owner-controlled)

Build the named release with dSYMs, then run `scripts/sentry_release.sh VERSION BUILD
PATH_TO_DSYM` with `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, and `SENTRY_PROJECT` supplied
outside the repository. Enable telemetry explicitly in the synthetic build and
set `INSIGHTKIT_SENTRY_SYNTHETIC_FAILURE=1` for one launch. Remove it immediately
after capture so ordinary launches cannot create the probe.

In Sentry, query release `com.yannjy.insightkit@VERSION+BUILD` and error event
whose transaction field is `workflow_failed`. Verify the event is symbolicated, release health is visible,
only allowlisted tags exist, server-side scrubbing and retention match owner policy,
and the configured synthetic-failure alert reaches its owner-selected route. Link
the resulting event and alert evidence to the local test above. Dashboard access,
credentials, retention changes, and alert-route creation are human-only acceptance;
absence must be reported as an external blocker, never inferred from local proof.
