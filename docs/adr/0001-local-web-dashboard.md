# ADR 0001: Local Web Dashboard for the Retry Monitor

## Status

Accepted

## Decision

Add a PowerShell-hosted local Web console. The host serves static HTML/CSS/JavaScript through `HttpListener`, starts the existing monitor as a child process, exposes JSON endpoints for status and settings, and stores pause state in a local control file. The monitor keeps ownership of UI Automation and retry semantics.

## Why

The existing product is a Windows PowerShell monitor with no frontend runtime. A local Web console gives the requested Apple-style glass UI without introducing a new build toolchain or a remote service. Keeping UI Automation in the monitor preserves the tested retry boundary, while the host can safely own process lifecycle and Windows logon-task configuration.

## Consequences

- The console is reachable only on loopback by default.
- Statistics are reconstructed from the active and rotated state JSONL files, so the UI reports the retained-history boundary.
- Pausing is cooperative: the monitor process stays alive and checks `retry-control.json` before each tick.
- Settings changes restart the monitor child so all parameters take effect consistently.
