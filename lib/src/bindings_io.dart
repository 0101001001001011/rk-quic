// The raw FFI bindings, hand-written against `src/rk_quic.h`.
//
// Nothing in this file is public API. It exists so that exactly one place
// knows the C signatures, and `test/abi_surface_test.dart` checks that place
// against the header.
//
// `ffigen` would have generated it. It was not used: the surface is small
// enough to read in one screen, ffigen needs LLVM wherever it is regenerated,
// and a generated file in git invites the question of which copy is true. The
// drift it would have prevented is caught by a test that also covers the Rust
// side, which ffigen would not have.

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart' show Utf8, Utf8Pointer;

typedef _AbiVersionNative = ffi.Uint32 Function();
typedef _VersionNative = ffi.Pointer<Utf8> Function();
typedef _StringFreeNative = ffi.Void Function(ffi.Pointer<Utf8>);
typedef _StringFreeDart = void Function(ffi.Pointer<Utf8>);
typedef _LastErrorNative = ffi.Pointer<Utf8> Function();
typedef _ServerStartNative = ffi.Pointer<Utf8> Function(
    ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint64>);
typedef _ServerStartDart = ffi.Pointer<Utf8> Function(
    ffi.Pointer<Utf8>, ffi.Pointer<ffi.Uint64>);
typedef _ServerStopNative = ffi.Pointer<Utf8> Function(ffi.Uint64);
typedef _ServerStopDart = ffi.Pointer<Utf8> Function(int);
typedef _LocalPortNative = ffi.Pointer<Utf8> Function(
    ffi.Uint64, ffi.Pointer<ffi.Uint16>);
typedef _LocalPortDart = ffi.Pointer<Utf8> Function(
    int, ffi.Pointer<ffi.Uint16>);
typedef _PollNative = ffi.Pointer<Utf8> Function(
    ffi.Uint64, ffi.Uint32, ffi.Pointer<ffi.Pointer<Utf8>>);
typedef _PollDart = ffi.Pointer<Utf8> Function(
    int, int, ffi.Pointer<ffi.Pointer<Utf8>>);
typedef _SendNative = ffi.Pointer<Utf8> Function(
    ffi.Uint64, ffi.Uint64, ffi.Pointer<Utf8>, ffi.Uint8);
typedef _SendDart = ffi.Pointer<Utf8> Function(
    int, int, ffi.Pointer<Utf8>, int);

/// Every entry point of the native library, resolved once.
class RkQuicBindings {
  RkQuicBindings(this._library)
      : abiVersion = _library
            .lookup<ffi.NativeFunction<_AbiVersionNative>>('rk_quic_abi_version')
            .asFunction<int Function()>(),
        version = _library
            .lookup<ffi.NativeFunction<_VersionNative>>('rk_quic_version')
            .asFunction<ffi.Pointer<Utf8> Function()>(),
        stringFree = _library
            .lookup<ffi.NativeFunction<_StringFreeNative>>('rk_quic_string_free')
            .asFunction<_StringFreeDart>(),
        lastErrorRaw = _library
            .lookup<ffi.NativeFunction<_LastErrorNative>>('rk_quic_last_error')
            .asFunction<ffi.Pointer<Utf8> Function()>(),
        serverStart = _library
            .lookup<ffi.NativeFunction<_ServerStartNative>>('rk_quic_server_start')
            .asFunction<_ServerStartDart>(),
        serverStop = _library
            .lookup<ffi.NativeFunction<_ServerStopNative>>('rk_quic_server_stop')
            .asFunction<_ServerStopDart>(),
        serverLocalPort = _library
            .lookup<ffi.NativeFunction<_LocalPortNative>>(
                'rk_quic_server_local_port')
            .asFunction<_LocalPortDart>(),
        serverPoll = _library
            .lookup<ffi.NativeFunction<_PollNative>>('rk_quic_server_poll')
            .asFunction<_PollDart>(),
        sessionSend = _library
            .lookup<ffi.NativeFunction<_SendNative>>('rk_quic_session_send')
            .asFunction<_SendDart>();

  // ignore: unused_field
  final ffi.DynamicLibrary _library;

  final int Function() abiVersion;
  final ffi.Pointer<Utf8> Function() version;
  final _StringFreeDart stringFree;
  final ffi.Pointer<Utf8> Function() lastErrorRaw;
  final _ServerStartDart serverStart;
  final _ServerStopDart serverStop;
  final _LocalPortDart serverLocalPort;
  final _PollDart serverPoll;
  final _SendDart sessionSend;

  /// Reads and clears the last error, freeing the buffer the library allocated.
  ///
  /// This is the only place that frees a native string, which is what makes
  /// И146 checkable: whoever allocated frees, and Dart hands the pointer back
  /// rather than calling `free()` on it.
  String? takeLastError() {
    final pointer = lastErrorRaw();
    if (pointer == ffi.nullptr) return null;
    final text = pointer.toDartString();
    stringFree(pointer);
    return text;
  }
}
