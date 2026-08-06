mod config;
mod control;
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
    // rustls 0.23 no longer picks a process-wide crypto provider implicitly
    // when multiple TLS stacks are linked (reqwest + tokio-rustls).
    // Use ring (not aws-lc-rs) so CI/Docker avoid the heavy aws-lc-sys C build.
    let _ = rustls::crypto::ring::default_provider().install_default();

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
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(&cfg.log_level)),
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

    let control = if cfg.control.bearer_token.is_empty() {
        None
    } else {
        let hub = crate::control::ControlHub::new(
            cfg.control.bearer_token.clone(),
            cfg.control.path.clone(),
        );
        info!(path = %hub.path(), "unlock control endpoint enabled on existing DoH TLS port");
        Some(hub)
    };
    let state = AppState::new(cfg.clone(), index, nodes, geo, control);

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
                    info!("SIGHUP: reload GeoIP and optional center ACL snapshot");
                    if let Err(e) = state.geoip.reload() {
                        warn!(error = %e, "geoip reload on SIGHUP");
                    }
                    match state.reload_acl_from_file().await {
                        Ok(true) => info!("center ACL reloaded and pushed to control nodes"),
                        Ok(false) => {}
                        Err(e) => warn!(error = %e, "center ACL reload on SIGHUP; kept old snapshot"),
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
    // Prefer remote URL (same model as unlock DOMAIN_LIST_URL): fetch first,
    // cache to domain_map_file, fall back to local seed on failure.
    if !cfg.tables.domain_map_url.is_empty() {
        match fetch_domain_map_text_blocking(&cfg.tables.domain_map_url) {
            Ok(text) => match DomainIndex::load_str(&text, min) {
                Ok(idx) => {
                    cache_domain_map_file(&cfg.tables.domain_map_file, &text);
                    info!(
                        url = %cfg.tables.domain_map_url,
                        entries = idx.len(),
                        "domain map loaded from URL"
                    );
                    return Ok(idx);
                }
                Err(e) => warn!(
                    error = %e,
                    url = %cfg.tables.domain_map_url,
                    "remote domain map invalid; trying local file"
                ),
            },
            Err(e) => warn!(
                error = %e,
                url = %cfg.tables.domain_map_url,
                "remote domain map fetch failed; trying local file"
            ),
        }
    }
    if cfg.tables.domain_map_file.exists() {
        info!(
            path = %cfg.tables.domain_map_file.display(),
            "domain map loaded from local file"
        );
        return DomainIndex::load_file(&cfg.tables.domain_map_file, min)
            .map_err(|e| anyhow::anyhow!(e));
    }
    warn!("no domain map file/url; starting with empty index");
    DomainIndex::load_str("", 0).map_err(|e| anyhow::anyhow!(e))
}

fn fetch_domain_map_text_blocking(url: &str) -> Result<String> {
    info!(%url, "fetch domain map");
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .user_agent("proxym-easy-unlock-center/domain-map")
        .build()
        .context("build http client")?;
    let text = client
        .get(url)
        .send()
        .context("fetch map")?
        .error_for_status()
        .context("map http")?
        .text()
        .context("map body")?;
    Ok(text)
}

fn cache_domain_map_file(path: &std::path::Path, text: &str) {
    if path.as_os_str().is_empty() {
        return;
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let tmp = path.with_extension("map.part");
    if std::fs::write(&tmp, text).is_ok() {
        let _ = std::fs::rename(&tmp, path);
    }
}

async fn fetch_domain_map_text(url: &str) -> Result<String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .user_agent("proxym-easy-unlock-center/domain-map")
        .build()
        .context("build http client")?;
    let resp = client.get(url).send().await.context("fetch map")?;
    let resp = resp.error_for_status().context("map http")?;
    let text = resp.text().await.context("map body")?;
    Ok(text)
}

async fn apply_domain_map_refresh(state: &AppState) {
    let cfg = &state.cfg;
    let min = cfg.tables.min_entries;
    let result = if !cfg.tables.domain_map_url.is_empty() {
        match fetch_domain_map_text(&cfg.tables.domain_map_url).await {
            Ok(text) => {
                let parsed = DomainIndex::load_str(&text, min);
                if parsed.is_ok() {
                    cache_domain_map_file(&cfg.tables.domain_map_file, &text);
                }
                parsed
            }
            Err(e) => {
                warn!(error = %e, "domain map URL refresh failed; trying local file");
                if cfg.tables.domain_map_file.exists() {
                    DomainIndex::load_file(&cfg.tables.domain_map_file, min)
                } else {
                    return;
                }
            }
        }
    } else if cfg.tables.domain_map_file.exists() {
        DomainIndex::load_file(&cfg.tables.domain_map_file, min)
    } else {
        return;
    };
    match result {
        Ok(idx) => {
            info!(entries = idx.len(), "domain index refreshed");
            state.index.store(Arc::new(idx));
        }
        Err(e) => warn!(error = %e, "domain map refresh failed; keep old index"),
    }
}

/// Default: daily at update_hour:update_minute (04:00, same as unlock domain-updater).
/// If refresh_interval_secs > 0, use fixed interval instead (legacy).
async fn refresh_loop(state: Arc<AppState>) {
    let hour = state.cfg.tables.update_hour.min(23);
    let minute = state.cfg.tables.update_minute.min(59);
    let interval_secs = state.cfg.tables.refresh_interval_secs;
    info!(
        hour,
        minute,
        interval_secs,
        url = %state.cfg.tables.domain_map_url,
        "domain map refresh armed"
    );

    if interval_secs > 0 {
        let mut interval =
            tokio::time::interval(Duration::from_secs(interval_secs.max(60)));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        // Boot already loaded the map; skip the immediate first tick.
        interval.tick().await;
        loop {
            interval.tick().await;
            apply_domain_map_refresh(&state).await;
        }
    } else {
        loop {
            let wait = crate::geoip::seconds_until_hhmm(hour, minute);
            info!(
                hour,
                minute,
                wait_secs = wait,
                "domain map sleeping until next daily refresh"
            );
            tokio::time::sleep(Duration::from_secs(wait)).await;
            apply_domain_map_refresh(&state).await;
            // Avoid double-fire within the same minute.
            tokio::time::sleep(Duration::from_secs(60)).await;
        }
    }
}
