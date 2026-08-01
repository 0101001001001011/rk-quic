# Security

## Reporting a vulnerability

Not through a public issue. Use **Security → Report a vulnerability** in this
repository — that is GitHub's private channel.

A reply within a week. If the vulnerability is confirmed, the fix ships as a
version of its own, and the description is published after that version is
out, not before.

## What counts as a vulnerability here

The package talks to the network and loads native code, so the following count
as vulnerabilities: bypassing certificate validation, accepting data from an
unauthenticated party as trusted, reading or writing past the end of a buffer
in the native part, and loading a library from a path an outsider can control.

## What this package does not do

It does not store credentials and does not decide who to trust. Certificates,
their validation and their expiry are the caller's responsibility. The package
is obliged only not to weaken what it was handed.
