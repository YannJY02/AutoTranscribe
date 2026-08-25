# Triage labels

| Role | GitHub label | Meaning |
| --- | --- | --- |
| `needs-triage` | `needs-triage` | Maintainer must classify or complete the task contract |
| `needs-info` | `needs-info` | Waiting for reporter or owner-controlled input |
| `ready-for-agent` | `ready-for-agent` | Unblocked task contract passes and unattended execution is allowed |
| `ready-for-human` | `ready-for-human` | Agent work or evidence awaits human acceptance |
| `wontfix` | `wontfix` | Maintainer decided not to proceed |

An active issue has exactly one label from this table. Only humans or deterministic preflight may authorize `ready-for-agent`. Agentic triage may suggest suitability, but must not apply that label. Active state lives on GitHub; status lines in `.scratch/` are historical.
