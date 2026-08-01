## 0.1.0

The first version with a native part — and a QUIC endpoint that speaks first.

- `QuicServer.start()` brings up an HTTP/3 endpoint and accepts WebTransport
  sessions; `server.events` yields `sessionOpened`, `sessionClosed`, `datagram`
  and `streamMessage`; `server.send()` writes into a session over a stream
  (ordered, retransmitted) or as a datagram. Implemented on **quinn** — see the
  README for why not quiche.
- Everything that blocks — waiting for an event and sending reliably — is on
  helper isolates: the interface isolate never enters the native part (И145).
- `idleTimeoutMs` is mandatory and has no "never" value. Measured: without it a
  client that vanished without warning is not noticed at all — the server had
  still not seen `sessionClosed` twenty seconds after the client left.
- The package does not issue certificates: that is `rk_pki`'s job. The chain has
  one representation across both packages —
  `rustls_pki_types::CertificateDer`.

**Breaking.** `rkQuicVersion` was a `const String` and is now a `String?`, read
out of the loaded library. A constant would go on reporting the right version
while a year-old library sat next to it; that is what the version was raised
for.

- `hasNativeTransport` is now a real probe: it opens the library and checks the
  ABI generation. No longer a stub returning `false`.
- `probeNativeLibrary()` returns a `NativeProbe`: `loaded`,
  `unsupportedPlatform`, `libraryMissing`, `symbolMissing`, `abiMismatch`. Not
  one of these cases throws an exception or brings the process down.
- Statuses cross the boundary **by name**, not by number; an unfamiliar name
  becomes `RkQuicStatus.unrecognised` rather than somebody else's branch.
- The native part builds and reaches the application on Windows, Linux and
  Android. For macOS and iOS the build files are written but **not confirmed by
  a build** — there is no Mac available.
- The package is safe to import in a browser: `dart:ffi` is behind a
  conditional import.

## 0.0.1

- Name claimed. No content yet: the package proves the publishing
  pipeline, it does not solve the problem.
