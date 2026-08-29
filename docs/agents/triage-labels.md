# Triage labels

| Role | Shared Linear/GitHub label | Meaning |
| --- | --- | --- |
| `needs-triage` | `needs-triage` | Maintainer must classify or complete the task contract |
| `needs-info` | `needs-info` | Waiting for reporter or owner-controlled input |
| `ready-for-agent` | `ready-for-agent` | Unblocked task contract passes and unattended execution is allowed |
| `ready-for-human` | `ready-for-human` | Agent work or evidence awaits human acceptance |
| `wontfix` | `wontfix` | Maintainer decided not to proceed |

An active issue has exactly one label from this table. Apply it in Linear after triage and verify that native sync mirrors it to GitHub before Symphony dispatch. Only humans or deterministic preflight may authorize `ready-for-agent`; agentic triage may suggest suitability but must not apply it. Detailed task state lives in Linear, while GitHub open/closed state and labels are the execution mirror. Status lines in `.scratch/` are historical.
