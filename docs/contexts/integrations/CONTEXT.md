# Integrations

Language for InsightKit's external host integration surface. This context currently centers on the AttentionOS module path and should keep host-specific vocabulary from leaking into the product model.

## Current Boundary

The integration layer is optional. InsightKit's Python sidecar is primarily the local AI runtime for the native app, and external hosts must call proven product actions instead of creating parallel runtime behavior.

The current external host demand is not active enough to justify new integration-first runtime work. The AttentionOS Module remains a thin generated wrapper. Older Bridge Actions such as `insight.build_final` may be accepted as compatibility aliases, but they should forward to product actions such as `smart_minutes.generate`.

## Language

**AttentionOS Module**:
The loadable module bundle that lets AttentionOS call selected InsightKit actions.
_Avoid_: Plugin, extension

**Host App**:
The external application that loads or calls the InsightKit module.
_Avoid_: Client app, consumer

**Module Bundle**:
The generated folder that contains the module manifest, entrypoint, README, and state file for a host app.
_Avoid_: Export folder, package

**Bridge Action**:
A small supported operation exposed through the integration bridge, such as starting a session, refreshing live insight, building final insight, or exporting a document.
_Avoid_: RPC method, endpoint

**Host Call**:
A request from a host app into the InsightKit module with an action, meeting id, and payload.
_Avoid_: API request

**Bridge Payload**:
The host-provided data passed with a bridge action.
_Avoid_: Params, body

**Module State**:
The enabled or disabled state that controls whether a host should load the module.
_Avoid_: Config

**External Host Contract**:
The stable agreement between InsightKit and a host app about supported actions, required identifiers, and returned meeting-asset data.
_Avoid_: Integration docs
