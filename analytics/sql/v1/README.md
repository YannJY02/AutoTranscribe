# Product analytics query contract v1

These repository-owned queries answer the PM questions accepted in issue #53. They pin event schema `1`, a named environment, and a caller-supplied UTC window. Dashboard views must use these definitions without editing their formulas.

| Query | Metric definition | Product decision |
| --- | --- | --- |
| `activation.sql` | consented installations with a completion / installations with a start | diagnose first-success friction |
| `maswr.sql` | completed eligible attempts / started eligible attempts, with all four Live/Import × local/cloud segments | choose the next workflow bottleneck; no target is implied |
| `funnel.sql` | ordered start → save → review → export events, paired by each start sequence within an app session | prioritize actionable drop-off |
| `recovery.sql` | actionable failures followed by recovery in the same sequential workflow or reopened-record context | improve prevention, guidance, or retry |
| `latency_guardrails.sql` | success and measured provider-analysis latency-bucket distribution by release/provider/mode | investigate path regressions |
| `retention.sql` | later successful workflows at days 7–13 and day 28 | future diagnostic; D28 stays inside the 30-day raw-retention boundary |
| `data_quality.sql` | unknown schema/event/enum, missing terminal dimensions, and excess-completion diagnostics | reject incomplete or ambiguous evidence |
| `reconciliation.sql` | remote aggregate event counts for comparison with the local evidence manifest | prove ingestion readback without uploading private attempt IDs |

The root `*.sql` files execute against the normalized relation `events(event_name, timestamp_utc, event_sequence, schema_version, environment, app_version, app_build, installation_id, app_session_id, workflow, analysis_mode, provider_class, phase, outcome, error_code, recovery_action, duration_bucket_ms, latency_bucket_ms, retry_count, result_count, module_count)`. The matching `posthog/*.hogql` files are the dashboard-ready forms: each maps PostHog's native `event`, `timestamp`, and `properties.*` fields into that relation and uses the saved SQL variables `environment`, `window_start`, and `window_end`. Dashboard views must save the matching HogQL file without changing its formula.

Automatic watcher admissions are not v1 eligible Import attempts: they are not explicit Import actions and a batch can overlap within one app session. Adding watcher analytics requires the new privacy/correlation decision reserved by YAN-42.

`event_sequence` preserves order within the short-lived app session. Queries derive sequential workflow groups from accepted `workflow_started` events and fail closed when attempts overlap. No workflow, Meeting, record, job, or attempt identifier/ordinal is uploaded; supporting concurrent attempts requires a new privacy decision.

`duration_bucket_ms` measures the full accepted workflow. `latency_bucket_ms` measures the provider/build analysis call only; queries exclude missing latency rather than substituting total meeting or user-wait time. Multiple sequential attempts in one app session are valid and are paired with window functions instead of being treated as duplicate data. Windowed attempt metrics count only attempts whose `workflow_started` falls inside the window. A terminal whose start predates the window is excluded only when retained pre-window history proves an open attempt; otherwise the readback fails closed as an orphan boundary terminal. A new start before that retained boundary attempt closes is ambiguous and also fails closed. `record_reopened` advances the funnel context so later review/export events cannot complete an older creation attempt.

Run `scripts/reconcile_product_analytics.py` against the local aggregate manifest and saved remote readback. Its versioned output preserves `partial-ingestion`, `opt-out`, `deletion-pending`, `late-offline-delivery`, `retention-window-expired`, and `query-failure` instead of manufacturing a complete metric. D28 must be read while the first success is still inside the 30-day raw-event window; older cohorts remain insufficient rather than being re-cohorted.

PostHog must be configured with autocapture, screen/lifecycle capture, person profiles/identify, surveys, replay, and tracing headers disabled. Remote ingestion, saved-query IDs, retention/deletion readback, and dashboard links remain owner-controlled verification when credentials are available.
