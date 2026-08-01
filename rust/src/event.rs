//! What the endpoint tells the caller, and why the caller has to ask.
//!
//! The whole reason this package exists is that **the server can speak first**
//! — a print job changing state should reach a browser when it happens, not
//! when something next polls. But a native library cannot call *into* Dart
//! safely from an arbitrary thread, so the direction is inverted at the
//! boundary only: events are queued in Rust and drained by one Dart call that
//! blocks until there is something or the wait runs out.
//!
//! That is a queue with a reader, not a poll: nothing is asked of the network,
//! and an event that arrives during the wait wakes the reader immediately.

use serde::Serialize;

/// One thing that happened on the endpoint.
///
/// Serialised with an explicit `kind` **name**, never a numbered tag (И147). A
/// reader that meets an unknown kind must be able to say "unknown", and an
/// integer tag makes that impossible to distinguish from a wrong branch.
// `rename_all` renames the *variants*; `rename_all_fields` renames the fields
// inside them. Only the first was here at one point, and the tag came out
// right while every field stayed `snake_case` — the kind of half-correct that
// a test comparing only the tag would have passed.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Event {
    /// A browser opened a WebTransport session.
    SessionOpened {
        session_id: u64,
        /// The `:authority` the client asked for — the host it thinks it
        /// reached.
        authority: String,
        path: String,
    },
    /// A session ended. `peerGone` covers both the polite close and the wire
    /// going away: from the server's side the consequence is the same, which
    /// is that writing to it is now pointless.
    SessionClosed { session_id: u64, reason: String },
    /// A datagram arrived. Lossy by nature — this is the path for "the current
    /// value", never for "the next change".
    Datagram { session_id: u64, utf8: String },
    /// A complete message arrived on a unidirectional stream. Ordered and
    /// reliable — this is the path for changes that must not be dropped.
    StreamMessage { session_id: u64, utf8: String },
    /// The endpoint stopped accepting because of an error of its own. The
    /// endpoint is still a valid handle and still has to be stopped.
    EndpointError { message: String },
}

impl Event {
    /// The name this event travels under, for tests that must not restate the
    /// serde attribute by hand.
    pub fn kind(&self) -> &'static str {
        match self {
            Event::SessionOpened { .. } => "sessionOpened",
            Event::SessionClosed { .. } => "sessionClosed",
            Event::Datagram { .. } => "datagram",
            Event::StreamMessage { .. } => "streamMessage",
            Event::EndpointError { .. } => "endpointError",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_serialised_tag_is_the_name_this_type_claims() {
        let cases = vec![
            Event::SessionOpened {
                session_id: 1,
                authority: "till.local".into(),
                path: "/rk".into(),
            },
            Event::SessionClosed {
                session_id: 1,
                reason: "peer gone".into(),
            },
            Event::Datagram {
                session_id: 1,
                utf8: "x".into(),
            },
            Event::StreamMessage {
                session_id: 1,
                utf8: "x".into(),
            },
            Event::EndpointError {
                message: "x".into(),
            },
        ];
        for event in cases {
            let json: serde_json::Value =
                serde_json::from_str(&serde_json::to_string(&event).unwrap()).unwrap();
            assert_eq!(
                json["kind"].as_str().unwrap(),
                event.kind(),
                "the wire tag and Event::kind disagree for {event:?}"
            );
        }
    }

    #[test]
    fn fields_travel_in_camel_case_so_dart_reads_them_unchanged() {
        let json = serde_json::to_string(&Event::SessionOpened {
            session_id: 7,
            authority: "a".into(),
            path: "/rk".into(),
        })
        .unwrap();
        assert!(json.contains("\"sessionId\":7"), "{json}");
        assert!(!json.contains("session_id"), "{json}");
    }
}
