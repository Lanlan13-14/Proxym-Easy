//! Core scheduling decision: domain match → unlock IP or passthrough.

use std::net::IpAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use arc_swap::ArcSwap;
use dashmap::DashMap;
use domain_index::{Class, DomainIndex, UnlockScope};
use hickory_proto::op::{Message, MessageType, OpCode, ResponseCode};
use hickory_proto::rr::rdata::A;
use hickory_proto::rr::{Name, RData, Record, RecordType};
use ipnet::IpNet;
use schedule::{Node, NodeTable};
use tracing::{debug, warn};

use crate::config::Config;
use crate::geoip::GeoIp;
use crate::profile::Profile;

pub struct AppState {
    pub cfg: Config,
    pub index: ArcSwap<DomainIndex>,
    pub nodes: ArcSwap<NodeTable>,
    pub geoip: Arc<GeoIp>,
    pub passthrough_cache: DashMap<String, CacheEntry>,
    pub control: Option<Arc<crate::control::ControlHub>>,
    pub acl_cidrs: ArcSwap<Vec<IpNet>>,
    pub trusted_proxy_cidrs: Vec<IpNet>,
}

pub struct CacheEntry {
    pub message: Message,
    pub expire: Instant,
}

#[derive(Debug)]
pub enum ResolveResult {
    /// Wire-format ready response message (questions copied from request).
    Message(Message),
    /// Caller should SERVFAIL
    ServFail,
}

impl AppState {
    pub fn new(
        cfg: Config,
        index: DomainIndex,
        nodes: NodeTable,
        geoip: GeoIp,
        control: Option<Arc<crate::control::ControlHub>>,
    ) -> Arc<Self> {
        // Config::validate has already rejected malformed CIDRs.
        let acl_cidrs = cfg
            .access
            .allowed_cidrs
            .iter()
            .map(|value| value.parse::<IpNet>().expect("validated CIDR"))
            .collect();
        let trusted_proxy_cidrs = cfg
            .access
            .trusted_proxy_cidrs
            .iter()
            .map(|value| value.parse::<IpNet>().expect("validated CIDR"))
            .collect();
        Arc::new(Self {
            cfg,
            index: ArcSwap::from_pointee(index),
            nodes: ArcSwap::from_pointee(nodes),
            geoip: Arc::new(geoip),
            passthrough_cache: DashMap::new(),
            control,
            acl_cidrs: ArcSwap::from_pointee(acl_cidrs),
            trusted_proxy_cidrs,
        })
    }

    pub fn control_acl_snapshot(&self) -> Vec<String> {
        self.acl_cidrs
            .load()
            .iter()
            .map(ToString::to_string)
            .collect()
    }

    pub fn access_allowed(&self, client_ip: IpAddr) -> bool {
        let cidrs = self.acl_cidrs.load();
        cidrs.is_empty() || cidrs.iter().any(|cidr| cidr.contains(&client_ip))
    }

    pub fn trusted_proxy(&self, peer_ip: IpAddr) -> bool {
        self.trusted_proxy_cidrs
            .iter()
            .any(|cidr| cidr.contains(&peer_ip))
    }

    pub async fn reload_acl_from_file(&self) -> anyhow::Result<bool> {
        let Some(path) = std::env::var_os("CENTER_ALLOWED_IPS_FILE").map(std::path::PathBuf::from)
        else {
            return Ok(false);
        };
        let text = std::fs::read_to_string(&path)
            .map_err(|error| anyhow::anyhow!("read center ACL file {}: {error}", path.display()))?;
        let cidrs = text
            .split(',')
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| value.parse::<IpNet>().map_err(|_| value.to_string()))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|invalid| anyhow::anyhow!("invalid center ACL file CIDR: {invalid}"))?;
        if cidrs.is_empty() {
            anyhow::bail!("refusing empty center ACL file snapshot");
        }
        let old = self.control_acl_snapshot();
        let next: Vec<String> = cidrs.iter().map(ToString::to_string).collect();
        if old == next {
            return Ok(false);
        }
        self.acl_cidrs.store(Arc::new(cidrs));
        if let Some(hub) = &self.control {
            hub.broadcast_acl(next).await;
        }
        Ok(true)
    }

    pub fn scope(&self) -> UnlockScope {
        self.cfg.scope().unwrap_or(UnlockScope::All)
    }

    /// Build DNS response for a request message.
    pub async fn handle_query(
        &self,
        request: &Message,
        client_ip: Option<IpAddr>,
        profile: &Profile,
    ) -> ResolveResult {
        if let Some(client_ip) = client_ip {
            if !self.access_allowed(client_ip) {
                return ResolveResult::Message(refused(request));
            }
        }
        let Some(query) = request.queries().first() else {
            return ResolveResult::ServFail;
        };
        let qname = query.name().to_string();
        let qtype = query.query_type();

        // Only A fully scheduled; AAAA per policy; others refused/passthrough.
        match qtype {
            RecordType::A => self.handle_a(request, &qname, client_ip, profile).await,
            RecordType::AAAA => self.handle_aaaa(request, &qname, client_ip, profile).await,
            _ => {
                if self.cfg.policy.other_qtype_mode == "passthrough" {
                    self.passthrough(request, &qname, qtype, client_ip).await
                } else {
                    ResolveResult::Message(refused(request))
                }
            }
        }
    }

    async fn handle_a(
        &self,
        request: &Message,
        qname: &str,
        client_ip: Option<IpAddr>,
        profile: &Profile,
    ) -> ResolveResult {
        let index = self.index.load();
        let (class, region_hint) =
            index.classify(qname, self.scope(), self.cfg.policy.enable_ai_unlock);

        match class {
            Class::Regional => {
                let region = region_hint.unwrap_or("us");
                self.answer_unlock(request, qname, region)
            }
            Class::Global => self.answer_unlock(request, qname, &profile.global_region),
            Class::Ai => {
                let region = profile.effective_ai_region();
                self.answer_unlock(request, qname, region)
            }
            Class::Other => {
                self.passthrough(request, qname, RecordType::A, client_ip)
                    .await
            }
        }
    }

    async fn handle_aaaa(
        &self,
        request: &Message,
        qname: &str,
        client_ip: Option<IpAddr>,
        profile: &Profile,
    ) -> ResolveResult {
        let _ = profile;
        let index = self.index.load();
        let (class, _) = index.classify(qname, self.scope(), self.cfg.policy.enable_ai_unlock);
        match self.cfg.policy.aaaa_mode.as_str() {
            "passthrough" => {
                self.passthrough(request, qname, RecordType::AAAA, client_ip)
                    .await
            }
            "soa" | "empty" | _ => {
                if class == Class::Other {
                    self.passthrough(request, qname, RecordType::AAAA, client_ip)
                        .await
                } else {
                    // NOERROR empty for unlock hits (prevent IPv6 bypass)
                    ResolveResult::Message(empty_noerror(request))
                }
            }
        }
    }

    fn answer_unlock(&self, request: &Message, qname: &str, region: &str) -> ResolveResult {
        let nodes = self.nodes.load();
        let node = match nodes.pick_region(region, self.cfg.schedule.allow_region_fallback) {
            Ok(n) => n,
            Err(e) => {
                warn!(%region, error=%e, "no unlock node");
                return ResolveResult::ServFail;
            }
        };
        debug!(%qname, %region, node=%node.id, ip=%node.unlock_ip, "unlock answer");
        match build_a_answer(
            request,
            qname,
            node.unlock_ip,
            self.cfg.policy.unlock_answer_ttl_secs,
        ) {
            Ok(m) => ResolveResult::Message(m),
            Err(_) => ResolveResult::ServFail,
        }
    }

    async fn passthrough(
        &self,
        request: &Message,
        qname: &str,
        qtype: RecordType,
        client_ip: Option<IpAddr>,
    ) -> ResolveResult {
        let nodes = self.nodes.load();
        let (lat, lon) = if self.cfg.geoip.enabled {
            client_ip
                .and_then(|ip| self.geoip.lookup(ip))
                .map(|ll| (Some(ll.lat), Some(ll.lon)))
                .unwrap_or((None, None))
        } else {
            (None, None)
        };
        let node = if self.cfg.schedule.nearest_for_passthrough {
            // Prefer lat/lon nearest when GeoIP hits; else default region pool.
            if lat.is_some() && lon.is_some() {
                nodes.nearest(lat, lon)
            } else {
                nodes.nearest_or_region(
                    Some(self.cfg.schedule.default_passthrough_region.as_str()),
                    None,
                    None,
                )
            }
            .or_else(|_| nodes.nearest(None, None))
        } else {
            nodes.pick_region(&self.cfg.schedule.default_passthrough_region, true)
        };

        let cache_key = format!(
            "{}|{:?}|{}",
            qname,
            qtype,
            node.as_ref().map(|n| n.id.as_str()).unwrap_or("-")
        );
        if let Some(ent) = self.passthrough_cache.get(&cache_key) {
            if ent.expire > Instant::now() {
                let mut m = ent.message.clone();
                m.set_id(request.id());
                return ResolveResult::Message(m);
            }
        }

        let upstreams: Vec<String> = {
            let mut u = Vec::new();
            if let Ok(ref n) = node {
                u.push(n.dns_upstream.clone());
            }
            u.extend(self.cfg.passthrough.fallback_upstreams.iter().cloned());
            u
        };

        let timeout = Duration::from_millis(self.cfg.passthrough.timeout_ms);
        // If the selected data-plane node has joined the authenticated control
        // channel, it is the authoritative passthrough transport. Fall back to
        // the legacy public UDP upstream chain only when the channel is absent
        // or unavailable, preserving old deployments exactly when unconfigured.
        if let (Some(hub), Ok(ref selected)) = (&self.control, &node) {
            match hub.query(&selected.id, request, timeout).await {
                Ok(mut msg) => {
                    msg.set_id(request.id());
                    return self.cache_passthrough(cache_key, msg, qname, "control");
                }
                Err(e) => {
                    warn!(%qname, node=%selected.id, error=%e, "control passthrough failed; trying legacy upstreams")
                }
            }
        }

        for up in upstreams {
            match query_upstream(&up, qname, qtype, timeout).await {
                Ok(mut msg) => {
                    msg.set_id(request.id());
                    return self.cache_passthrough(cache_key, msg, qname, &up);
                }
                Err(e) => {
                    warn!(%qname, %up, error=%e, "passthrough failed");
                }
            }
        }
        ResolveResult::ServFail
    }

    fn cache_passthrough(
        &self,
        cache_key: String,
        mut msg: Message,
        qname: &str,
        upstream: &str,
    ) -> ResolveResult {
        let max_ttl = self.cfg.cache.passthrough_max_ttl_secs;
        for rec in msg.answers_mut() {
            if rec.ttl() > max_ttl {
                rec.set_ttl(max_ttl);
            }
        }
        if self.passthrough_cache.len() < self.cfg.cache.passthrough_max_entries {
            self.passthrough_cache.insert(
                cache_key,
                CacheEntry {
                    message: msg.clone(),
                    expire: Instant::now() + Duration::from_secs(max_ttl as u64),
                },
            );
        }
        debug!(%qname, %upstream, "passthrough ok");
        ResolveResult::Message(msg)
    }
}

fn build_a_answer(request: &Message, qname: &str, ip: IpAddr, ttl: u32) -> Result<Message, ()> {
    let name = Name::from_utf8(qname).map_err(|_| ())?;
    let mut msg = Message::new();
    msg.set_id(request.id());
    msg.set_message_type(MessageType::Response);
    msg.set_op_code(OpCode::Query);
    msg.set_response_code(ResponseCode::NoError);
    msg.set_authoritative(true);
    msg.set_recursion_available(true);
    if let Some(q) = request.queries().first() {
        msg.add_query(q.clone());
    }
    match ip {
        IpAddr::V4(v4) => {
            let rec = Record::from_rdata(name, ttl, RData::A(A(v4)));
            msg.add_answer(rec);
        }
        IpAddr::V6(_) => {
            // Unlock answers are IPv4 in current design
            return Err(());
        }
    }
    Ok(msg)
}

fn empty_noerror(request: &Message) -> Message {
    let mut msg = Message::new();
    msg.set_id(request.id());
    msg.set_message_type(MessageType::Response);
    msg.set_op_code(OpCode::Query);
    msg.set_response_code(ResponseCode::NoError);
    msg.set_authoritative(true);
    msg.set_recursion_available(true);
    if let Some(q) = request.queries().first() {
        msg.add_query(q.clone());
    }
    msg
}

fn refused(request: &Message) -> Message {
    let mut msg = Message::new();
    msg.set_id(request.id());
    msg.set_message_type(MessageType::Response);
    msg.set_op_code(OpCode::Query);
    msg.set_response_code(ResponseCode::Refused);
    msg.set_recursion_available(true);
    if let Some(q) = request.queries().first() {
        msg.add_query(q.clone());
    }
    msg
}

async fn query_upstream(
    upstream: &str,
    qname: &str,
    qtype: RecordType,
    timeout: Duration,
) -> anyhow::Result<Message> {
    // MVP: UDP host:port only (unlock node DNS or 1.1.1.1:53).
    if upstream.starts_with("https://") {
        anyhow::bail!("https upstream not supported in MVP; use host:port");
    }
    let socket: std::net::SocketAddr = upstream.parse()?;
    let name = Name::from_utf8(qname)?;
    raw_udp_query(socket, &name, qtype, timeout).await
}

async fn raw_udp_query(
    server: std::net::SocketAddr,
    name: &Name,
    qtype: RecordType,
    timeout: Duration,
) -> anyhow::Result<Message> {
    use hickory_proto::op::Query;
    use hickory_proto::serialize::binary::{BinDecodable, BinEncodable};
    use tokio::net::UdpSocket;

    let mut req = Message::new();
    req.set_id(rand_u16());
    req.set_message_type(MessageType::Query);
    req.set_op_code(OpCode::Query);
    req.set_recursion_desired(true);
    let mut q = Query::new();
    q.set_name(name.clone());
    q.set_query_type(qtype);
    req.add_query(q);

    let bytes = req.to_bytes()?;
    let sock = UdpSocket::bind("0.0.0.0:0").await?;
    sock.send_to(&bytes, server).await?;

    let mut buf = vec![0u8; 4096];
    let n = tokio::time::timeout(timeout, sock.recv_from(&mut buf))
        .await??
        .0;
    let msg = Message::from_bytes(&buf[..n])?;
    Ok(msg)
}

fn rand_u16() -> u16 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let t = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(1);
    (t as u16) | 1
}

// silence unused import in some builds
#[allow(dead_code)]
fn _use_node(_: &Node) {}

#[cfg(test)]
mod tests {
    use super::*;

    fn state_with_acl(cidrs: Vec<&str>) -> Arc<AppState> {
        let mut cfg = Config::default();
        cfg.access.allowed_cidrs = cidrs.into_iter().map(ToOwned::to_owned).collect();
        let index = DomainIndex::load_str("", 0).unwrap();
        let nodes = NodeTable::from_configs(vec![]).unwrap();
        AppState::new(cfg, index, nodes, GeoIp::open("/dev/null"), None)
    }

    #[test]
    fn center_access_acl_applies_to_dns_requests() {
        let state = state_with_acl(vec!["198.51.100.0/24", "2001:db8::/48"]);
        assert!(state.access_allowed("198.51.100.8".parse().unwrap()));
        assert!(state.access_allowed("2001:db8::1".parse().unwrap()));
        assert!(!state.access_allowed("203.0.113.8".parse().unwrap()));
    }

    #[test]
    fn empty_center_acl_preserves_legacy_open_behavior() {
        let state = state_with_acl(vec![]);
        assert!(state.access_allowed("203.0.113.8".parse().unwrap()));
    }
}
