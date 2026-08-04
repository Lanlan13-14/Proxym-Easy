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
    pub fn new(cfg: Config, index: DomainIndex, nodes: NodeTable, geoip: GeoIp) -> Arc<Self> {
        Arc::new(Self {
            cfg,
            index: ArcSwap::from_pointee(index),
            nodes: ArcSwap::from_pointee(nodes),
            geoip: Arc::new(geoip),
            passthrough_cache: DashMap::new(),
        })
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
        let (class, _) =
            index.classify(qname, self.scope(), self.cfg.policy.enable_ai_unlock);
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
            nodes.pick_region(
                &self.cfg.schedule.default_passthrough_region,
                true,
            )
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
        for up in upstreams {
            match query_upstream(&up, qname, qtype, timeout).await {
                Ok(mut msg) => {
                    msg.set_id(request.id());
                    // Clamp TTL
                    let max_ttl = self.cfg.cache.passthrough_max_ttl_secs;
                    for rec in msg.answers_mut() {
                        if rec.ttl() > max_ttl {
                            rec.set_ttl(max_ttl);
                        }
                    }
                    if self.passthrough_cache.len() < self.cfg.cache.passthrough_max_entries {
                        self.passthrough_cache.insert(
                            cache_key.clone(),
                            CacheEntry {
                                message: msg.clone(),
                                expire: Instant::now()
                                    + Duration::from_secs(max_ttl as u64),
                            },
                        );
                    }
                    debug!(%qname, %up, "passthrough ok");
                    return ResolveResult::Message(msg);
                }
                Err(e) => {
                    warn!(%qname, %up, error=%e, "passthrough failed");
                }
            }
        }
        ResolveResult::ServFail
    }
}

fn build_a_answer(
    request: &Message,
    qname: &str,
    ip: IpAddr,
    ttl: u32,
) -> Result<Message, ()> {
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
    let n = tokio::time::timeout(timeout, sock.recv_from(&mut buf)).await??.0;
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
