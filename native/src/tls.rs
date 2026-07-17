// lvim-db-native/tls: the shared rustls client-config builder.
//
// One place turns a TlsSpec into a rustls ClientConfig for every network driver
// (no OpenSSL anywhere). Encryption is the DEFAULT posture: `Prefer` attempts
// TLS and only falls back to plaintext when the server has none (and that is
// surfaced, never silent); `Require`/`VerifyCa`/`VerifyFull` mandate it. `ca`
// verifies the server chain; `client_cert`/`client_key` enable mutual X.509.
//
// The daemon installs a process-wide crypto provider once at startup (see
// install_crypto_provider) so rustls has algorithms without each call wiring one.

use std::sync::Arc;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, RootCertStore, SignatureScheme};

use crate::spec::TlsSpec;

/// Install the process-wide default crypto provider (ring) once. Idempotent.
pub fn install_crypto_provider() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

/// Load PEM certificates from a file.
fn load_certs(path: &str) -> anyhow::Result<Vec<CertificateDer<'static>>> {
    let data = std::fs::read(path).map_err(|e| anyhow::anyhow!("cannot read cert '{path}': {e}"))?;
    let mut reader = std::io::BufReader::new(&data[..]);
    let certs: Result<Vec<_>, _> = rustls_pemfile::certs(&mut reader).collect();
    certs.map_err(|e| anyhow::anyhow!("bad certificate '{path}': {e}"))
}

/// Load a PEM private key from a file.
fn load_key(path: &str) -> anyhow::Result<PrivateKeyDer<'static>> {
    let data = std::fs::read(path).map_err(|e| anyhow::anyhow!("cannot read key '{path}': {e}"))?;
    let mut reader = std::io::BufReader::new(&data[..]);
    rustls_pemfile::private_key(&mut reader)
        .map_err(|e| anyhow::anyhow!("bad private key '{path}': {e}"))?
        .ok_or_else(|| anyhow::anyhow!("no private key found in '{path}'"))
}

/// A dangerous verifier that accepts ANY server certificate — used for the
/// encrypt-but-do-not-verify modes (`Prefer` / `Require`), where the link is
/// still fully encrypted but the peer identity is not checked (as with libpq's
/// sslmode=require). The verifying modes (`VerifyCa`/`VerifyFull`) never use it.
#[derive(Debug)]
struct AcceptAnyServerCert(Arc<rustls::crypto::CryptoProvider>);

impl ServerCertVerifier for AcceptAnyServerCert {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &self.0.signature_verification_algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.0.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

/// Build a rustls ClientConfig for `tls`. Applies the CA / system roots and any
/// client certificate (mutual X.509); uses the accept-any verifier for the
/// encrypt-only modes. Errors if a client cert is given without a key (or vice
/// versa), or a referenced file is unreadable.
pub fn client_config(tls: &TlsSpec) -> anyhow::Result<Arc<ClientConfig>> {
    let provider = rustls::crypto::CryptoProvider::get_default()
        .cloned()
        .unwrap_or_else(|| Arc::new(rustls::crypto::ring::default_provider()));

    let builder = ClientConfig::builder();

    // Root store (used only when the mode verifies the chain).
    let config = if tls.verifies_cert() {
        let mut roots = RootCertStore::empty();
        if let Some(ca) = &tls.ca {
            for cert in load_certs(ca)? {
                roots
                    .add(cert)
                    .map_err(|e| anyhow::anyhow!("bad CA certificate: {e}"))?;
            }
        } else {
            let native = rustls_native_certs::load_native_certs();
            for cert in native.certs {
                let _ = roots.add(cert);
            }
        }
        let b = builder.with_root_certificates(roots);
        finish(b, tls)?
    } else {
        // Encrypt-only (Prefer / Require): accept any server cert.
        let verifier = Arc::new(AcceptAnyServerCert(provider));
        let b = builder.dangerous().with_custom_certificate_verifier(verifier);
        finish(b, tls)?
    };

    Ok(Arc::new(config))
}

/// Apply the optional client certificate (mutual X.509), else no client auth.
fn finish(
    builder: rustls::ConfigBuilder<ClientConfig, rustls::client::WantsClientCert>,
    tls: &TlsSpec,
) -> anyhow::Result<ClientConfig> {
    match (&tls.client_cert, &tls.client_key) {
        (Some(cert), Some(key)) => {
            let certs = load_certs(cert)?;
            let key = load_key(key)?;
            builder
                .with_client_auth_cert(certs, key)
                .map_err(|e| anyhow::anyhow!("client certificate rejected: {e}"))
        }
        (None, None) => Ok(builder.with_no_client_auth()),
        _ => Err(anyhow::anyhow!("TLS client cert and key must be provided together")),
    }
}
