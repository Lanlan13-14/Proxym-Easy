use std::fs::File;
use std::io::BufReader;
use std::path::Path;
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use rustls::ServerConfig;
use tracing::info;

use crate::config::Config;

pub fn load_server_config(cfg: &Config) -> Result<Arc<ServerConfig>> {
    match cfg.tls.mode.as_str() {
        "selfsigned" => {
            if cfg.tls.cert_file.exists() && cfg.tls.key_file.exists() {
                load_files(&cfg.tls.cert_file, &cfg.tls.key_file)
            } else {
                info!(domain=%cfg.tls.domain, "generating self-signed TLS cert in memory");
                generate_self_signed(&cfg.tls.domain)
            }
        }
        "files" | "letsencrypt" => {
            load_files(&cfg.tls.cert_file, &cfg.tls.key_file)
                .with_context(|| {
                    format!(
                        "load TLS from {} / {} (mode={})",
                        cfg.tls.cert_file.display(),
                        cfg.tls.key_file.display(),
                        cfg.tls.mode
                    )
                })
        }
        other => bail!("unknown tls mode {other}"),
    }
}

fn load_files(cert_path: &Path, key_path: &Path) -> Result<Arc<ServerConfig>> {
    let cert_file = File::open(cert_path)
        .with_context(|| format!("open cert {}", cert_path.display()))?;
    let mut cert_reader = BufReader::new(cert_file);
    let certs: Vec<CertificateDer<'static>> = rustls_pemfile::certs(&mut cert_reader)
        .collect::<Result<Vec<_>, _>>()
        .context("parse certs pem")?;
    if certs.is_empty() {
        bail!("no certificates in {}", cert_path.display());
    }

    let key_file = File::open(key_path)
        .with_context(|| format!("open key {}", key_path.display()))?;
    let mut key_reader = BufReader::new(key_file);
    let key = rustls_pemfile::private_key(&mut key_reader)
        .context("parse private key")?
        .ok_or_else(|| anyhow::anyhow!("no private key in {}", key_path.display()))?;

    build_config(certs, key)
}

fn generate_self_signed(domain: &str) -> Result<Arc<ServerConfig>> {
    let cert = rcgen::generate_simple_self_signed(vec![domain.to_string(), "localhost".into()])
        .context("rcgen self-signed")?;
    let cert_der = CertificateDer::from(cert.cert);
    let key_der = PrivateKeyDer::try_from(cert.key_pair.serialize_der())
        .map_err(|e| anyhow::anyhow!("key: {e}"))?;
    build_config(vec![cert_der], key_der)
}

fn build_config(
    certs: Vec<CertificateDer<'static>>,
    key: PrivateKeyDer<'static>,
) -> Result<Arc<ServerConfig>> {
    let mut config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .context("build rustls ServerConfig")?;
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    Ok(Arc::new(config))
}
