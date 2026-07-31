/// QUIC and WebTransport for Dart, over a native library.
///
/// **This release claims the name and nothing more.** There is no transport
/// here yet: it exists so the publishing pipeline, the package layout and the
/// build matrix can be proved on something that cannot break a caller.
///
/// What it is going to be: an HTTP/3 endpoint a Dart process can serve
/// directly, so a browser client can talk to it over WebTransport instead of
/// polling REST. Dart has no QUIC of its own — both SDK issues were closed as
/// not planned — so the implementation lives in a native library and is
/// reached through `dart:ffi`.
library;

/// The version this package reports about itself.
///
/// Deliberately a plain constant rather than a read of the pubspec: the first
/// thing the build pipeline has to prove is that a package can be published,
/// resolved and called at all. Anything that could fail for its own reasons
/// would blur that answer.
const String rkQuicVersion = '0.0.1';

/// Whether a native transport is available in this build.
///
/// Always `false` for now, and honest about it: a caller that asks gets a
/// straight answer instead of a method that throws on use. When the native
/// library lands, this becomes a real probe.
bool get hasNativeTransport => false;
