//! The client half of the C ABI — two entry points and no more.
//!
//! # Why only two
//!
//! A connected client is an endpoint with one session in it
//! ([`crate::transport::connect`]), registered in the same registry the server
//! uses. So polling for events, writing into a stream, finishing a stream and
//! stopping the endpoint are `rk_quic_server_poll`, `rk_quic_stream_send`,
//! `rk_quic_stream_close` and `rk_quic_server_stop` — already here, already
//! proved, and identical on both sides.
//!
//! What does not exist for a server is **connecting** and **opening a stream**:
//! the server is connected *to*, and on this wire the peer is the side that
//! opens streams. Those two are here.
//!
//! The `server` in the shared names is historical. Renaming them would be an
//! ABI break for every caller that already links them, and the cost of the old
//! name is this paragraph; the cost of the break is everybody's build.
//!
//! The three rules of [`crate::ffi`] hold here unchanged: a failure is a
//! returned value, a status crosses by name, and whoever allocated frees.

use std::ffi::c_char;

use crate::client_config::ClientConfig;
use crate::ffi::{borrow_c_string, guard, write_out};
use crate::status::Status;
use crate::{clear_last_error, set_last_error, transport};

/// Connects to a WebTransport endpoint and writes the handle.
///
/// The certificate is accepted by SHA-256 hash and by nothing else — the same
/// rule the browser half uses. See [`crate::client_config`].
///
/// # Ownership
/// Nothing is transferred. The handle is a name, not a pointer: it is freed by
/// `rk_quic_server_stop`, and a stale one is `"unknownHandle"` rather than a
/// use-after-free.
///
/// # Safety
/// `config_json` must be a valid NUL-terminated string; `out_handle` and
/// `out_session` must each be null or point to a writable `uint64_t`.
#[no_mangle]
pub unsafe extern "C" fn rk_quic_client_connect(
    config_json: *const c_char,
    out_handle: *mut u64,
    out_session: *mut u64,
) -> *const c_char {
    // SAFETY: promised by the caller; the borrow does not outlive this call.
    let json = unsafe { borrow_c_string(config_json) };
    guard(move || {
        clear_last_error();
        let Some(json) = json else {
            set_last_error("configJson is null or not UTF-8");
            return Status::InvalidArgument;
        };
        let config: ClientConfig = match serde_json::from_str(json) {
            Ok(config) => config,
            Err(e) => {
                set_last_error(format!("configJson is not the expected shape: {e}"));
                return Status::InvalidArgument;
            }
        };
        let parsed = match config.parse() {
            Ok(parsed) => parsed,
            Err((status, message)) => {
                set_last_error(message);
                return status;
            }
        };
        match transport::connect(parsed) {
            Ok((handle, session_id)) => {
                // SAFETY: the caller promised writable u64s or nulls.
                unsafe { write_out(out_handle, handle) };
                unsafe { write_out(out_session, session_id) };
                Status::Ok
            }
            Err((status, message)) => {
                set_last_error(message);
                status
            }
        }
    })
}

/// Opens a bidirectional stream on a session and writes its id.
///
/// The id is the QUIC stream id, which both ends see identically — that is
/// what lets an answer be addressed to the question at all.
///
/// # Safety
/// `out_stream` must be null or point to a writable `uint64_t`.
#[no_mangle]
pub unsafe extern "C" fn rk_quic_client_open_stream(
    handle: u64,
    session_id: u64,
    out_stream: *mut u64,
) -> *const c_char {
    guard(move || {
        clear_last_error();
        match transport::open_stream(handle, session_id) {
            Ok(stream_id) => {
                // SAFETY: the caller promised a writable u64 or null.
                unsafe { write_out(out_stream, stream_id) };
                Status::Ok
            }
            Err((status, message)) => {
                set_last_error(message);
                status
            }
        }
    })
}
