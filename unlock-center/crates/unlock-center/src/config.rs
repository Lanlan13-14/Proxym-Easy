use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde::Deserialize;

use domain_index::UnlockScope;
use ipnet::IpNet;

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Config {
    pub listen: ListenConfig,
    pub tls: TlsConfig,
    pub policy: PolicyConfig,
    pub tables: TablesConfig,
    pub nodes: NodesConfig,
    pub schedule: ScheduleConfig,
    pub geoip: GeoIpConfig,
    pub passthrough: PassthroughConfig,
    pub cache: CacheConfig,
    pub access: AccessConfig,
    pub control: ControlConfig,
    pub log_level: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct GeoIpConfig {
    /// Path to City MMDB (GeoLite2-City / DB-IP).
    pub db_path: PathBuf,
    /// Enable loading/using MMDB for nearest.
    pub enabled: bool,
    /// Built-in default City MMDB URL (override if needed).
    pub update_url: String,
    pub auto_update: bool,
    pub update_hour: u32,
    pub update_minute: u32,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct NodesConfig {
    /// Path to nodes.toml registry
    pub file: PathBuf,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct ListenConfig {
    pub enable_dns: bool,
    pub dns_host: String,
    pub dns_port: u16,
    pub enable_dot: bool,
    pub dot_host: String,
    pub dot_port: u16,
    pub enable_doh: bool,
    pub doh_host: String,
    pub doh_port: u16,
    pub doh_base_path: String,
    pub doh_extra_paths: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct TlsConfig {
    /// selfsigned | files | letsencrypt (letsencrypt uses files written by cert-manager)
    pub mode: String,
    pub domain: String,
    pub cert_file: PathBuf,
    pub key_file: PathBuf,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct PolicyConfig {
    pub unlock_scope: String,
    pub enable_ai_unlock: bool,
    pub default_global_region: String,
    /// Empty = follow global
    pub default_ai_region: String,
    pub allow_regions: Vec<String>,
    pub unlock_answer_ttl_secs: u32,
    /// empty | passthrough | soa
    pub aaaa_mode: String,
    /// refused | passthrough
    pub other_qtype_mode: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct TablesConfig {
    pub domain_map_url: String,
    pub domain_map_file: PathBuf,
    pub refresh_interval_secs: u64,
    pub min_entries: usize,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct ScheduleConfig {
    pub nearest_for_passthrough: bool,
    pub default_passthrough_region: String,
    pub allow_region_fallback: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct PassthroughConfig {
    pub timeout_ms: u64,
    pub fallback_upstreams: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct CacheConfig {
    pub passthrough_max_entries: usize,
    pub passthrough_max_ttl_secs: u32,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct AccessConfig {
    pub allowed_cidrs: Vec<String>,
    pub bearer_token: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct ControlConfig {
    /// Shared bearer token for WebSocket control sessions. Empty disables the endpoint.
    pub bearer_token: String,
    /// Path served on the existing DoH TLS listener; it never opens another port.
    pub path: String,
}

impl Default for ListenConfig {
    fn default() -> Self {
        Self {
            enable_dns: false,
            dns_host: "0.0.0.0".into(),
            dns_port: 53,
            enable_dot: true,
            dot_host: "0.0.0.0".into(),
            dot_port: 853,
            enable_doh: true,
            doh_host: "0.0.0.0".into(),
            doh_port: 443,
            doh_base_path: "/api/v2/weather".into(),
            doh_extra_paths: vec![],
        }
    }
}

impl Default for TlsConfig {
    fn default() -> Self {
        Self {
            mode: "selfsigned".into(),
            domain: "dns.example.com".into(),
            cert_file: PathBuf::from("/data/tls/cert.pem"),
            key_file: PathBuf::from("/data/tls/key.pem"),
        }
    }
}

impl Default for PolicyConfig {
    fn default() -> Self {
        Self {
            unlock_scope: "all".into(),
            enable_ai_unlock: true,
            default_global_region: "us".into(),
            default_ai_region: String::new(),
            allow_regions: vec![
                "us".into(),
                "jp".into(),
                "hk".into(),
                "sg".into(),
                "tw".into(),
                "uk".into(),
                "kr".into(),
                "eu".into(),
                "sea".into(),
            ],
            unlock_answer_ttl_secs: 45,
            aaaa_mode: "empty".into(),
            other_qtype_mode: "refused".into(),
        }
    }
}

impl Default for TablesConfig {
    fn default() -> Self {
        Self {
            domain_map_url: String::new(),
            domain_map_file: PathBuf::from("domains/domain-region.map"),
            refresh_interval_secs: 3600,
            min_entries: 1,
        }
    }
}

impl Default for NodesConfig {
    fn default() -> Self {
        Self {
            file: PathBuf::from("nodes.toml"),
        }
    }
}

impl Default for ScheduleConfig {
    fn default() -> Self {
        Self {
            nearest_for_passthrough: true,
            default_passthrough_region: "us".into(),
            allow_region_fallback: false,
        }
    }
}

impl Default for GeoIpConfig {
    fn default() -> Self {
        Self {
            db_path: PathBuf::from("/data/geoip/GeoLite2-City.mmdb"),
            enabled: true,
            // Same built-in as scripts/geoip-updater.sh (no MaxMind key required).
            update_url: "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb"
                .into(),
            auto_update: true,
            update_hour: 4,
            update_minute: 0,
        }
    }
}

impl Default for PassthroughConfig {
    fn default() -> Self {
        Self {
            timeout_ms: 800,
            fallback_upstreams: vec!["1.1.1.1:53".into(), "8.8.8.8:53".into()],
        }
    }
}

impl Default for CacheConfig {
    fn default() -> Self {
        Self {
            passthrough_max_entries: 500_000,
            passthrough_max_ttl_secs: 300,
        }
    }
}

impl Default for AccessConfig {
    fn default() -> Self {
        Self {
            allowed_cidrs: vec![],
            bearer_token: String::new(),
        }
    }
}

impl Default for ControlConfig {
    fn default() -> Self {
        Self {
            bearer_token: String::new(),
            path: "/unlock-control/v1/connect".into(),
        }
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            listen: ListenConfig::default(),
            tls: TlsConfig::default(),
            policy: PolicyConfig::default(),
            tables: TablesConfig::default(),
            nodes: NodesConfig::default(),
            schedule: ScheduleConfig::default(),
            geoip: GeoIpConfig::default(),
            passthrough: PassthroughConfig::default(),
            cache: CacheConfig::default(),
            access: AccessConfig::default(),
            control: ControlConfig::default(),
            log_level: "info".into(),
        }
    }
}

impl Config {
    pub fn load(path: Option<&Path>) -> Result<Self> {
        let mut cfg = if let Some(p) = path {
            let text =
                fs::read_to_string(p).with_context(|| format!("read config {}", p.display()))?;
            toml::from_str(&text).context("parse config toml")?
        } else if Path::new("config.toml").exists() {
            let text = fs::read_to_string("config.toml")?;
            toml::from_str(&text)?
        } else {
            Config::default()
        };
        cfg.apply_env();
        cfg.normalize()?;
        cfg.validate()?;
        Ok(cfg)
    }

    fn apply_env(&mut self) {
        if let Ok(v) = env::var("CENTER_ENABLE_DNS") {
            self.listen.enable_dns = parse_bool(&v);
        }
        if let Ok(v) = env::var("CENTER_ENABLE_DOT") {
            self.listen.enable_dot = parse_bool(&v);
        }
        if let Ok(v) = env::var("CENTER_ENABLE_DOH") {
            self.listen.enable_doh = parse_bool(&v);
        }
        if let Ok(v) = env::var("CENTER_DNS_PORT") {
            if let Ok(p) = v.parse() {
                self.listen.dns_port = p;
            }
        }
        if let Ok(v) = env::var("CENTER_DOT_PORT") {
            if let Ok(p) = v.parse() {
                self.listen.dot_port = p;
            }
        }
        if let Ok(v) = env::var("CENTER_DOH_PORT") {
            if let Ok(p) = v.parse() {
                self.listen.doh_port = p;
            }
        }
        if let Ok(v) = env::var("CENTER_DOH_BASE_PATH") {
            self.listen.doh_base_path = v;
        }
        if let Ok(v) = env::var("CENTER_ALLOWED_IPS") {
            self.access.allowed_cidrs = split_cidrs(&v);
        }
        if let Ok(v) = env::var("CENTER_UNLOCK_SCOPE") {
            self.policy.unlock_scope = v;
        }
        if let Ok(v) = env::var("CENTER_DEFAULT_GLOBAL_REGION") {
            self.policy.default_global_region = v;
        }
        if let Ok(v) = env::var("CENTER_DEFAULT_AI_REGION") {
            self.policy.default_ai_region = v;
        }
        if let Ok(v) = env::var("CENTER_DOMAIN_MAP_URL") {
            self.tables.domain_map_url = v;
        }
        if let Ok(v) = env::var("CENTER_DOMAIN_MAP_FILE") {
            self.tables.domain_map_file = PathBuf::from(v);
        }
        if let Ok(v) = env::var("CENTER_NODES_FILE") {
            self.nodes.file = PathBuf::from(v);
        }
        if let Ok(v) = env::var("CENTER_TLS_MODE") {
            self.tls.mode = v;
        }
        if let Ok(v) = env::var("CENTER_DOT_DOMAIN") {
            self.tls.domain = v;
        }
        if let Ok(v) = env::var("CENTER_TLS_CERT") {
            self.tls.cert_file = PathBuf::from(v);
        }
        if let Ok(v) = env::var("CENTER_TLS_KEY") {
            self.tls.key_file = PathBuf::from(v);
        }
        if let Ok(v) = env::var("CENTER_CONTROL_TOKEN") {
            self.control.bearer_token = v;
        }
        if let Ok(v) = env::var("CENTER_CONTROL_PATH") {
            self.control.path = v;
        }
        if let Ok(v) = env::var("CENTER_LOG_LEVEL") {
            self.log_level = v;
        }
        if let Ok(v) = env::var("GEOIP_DB_PATH") {
            self.geoip.db_path = PathBuf::from(v);
        }
        if let Ok(v) = env::var("GEOIP_ENABLE") {
            self.geoip.enabled = parse_bool(&v);
        }
        if let Ok(v) = env::var("GEOIP_DB_URL") {
            self.geoip.update_url = v;
        }
        if let Ok(v) = env::var("GEOIP_ENABLE_AUTO_UPDATE") {
            self.geoip.auto_update = parse_bool(&v);
        }
        if let Ok(v) = env::var("GEOIP_UPDATE_HOUR") {
            if let Ok(h) = v.parse() {
                self.geoip.update_hour = h;
            }
        }
        if let Ok(v) = env::var("GEOIP_UPDATE_MINUTE") {
            if let Ok(m) = v.parse() {
                self.geoip.update_minute = m;
            }
        }
    }

    fn normalize(&mut self) -> Result<()> {
        // base path
        let mut p = self.listen.doh_base_path.trim().to_string();
        if p.is_empty() {
            p = "/dns-query".into();
        }
        if !p.starts_with('/') {
            p = format!("/{p}");
        }
        while p.len() > 1 && p.ends_with('/') {
            p.pop();
        }
        self.listen.doh_base_path = p;

        let mut control_path = self.control.path.trim().to_string();
        if control_path.is_empty() {
            control_path = "/unlock-control/v1/connect".into();
        }
        if !control_path.starts_with('/') {
            control_path = format!("/{control_path}");
        }
        while control_path.len() > 1 && control_path.ends_with('/') {
            control_path.pop();
        }
        self.control.path = control_path;

        self.policy.default_global_region = self
            .policy
            .default_global_region
            .trim()
            .to_ascii_lowercase();
        self.policy.default_ai_region = self.policy.default_ai_region.trim().to_ascii_lowercase();
        self.schedule.default_passthrough_region = self
            .schedule
            .default_passthrough_region
            .trim()
            .to_ascii_lowercase();
        for r in &mut self.policy.allow_regions {
            *r = r.trim().to_ascii_lowercase();
        }
        Ok(())
    }

    pub fn validate(&self) -> Result<()> {
        if !self.listen.enable_dns && !self.listen.enable_dot && !self.listen.enable_doh {
            bail!("at least one of ENABLE_DNS / ENABLE_DOT / ENABLE_DOH must be on");
        }
        let _scope = self.scope()?;
        if self.policy.default_global_region.is_empty() {
            bail!("default_global_region required");
        }
        if !self
            .policy
            .allow_regions
            .iter()
            .any(|r| r == &self.policy.default_global_region)
        {
            bail!(
                "default_global_region {} not in allow_regions",
                self.policy.default_global_region
            );
        }
        if self.listen.enable_dot || self.listen.enable_doh {
            match self.tls.mode.as_str() {
                "selfsigned" | "files" | "letsencrypt" => {}
                other => bail!("unknown tls.mode: {other}"),
            }
        }
        if !self.control.bearer_token.is_empty() {
            if !self.listen.enable_doh {
                bail!("control.bearer_token requires listen.enable_doh=true (the control path reuses DoH TLS)");
            }
            if !self.control.path.starts_with('/') || self.control.path.len() < 2 {
                bail!("control.path must be an absolute non-root HTTP path");
            }
            if self.access.allowed_cidrs.is_empty() {
                bail!("control.bearer_token requires non-empty access.allowed_cidrs");
            }
        }
        for cidr in &self.access.allowed_cidrs {
            cidr.parse::<IpNet>()
                .map_err(|_| anyhow::anyhow!("invalid access.allowed_cidrs entry: {cidr}"))?;
        }
        Ok(())
    }

    pub fn scope(&self) -> Result<UnlockScope> {
        self.policy
            .unlock_scope
            .parse()
            .map_err(|e| anyhow::anyhow!("{e}"))
    }

    pub fn needs_tls(&self) -> bool {
        self.listen.enable_dot || self.listen.enable_doh
    }

    pub fn region_allowed(&self, region: &str) -> bool {
        let r = region.to_ascii_lowercase();
        self.policy.allow_regions.iter().any(|x| x == &r)
    }
}

fn split_cidrs(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

fn parse_bool(s: &str) -> bool {
    matches!(
        s.trim().to_ascii_lowercase().as_str(),
        "1" | "true" | "yes" | "on"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_requires_doh_and_nonempty_acl() {
        let mut cfg = Config::default();
        cfg.control.bearer_token = "secret".into();
        assert!(cfg.validate().is_err());
        cfg.access.allowed_cidrs = vec!["198.51.100.0/24".into()];
        assert!(cfg.validate().is_ok());
        cfg.listen.enable_doh = false;
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn parses_center_allowed_ips_env_value() {
        assert_eq!(
            split_cidrs(" 198.51.100.0/24, 2001:db8::/48 ,,"),
            vec!["198.51.100.0/24", "2001:db8::/48"]
        );
    }
}
