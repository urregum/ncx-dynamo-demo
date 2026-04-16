# Security Policy

## Reporting a Vulnerability

Please **do not** report security vulnerabilities through public GitHub issues.

Instead, email the maintainer directly at the address on the GitHub profile.
Include a description of the issue, steps to reproduce, and any relevant logs
or configuration details. You can expect an acknowledgement within 48 hours.

## Scope

This project is a local development demo environment — it creates a Kind
cluster on your own machine and does not expose services externally. It has
no authentication layer, no user data, and no production deployment path.

The primary security surface is the dependency chain (container images,
Helm charts, Python packages). If you identify a dependency with a known CVE
that materially affects the demo, a report is welcome but a public issue is
also acceptable in that case given the limited attack surface.
