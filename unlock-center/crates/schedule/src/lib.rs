//! Unlock node table: pick by region, nearest for passthrough.

use std::fs;
use std::net::IpAddr;
use std::path::Path;
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use serde::Deserialize;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ScheduleError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("toml: {0}")]
    Toml(#[from] toml::de::Error),
    #[error("no healthy node for region {0}")]
    NoNode(String),
    #[error("invalid unlock_ip for node {0}")]
    BadIp(String),
}

#[derive(Debug, Clone, Deserialize)]
pub struct NodeConfig {
    pub id: String,
    pub region: String,
    pub unlock_ip: String,
    /// DNS passthrough upstream, e.g. "1.2.3.4:53"
    pub dns_upstream: String,
    #[serde(default = "default_weight")]
    pub weight: u32,
    pub lat: Option<f64>,
    pub lon: Option<f64>,
}

fn default_weight() -> u32 {
    10
}

#[derive(Debug, Deserialize)]
struct NodesFile {
    nodes: Vec<NodeConfig>,
}

#[derive(Debug)]
pub struct Node {
    pub id: String,
    pub region: String,
    pub unlock_ip: IpAddr,
    pub dns_upstream: String,
    pub weight: u32,
    pub lat: Option<f64>,
    pub lon: Option<f64>,
    pub healthy: AtomicBool,
}

impl Node {
    pub fn is_healthy(&self) -> bool {
        self.healthy.load(Ordering::Relaxed)
    }

    pub fn set_healthy(&self, ok: bool) {
        self.healthy.store(ok, Ordering::Relaxed);
    }
}

#[derive(Debug, Default)]
pub struct NodeTable {
    nodes: Vec<Arc<Node>>,
}

impl NodeTable {
    pub fn from_configs(cfgs: Vec<NodeConfig>) -> Result<Self, ScheduleError> {
        let mut nodes = Vec::with_capacity(cfgs.len());
        for c in cfgs {
            let ip = IpAddr::from_str(c.unlock_ip.trim())
                .map_err(|_| ScheduleError::BadIp(c.id.clone()))?;
            nodes.push(Arc::new(Node {
                id: c.id,
                region: c.region.to_ascii_lowercase(),
                unlock_ip: ip,
                dns_upstream: c.dns_upstream,
                weight: c.weight.max(1),
                lat: c.lat,
                lon: c.lon,
                healthy: AtomicBool::new(true),
            }));
        }
        Ok(Self { nodes })
    }

    pub fn load_file(path: impl AsRef<Path>) -> Result<Self, ScheduleError> {
        let text = fs::read_to_string(path)?;
        let f: NodesFile = toml::from_str(&text)?;
        Self::from_configs(f.nodes)
    }

    pub fn load_str(text: &str) -> Result<Self, ScheduleError> {
        let f: NodesFile = toml::from_str(text)?;
        Self::from_configs(f.nodes)
    }

    pub fn all(&self) -> &[Arc<Node>] {
        &self.nodes
    }

    pub fn regions(&self) -> Vec<String> {
        let mut v: Vec<String> = self.nodes.iter().map(|n| n.region.clone()).collect();
        v.sort();
        v.dedup();
        v
    }

    /// Weighted pick among healthy nodes in region; fallback any healthy if allow_fallback.
    pub fn pick_region(&self, region: &str, allow_fallback: bool) -> Result<Arc<Node>, ScheduleError> {
        let region = region.to_ascii_lowercase();
        let mut pool: Vec<&Arc<Node>> = self
            .nodes
            .iter()
            .filter(|n| n.region == region && n.is_healthy())
            .collect();
        if pool.is_empty() && allow_fallback {
            pool = self.nodes.iter().filter(|n| n.is_healthy()).collect();
        }
        if pool.is_empty() {
            return Err(ScheduleError::NoNode(region));
        }
        // Deterministic weighted pick by id hash + weight for simplicity (no RNG dependency).
        let total: u64 = pool.iter().map(|n| n.weight as u64).sum();
        let mut slot = simple_hash(region.as_bytes()) % total.max(1);
        for n in &pool {
            if slot < n.weight as u64 {
                return Ok(Arc::clone(n));
            }
            slot -= n.weight as u64;
        }
        Ok(Arc::clone(pool[0]))
    }

    /// Nearest healthy node by lat/lon if available; else first healthy; else error.
    pub fn nearest(&self, lat: Option<f64>, lon: Option<f64>) -> Result<Arc<Node>, ScheduleError> {
        let healthy: Vec<&Arc<Node>> = self.nodes.iter().filter(|n| n.is_healthy()).collect();
        if healthy.is_empty() {
            return Err(ScheduleError::NoNode("*".into()));
        }
        if let (Some(clat), Some(clon)) = (lat, lon) {
            let mut best = healthy[0];
            let mut best_d = f64::MAX;
            for n in &healthy {
                if let (Some(nlat), Some(nlon)) = (n.lat, n.lon) {
                    let d = haversine_km(clat, clon, nlat, nlon);
                    if d < best_d {
                        best_d = d;
                        best = n;
                    }
                }
            }
            return Ok(Arc::clone(best));
        }
        Ok(Arc::clone(healthy[0]))
    }

    /// Prefer region match for passthrough; else nearest.
    pub fn nearest_or_region(
        &self,
        preferred_region: Option<&str>,
        lat: Option<f64>,
        lon: Option<f64>,
    ) -> Result<Arc<Node>, ScheduleError> {
        if let Some(r) = preferred_region {
            if let Ok(n) = self.pick_region(r, false) {
                return Ok(n);
            }
        }
        self.nearest(lat, lon)
    }
}

fn simple_hash(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x100_0000_01b3);
    }
    h
}

fn haversine_km(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    let r = 6371.0_f64;
    let dlat = (lat2 - lat1).to_radians();
    let dlon = (lon2 - lon1).to_radians();
    let a = (dlat / 2.0).sin().powi(2)
        + lat1.to_radians().cos() * lat2.to_radians().cos() * (dlon / 2.0).sin().powi(2);
    2.0 * r * a.sqrt().asin()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pick_region_and_nearest() {
        let table = NodeTable::load_str(
            r#"
[[nodes]]
id = "us-1"
region = "us"
unlock_ip = "203.0.113.10"
dns_upstream = "203.0.113.10:53"
weight = 10
lat = 37.0
lon = -122.0

[[nodes]]
id = "jp-1"
region = "jp"
unlock_ip = "203.0.113.20"
dns_upstream = "203.0.113.20:53"
weight = 10
lat = 35.0
lon = 139.0

[[nodes]]
id = "uk-1"
region = "uk"
unlock_ip = "203.0.113.40"
dns_upstream = "203.0.113.40:53"
weight = 10
lat = 51.5
lon = -0.1
"#,
        )
        .unwrap();

        let n = table.pick_region("uk", false).unwrap();
        assert_eq!(n.id, "uk-1");
        assert_eq!(n.unlock_ip.to_string(), "203.0.113.40");

        // Near Tokyo → jp
        let n = table.nearest(Some(35.6), Some(139.7)).unwrap();
        assert_eq!(n.region, "jp");

        // Near London → uk
        let n = table.nearest(Some(51.5), Some(-0.1)).unwrap();
        assert_eq!(n.region, "uk");
    }
}
