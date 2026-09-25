// The parts both halves of the endpoint share, driven from Dart.
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
//
// # Why this is not inside `server_io.dart` any more
//
// Since 0.3.0 there are two halves, and they share every part of this file:
// the poll loop, the command isolate, the reply-by-id matching. A client with
// its own copy would be a second place for the same defect to be fixed once —
// and the defect this plumbing exists to prevent (a reply handed to the wrong
// caller) was invisible for two versions the first time.
//
// The names here carry no underscore because two files need them. They are
// not exported from `rk_quic.dart`, which is what keeps them private in the
// sense that matters.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart' show Utf8, calloc, malloc;
import 'package:ffi/ffi.dart' show StringUtf8Pointer, Utf8Pointer;

import 'bindings_io.dart';
import 'client_io.dart';
import 'loader_io.dart';
import 'status.dart';

/// How long the poller waits inside one native call.
///
/// Not a latency: an event arriving during the wait returns at once. It is how
/// long a stopped endpoint can take to notice it should exit, so it is short.
const Duration pollSlice = Duration(milliseconds: 200);

class PollRequest {
  const PollRequest({
    required this.handle,
    required this.candidatePaths,
    required this.events,
  });
  final int handle;
  final List<String>? candidatePaths;
  final SendPort events;
}

/// The poller. Opens the library itself — an isolate cannot be handed a
/// resolved function pointer, and re-opening an already-mapped file is cheap.
void pollLoop(PollRequest request) {
  final bindings = _openBindings(request.candidatePaths);
  if (bindings == null) return;

  final out = calloc<ffi.Pointer<Utf8>>();
  try {
    while (true) {
      final status = statusFromWireName(
        bindings
            .serverPoll(request.handle, pollSlice.inMilliseconds, out)
            .toDartString(),
      );
      if (status == RkQuicStatus.ok) {
        final pointer = out.value;
        if (pointer != ffi.nullptr) {
          final json = pointer.toDartString();
          // Freed immediately, by the side that allocated it (И146). Holding
          // it until the message is delivered would tie native memory to a
          // Dart queue nobody is watching the length of.
          bindings.stringFree(pointer);
          out.value = ffi.nullptr;
          request.events.send(json);
        }
        continue;
      }
      if (status == RkQuicStatus.wouldBlock) continue;
      // unknownHandle means the endpoint was stopped: leaving is correct, and
      // anything else here would spin.
      return;
    }
  } finally {
    calloc.free(out);
  }
}

/// One isolate for the short calls, so they never queue behind a poll.
///
/// ## Every reply is addressed to the call that asked for it
///
/// Calls overlap: a server writes to many streams without awaiting one write
/// before the next. Until 0.2.2 a call took "the next reply to arrive" from a
/// broadcast stream, so two calls in flight both received the first reply and
/// the second reply reached nobody. While everything succeeded that was
/// invisible — `ok` handed to the wrong caller is still `ok`. When one call
/// failed, its failure was handed to a healthy call beside it as well: a write
/// into a stream the peer had abandoned (`peerGone`) made a concurrent write
/// into a live subscription report `peerGone` too, and its caller closed a
/// subscription that was working.
///
/// Hence an id on the way out and the same id on the way back. Matching by
/// order would also be correct today, because the worker answers every command
/// synchronously and in turn — but a single missing reply would then shift
/// every later answer onto the wrong call, silently and for the rest of the
/// process. With ids a missing reply costs exactly one call.
class CommandChannel {
  CommandChannel._(this._isolate, this._toWorker, Stream<Object?> replies) {
    _replies = replies.listen((message) {
      if (message is! Reply) return;
      _pending.remove(message.id)?.complete(message.payload);
    });
  }

  final Isolate _isolate;
  final SendPort _toWorker;
  late final StreamSubscription<Object?> _replies;
  final _pending = <int, Completer<Object?>>{};
  var _nextId = 0;

  static Future<CommandChannel?> spawn(List<String>? candidatePaths) async {
    final probe = probeNativeLibrary(candidatePaths: candidatePaths);
    if (!probe.isUsable) return null;

    final handshake = ReceivePort();
    final isolate = await Isolate.spawn(
      _commandLoop,
      CommandStart(handshake.sendPort, candidatePaths),
      debugName: 'rk_quic-commands',
    );
    final replies = handshake.asBroadcastStream();
    final toWorker = await replies.first as SendPort;
    return CommandChannel._(isolate, toWorker, replies);
  }

  Future<Object?> send(Object command) {
    final id = _nextId++;
    final reply = Completer<Object?>();
    _pending[id] = reply;
    _toWorker.send(Envelope(id, command));
    return reply.future;
  }

  Future<void> dispose() async {
    _isolate.kill(priority: Isolate.immediate);
    await _replies.cancel();
    // A call still waiting when the worker is killed would otherwise wait
    // forever. The same value a missing library gives: nothing was done.
    final orphans = _pending.values.toList();
    _pending.clear();
    for (final orphan in orphans) {
      orphan.complete(
        const StatusReply(RkQuicStatus.notRunning, 'the endpoint was stopped'),
      );
    }
  }
}

/// A command and the id its reply will carry back.
class Envelope {
  const Envelope(this.id, this.command);
  final int id;
  final Object command;
}

/// A reply and the id of the command it answers.
class Reply {
  const Reply(this.id, this.payload);
  final int id;
  final Object? payload;
}

class CommandStart {
  const CommandStart(this.reply, this.candidatePaths);
  final SendPort reply;
  final List<String>? candidatePaths;
}

class StartCommand {
  const StartCommand(this.configJson);
  final Map<String, Object?> configJson;
}

class SendCommand {
  const SendCommand(this.sessionId, this.message, this.reliable);
  final int sessionId;
  final String message;
  final bool reliable;
}

class StreamSendCommand {
  const StreamSendCommand(this.sessionId, this.streamId, this.message);
  final int sessionId;
  final int streamId;
  final String message;
}

class StreamCloseCommand {
  const StreamCloseCommand(this.sessionId, this.streamId);
  final int sessionId;
  final int streamId;
}

class StopCommand {
  const StopCommand();
}

class StartedReply {
  const StartedReply(this.handle, this.port);
  final int handle;
  final int port;
}

class StatusReply {
  const StatusReply(this.status, this.detail);
  final RkQuicStatus status;
  final String? detail;
}

void _commandLoop(CommandStart start) {
  final inbox = ReceivePort();
  start.reply.send(inbox.sendPort);

  final bindings = _openBindings(start.candidatePaths);
  if (bindings == null) {
    // Answered per command, not once up front: a reply nobody asked for has no
    // call to be addressed to, and the call that did ask would wait forever.
    inbox.listen((message) {
      if (message is! Envelope) return;
      start.reply.send(
        Reply(
          message.id,
          const StatusReply(RkQuicStatus.unsupported, 'no library'),
        ),
      );
    });
    return;
  }

  var handle = 0;

  inbox.listen((envelope) {
    if (envelope is! Envelope) return;
    final id = envelope.id;
    final message = envelope.command;
    switch (message) {
      case StartCommand(:final configJson):
        final json = jsonEncode(configJson).toNativeUtf8();
        final out = calloc<ffi.Uint64>();
        try {
          final status = statusFromWireName(
            bindings.serverStart(json, out).toDartString(),
          );
          if (status != RkQuicStatus.ok) {
            start.reply.send(
              Reply(id, StatusReply(status, bindings.takeLastError())),
            );
            return;
          }
          handle = out.value;
          final portOut = calloc<ffi.Uint16>();
          try {
            bindings.serverLocalPort(handle, portOut);
            start.reply.send(Reply(id, StartedReply(handle, portOut.value)));
          } finally {
            calloc.free(portOut);
          }
        } finally {
          // Allocated by Dart, freed by Dart. The native side never took it.
          malloc.free(json);
          calloc.free(out);
        }

      case ConnectCommand(:final configJson):
        final json = jsonEncode(configJson).toNativeUtf8();
        // Two cells, because the native side writes two numbers. Deriving the
        // session from the handle would be a coupling nothing states: they
        // happen to be consecutive today, and that is an implementation
        // detail of the allocator, not an interface.
        final out = calloc<ffi.Uint64>();
        final session = calloc<ffi.Uint64>();
        try {
          final status = statusFromWireName(
            bindings.clientConnect(json, out, session).toDartString(),
          );
          if (status != RkQuicStatus.ok) {
            start.reply.send(
              Reply(id, StatusReply(status, bindings.takeLastError())),
            );
            return;
          }
          handle = out.value;
          start.reply.send(Reply(id, ConnectedReply(handle, session.value)));
        } finally {
          // Allocated by Dart, freed by Dart. The native side never took it.
          malloc.free(json);
          calloc.free(out);
          calloc.free(session);
        }

      case OpenStreamCommand(:final sessionId):
        final out = calloc<ffi.Uint64>();
        try {
          final status = statusFromWireName(
            bindings.clientOpenStream(handle, sessionId, out).toDartString(),
          );
          start.reply.send(
            Reply(
              id,
              status == RkQuicStatus.ok
                  ? StreamOpenedReply(out.value)
                  : StatusReply(status, bindings.takeLastError()),
            ),
          );
        } finally {
          calloc.free(out);
        }

      case SendCommand(:final sessionId, :final message, :final reliable):
        final payload = message.toNativeUtf8();
        try {
          final status = statusFromWireName(
            bindings
                .sessionSend(handle, sessionId, payload, reliable ? 1 : 0)
                .toDartString(),
          );
          start.reply.send(
            Reply(
              id,
              StatusReply(
                status,
                status == RkQuicStatus.ok ? null : bindings.takeLastError(),
              ),
            ),
          );
        } finally {
          malloc.free(payload);
        }

      case StreamSendCommand(
        :final sessionId,
        :final streamId,
        :final message,
      ):
        final payload = message.toNativeUtf8();
        try {
          final status = statusFromWireName(
            bindings
                .streamSend(handle, sessionId, streamId, payload)
                .toDartString(),
          );
          start.reply.send(
            Reply(
              id,
              StatusReply(
                status,
                status == RkQuicStatus.ok ? null : bindings.takeLastError(),
              ),
            ),
          );
        } finally {
          // Allocated by Dart, freed by Dart (И146). The native side borrowed
          // it for the length of the call and never took ownership.
          malloc.free(payload);
        }

      case StreamCloseCommand(:final sessionId, :final streamId):
        final status = statusFromWireName(
          bindings.streamClose(handle, sessionId, streamId).toDartString(),
        );
        start.reply.send(
          Reply(
            id,
            StatusReply(
              status,
              status == RkQuicStatus.ok ? null : bindings.takeLastError(),
            ),
          ),
        );

      case StopCommand():
        final status = statusFromWireName(
          bindings.serverStop(handle).toDartString(),
        );
        start.reply.send(Reply(id, StatusReply(status, null)));

      default:
        start.reply.send(
          Reply(
            id,
            const StatusReply(RkQuicStatus.unrecognised, 'unknown command'),
          ),
        );
    }
  });
}

RkQuicBindings? _openBindings(List<String>? candidatePaths) {
  final probe = probeNativeLibrary(candidatePaths: candidatePaths);
  if (!probe.isUsable || probe.path == null) return null;
  try {
    return RkQuicBindings(ffi.DynamicLibrary.open(probe.path!));
  } on Object {
    // The probe just opened it, so this only happens if the file changed
    // underneath. Still a value: an isolate that throws reports nowhere.
    return null;
  }
}

