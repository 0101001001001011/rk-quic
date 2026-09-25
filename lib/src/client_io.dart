// The client half, driven from Dart — and never from the interface isolate.
//
// The isolates, the poll loop and the reply-by-id matching live in
// `endpoint_io.dart` and are shared with the server half. What is here is what
// differs: connecting, and opening a stream.
//
// # Why a connected client is so small
//
// Because after the connection there is nothing left that differs. A session
// is a session, a stream is a stream, and an event is the same event: the
// native side registers a client in the same endpoint registry the server uses
// (`transport::connect`), so writing into a stream, finishing one and stopping
// the endpoint are the calls that already existed.
//
// The alternative — a client with its own registry, its own poll and its own
// event names — would be two vocabularies for one exchange, and they would
// disagree on a live wire rather than at the build.

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart' show Utf8;

import 'endpoint_io.dart';
import 'quic_event.dart';
import 'status.dart';

/// What a caller has to say to connect.
class QuicClientConfig {
  const QuicClientConfig({
    required this.url,
    required this.certificateHashSha256,
    this.idleTimeout = const Duration(seconds: 30),
  });

  /// Where to connect: `https://host:port/path`.
  ///
  /// `https`, because that is how WebTransport names an endpoint — the same
  /// string a browser is given.
  final String url;

  /// SHA-256 of the certificate this client will accept, hex, 64 characters.
  ///
  /// **Required, and the only rule on offer.** The till issues its own
  /// certificate and no authority vouches for it; the browser half of this
  /// system pins it by hash (`serverCertificateHashes`) and so does this. A
  /// "trust anything" option would be an option that gets used.
  final String certificateHashSha256;

  /// How long a silent session lives before it is called gone.
  final Duration idleTimeout;

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'certificateHashSha256': certificateHashSha256,
    'idleTimeoutMs': idleTimeout.inMilliseconds,
  };
}

/// What came back from an attempt to connect.
///
/// A record and not an exception (И144): a till that is off, a network that
/// dropped and a certificate that was rotated are ordinary answers on a
/// handheld, and the caller decides which of them is worth an operator's
/// attention.
class QuicClientConnect {
  const QuicClientConnect._(this.status, this.client, this.detail);

  final RkQuicStatus status;

  /// The connection, or `null` when [status] is anything but
  /// [RkQuicStatus.ok].
  final QuicClient? client;

  /// What went wrong, in a sentence, when something did.
  final String? detail;

  bool get isConnected => client != null;
}

/// A live connection to a WebTransport endpoint.
class QuicClient {
  QuicClient._(this._commands, this._pollIsolate, this._events, this.sessionId);

  final CommandChannel _commands;
  final Isolate _pollIsolate;
  final Stream<QuicEvent> _events;

  /// The session this connection is.
  ///
  /// A client has exactly one and it is known before any event arrives, so a
  /// caller never has to wait for `sessionOpened` to be able to ask something.
  /// The event still comes — the two halves say the same thing, and a caller
  /// that watches events rather than fields is not a special case.
  final int sessionId;

  bool _stopped = false;

  /// Events, in the order the connection saw them.
  Stream<QuicEvent> get events => _events;

  /// Connects. Never throws.
  static Future<QuicClientConnect> connect(
    QuicClientConfig config, {
    List<String>? candidatePaths,
  }) async {
    final commands = await CommandChannel.spawn(candidatePaths);
    if (commands == null) {
      return const QuicClientConnect._(
        RkQuicStatus.unsupported,
        null,
        'the native library could not be loaded; call probeNativeLibrary() '
        'for which of missing, wrong file or wrong ABI it was',
      );
    }

    final connected = await commands.send(ConnectCommand(config.toJson()));
    if (connected is! ConnectedReply) {
      await commands.dispose();
      return QuicClientConnect._(
        connected is StatusReply ? connected.status : RkQuicStatus.unrecognised,
        null,
        connected is StatusReply ? connected.detail : 'unexpected reply',
      );
    }

    final eventPort = ReceivePort();
    final pollIsolate = await Isolate.spawn(
      pollLoop,
      PollRequest(
        handle: connected.handle,
        candidatePaths: candidatePaths,
        events: eventPort.sendPort,
      ),
      debugName: 'rk_quic-poll',
    );

    final events = eventPort
        .map((message) => QuicEvent.fromJson(message as String))
        .asBroadcastStream();

    return QuicClientConnect._(
      RkQuicStatus.ok,
      QuicClient._(commands, pollIsolate, events, connected.sessionId),
      null,
    );
  }

  /// Opens a bidirectional stream and returns its id, or a status.
  ///
  /// On this wire the client is the side that asks, and an exchange **is** a
  /// stream: the question goes in, the caller finishes its half, and the
  /// answer comes back on the same id. See `till_wire.dart`.
  Future<(RkQuicStatus, int?)> openStream() async {
    if (_stopped) return (RkQuicStatus.notRunning, null);
    final reply = await _commands.send(OpenStreamCommand(sessionId));
    if (reply is StreamOpenedReply) return (RkQuicStatus.ok, reply.streamId);
    if (reply is StatusReply) return (reply.status, null);
    return (RkQuicStatus.unrecognised, null);
  }

  /// Writes UTF-8 into a stream without ending it.
  Future<RkQuicStatus> sendOn(int streamId, String message) async {
    if (_stopped) return RkQuicStatus.notRunning;
    final reply = await _commands.send(
      StreamSendCommand(sessionId, streamId, message),
    );
    return reply is StatusReply ? reply.status : RkQuicStatus.unrecognised;
  }

  /// Finishes this side of a stream: the question is whole, nothing more is
  /// coming. The answer half stays open.
  Future<RkQuicStatus> closeStream(int streamId) async {
    if (_stopped) return RkQuicStatus.notRunning;
    final reply = await _commands.send(StreamCloseCommand(sessionId, streamId));
    return reply is StatusReply ? reply.status : RkQuicStatus.unrecognised;
  }

  /// Sends UTF-8 to the session itself, as a datagram or on its own stream.
  Future<RkQuicStatus> send(String message, {bool reliable = true}) async {
    if (_stopped) return RkQuicStatus.notRunning;
    final reply = await _commands.send(
      SendCommand(sessionId, message, reliable),
    );
    return reply is StatusReply ? reply.status : RkQuicStatus.unrecognised;
  }

  /// Closes the connection and frees everything it owns. Idempotent.
  Future<RkQuicStatus> close() async {
    if (_stopped) return RkQuicStatus.ok;
    _stopped = true;
    final reply = await _commands.send(const StopCommand());
    _pollIsolate.kill(priority: Isolate.immediate);
    await _commands.dispose();
    return reply is StatusReply ? reply.status : RkQuicStatus.unrecognised;
  }
}

/// Connect, on the command isolate.
class ConnectCommand {
  const ConnectCommand(this.configJson);
  final Map<String, Object?> configJson;
}

/// Open a stream, on the command isolate.
class OpenStreamCommand {
  const OpenStreamCommand(this.sessionId);
  final int sessionId;
}

/// The handle and the session id a connection came back with.
class ConnectedReply {
  const ConnectedReply(this.handle, this.sessionId);
  final int handle;
  final int sessionId;
}

/// The id of a stream that was opened.
class StreamOpenedReply {
  const StreamOpenedReply(this.streamId);
  final int streamId;
}

/// Reads a `uint64` out, for the two client calls that write one.
int readHandle(ffi.Pointer<ffi.Uint64> out) => out.value;

/// Kept so the analyser sees `Utf8` used from here as well as in the shared
/// file; the bindings are reached through [CommandChannel].
typedef ClientUtf8 = Utf8;
