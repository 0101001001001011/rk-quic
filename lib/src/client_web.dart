// The browser half of the conditional import in `client.dart`.
//
// A browser already has a WebTransport client — the `WebTransport` constructor
// — and reaching it through a native library it cannot load would be a worse
// version of something built in. So this is not a stub waiting to be filled
// in: it is the permanent, correct answer, and the reason `flutter build web`
// keeps passing (И143).
//
// The surface matches `client_io.dart` exactly, so a caller compiled for both
// does not have to know which half it got.

import 'dart:async';

import 'quic_event.dart';
import 'status.dart';

/// Mirrors the native side so the two halves present one surface.
class QuicClientConfig {
  const QuicClientConfig({
    required this.url,
    required this.certificateHashSha256,
    this.idleTimeout = const Duration(seconds: 30),
  });

  final String url;
  final String certificateHashSha256;
  final Duration idleTimeout;

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'certificateHashSha256': certificateHashSha256,
    'idleTimeoutMs': idleTimeout.inMilliseconds,
  };
}

/// What came back from an attempt to connect. In a browser, always the same
/// answer, and it is not a failure of this build — it is what a browser is.
class QuicClientConnect {
  const QuicClientConnect._(this.status, this.client, this.detail);

  final RkQuicStatus status;
  final QuicClient? client;
  final String? detail;

  bool get isConnected => client != null;
}

/// The shape of a connection, so code compiled for both halves type-checks.
class QuicClient {
  QuicClient._();

  int get sessionId => 0;

  Stream<QuicEvent> get events => const Stream<QuicEvent>.empty();

  /// Always [RkQuicStatus.unsupported], and permanently so.
  ///
  /// A browser reaches a WebTransport endpoint with its own `WebTransport`
  /// constructor. Use that; this package is the half a browser talks *to*.
  static Future<QuicClientConnect> connect(
    QuicClientConfig config, {
    List<String>? candidatePaths,
  }) async => const QuicClientConnect._(
    RkQuicStatus.unsupported,
    null,
    'a browser has its own WebTransport client; this package is the endpoint '
    'it connects to, not a second way of connecting',
  );

  Future<(RkQuicStatus, int?)> openStream() async =>
      (RkQuicStatus.unsupported, null);

  Future<RkQuicStatus> sendOn(int streamId, String message) async =>
      RkQuicStatus.unsupported;

  Future<RkQuicStatus> closeStream(int streamId) async =>
      RkQuicStatus.unsupported;

  Future<RkQuicStatus> send(String message, {bool reliable = true}) async =>
      RkQuicStatus.unsupported;

  Future<RkQuicStatus> close() async => RkQuicStatus.ok;
}
