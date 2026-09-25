//! The JSON a caller passes to `rk_quic_client_connect`, and its parsed form.
//!
//! Separate from [`crate::config`] and not an extension of it, because the two
//! sides ask for different things and almost nothing overlaps: a server is told
//! where to bind and which identity to present, a client is told where to go
//! and which certificate to accept. Folding them into one structure would make
//! half the fields meaningless on each side, and "meaningless here" is how a
//! field ends up silently ignored.
//!
//! # Why a hash and not a root store
//!
//! The till presents a certificate it issued itself, valid for days, rotated on
//! a timer. No certificate authority vouches for it and none can. The browser
//! half of this system already solves that with the W3C
//! `serverCertificateHashes` option — the page names the exact certificate it
//! will accept — and `wtransport` exposes the same mechanism
//! (`with_server_certificate_hashes`). Doing anything else here would mean the
//! native client trusted the till by a *different* rule than the browser does,
//! and two rules for one decision is how one of them ends up wrong.
//!
//! The hash therefore is **required**. There is no "trust anything" mode and no
//! system root store option: both exist in `wtransport`, both are wrong for
//! this endpoint, and an option that must never be used is an option that will
//! be used.

use std::time::Duration;

use serde::Deserialize;

use crate::status::Status;

/// The JSON a caller passes to `rk_quic_client_connect`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientConfig {
    /// Where to connect, as a WebTransport URL: `https://host:port/path`.
    ///
    /// `https`, not `wss` and not `quic`: WebTransport over HTTP/3 names its
    /// endpoints with `https`, and the browser half of this system uses the
    /// same string.
    pub url: String,

    /// SHA-256 of the server's certificate, hex, 64 characters.
    ///
    /// The same string the till publishes as `certificateFingerprintSha256`.
    /// Case is not significant; separators are not accepted, because a value
    /// copied from one tool with colons and from another without them would
    /// otherwise be two different values for one certificate.
    pub certificate_hash_sha256: String,

    /// How long a silent session lives before it is called gone.
    ///
    /// Mirrors the server's field and its default for the same reason: a
    /// client that gives up sooner than the server does turns a slow network
    /// into a reconnect loop, and one that gives up later holds a dead session
    /// for as long as the operator is willing to wait.
    #[serde(default = "default_idle_timeout_ms")]
    pub idle_timeout_ms: u64,
}

/// Thirty seconds, the same as the server's. See [`crate::config`].
fn default_idle_timeout_ms() -> u64 {
    30_000
}

/// A parsed, validated client configuration.
#[derive(Debug)]
pub struct ParsedClientConfig {
    pub url: String,
    /// The certificate hash as bytes — 32 of them, always.
    pub certificate_hash: [u8; 32],
    pub idle_timeout: Duration,
}

impl ClientConfig {
    /// Validates and converts, or says exactly what is wrong.
    ///
    /// Everything that can be refused is refused here, before a socket exists:
    /// a connection that fails for a reason knowable in advance costs a
    /// timeout to discover and explains itself badly.
    pub fn parse(&self) -> Result<ParsedClientConfig, (Status, String)> {
        if self.url.is_empty() {
            return Err((Status::InvalidArgument, "url is empty".into()));
        }
        if !self.url.starts_with("https://") {
            return Err((
                Status::InvalidArgument,
                format!(
                    "url must start with https:// — WebTransport names its \
                     endpoints that way; got {:?}",
                    self.url
                ),
            ));
        }

        let hash = parse_hash(&self.certificate_hash_sha256)?;

        // Zero would mean "never give up", which is not a timeout but its
        // absence, and the server refuses the same value for the same reason.
        if self.idle_timeout_ms == 0 {
            return Err((
                Status::InvalidArgument,
                "idleTimeoutMs 0 means no timeout at all; give a duration".into(),
            ));
        }

        Ok(ParsedClientConfig {
            url: self.url.clone(),
            certificate_hash: hash,
            idle_timeout: Duration::from_millis(self.idle_timeout_ms),
        })
    }
}

/// 64 hex characters into 32 bytes, or a sentence saying why not.
///
/// The length is checked before the digits so that the common mistake — a
/// fingerprint copied with colons, which is 95 characters — is reported as a
/// length problem rather than as an unexpected `:` at position 2.
fn parse_hash(text: &str) -> Result<[u8; 32], (Status, String)> {
    let trimmed = text.trim();
    if trimmed.len() != 64 {
        return Err((
            Status::InvalidArgument,
            format!(
                "certificateHashSha256 must be 64 hex characters, got {} — \
                 a fingerprint copied with colons has 95",
                trimmed.len()
            ),
        ));
    }
    let mut out = [0u8; 32];
    for (i, byte) in out.iter_mut().enumerate() {
        let pair = &trimmed[i * 2..i * 2 + 2];
        *byte = u8::from_str_radix(pair, 16).map_err(|_| {
            (
                Status::InvalidArgument,
                format!("certificateHashSha256 has {pair:?} where two hex digits belong"),
            )
        })?;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(url: &str, hash: &str) -> ClientConfig {
        ClientConfig {
            url: url.into(),
            certificate_hash_sha256: hash.into(),
            idle_timeout_ms: 30_000,
        }
    }

    const GOOD: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    #[test]
    fn accepts_a_well_formed_configuration() {
        let parsed = config("https://127.0.0.1:4433/wire", GOOD).parse().unwrap();
        assert_eq!(parsed.certificate_hash[0], 0x01);
        assert_eq!(parsed.certificate_hash[31], 0xef);
    }

    #[test]
    fn refuses_a_url_that_is_not_https() {
        let (status, detail) = config("wss://127.0.0.1:4433/wire", GOOD).parse().unwrap_err();
        assert_eq!(status, Status::InvalidArgument);
        assert!(detail.contains("https://"), "{detail}");
    }

    #[test]
    fn names_the_colon_mistake_by_its_length() {
        let colons = "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef:\
                      01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef";
        let (status, detail) = config("https://x:1/y", colons).parse().unwrap_err();
        assert_eq!(status, Status::InvalidArgument);
        assert!(detail.contains("colons"), "{detail}");
    }

    #[test]
    fn refuses_a_zero_timeout_rather_than_meaning_forever() {
        let mut c = config("https://x:1/y", GOOD);
        c.idle_timeout_ms = 0;
        let (status, detail) = c.parse().unwrap_err();
        assert_eq!(status, Status::InvalidArgument);
        assert!(detail.contains("no timeout at all"), "{detail}");
    }

    #[test]
    fn hex_is_case_insensitive_because_tools_disagree() {
        let upper = GOOD.to_uppercase();
        let a = config("https://x:1/y", GOOD).parse().unwrap();
        let b = config("https://x:1/y", &upper).parse().unwrap();
        assert_eq!(a.certificate_hash, b.certificate_hash);
    }
}
