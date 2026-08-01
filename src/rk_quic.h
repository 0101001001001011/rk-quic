/*
 * rk_quic — the C ABI, and the authoritative statement of it.
 *
 * Hand-written, and the Dart bindings are hand-written against it. `ffigen`
 * was not used: this surface is small enough to read in one screen, ffigen
 * needs LLVM installed on every machine that regenerates it, and a generated
 * file in git invites the question of which copy is true. Instead
 * `test/abi_surface_test.dart` parses this header and fails if the Dart
 * bindings and this file disagree about the exported names — the drift ffigen
 * would have prevented is caught, without the toolchain.
 *
 * THREE RULES HOLD EVERYWHERE BELOW.
 *
 * Failure is a returned value (И144). No function here unwinds into the
 * caller and none aborts: a panic in Rust comes back as the status "panic".
 *
 * Enumerations cross by name (И147). A status is a NUL-terminated name such as
 * "ok" or "portInUse", never an integer. It points into static storage: the
 * caller must not free it, and it is valid for the life of the process.
 *
 * Freeing is one-sided and deterministic (И146). Whoever allocated frees.
 * Every pointer this library returns is either static (never freed) or was
 * allocated by Rust and must come back through rk_quic_string_free. The caller
 * never calls free() on it, and Rust never frees a pointer the caller owns.
 */

#ifndef RK_QUIC_H
#define RK_QUIC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Generation of this ABI. Bumped when a signature or an ownership rule
 * changes — not when the package version changes. A caller that does not know
 * the generation it finds must refuse the library rather than guess. */
#define RK_QUIC_ABI_VERSION 1

/* Returns the generation the loaded library implements. Cannot fail. */
uint32_t rk_quic_abi_version(void);

/* Returns the library version, NUL-terminated, in static storage.
 * Ownership: not the caller's. Do not free. */
const char *rk_quic_version(void);

/* Frees a string this library allocated.
 * Ownership: takes the pointer back. Null is accepted and does nothing.
 * Passing a static pointer, a foreign pointer, or one already freed is
 * undefined behaviour. */
void rk_quic_string_free(char *s);

/* Returns the detail behind the last failure on the calling thread, or NULL
 * when there is none. Reading clears it, so a message is never reported twice.
 * Ownership: the caller's. Free with rk_quic_string_free. */
char *rk_quic_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* RK_QUIC_H */
