//! DoH path → Profile (global region + optional AI region).

use crate::config::Config;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Profile {
    pub global_region: String,
    /// None = follow global
    pub ai_region: Option<String>,
}

impl Profile {
    pub fn default_from_config(cfg: &Config) -> Self {
        let ai = if cfg.policy.default_ai_region.is_empty() {
            None
        } else {
            Some(cfg.policy.default_ai_region.clone())
        };
        Self {
            global_region: cfg.policy.default_global_region.clone(),
            ai_region: ai,
        }
    }

    pub fn effective_ai_region(&self) -> &str {
        self.ai_region
            .as_deref()
            .unwrap_or(self.global_region.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PathMatch {
    Profile(Profile),
    NotFound,
}

/// Parse HTTP path against configured DoH base.
pub fn parse_doh_path(path: &str, cfg: &Config) -> PathMatch {
    let path = normalize_path(path);
    let base = cfg.listen.doh_base_path.as_str();

    let mut candidates = vec![base.to_string()];
    for extra in &cfg.listen.doh_extra_paths {
        candidates.push(normalize_path(extra));
    }

    for b in candidates {
        if let Some(prof) = match_one(&path, &b, cfg) {
            return PathMatch::Profile(prof);
        }
    }
    PathMatch::NotFound
}

fn match_one(path: &str, base: &str, cfg: &Config) -> Option<Profile> {
    if path == base {
        return Some(Profile::default_from_config(cfg));
    }
    let prefix = format!("{base}/");
    if !path.starts_with(&prefix) {
        return None;
    }
    let rest = &path[prefix.len()..];
    if rest.is_empty() {
        return Some(Profile::default_from_config(cfg));
    }
    let parts: Vec<&str> = rest.split('/').filter(|p| !p.is_empty()).collect();
    match parts.as_slice() {
        // /{g}
        [g] => {
            if !cfg.region_allowed(g) {
                return None;
            }
            Some(Profile {
                global_region: g.to_ascii_lowercase(),
                ai_region: None,
            })
        }
        // /ai/{a}
        ["ai", a] => {
            if !cfg.region_allowed(a) {
                return None;
            }
            Some(Profile {
                global_region: cfg.policy.default_global_region.clone(),
                ai_region: Some(a.to_ascii_lowercase()),
            })
        }
        // /{g}/ai/{a}
        [g, "ai", a] => {
            if !cfg.region_allowed(g) || !cfg.region_allowed(a) {
                return None;
            }
            Some(Profile {
                global_region: g.to_ascii_lowercase(),
                ai_region: Some(a.to_ascii_lowercase()),
            })
        }
        _ => None,
    }
}

fn normalize_path(p: &str) -> String {
    let mut s = p.trim().to_string();
    if s.is_empty() {
        return "/".into();
    }
    if !s.starts_with('/') {
        s = format!("/{s}");
    }
    // strip query
    if let Some(i) = s.find('?') {
        s.truncate(i);
    }
    while s.len() > 1 && s.ends_with('/') {
        s.pop();
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> Config {
        let mut c = Config::default();
        c.listen.doh_base_path = "/api/v2/weather".into();
        c.policy.default_global_region = "us".into();
        c.policy.allow_regions = vec![
            "us".into(),
            "jp".into(),
            "uk".into(),
            "hk".into(),
        ];
        c
    }

    #[test]
    fn path_profiles() {
        let c = cfg();
        match parse_doh_path("/api/v2/weather", &c) {
            PathMatch::Profile(p) => {
                assert_eq!(p.global_region, "us");
                assert!(p.ai_region.is_none());
            }
            _ => panic!(),
        }
        match parse_doh_path("/api/v2/weather/uk", &c) {
            PathMatch::Profile(p) => assert_eq!(p.global_region, "uk"),
            _ => panic!(),
        }
        match parse_doh_path("/api/v2/weather/us/ai/jp", &c) {
            PathMatch::Profile(p) => {
                assert_eq!(p.global_region, "us");
                assert_eq!(p.ai_region.as_deref(), Some("jp"));
                assert_eq!(p.effective_ai_region(), "jp");
            }
            _ => panic!(),
        }
        match parse_doh_path("/api/v2/weather/ai/jp", &c) {
            PathMatch::Profile(p) => {
                assert_eq!(p.global_region, "us");
                assert_eq!(p.effective_ai_region(), "jp");
            }
            _ => panic!(),
        }
        assert!(matches!(
            parse_doh_path("/wrong", &c),
            PathMatch::NotFound
        ));
        assert!(matches!(
            parse_doh_path("/api/v2/weather/zz", &c),
            PathMatch::NotFound
        ));
    }
}
