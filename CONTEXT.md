# Retry Monitor Dashboard Context

## Purpose

The project is a local Windows operator console for the Codex Desktop retry monitor. The console controls the monitor process and explains the retained retry history without sending rollout data to a remote service.

## Terms

- **Monitor**: The PowerShell process that watches rollout JSONL files and invokes a verified Retry action.
- **Console**: The local Web UI and its PowerShell host process.
- **Paused**: The monitor process remains alive, but it stops reading new retry events and stops automatic retry work until resumed.
- **Session**: A Codex conversation identified by its session id; the source path is used only as a fallback identity.
- **Capacity error**: A turn-scoped error that matches the monitor's capacity classifier.
- **Attempt**: One verified Retry control invocation associated with a capacity error.
- **Success**: A verified Retry click recorded as `retry-clicked`; the dashboard counts one click as one success.
- **Failure**: A `retry-failed` or `limit-reached` event retained in the state history. A later capacity response is a new capacity event, not a failure of the prior click.
- **Retained history**: The active state JSONL plus its configured rotated files. The console reports this boundary explicitly.

## User-facing invariants

- Pause does not terminate the monitor or clear history.
- Session statistics are independent; one session cannot consume another session's retry count.
- A failure reason is shown in normalized form in lists and as the original event detail in the session timeline.
- Autostart applies to the current Windows user through a logon task and does not require administrator access.
