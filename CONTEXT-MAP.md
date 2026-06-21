# Context Map

## Contexts

- [Product Model](./docs/contexts/product/CONTEXT.md) - names the product, meeting-asset model, and smart-minutes concepts.
- [Python Runtime](./docs/contexts/python-runtime/CONTEXT.md) - names the local speech, transcript, insight, and sidecar runtime concepts.
- [macOS App](./docs/contexts/macos-app/CONTEXT.md) - names the native user workflows, session states, records review, and media interactions.
- [Release Workflow](./docs/contexts/release-workflow/CONTEXT.md) - names the evidence, gate, and release-channel vocabulary used to judge readiness.
- [Integrations](./docs/contexts/integrations/CONTEXT.md) - names the AttentionOS module and external-host contract concepts.

## Relationships

- **Product Model -> Python Runtime**: the runtime produces transcripts and insight packages using the product model's meeting-asset vocabulary.
- **Product Model -> macOS App**: the app presents the product model as live, import, record-review, and export workflows.
- **Python Runtime -> macOS App**: the app requests runtime actions and receives transcript, job, provider, and insight results.
- **macOS App -> Release Workflow**: release evidence must prove the installed app can complete the user-visible workflows, not only pass isolated tests.
- **Python Runtime -> Release Workflow**: release evidence must also prove the sidecar/runtime remains compatible with the packaged app.
- **Integrations -> Python Runtime**: external hosts call a small set of bridge actions that delegate to the InsightKit runtime.
- **Integrations -> Product Model**: integration outputs should preserve InsightKit's meeting-asset vocabulary instead of adopting host-specific labels.
