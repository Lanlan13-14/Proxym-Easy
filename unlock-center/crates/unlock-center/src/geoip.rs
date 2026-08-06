//! MaxMind/DB-IP MMDB city lookup + optional periodic file reload.

use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use arc_swap::ArcSwap;
use maxminddb::geoip2;
use tracing::{info, warn};

#[derive(Debug, Clone, Copy)]
pub struct LatLon {
    pub lat: f64,
    pub lon: f64,
}

pub struct GeoIp {
    path: PathBuf,
    reader: ArcSwap<Option<maxminddb::Reader<Vec<u8>>>>,
}

impl GeoIp {
    pub fn open(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let g = Self {
            path,
            reader: ArcSwap::from_pointee(None),
        };
        let _ = g.reload();
        g
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn reload(&self) -> Result<bool> {
        if !self.path.exists() {
            self.reader.store(Arc::new(None));
            return Ok(false);
        }
        let data = std::fs::read(&self.path)
            .with_context(|| format!("read geoip {}", self.path.display()))?;
        let reader = maxminddb::Reader::from_source(data)
            .with_context(|| format!("parse mmdb {}", self.path.display()))?;
        self.reader.store(Arc::new(Some(reader)));
        info!(path = %self.path.display(), "geoip database loaded");
        Ok(true)
    }

    pub fn lookup(&self, ip: IpAddr) -> Option<LatLon> {
        let guard = self.reader.load();
        let reader = guard.as_ref().as_ref()?;
        // maxminddb 0.24: lookup returns Result<Option<T>, _>
        let city: geoip2::City<'_> = match reader.lookup(ip) {
            Ok(Some(c)) => c,
            Ok(None) | Err(_) => return None,
        };
        let loc = city.location?;
        let lat = loc.latitude?;
        let lon = loc.longitude?;
        Some(LatLon { lat, lon })
    }

    pub fn is_loaded(&self) -> bool {
        self.reader.load().is_some()
    }
}

/// Sleep until next local HH:MM, then run forever at that daily time.
pub async fn daily_at_loop(hour: u32, minute: u32, mut tick: impl FnMut()) {
    loop {
        let wait = seconds_until_hhmm(hour, minute);
        info!(hour, minute, wait_secs = wait, "geoip updater sleeping until next run");
        tokio::time::sleep(Duration::from_secs(wait)).await;
        tick();
        // avoid double-fire in same minute
        tokio::time::sleep(Duration::from_secs(60)).await;
    }
}

/// Seconds until next local HH:MM (CENTER_TZ_OFFSET_HOURS, default +8).
pub fn seconds_until_hhmm(hour: u32, minute: u32) -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    // Local time via chrono-less approximation: use UTC offset from env TZ is complex;
    // use localtime via libc-less: parse from `date` is shell-only.
    // Here use UTC for portable container; entrypoint sets TZ=Asia/Shanghai and we
    // compute with chrono if available — keep simple UTC+ manual offset config later.
    // Prefer: system local via `time` crate OffsetDateTime::now_local if feature exists.
    // Fallback: UTC clock.
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Use local offset from env CENTER_TZ_OFFSET_HOURS default 8 (Shanghai)
    let offset_h: i64 = std::env::var("CENTER_TZ_OFFSET_HOURS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(8);
    let local = (now as i64) + offset_h * 3600;
    let day = ((local % 86400) + 86400) % 86400;
    let target = (hour as i64) * 3600 + (minute as i64) * 60;
    let mut delta = target - day;
    if delta <= 0 {
        delta += 86400;
    }
    delta as u64
}

/// Download MMDB (plain or .gz) to path atomically.
pub fn download_mmdb(url: &str, dest: &Path) -> Result<()> {
    info!(%url, dest = %dest.display(), "downloading geoip database");
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = dest.with_extension("mmdb.part");
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(300))
        .build()?;
    let bytes = client
        .get(url)
        .send()
        .context("geoip http")?
        .error_for_status()
        .context("geoip status")?
        .bytes()
        .context("geoip body")?;

    let data = if url.ends_with(".gz") || looks_gzip(&bytes) {
        use flate2::read::GzDecoder;
        use std::io::Read;
        let mut d = GzDecoder::new(&bytes[..]);
        let mut out = Vec::new();
        d.read_to_end(&mut out).context("gunzip mmdb")?;
        out
    } else {
        bytes.to_vec()
    };

    // MMDB magic: first 16 bytes somewhere contain "\xab\xcd\xefMaxMind.com" near end;
    // basic size check
    if data.len() < 1024 {
        anyhow::bail!("geoip download too small: {} bytes", data.len());
    }
    std::fs::write(&tmp, &data)?;
    std::fs::rename(&tmp, dest)?;
    info!(dest = %dest.display(), bytes = data.len(), "geoip database updated");
    Ok(())
}

fn looks_gzip(b: &[u8]) -> bool {
    b.len() >= 2 && b[0] == 0x1f && b[1] == 0x8b
}

pub fn warn_if_missing(geo: &GeoIp) {
    if !geo.is_loaded() {
        warn!(
            path = %geo.path().display(),
            "geoip DB not loaded; nearest falls back to default_passthrough_region"
        );
    }
}
