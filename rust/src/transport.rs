//! The endpoint: a QUIC/HTTP-3 server the till runs, and the WebTransport
//! sessions browsers open on it.
//!
//! ## Threads, and what never crosses one
//!
//! A tokio runtime lives inside each endpoint and owns every socket. The
//! calling thread — Dart's — never awaits anything: it pushes a configuration
//! in, and later drains a queue. That is what makes И145 keepable on the Dart
//! side, because there is nothing here that *has* to block for long.
//!
//! ## Who frees what (И146)
//!
//! An endpoint is owned by the registry below and freed by
//! `rk_quic_server_stop`, which removes it and drops it. Dart holds a `u64`
//! handle, which is a name and not a pointer: a stale handle is
//! `unknownHandle`, not a use-after-free. Events leave as strings Rust
//! allocated, and come back through `rk_quic_string_free`.

use std::collections::HashMap;
use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::time::Duration;

use rustls_pki_types::PrivateKeyDer;
use wtransport::tls::{Certificate, CertificateChain, PrivateKey};
use wtransport::{Connection, Identity, VarInt};

use crate::config::ParsedConfig;
use crate::event::Event;
use crate::status::Status;

/// How many events may wait before the queue starts dropping.
///
/// Bounded on purpose: an unbounded queue turns a Dart side that stopped
/// draining into unbounded memory growth on a till, which fails at the worst
/// possible moment and looks like something else entirely. When it is full the
/// **oldest** is dropped, because for a stream of state changes the newest is
/// the one that matters.
const EVENT_QUEUE_DEPTH: usize = 1024;

/// A live endpoint.
pub struct Endpoint {
    runtime: Option<tokio::runtime::Runtime>,
    events: Mutex<Receiver<Event>>,
    sessions: Arc<Mutex<HashMap<u64, Connection>>>,
    local_port: u16,
}

impl Endpoint {
    /// The port actually bound. Interesting when the caller asked for 0.
    pub fn local_port(&self) -> u16 {
        self.local_port
    }

    /// Waits up to `timeout` for the next event.
    pub fn next_event(&self, timeout: Duration) -> Option<Event> {
        let events = self.events.lock().ok()?;
        match events.recv_timeout(timeout) {
            Ok(event) => Some(event),
            // Disconnected means the accept loop is gone; from the caller's
            // side that is indistinguishable from "nothing right now", and
            // saying so keeps a poll loop from spinning.
            Err(RecvTimeoutError::Timeout) | Err(RecvTimeoutError::Disconnected) => None,
        }
    }

    /// Sends a message to one session.
    ///
    /// `reliable` picks the road, and the choice is not cosmetic. A stream is
    /// ordered and retransmitted — for a change that must not be lost, such as
    /// a print job finishing. A datagram is neither — for the current value of
    /// something, where a newer one is on its way anyway.
    pub fn send(&self, session_id: u64, payload: &str, reliable: bool) -> Result<(), Status> {
        let connection = {
            let sessions = self.sessions.lock().map_err(|_| Status::Panic)?;
            sessions.get(&session_id).cloned()
        };
        let Some(connection) = connection else {
            return Err(Status::UnknownHandle);
        };
        let runtime = self.runtime.as_ref().ok_or(Status::NotRunning)?;

        if reliable {
            let payload = payload.to_owned();
            runtime.block_on(async move {
                let mut stream = connection
                    .open_uni()
                    .await
                    .map_err(|_| Status::PeerGone)?
                    .await
                    .map_err(|_| Status::PeerGone)?;
                stream
                    .write_all(payload.as_bytes())
                    .await
                    .map_err(|_| Status::PeerGone)?;
                // Without this the peer never sees the end of the message and
                // waits forever for a length it was never told.
                stream.finish().await.map_err(|_| Status::PeerGone)?;
                Ok(())
            })
        } else {
            connection
                .send_datagram(payload.as_bytes())
                .map_err(|_| Status::PeerGone)
        }
    }
}

impl Drop for Endpoint {
    fn drop(&mut self) {
        // Every session is closed before the runtime goes, so a peer is told
        // rather than left to find out by timeout.
        if let Ok(mut sessions) = self.sessions.lock() {
            for (_, connection) in sessions.drain() {
                connection.close(VarInt::from_u32(0), b"endpoint stopped");
            }
        }
        if let Some(runtime) = self.runtime.take() {
            // `shutdown_background` and not a plain drop: dropping a runtime
            // blocks until its tasks finish, and this runs on the caller's
            // thread — on a till that is the thread serving an operator.
            runtime.shutdown_background();
        }
    }
}

// --- registry ---------------------------------------------------------------

fn registry() -> &'static Mutex<HashMap<u64, Arc<Endpoint>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<u64, Arc<Endpoint>>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn next_handle() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

/// Looks a handle up. `None` means the caller is holding a name for something
/// that is gone — which is a value, not a crash.
pub fn lookup(handle: u64) -> Option<Arc<Endpoint>> {
    registry().lock().ok()?.get(&handle).cloned()
}

/// Removes and drops an endpoint. Idempotent by returning `notRunning` rather
/// than failing, so a double stop during shutdown is not an error to explain.
pub fn remove(handle: u64) -> Status {
    let removed = match registry().lock() {
        Ok(mut map) => map.remove(&handle),
        Err(_) => return Status::Panic,
    };
    match removed {
        Some(endpoint) => {
            drop(endpoint);
            Status::Ok
        }
        None => Status::NotRunning,
    }
}

/// How many endpoints are live. For tests, and for asserting that stopping
/// actually frees rather than merely forgetting.
pub fn live_count() -> usize {
    registry().lock().map(|m| m.len()).unwrap_or(0)
}

// --- start ------------------------------------------------------------------

/// Starts an endpoint, or says exactly why it could not.
pub fn start(config: ParsedConfig) -> Result<u64, (Status, String)> {
    let identity = identity_from(&config)?;

    let server_config = wtransport::ServerConfig::builder()
        .with_bind_address(config.bind)
        .with_identity(identity)
        // Both, and neither is optional.
        //
        // Without `max_idle_timeout` a peer that vanishes without a close —
        // a shut lid, a killed tab, a Wi-Fi that went — is never noticed:
        // measured, no `sessionClosed` twenty seconds after the client was
        // gone. Without the keep-alive an idle *live* session would then be
        // dropped as dead. A third of the timeout gives two missed probes
        // before a session is called gone.
        .max_idle_timeout(Some(config.idle_timeout))
        .map_err(|_| {
            (
                Status::InvalidArgument,
                format!("idleTimeoutMs {:?} is out of range for QUIC", config.idle_timeout),
            )
        })?
        .keep_alive_interval(Some(config.idle_timeout / 3))
        .build();

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .thread_name("rk_quic")
        .build()
        .map_err(|e| (Status::BindFailed, format!("no tokio runtime: {e}")))?;

    let endpoint = runtime
        .block_on(async { wtransport::Endpoint::server(server_config) })
        .map_err(|e| (bind_status(&e), format!("bind {}: {e}", config.bind)))?;

    let local_port = endpoint
        .local_addr()
        .map_err(|e| (Status::BindFailed, format!("no local address: {e}")))?
        .port();

    let (tx, rx) = mpsc::sync_channel(EVENT_QUEUE_DEPTH);
    let sessions: Arc<Mutex<HashMap<u64, Connection>>> = Arc::new(Mutex::new(HashMap::new()));

    let accept_sessions = Arc::clone(&sessions);
    let accept_tx = tx.clone();
    let expected_path = config.path.clone();
    runtime.spawn(async move {
        accept_loop(endpoint, expected_path, accept_sessions, accept_tx).await;
    });

    let handle = next_handle();
    let live = Endpoint {
        runtime: Some(runtime),
        events: Mutex::new(rx),
        sessions,
        local_port,
    };
    match registry().lock() {
        Ok(mut map) => {
            map.insert(handle, Arc::new(live));
        }
        Err(_) => return Err((Status::Panic, "endpoint registry is poisoned".into())),
    }
    Ok(handle)
}

/// A taken port is its own status, not a generic bind failure.
///
/// It is the one bind error an operator can act on without help — something
/// else is already serving there — so it must be distinguishable at the call
/// site rather than buried in a message nobody parses.
fn bind_status(error: &io::Error) -> Status {
    match error.kind() {
        io::ErrorKind::AddrInUse => Status::PortInUse,
        _ => Status::BindFailed,
    }
}

fn identity_from(config: &ParsedConfig) -> Result<Identity, (Status, String)> {
    let mut chain = Vec::with_capacity(config.chain.len());
    for der in &config.chain {
        chain.push(Certificate::from_der(der.as_ref().to_vec()).map_err(|e| {
            (
                Status::BadCertificate,
                format!("certificate in chain is not usable: {e}"),
            )
        })?);
    }

    let key = match &config.key {
        PrivateKeyDer::Pkcs8(der) => PrivateKey::from_der_pkcs8(der.secret_pkcs8_der().to_vec()),
        // Named rather than "bad key": the caller has a key that is fine, in a
        // container this build cannot read, and that is a different action.
        other => {
            return Err((
                Status::BadCertificate,
                format!(
                    "private key is {}, and only PKCS#8 is accepted — \
                     convert with `openssl pkcs8 -topk8`",
                    match other {
                        PrivateKeyDer::Pkcs1(_) => "PKCS#1 (BEGIN RSA PRIVATE KEY)",
                        PrivateKeyDer::Sec1(_) => "SEC1 (BEGIN EC PRIVATE KEY)",
                        _ => "of an unknown kind",
                    }
                ),
            ))
        }
    };

    Ok(Identity::new(CertificateChain::new(chain), key))
}

// --- the accept loop --------------------------------------------------------

async fn accept_loop(
    endpoint: wtransport::Endpoint<wtransport::endpoint::endpoint_side::Server>,
    expected_path: String,
    sessions: Arc<Mutex<HashMap<u64, Connection>>>,
    tx: SyncSender<Event>,
) {
    let next_session = Arc::new(AtomicU64::new(1));
    loop {
        let incoming = endpoint.accept().await;
        let sessions = Arc::clone(&sessions);
        let tx = tx.clone();
        let expected_path = expected_path.clone();
        let next_session = Arc::clone(&next_session);

        tokio::spawn(async move {
            let request = match incoming.await {
                Ok(request) => request,
                // A handshake that never completed is not an event: a port
                // scanner would otherwise fill the queue.
                Err(_) => return,
            };

            if request.path() != expected_path {
                request.not_found().await;
                return;
            }

            let authority = request.authority().to_string();
            let path = request.path().to_string();

            let connection = match request.accept().await {
                Ok(connection) => connection,
                Err(_) => return,
            };

            let session_id = next_session.fetch_add(1, Ordering::Relaxed);
            if let Ok(mut map) = sessions.lock() {
                map.insert(session_id, connection.clone());
            }
            emit(
                &tx,
                Event::SessionOpened {
                    session_id,
                    authority,
                    path,
                },
            );

            session_loop(session_id, connection, &tx).await;

            if let Ok(mut map) = sessions.lock() {
                map.remove(&session_id);
            }
        });
    }
}

async fn session_loop(session_id: u64, connection: Connection, tx: &SyncSender<Event>) {
    use tokio::io::AsyncReadExt;

    loop {
        tokio::select! {
            datagram = connection.receive_datagram() => match datagram {
                Ok(datagram) => {
                    if let Ok(text) = std::str::from_utf8(&datagram) {
                        emit(tx, Event::Datagram { session_id, utf8: text.to_string() });
                    }
                }
                Err(error) => {
                    emit(tx, Event::SessionClosed { session_id, reason: error.to_string() });
                    return;
                }
            },
            stream = connection.accept_uni() => match stream {
                Ok(mut stream) => {
                    let mut buffer = Vec::new();
                    // A stream is a message here, so it is read to its end
                    // before it becomes an event: half a message is worse than
                    // none, because it looks like a whole one.
                    if stream.read_to_end(&mut buffer).await.is_ok() {
                        if let Ok(text) = String::from_utf8(buffer) {
                            emit(tx, Event::StreamMessage { session_id, utf8: text });
                        }
                    }
                }
                Err(error) => {
                    emit(tx, Event::SessionClosed { session_id, reason: error.to_string() });
                    return;
                }
            },
        }
    }
}

/// Queues an event, dropping the oldest when full.
///
/// Silence would be worse: a Dart side that stopped draining would grow this
/// queue until the till ran out of memory, and the failure would surface
/// somewhere else entirely.
fn emit(tx: &SyncSender<Event>, event: Event) {
    match tx.try_send(event) {
        Ok(()) => {}
        Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ServerConfig;

    fn config_on(port: u16) -> ParsedConfig {
        let (chain, key) = crate::testing::self_signed_pem();
        ServerConfig {
            bind_address: format!("127.0.0.1:{port}"),
            certificate_chain_pem: chain,
            private_key_pem: key,
            path: "/rk".into(),
            idle_timeout_ms: 30_000,
        }
        .parse()
        .unwrap()
    }

    #[test]
    fn an_endpoint_starts_reports_its_port_and_is_really_freed_on_stop() {
        let handle = start(config_on(0)).expect("start");
        assert!(live_count() >= 1);

        let endpoint = lookup(handle).expect("handle resolves");
        assert_ne!(endpoint.local_port(), 0, "port 0 must be resolved to a real one");

        // A weak reference and not a count: `live_count` is process-global and
        // cargo runs these tests in parallel, so a count proves nothing. This
        // proves the object was *dropped* — И146 asks for deterministic
        // freeing, and "removed from a map" is not the same claim.
        let weak = Arc::downgrade(&endpoint);
        drop(endpoint);

        assert_eq!(remove(handle), Status::Ok);
        assert!(
            weak.upgrade().is_none(),
            "stopping removed the handle but something still holds the endpoint"
        );
        assert!(lookup(handle).is_none());
    }

    #[test]
    fn stopping_twice_says_not_running_rather_than_failing() {
        let handle = start(config_on(0)).expect("start");
        assert_eq!(remove(handle), Status::Ok);
        assert_eq!(remove(handle), Status::NotRunning);
    }

    #[test]
    fn a_handle_that_was_never_issued_does_not_resolve() {
        assert!(lookup(u64::MAX).is_none());
        assert_eq!(remove(u64::MAX), Status::NotRunning);
    }

    #[test]
    fn a_port_already_taken_is_port_in_use_and_not_a_generic_failure() {
        let first = start(config_on(0)).expect("first endpoint");
        let port = lookup(first).unwrap().local_port();

        let (status, message) = start(config_on(port)).expect_err("second must not bind");

        assert_eq!(
            status,
            Status::PortInUse,
            "an operator can act on a taken port; a generic bindFailed hides it. \
             message was: {message}"
        );
        assert!(message.contains(&port.to_string()), "message names no port: {message}");

        assert_eq!(remove(first), Status::Ok);
    }

    #[test]
    fn sending_to_a_session_that_never_existed_is_unknown_handle() {
        let handle = start(config_on(0)).expect("start");
        let endpoint = lookup(handle).unwrap();
        assert_eq!(endpoint.send(999, "x", true), Err(Status::UnknownHandle));
        assert_eq!(endpoint.send(999, "x", false), Err(Status::UnknownHandle));
        drop(endpoint);
        assert_eq!(remove(handle), Status::Ok);
    }

    #[test]
    fn polling_an_idle_endpoint_returns_nothing_rather_than_blocking_forever() {
        let handle = start(config_on(0)).expect("start");
        let endpoint = lookup(handle).unwrap();
        let started = std::time::Instant::now();
        assert!(endpoint.next_event(Duration::from_millis(50)).is_none());
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "the wait did not respect its own timeout"
        );
        drop(endpoint);
        assert_eq!(remove(handle), Status::Ok);
    }
}
