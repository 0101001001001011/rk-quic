//! The two halves of this package talk to each other.
//!
//! # Why this test and not one against a third-party server
//!
//! A test against somebody else's WebTransport server would prove
//! *compatibility* — useful, and not what is at risk here. What is at risk is
//! **symmetry**: the client and the server share a transport, an event
//! vocabulary and a closed set of statuses, and the way that breaks is one
//! half changing and the other not noticing. Only our own client against our
//! own server can fail that way, so only it can catch it.
//!
//! The exchange asserted here is the one the till actually uses
//! (`till_wire.dart`): the peer opens a bidirectional stream and asks, the
//! host answers **into that same stream**, and the answer is addressed by the
//! stream rather than by an id. If that stops working, every terminal stops
//! working, and nothing else in this package would say so.
//!
//! Certificates are trusted by SHA-256 hash on the client, which is the only
//! rule this endpoint offers and the same one the browser uses.

use std::time::{Duration, Instant};

use rk_quic::client_config::ClientConfig;
use rk_quic::config::ServerConfig;
use rk_quic::event::Event;
use rk_quic::transport;

#[path = "../src/testing.rs"]
mod testing;

use testing::self_signed_pem as self_signed;

/// SHA-256 of the first certificate in a PEM chain, hex, as the client wants it.
fn hash_hex(pem: &str) -> String {
    let der = rustls_pemfile::certs(&mut pem.as_bytes())
        .next()
        .expect("a certificate")
        .expect("readable");
    let certificate = wtransport::tls::Certificate::from_der(der.to_vec()).expect("usable");
    certificate
        .hash()
        .as_ref()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Waits for an event the predicate accepts, or gives up and says so.
///
/// A deadline rather than a fixed number of polls: what is being waited for is
/// a network round trip, and counting polls would turn a slow machine into a
/// failing test.
fn wait_for<F>(handle: u64, what: &str, mut accept: F) -> Event
where
    F: FnMut(&Event) -> bool,
{
    let deadline = Instant::now() + Duration::from_secs(10);
    let endpoint = transport::lookup(handle).expect("endpoint is live");
    while Instant::now() < deadline {
        if let Some(event) = endpoint.next_event(Duration::from_millis(200)) {
            if accept(&event) {
                return event;
            }
        }
    }
    panic!("no {what} within ten seconds");
}

#[test]
fn client_asks_and_server_answers_in_the_same_stream() {
    let (chain, key) = self_signed();
    let hash = hash_hex(&chain);

    let server = ServerConfig {
        bind_address: "127.0.0.1:0".into(),
        certificate_chain_pem: chain,
        private_key_pem: key,
        path: "/wire".into(),
        idle_timeout_ms: 30_000,
    };
    let server_handle = transport::start(server.parse().expect("server config")).expect("listening");
    let port = transport::lookup(server_handle)
        .expect("server is live")
        .local_port();

    let client = ClientConfig {
        url: format!("https://127.0.0.1:{port}/wire"),
        certificate_hash_sha256: hash,
        idle_timeout_ms: 30_000,
    };
    let (client_handle, connect_session) =
        transport::connect(client.parse().expect("client config")).expect("connected");

    // The client's own event queue says the session opened; the server's says
    // it accepted one. Both are asserted, because a client that believes it is
    // connected to a server that never saw it is exactly the failure this
    // package exists to make impossible.
    let client_session = match wait_for(client_handle, "sessionOpened on the client", |e| {
        matches!(e, Event::SessionOpened { .. })
    }) {
        Event::SessionOpened { session_id, .. } => session_id,
        other => panic!("wrong event: {other:?}"),
    };
    // The number `connect` handed back and the number the event carries are
    // the same number. They are produced by different code paths, and a
    // caller that trusted one while the other meant something else would
    // address its streams to a session that does not exist.
    assert_eq!(
        connect_session, client_session,
        "connect() and sessionOpened must name the same session",
    );
    let server_session = match wait_for(server_handle, "sessionOpened on the server", |e| {
        matches!(e, Event::SessionOpened { .. })
    }) {
        Event::SessionOpened { session_id, .. } => session_id,
        other => panic!("wrong event: {other:?}"),
    };

    // The peer opens the stream and asks.
    let stream = transport::open_stream(client_handle, client_session).expect("stream opened");
    transport::lookup(client_handle)
        .expect("client is live")
        .stream_send(client_session, stream, "sale.ping")
        .expect("question sent");

    // The server sees the stream and the question in it.
    let opened = wait_for(server_handle, "streamOpened on the server", |e| {
        matches!(e, Event::StreamOpened { .. })
    });
    let server_stream = match opened {
        Event::StreamOpened { stream_id, .. } => stream_id,
        other => panic!("wrong event: {other:?}"),
    };
    assert_eq!(
        server_stream, stream,
        "both ends must name the exchange identically, or an answer cannot be addressed",
    );

    // The client finishes its half so the question is a whole message: on this
    // wire a stream IS the message, and the host reads it to the end before it
    // becomes an event.
    transport::lookup(client_handle)
        .expect("client is live")
        .stream_close(client_session, stream)
        .expect("half closed");

    let asked = wait_for(server_handle, "the question", |e| {
        matches!(e, Event::StreamData { .. })
    });
    match asked {
        Event::StreamData { utf8, .. } => assert_eq!(utf8, "sale.ping"),
        other => panic!("wrong event: {other:?}"),
    }

    // The host answers into that same stream.
    transport::lookup(server_handle)
        .expect("server is live")
        .stream_send(server_session, server_stream, "pong")
        .expect("answer sent");
    transport::lookup(server_handle)
        .expect("server is live")
        .stream_close(server_session, server_stream)
        .expect("answer finished");

    let answered = wait_for(client_handle, "the answer", |e| {
        matches!(e, Event::StreamData { .. })
    });
    match answered {
        Event::StreamData { utf8, .. } => assert_eq!(utf8, "pong"),
        other => panic!("wrong event: {other:?}"),
    }

    assert_eq!(transport::remove(client_handle), rk_quic::status::Status::Ok);
    assert_eq!(transport::remove(server_handle), rk_quic::status::Status::Ok);
}

#[test]
fn a_wrong_certificate_hash_is_refused_by_name() {
    let (chain, key) = self_signed();
    let server = ServerConfig {
        bind_address: "127.0.0.1:0".into(),
        certificate_chain_pem: chain,
        private_key_pem: key,
        path: "/wire".into(),
        idle_timeout_ms: 30_000,
    };
    let server_handle = transport::start(server.parse().expect("server config")).expect("listening");
    let port = transport::lookup(server_handle)
        .expect("server is live")
        .local_port();

    // A hash of the right shape and the wrong value: the mistake an operator
    // actually makes is a stale fingerprint after the till rotated its
    // certificate, not a malformed one.
    let client = ClientConfig {
        url: format!("https://127.0.0.1:{port}/wire"),
        certificate_hash_sha256: "0".repeat(64),
        idle_timeout_ms: 30_000,
    };
    let (status, detail) = transport::connect(client.parse().expect("client config"))
        .expect_err("a wrong hash must not connect");

    assert_eq!(
        status,
        rk_quic::status::Status::BadCertificate,
        "a rejected certificate is its own status, not a generic failure: {detail}",
    );

    assert_eq!(transport::remove(server_handle), rk_quic::status::Status::Ok);
}
