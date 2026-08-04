//! Longest-suffix domain policy index for unlock-center.
//!
//! Map line format (TAB-separated):
//!   domain\tclass\tregion
//! class: global | regional | ai
//! region: region id, or "-" when none (global/ai)

use std::collections::HashMap;
use std::fmt;
use std::fs;
use std::path::Path;
use std::str::FromStr;

use thiserror::Error;

/// Domain classification for scheduling.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Class {
    Global,
    Regional,
    Ai,
    Other,
}

impl Class {
    pub fn as_str(self) -> &'static str {
        match self {
            Class::Global => "global",
            Class::Regional => "regional",
            Class::Ai => "ai",
            Class::Other => "other",
        }
    }
}

impl FromStr for Class {
    type Err = ParseError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "global" => Ok(Class::Global),
            "regional" => Ok(Class::Regional),
            "ai" => Ok(Class::Ai),
            other => Err(ParseError::InvalidClass(other.to_string())),
        }
    }
}

impl fmt::Display for Class {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Policy attached to a domain suffix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DomainPolicy {
    pub class: Class,
    /// Required for Regional; None for Global/Ai.
    pub region: Option<String>,
}

#[derive(Debug, Error)]
pub enum ParseError {
    #[error("invalid class: {0}")]
    InvalidClass(String),
    #[error("invalid map line {line_no}: {msg}")]
    InvalidLine { line_no: usize, msg: String },
    #[error("regional domain missing region on line {0}")]
    RegionalMissingRegion(usize),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("map too small: {got} < min {min}")]
    TooSmall { got: usize, min: usize },
}

/// Unlock scope filter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnlockScope {
    Global,
    Regional,
    All,
}

impl FromStr for UnlockScope {
    type Err = ParseError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "global" => Ok(UnlockScope::Global),
            "regional" => Ok(UnlockScope::Regional),
            "all" => Ok(UnlockScope::All),
            other => Err(ParseError::InvalidClass(format!("scope:{other}"))),
        }
    }
}

impl UnlockScope {
    /// Whether this class is hijacked under the scope (AI controlled separately).
    pub fn allows(self, class: Class, enable_ai: bool) -> bool {
        match (self, class) {
            (_, Class::Other) => false,
            (UnlockScope::All, Class::Global | Class::Regional) => true,
            (UnlockScope::All, Class::Ai) => enable_ai,
            (UnlockScope::Global, Class::Global) => true,
            (UnlockScope::Global, Class::Ai) => enable_ai,
            (UnlockScope::Global, Class::Regional) => false,
            (UnlockScope::Regional, Class::Regional) => true,
            (UnlockScope::Regional, Class::Global | Class::Ai) => false,
        }
    }
}

/// Normalize a domain: lowercase, strip trailing dots and leading wildcard markers.
pub fn normalize_domain(raw: &str) -> Option<String> {
    let mut s = raw.trim().to_ascii_lowercase();
    if s.is_empty() || s.starts_with('#') {
        return None;
    }
    while s.ends_with('.') {
        s.pop();
    }
    while s.starts_with("*.") {
        s = s[2..].to_string();
    }
    while s.starts_with("+.") {
        s = s[2..].to_string();
    }
    while s.starts_with('.') {
        s = s[1..].to_string();
    }
    if s.is_empty() || !s.contains('.') {
        return None;
    }
    if s.contains('/') || s.contains(' ') || s.contains('*') {
        return None;
    }
    if !s
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-' || b == b'_')
    {
        return None;
    }
    // reject IPv4 literals
    if s.split('.').all(|p| p.parse::<u8>().is_ok()) && s.split('.').count() == 4 {
        return None;
    }
    Some(s)
}

/// Google/YouTube family — never unlock.
pub fn is_blocked_domain(domain: &str) -> bool {
    const NEEDLES: &[&str] = &[
        "google",
        "googleapis",
        "gstatic",
        "googleusercontent",
        "googlevideo",
        "ggpht",
        "youtube",
        "ytimg",
        "youtu.be",
        "withgoogle",
        "blogspot",
        "blogger",
        "appspot",
        "doubleclick",
        "app-measurement.com",
        "pik.goog",
    ];
    let d = domain.to_ascii_lowercase();
    for n in NEEDLES {
        if d == *n || d.ends_with(&format!(".{n}")) || d.contains(&format!(".{n}.")) {
            return true;
        }
        // also bare contains for google-ish labels
        if *n == "google" && (d.contains("google") || d.ends_with(".goog")) {
            return true;
        }
    }
    if d.ends_with(".goog") || d == "android.com" || d.ends_with(".android.com") {
        return true;
    }
    false
}

/// In-memory longest-suffix index.
#[derive(Debug, Default, Clone)]
pub struct DomainIndex {
    /// Exact suffix → policy. Query tries full name then parent suffixes.
    map: HashMap<String, DomainPolicy>,
}

impl DomainIndex {
    pub fn new() -> Self {
        Self {
            map: HashMap::new(),
        }
    }

    pub fn len(&self) -> usize {
        self.map.len()
    }

    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }

    pub fn insert(&mut self, domain: String, policy: DomainPolicy) {
        // Longer / more specific already preferred at query time by trying full name first.
        // On conflict: regional wins over global/ai; otherwise last write wins for same class.
        match self.map.get(&domain) {
            Some(old) if old.class == Class::Regional && policy.class != Class::Regional => {
                return;
            }
            Some(old)
                if old.class != Class::Regional
                    && policy.class == Class::Regional =>
            {
                // upgrade to regional
            }
            _ => {}
        }
        self.map.insert(domain, policy);
    }

    /// Longest suffix match. Returns Other-equivalent as None.
    pub fn lookup(&self, qname: &str) -> Option<&DomainPolicy> {
        let Some(mut name) = normalize_domain(qname) else {
            return None;
        };
        loop {
            if let Some(p) = self.map.get(&name) {
                return Some(p);
            }
            match name.find('.') {
                Some(i) => name = name[i + 1..].to_string(),
                None => break,
            }
        }
        None
    }

    /// Effective class after scope filter.
    pub fn classify(&self, qname: &str, scope: UnlockScope, enable_ai: bool) -> (Class, Option<&str>) {
        match self.lookup(qname) {
            Some(p) if scope.allows(p.class, enable_ai) => {
                (p.class, p.region.as_deref())
            }
            Some(_) | None => (Class::Other, None),
        }
    }

    pub fn load_str(text: &str, min_entries: usize) -> Result<Self, ParseError> {
        let mut idx = DomainIndex::new();
        for (i, line) in text.lines().enumerate() {
            let line_no = i + 1;
            let raw = line.trim();
            if raw.is_empty() || raw.starts_with('#') {
                continue;
            }
            let parts: Vec<&str> = raw.split('\t').map(|s| s.trim()).collect();
            if parts.len() < 2 {
                return Err(ParseError::InvalidLine {
                    line_no,
                    msg: "expected domain\\tclass[\\tregion]".into(),
                });
            }
            let domain = normalize_domain(parts[0]).ok_or_else(|| ParseError::InvalidLine {
                line_no,
                msg: format!("bad domain {}", parts[0]),
            })?;
            if is_blocked_domain(&domain) {
                continue;
            }
            let class = Class::from_str(parts[1])?;
            let region = if parts.len() >= 3 {
                let r = parts[2].trim();
                if r.is_empty() || r == "-" {
                    None
                } else {
                    Some(r.to_ascii_lowercase())
                }
            } else {
                None
            };
            if class == Class::Regional && region.is_none() {
                return Err(ParseError::RegionalMissingRegion(line_no));
            }
            idx.insert(
                domain,
                DomainPolicy {
                    class,
                    region,
                },
            );
        }
        if idx.len() < min_entries {
            return Err(ParseError::TooSmall {
                got: idx.len(),
                min: min_entries,
            });
        }
        Ok(idx)
    }

    pub fn load_file(path: impl AsRef<Path>, min_entries: usize) -> Result<Self, ParseError> {
        let text = fs::read_to_string(path)?;
        Self::load_str(&text, min_entries)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn longest_suffix() {
        let mut idx = DomainIndex::new();
        idx.insert(
            "dmm.co.jp".into(),
            DomainPolicy {
                class: Class::Regional,
                region: Some("jp".into()),
            },
        );
        idx.insert(
            "netflix.com".into(),
            DomainPolicy {
                class: Class::Global,
                region: None,
            },
        );
        idx.insert(
            "openai.com".into(),
            DomainPolicy {
                class: Class::Ai,
                region: None,
            },
        );

        let p = idx.lookup("api.dmm.co.jp").unwrap();
        assert_eq!(p.class, Class::Regional);
        assert_eq!(p.region.as_deref(), Some("jp"));

        assert_eq!(idx.lookup("netflix.com").unwrap().class, Class::Global);
        assert!(idx.lookup("example.com").is_none());
    }

    #[test]
    fn scope_filters_regional() {
        let text = "\
netflix.com\tglobal\t-
dmm.co.jp\tregional\tjp
openai.com\tai\t-
";
        let idx = DomainIndex::load_str(text, 1).unwrap();
        let (c, _) = idx.classify("dmm.co.jp", UnlockScope::Global, true);
        assert_eq!(c, Class::Other);
        let (c, r) = idx.classify("dmm.co.jp", UnlockScope::All, true);
        assert_eq!(c, Class::Regional);
        assert_eq!(r, Some("jp"));
        let (c, _) = idx.classify("openai.com", UnlockScope::Global, true);
        assert_eq!(c, Class::Ai);
        let (c, _) = idx.classify("openai.com", UnlockScope::Global, false);
        assert_eq!(c, Class::Other);
    }

    #[test]
    fn regional_overrides_global_on_insert() {
        let mut idx = DomainIndex::new();
        idx.insert(
            "foo.com".into(),
            DomainPolicy {
                class: Class::Global,
                region: None,
            },
        );
        idx.insert(
            "foo.com".into(),
            DomainPolicy {
                class: Class::Regional,
                region: Some("uk".into()),
            },
        );
        assert_eq!(idx.lookup("foo.com").unwrap().class, Class::Regional);
    }

    #[test]
    fn blocked_google() {
        assert!(is_blocked_domain("google.com"));
        assert!(is_blocked_domain("foo.googleapis.com"));
        assert!(!is_blocked_domain("netflix.com"));
    }

    #[test]
    fn parse_map_file_format() {
        let text = "\
# comment
bbc.co.uk\tregional\tuk
netflix.com\tglobal\t-
";
        let idx = DomainIndex::load_str(text, 2).unwrap();
        assert_eq!(idx.len(), 2);
        assert_eq!(
            idx.lookup("www.bbc.co.uk").unwrap().region.as_deref(),
            Some("uk")
        );
    }
}
