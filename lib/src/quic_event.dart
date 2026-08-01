import 'dart:convert';

/// Something that happened on the endpoint.
///
/// The native side sends a `kind` **name**, and it is resolved by name here
/// (И147). A kind this build does not know becomes [UnknownQuicEvent] rather
/// than the nearest match — a newer library talking to an older Dart side must
/// degrade to "I do not know what that was", never to the wrong branch.
sealed class QuicEvent {
  const QuicEvent();

  /// Parses one event. Never throws: malformed JSON from the native side is a
  /// bug worth *seeing*, and an exception out of a background isolate is the
  /// least visible way to report it.
  factory QuicEvent.fromJson(String json) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (error) {
      return UnknownQuicEvent(
        kind: '<unparsable>',
        raw: json,
        detail: '$error',
      );
    }
    if (decoded is! Map<String, Object?>) {
      return UnknownQuicEvent(
        kind: '<not an object>',
        raw: json,
        detail: 'expected a JSON object',
      );
    }

    final kind = decoded['kind'];
    if (kind is! String) {
      return UnknownQuicEvent(kind: '<no kind>', raw: json);
    }

    int sessionId() =>
        (decoded as Map<String, Object?>)['sessionId'] as int? ?? -1;
    String text(String key) =>
        (decoded as Map<String, Object?>)[key] as String? ?? '';

    return switch (kind) {
      'sessionOpened' => SessionOpened(
        sessionId: sessionId(),
        authority: text('authority'),
        path: text('path'),
      ),
      'sessionClosed' => SessionClosed(
        sessionId: sessionId(),
        reason: text('reason'),
      ),
      'datagram' => DatagramReceived(
        sessionId: sessionId(),
        message: text('utf8'),
      ),
      'streamMessage' => StreamMessageReceived(
        sessionId: sessionId(),
        message: text('utf8'),
      ),
      'endpointError' => EndpointError(message: text('message')),
      _ => UnknownQuicEvent(kind: kind, raw: json),
    };
  }
}

/// A browser opened a WebTransport session.
final class SessionOpened extends QuicEvent {
  const SessionOpened({
    required this.sessionId,
    required this.authority,
    required this.path,
  });

  final int sessionId;

  /// The host the client believes it reached.
  final String authority;
  final String path;

  @override
  String toString() => 'SessionOpened($sessionId, $authority$path)';
}

/// A session ended — politely, or because the peer stopped answering.
///
/// One event for both, because the consequence is the same: writing to it is
/// now pointless, and anything queued for it has to go somewhere else.
final class SessionClosed extends QuicEvent {
  const SessionClosed({required this.sessionId, required this.reason});

  final int sessionId;
  final String reason;

  @override
  String toString() => 'SessionClosed($sessionId, $reason)';
}

/// A datagram arrived: unordered, droppable.
final class DatagramReceived extends QuicEvent {
  const DatagramReceived({required this.sessionId, required this.message});

  final int sessionId;
  final String message;

  @override
  String toString() => 'DatagramReceived($sessionId, ${message.length} chars)';
}

/// A complete message arrived on a stream: ordered, retransmitted.
final class StreamMessageReceived extends QuicEvent {
  const StreamMessageReceived({required this.sessionId, required this.message});

  final int sessionId;
  final String message;

  @override
  String toString() =>
      'StreamMessageReceived($sessionId, ${message.length} chars)';
}

/// The endpoint hit trouble of its own. Still a valid handle; still has to be
/// stopped.
final class EndpointError extends QuicEvent {
  const EndpointError({required this.message});

  final String message;

  @override
  String toString() => 'EndpointError($message)';
}

/// A kind this build does not know, kept whole.
///
/// Deliberately not dropped: an event nobody can read is still evidence that
/// the two sides disagree, and silently discarding it turns a version mismatch
/// into "the feature does not work".
final class UnknownQuicEvent extends QuicEvent {
  const UnknownQuicEvent({required this.kind, required this.raw, this.detail});

  final String kind;
  final String raw;
  final String? detail;

  @override
  String toString() =>
      'UnknownQuicEvent($kind${detail == null ? '' : ', $detail'})';
}
