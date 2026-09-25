// The server half, driven from Dart — and never from the interface isolate.
//
// The isolates, the poll loop and the reply-by-id matching live in
// `endpoint_io.dart`: since 0.3.0 the client half needs every one of them, and
// a second copy would be a second place to fix one defect.
//
// **И145 is the shape of this file.** Two things here would stall a UI: the
// poll call blocks a thread until an event arrives or the wait runs out, and
// a reliable send waits for the stream to be opened and flushed. Both live on
// helper isolates, and the interface isolate only ever sends and receives
// messages.
//
// Two isolates and not one, deliberately. The poller spends its life inside a
// blocking call; if commands shared that isolate, every stop and every send
// would queue behind the current wait. A `stop` that takes a fifth of a second
// to be noticed is the difference between a clean shutdown and one that looks
// hung.

import 'dart:async';
import 'dart:isolate';


import 'endpoint_io.dart';
import 'quic_event.dart';
import 'status.dart';

/// How long the poller waits inside one native call.
///
/// Not a latency: an event arriving during the wait returns at once. It is how
/// long a stopped endpoint can take to notice it should exit, so it is short.
const Duration pollSlice = Duration(milliseconds: 200);

/// What a caller has to say to start an endpoint.
class QuicServerConfig {
  const QuicServerConfig({
    required this.bindAddress,
    required this.certificateChainPem,
    required this.privateKeyPem,
    this.path = '/rk',
    this.idleTimeout = const Duration(seconds: 30),
  });

  /// `"0.0.0.0:4433"`. A port of 0 asks the operating system to choose, and
  /// [QuicServer.port] then reports what it chose.
  final String bindAddress;

  /// The chain, leaf first. PEM is how a certificate *travels*; it is the same
  /// DER `rk_pki` deals in on the other side of the wire.
  final String certificateChainPem;

  /// The leaf's private key, PKCS#8 PEM.
  final String privateKeyPem;

  /// The path a client connects to. Anything else is refused, so a stray
  /// connection is never mistaken for a session.
  final String path;

  /// How long a silent session may stay open.
  ///
  /// There is no value meaning "never", and that is the point: a browser tab
  /// killed by the operating system sends nothing, so without a bound the
  /// endpoint would hold the session and go on believing someone is there.
  final Duration idleTimeout;

  Map<String, Object?> toJson() => {
    'bindAddress': bindAddress,
    'certificateChainPem': certificateChainPem,
    'privateKeyPem': privateKeyPem,
    'path': path,
    'idleTimeoutMs': idleTimeout.inMilliseconds,
  };
}

/// What came back from an attempt to start.
///
/// A record and not an exception (И144): "the port is taken" is an ordinary
/// answer on a till where something else may already be serving, and the
/// caller decides whether that is worth telling an operator.
class QuicServerStart {
  const QuicServerStart._(this.status, this.server, this.detail);

  final RkQuicStatus status;

  /// Non-null exactly when [status] is [RkQuicStatus.ok].
  final QuicServer? server;

  /// One line for a log. Never the sole carrier of meaning.
  final String? detail;

  bool get isOk => status == RkQuicStatus.ok;

  @override
  String toString() =>
      'QuicServerStart(${status.name}${detail == null ? '' : ', $detail'})';
}

/// A running endpoint.
class QuicServer {
  QuicServer._(this._commands, this._pollIsolate, this._events, this.port);

  final CommandChannel _commands;
  final Isolate _pollIsolate;
  final Stream<QuicEvent> _events;

  /// The port actually bound.
  final int port;

  bool _stopped = false;

  /// Events, in the order the endpoint saw them.
  ///
  /// This is the whole point of the package: the server speaks first, and this
  /// is where a caller hears it.
  Stream<QuicEvent> get events => _events;

  /// Starts an endpoint. Never throws.
  static Future<QuicServerStart> start(
    QuicServerConfig config, {
    List<String>? candidatePaths,
  }) async {
    final commands = await CommandChannel.spawn(candidatePaths);
    if (commands == null) {
      return const QuicServerStart._(
        RkQuicStatus.unsupported,
        null,
        'the native library could not be loaded; call probeNativeLibrary() '
        'for which of missing, wrong file or wrong ABI it was',
      );
    }

    final started = await commands.send(StartCommand(config.toJson()));
    if (started is! StartedReply) {
      await commands.dispose();
      return QuicServerStart._(
        started is StatusReply ? started.status : RkQuicStatus.unrecognised,
        null,
        started is StatusReply ? started.detail : 'unexpected reply',
      );
    }

    final eventPort = ReceivePort();
    final pollIsolate = await Isolate.spawn(
      pollLoop,
      PollRequest(
        handle: started.handle,
        candidatePaths: candidatePaths,
        events: eventPort.sendPort,
      ),
      debugName: 'rk_quic-poll',
    );

    final events = eventPort
        .map((message) => QuicEvent.fromJson(message as String))
        .asBroadcastStream();

    return QuicServerStart._(
      RkQuicStatus.ok,
      QuicServer._(commands, pollIsolate, events, started.port),
      null,
    );
  }

  /// Sends UTF-8 to one session.
  ///
  /// [reliable] picks the road: a stream is ordered and retransmitted, for a
  /// change that must not be lost; a datagram is neither, for the current
  /// value of something that will be sent again.
  ///
  /// [RkQuicStatus.peerGone] means the session went away — a fact, not a
  /// fault, and the signal to stop writing to it.
  Future<RkQuicStatus> send(
    int sessionId,
    String message, {
    bool reliable = true,
  }) async {
    if (_stopped) return RkQuicStatus.notRunning;
    final reply = await _commands.send(
      SendCommand(sessionId, message, reliable),
    );
    return reply is StatusReply ? reply.status : RkQuicStatus.unrecognised;
  }

  /// Writes one frame into a bidirectional stream the peer opened.
  ///
  /// The stream stays open. Which kind of exchange this is — an answer, a
  /// subscription, a run reporting progress — belongs to the caller and not to
  /// the transport, so ending it is a separate call to [closeStream].
  ///
  /// The ids come from [StreamOpened] and [StreamData]. Answering the session
  /// instead of the stream would leave a browser with several questions in
  /// flight unable to tell which reply is which, which is the whole reason
  /// this is not [send].
  ///
  /// [RkQuicStatus.unknownHandle] means the stream is gone — closed, or its
  /// session ended. [RkQuicStatus.peerGone] means the write found the peer
  /// absent. Both are facts about the peer, not faults, and both are the
  /// signal to stop producing for it.
  Future<RkQuicStatus> sendOn(
    int sessionId,
    int streamId,
    String message,
  ) async {
    if (_stopped) return RkQuicStatus.notRunning;
    final reply = await _commands.send(
      StreamSendCommand(sessionId, streamId, message),
    );
    return reply is StatusReply ? reply.status : RkQuicStatus.unrecognised;
  }

  /// Finishes this side of a bidirectional stream.
  ///
  /// Calling it twice is not an error: the second call answers
  /// [RkQuicStatus.unknownHandle], because during teardown a second close is
  /// ordinary and making it a failure only teaches callers to ignore the
  /// return value.
  Future<RkQuicStatus> closeStream(int sessionId, int streamId) async {
    if (_stopped) return RkQuicStatus.notRunning;
    final reply = await _commands.send(
      StreamCloseCommand(sessionId, streamId),
    );
    return reply is StatusReply ? reply.status : RkQuicStatus.unrecognised;
  }

  /// Stops the endpoint and frees everything it owns.
  ///
  /// Calling it twice is not an error. Never throws.
  Future<RkQuicStatus> stop() async {
    if (_stopped) return RkQuicStatus.notRunning;
    _stopped = true;
    final reply = await _commands.send(const StopCommand());
    _pollIsolate.kill(priority: Isolate.immediate);
    await _commands.dispose();
    return reply is StatusReply ? reply.status : RkQuicStatus.unrecognised;
  }
}

// --- the isolates -----------------------------------------------------------

