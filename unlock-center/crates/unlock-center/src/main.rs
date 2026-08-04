mod config;
mod dns_plain;
mod geoip;
mod profile;
mod resolve;
mod serve_tls;
mod tls;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use domain_index::DomainIndex;
use schedule::NodeTable;
use tracing::{error, info, warn};
use tracing_subscriber::EnvFilter;

use crate::config::Config;
use crate::geoip::GeoIp;
use crate::resolve::AppState;

#[tokio::main]
async fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let mut config_path: Option<PathBuf> = None;
    while let Some(a) = args.next() {
        match a.as_str() {
            "-c" | "--config" => {
                config_path = args.next().map(PathBuf::from);
            }
            "-h" | "--help" => {
                eprintln!(
                    "unlock-center — DNS unlock control plane\n  -c, --config <path>  config.toml"
                );
                return Ok(());
            }
            other => {
                eprintln!("unknown arg: {other}");
                std::process::exit(2);
            }
        }
    }

    let cfg = Config::load(config_path.as_deref())?;
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new(&cfg.log_level)),
        )
        .init();

    info!(
        dns = cfg.listen.enable_dns,
        dot = cfg.listen.enable_dot,
        doh = cfg.listen.enable_doh,
        scope = %cfg.policy.unlock_scope,
        default_global = %cfg.policy.default_global_region,
        doh_path = %cfg.listen.doh_base_path,
        geoip = cfg.geoip.enabled,
        "starting unlock-center"
    );

    let index = load_index(&cfg)?;
    info!(entries = index.len(), "domain index loaded");

    let nodes = NodeTable::load_file(&cfg.nodes.file)
        .with_context(|| format!("load nodes {}", cfg.nodes.file.display()))?;
    info!(
        nodes = nodes.all().len(),
        regions = ?nodes.regions(),
        "nodes loaded"
    );

    let geo = if cfg.geoip.enabled {
        GeoIp::open(&cfg.geoip.db_path)
    } else {
        GeoIp::open("/dev/null")
    };
    crate::geoip::warn_if_missing(&geo);

    let state = AppState::new(cfg.clone(), index, nodes, geo);

    // Write pid for cert-manager / geoip-updater signals.
    if let Ok(pid_path) = std::env::var("CENTER_PID_FILE") {
        if let Some(parent) = std::path::Path::new(&pid_path).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(&pid_path, format!("{}\n", std::process::id()));
    }

    {
        let st = Arc::clone(&state);
        tokio::spawn(async move {
            refresh_loop(st).await;
        });
    }

    // Optional in-process geoip download schedule (shell updater preferred in Docker).
    if cfg.geoip.enabled && cfg.geoip.auto_update && !cfg.geoip.update_url.is_empty() {
        let st = Arc::clone(&state);
        let url = cfg.geoip.update_url.clone();
        let path = cfg.geoip.db_path.clone();
        let hour = cfg.geoip.update_hour;
        let minute = cfg.geoip.update_minute;
        tokio::spawn(async move {
            crate::geoip::daily_at_loop(hour, minute, || {
                match crate::geoip::download_mmdb(&url, &path) {
                    Ok(()) => {
                        if let Err(e) = st.geoip.reload() {
                            warn!(error = %e, "geoip reload after download");
                        }
                    }
                    Err(e) => warn!(error = %e, "geoip download failed"),
                }
            })
            .await;
        });
    }

    // Signal handlers: SIGHUP reload TLS+geoip, SIGUSR1 reload geoip only.
    {
        let st = Arc::clone(&state);
        tokio::spawn(async move {
            signal_loop(st).await;
        });
    }

    let mut handles = Vec::new();

    if cfg.listen.enable_dns {
        let addr: SocketAddr = format!("{}:{}", cfg.listen.dns_host, cfg.listen.dns_port)
            .parse()
            .context("dns addr")?;
        let st = Arc::clone(&state);
        handles.push(tokio::spawn(async move {
            if let Err(e) = dns_plain::serve_udp(st, addr).await {
                error!(error = %e, "dns udp exited");
            }
        }));
        let st = Arc::clone(&state);
        let addr_tcp = addr;
        handles.push(tokio::spawn(async move {
            if let Err(e) = dns_plain::serve_tcp(st, addr_tcp).await {
                error!(error = %e, "dns tcp exited");
            }
        }));
    }

    if cfg.needs_tls() {
        let tls_cfg = tls::load_server_config(&cfg)?;
        if cfg.listen.enable_dot {
            let addr: SocketAddr = format!("{}:{}", cfg.listen.dot_host, cfg.listen.dot_port)
                .parse()
                .context("dot addr")?;
            let st = Arc::clone(&state);
            let tls = Arc::clone(&tls_cfg);
            handles.push(tokio::spawn(async move {
                if let Err(e) = serve_tls::serve_dot(st, addr, tls).await {
                    error!(error = %e, "dot exited");
                }
            }));
        }
        if cfg.listen.enable_doh {
            let addr: SocketAddr = format!("{}:{}", cfg.listen.doh_host, cfg.listen.doh_port)
                .parse()
                .context("doh addr")?;
            let st = Arc::clone(&state);
            let tls = Arc::clone(&tls_cfg);
            handles.push(tokio::spawn(async move {
                if let Err(e) = serve_tls::serve_doh(st, addr, tls).await {
                    error!(error = %e, "doh exited");
                }
            }));
        }
    }

    if handles.is_empty() {
        anyhow::bail!("no listeners started");
    }

    info!("unlock-center ready");
    tokio::signal::ctrl_c().await.ok();
    info!("shutdown signal");
    let _ = handles.len();
    Ok(())
}

async fn signal_loop(state: Arc<AppState>) {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        let mut hup = match signal(SignalKind::hangup()) {
            Ok(s) => s,
            Err(e) => {
                warn!(error = %e, "SIGHUP handler unavailable");
                return;
            }
        };
        let mut usr1 = match signal(SignalKind::user_defined1()) {
            Ok(s) => s,
            Err(e) => {
                warn!(error = %e, "SIGUSR1 handler unavailable");
                return;
            }
        };
        loop {
            tokio::select! {
                _ = hup.recv() => {
                    info!("SIGHUP: reload geoip (+ TLS requires process restart for rustls identity today)");
                    if let Err(e) = state.geoip.reload() {
                        warn!(error = %e, "geoip reload on SIGHUP");
                    }
                }
                _ = usr1.recv() => {
                    info!("SIGUSR1: reload geoip database");
                    if let Err(e) = state.geoip.reload() {
                        warn!(error = %e, "geoip reload on SIGUSR1");
                    }
                }
            }
        }
    }
    #[cfg(not(unix))]
    {
        let _ = state;
        std::future::pending::<()>().await;
    }
}

fn load_index(cfg: &Config) -> Result<DomainIndex> {
    let min = cfg.tables.min_entries;
    if cfg.tables.domain_map_file.exists() {
        return DomainIndex::load_file(&cfg.tables.domain_map_file, min)
            .map_err(|e| anyhow::anyhow!(e));
    }
    if !cfg.tables.domain_map_url.is_empty() {
        info!(url = %cfg.tables.domain_map_url, "fetch domain map");
        let text = reqwest::blocking::get(&cfg.tables.domain_map_url)
            .context("fetch map")?
            .error_for_status()
            .context("map http")?
            .text()
            .context("map body")?;
        return DomainIndex::load_str(&text, min).map_err(|e| anyhow::anyhow!(e));
    }
    warn!("no domain map file/url; starting with empty index");
    DomainIndex::load_str("", 0).map_err(|e| anyhow::anyhow!(e))
}

async fn refresh_loop(state: Arc<AppState>) {
    let interval = Duration::from_secs(state.cfg.tables.refresh_interval_secs.max(60));
    loop {
        tokio::time::sleep(interval).await;
        let cfg = &state.cfg;
        let min = cfg.tables.min_entries;
        let result = if cfg.tables.domain_map_file.exists() {
            DomainIndex::load_file(&cfg.tables.domain_map_file, min)
        } else if !cfg.tables.domain_map_url.is_empty() {
            match reqwest::get(&cfg.tables.domain_map_url).await {
                Ok(resp) => match resp.text().await {
                    Ok(text) => DomainIndex::load_str(&text, min),
                    Err(e) => {
                        warn!(error = %e, "refresh body");
                        continue;
                    }
                },
                Err(e) => {
                    warn!(error = %e, "refresh fetch");
                    continue;
                }
            }
        } else {
            continue;
        };
        match result {
            Ok(idx) => {
                info!(entries = idx.len(), "domain index refreshed");
                state.index.store(Arc::new(idx));
            }
            Err(e) => warn!(error = %e, "refresh failed; keep old index"),
        }
    }
}
