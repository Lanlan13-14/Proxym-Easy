use std::net::{IpAddr, SocketAddr};
use std::str::FromStr;
use std::sync::Arc;

use anyhow::Result;
use bytes::Bytes;
use hickory_proto::op::Message;
use hickory_proto::serialize::binary::{BinDecodable, BinEncodable};
use http_body_util::{BodyExt, Full};
use hyper::body::Incoming;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use rustls::ServerConfig;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio_rustls::TlsAcceptor;
use tracing::{info, warn};

use crate::profile::{parse_doh_path, PathMatch, Profile};
use crate::resolve::{AppState, ResolveResult};

/// DNS-over-TLS: length-prefixed DNS messages over TLS TCP.
pub async fn serve_dot(
    state: Arc<AppState>,
    addr: SocketAddr,
    tls: Arc<ServerConfig>,
) -> Result<()> {
    let acceptor = TlsAcceptor::from(tls);
    let listener = TcpListener::bind(addr).await?;
    info!(%addr, "DoT listening");
    loop {
        let (stream, peer) = listener.accept().await?;
        let acceptor = acceptor.clone();
        let state = Arc::clone(&state);
        tokio::spawn(async move {
            let mut tls_stream = match acceptor.accept(stream).await {
                Ok(s) => s,
                Err(e) => {
                    warn!(%peer, error=%e, "dot tls accept");
                    return;
                }
            };
            if let Err(e) = handle_dot_conn(&state, &mut tls_stream, peer).await {
                warn!(%peer, error=%e, "dot conn");
            }
        });
    }
}

async fn handle_dot_conn<S>(state: &AppState, stream: &mut S, peer: SocketAddr) -> Result<()>
where
    S: AsyncReadExt + AsyncWriteExt + Unpin,
{
    loop {
        let mut len_buf = [0u8; 2];
        if stream.read_exact(&mut len_buf).await.is_err() {
            break;
        }
        let len = u16::from_be_bytes(len_buf) as usize;
        if len == 0 || len > 4096 {
            break;
        }
        let mut data = vec![0u8; len];
        stream.read_exact(&mut data).await?;
        let request = Message::from_bytes(&data)?;
        let profile = Profile::default_from_config(&state.cfg);
        let resp = match state
            .handle_query(&request, Some(peer.ip()), &profile)
            .await
        {
            ResolveResult::Message(m) => m,
            ResolveResult::ServFail => servfail(&request),
        };
        let out = resp.to_bytes()?;
        let l = (out.len() as u16).to_be_bytes();
        stream.write_all(&l).await?;
        stream.write_all(&out).await?;
    }
    Ok(())
}

/// DNS-over-HTTPS and, when configured, the authenticated WebSocket control
/// endpoint share the same existing TLS listener and port.
pub async fn serve_doh(
    state: Arc<AppState>,
    addr: SocketAddr,
    tls: Arc<ServerConfig>,
) -> Result<()> {
    let acceptor = TlsAcceptor::from(tls);
    let listener = TcpListener::bind(addr).await?;
    info!(
        %addr,
        path=%state.cfg.listen.doh_base_path,
        control_path=?state.control.as_ref().map(|hub| hub.path()),
        "DoH listening"
    );
    loop {
        let (stream, peer) = listener.accept().await?;
        let acceptor = acceptor.clone();
        let state = Arc::clone(&state);
        tokio::spawn(async move {
            let tls_stream = match acceptor.accept(stream).await {
                Ok(s) => s,
                Err(e) => {
                    warn!(%peer, error=%e, "doh tls accept");
                    return;
                }
            };
            let io = TokioIo::new(tls_stream);
            let svc = service_fn(move |req| {
                let state = Arc::clone(&state);
                async move { handle_doh_http(state, req, peer).await }
            });
            if let Err(e) = http1::Builder::new()
                .serve_connection(io, svc)
                .with_upgrades()
                .await
            {
                warn!(%peer, error=%e, "doh http conn");
            }
        });
    }
}

async fn handle_doh_http(
    state: Arc<AppState>,
    mut req: Request<Incoming>,
    peer: SocketAddr,
) -> Result<Response<Full<Bytes>>, std::convert::Infallible> {
    if is_control_upgrade(&req, &state) {
        let authorization = req
            .headers()
            .get(hyper::header::AUTHORIZATION)
            .and_then(|value| value.to_str().ok());
        let hub = state.control.as_ref().expect("checked control hub");
        if !hub.authorize(authorization) {
            return Ok(status_body(StatusCode::UNAUTHORIZED, b"unauthorized"));
        }
        let key = match req
            .headers()
            .get("sec-websocket-key")
            .and_then(|value| value.to_str().ok())
        {
            Some(value) => value,
            None => {
                return Ok(status_body(
                    StatusCode::BAD_REQUEST,
                    b"missing websocket key",
                ))
            }
        };
        let accept = websocket_accept(key);
        let upgrade = hyper::upgrade::on(&mut req);
        let hub = Arc::clone(hub);
        let acl = state.control_acl_snapshot();
        tokio::spawn(async move {
            match upgrade.await {
                Ok(upgraded) => {
                    if let Err(error) = hub.serve(TokioIo::new(upgraded), acl).await {
                        warn!(%peer, error=%error, "unlock control session");
                    }
                }
                Err(error) => warn!(%peer, error=%error, "unlock control upgrade"),
            }
        });
        return Ok(Response::builder()
            .status(StatusCode::SWITCHING_PROTOCOLS)
            .header(hyper::header::CONNECTION, "Upgrade")
            .header(hyper::header::UPGRADE, "websocket")
            .header("sec-websocket-accept", accept)
            .header("sec-websocket-protocol", crate::control::protocol())
            .body(Full::new(Bytes::new()))
            .unwrap());
    }

    // Optional bearer remains for normal DoH clients.
    if !state.cfg.access.bearer_token.is_empty() {
        let ok = req
            .headers()
            .get(hyper::header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .map(|v| {
                v == format!("Bearer {}", state.cfg.access.bearer_token)
                    || v == state.cfg.access.bearer_token
            })
            .unwrap_or(false);
        if !ok {
            return Ok(Response::builder()
                .status(StatusCode::UNAUTHORIZED)
                .body(Full::new(Bytes::from_static(b"unauthorized")))
                .unwrap());
        }
    }

    // Only a peer explicitly configured as a trusted reverse proxy may supply
    // CF-Connecting-IP. This is required for cloudflared localhost tunnels:
    // their TCP peer is 127.0.0.1, while Cloudflare supplies the real client IP.
    // Direct clients cannot spoof this header because their peer is not trusted.
    let client_ip = effective_client_ip(&req, peer.ip(), &state);

    let path = req.uri().path();
    let profile = match parse_doh_path(path, &state.cfg) {
        PathMatch::Profile(p) => p,
        PathMatch::NotFound => {
            return Ok(Response::builder()
                .status(StatusCode::NOT_FOUND)
                .body(Full::new(Bytes::from_static(b"not found")))
                .unwrap());
        }
    };

    let wire = match *req.method() {
        Method::POST => {
            let ct = req
                .headers()
                .get(hyper::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("");
            if !ct.starts_with("application/dns-message") && !ct.is_empty() {
                // allow empty content-type for lenient clients
            }
            let body = match req.collect().await {
                Ok(b) => b.to_bytes(),
                Err(_) => {
                    return Ok(status_body(StatusCode::BAD_REQUEST, b"body"));
                }
            };
            body.to_vec()
        }
        Method::GET => {
            let q = req.uri().query().unwrap_or("");
            let dns_param = q.split('&').find_map(|kv| {
                let mut it = kv.splitn(2, '=');
                let k = it.next()?;
                let v = it.next()?;
                if k == "dns" {
                    Some(v)
                } else {
                    None
                }
            });
            let Some(b64) = dns_param else {
                return Ok(status_body(StatusCode::BAD_REQUEST, b"missing dns"));
            };
            match base64url_decode(b64) {
                Ok(v) => v,
                Err(_) => return Ok(status_body(StatusCode::BAD_REQUEST, b"bad dns b64")),
            }
        }
        _ => {
            return Ok(status_body(StatusCode::METHOD_NOT_ALLOWED, b"method"));
        }
    };

    let request = match Message::from_bytes(&wire) {
        Ok(m) => m,
        Err(_) => return Ok(status_body(StatusCode::BAD_REQUEST, b"bad dns message")),
    };

    let resp = match state
        .handle_query(&request, Some(client_ip), &profile)
        .await
    {
        ResolveResult::Message(m) => m,
        ResolveResult::ServFail => servfail(&request),
    };
    let out = match resp.to_bytes() {
        Ok(b) => b,
        Err(_) => return Ok(status_body(StatusCode::INTERNAL_SERVER_ERROR, b"encode")),
    };

    Ok(Response::builder()
        .status(StatusCode::OK)
        .header(hyper::header::CONTENT_TYPE, "application/dns-message")
        .header(hyper::header::CACHE_CONTROL, "max-age=45")
        .body(Full::new(Bytes::from(out)))
        .unwrap())
}

fn effective_client_ip<B>(req: &Request<B>, peer_ip: IpAddr, state: &AppState) -> IpAddr {
    if !state.trusted_proxy(peer_ip) {
        return peer_ip;
    }
    let Some(value) = req
        .headers()
        .get("cf-connecting-ip")
        .and_then(|value| value.to_str().ok())
    else {
        return peer_ip;
    };
    // Cloudflare provides exactly one plain IP. Reject comma-separated values,
    // ports, whitespace-only values, and malformed content instead of treating
    // arbitrary X-Forwarded-For input as authoritative.
    IpAddr::from_str(value.trim()).unwrap_or(peer_ip)
}

fn is_control_upgrade(req: &Request<Incoming>, state: &AppState) -> bool {
    let Some(hub) = state.control.as_ref() else {
        return false;
    };
    req.uri().path() == hub.path()
        && req
            .headers()
            .get(hyper::header::UPGRADE)
            .and_then(|value| value.to_str().ok())
            .map(|value| value.eq_ignore_ascii_case("websocket"))
            .unwrap_or(false)
        && req
            .headers()
            .get("sec-websocket-protocol")
            .and_then(|value| value.to_str().ok())
            .map(|value| {
                value
                    .split(',')
                    .any(|item| item.trim() == crate::control::protocol())
            })
            .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use crate::geoip::GeoIp;
    use domain_index::DomainIndex;
    use schedule::NodeTable;

    fn state(proxy_cidrs: Vec<&str>) -> Arc<AppState> {
        let mut cfg = Config::default();
        cfg.access.trusted_proxy_cidrs = proxy_cidrs.into_iter().map(ToOwned::to_owned).collect();
        let index = DomainIndex::load_str("", 0).unwrap();
        let nodes = NodeTable::from_configs(vec![]).unwrap();
        AppState::new(cfg, index, nodes, GeoIp::open("/dev/null"), None)
    }

    fn request(header: Option<&str>) -> Request<()> {
        let mut builder = Request::builder().uri("/dns-query");
        if let Some(value) = header {
            builder = builder.header("cf-connecting-ip", value);
        }
        builder.body(()).unwrap()
    }

    #[test]
    fn trusted_local_proxy_can_supply_cf_connecting_ip() {
        let state = state(vec!["127.0.0.1/32"]);
        let got = effective_client_ip(
            &request(Some("203.0.113.9")),
            "127.0.0.1".parse().unwrap(),
            &state,
        );
        assert_eq!(got, "203.0.113.9".parse::<IpAddr>().unwrap());
    }

    #[test]
    fn direct_client_cannot_spoof_cf_connecting_ip() {
        let state = state(vec!["127.0.0.1/32"]);
        let got = effective_client_ip(
            &request(Some("198.51.100.10")),
            "203.0.113.9".parse().unwrap(),
            &state,
        );
        assert_eq!(got, "203.0.113.9".parse::<IpAddr>().unwrap());
    }

    #[test]
    fn malformed_proxy_header_falls_back_to_peer() {
        let state = state(vec!["127.0.0.1/32"]);
        let got = effective_client_ip(
            &request(Some("203.0.113.9, 198.51.100.10")),
            "127.0.0.1".parse().unwrap(),
            &state,
        );
        assert_eq!(got, "127.0.0.1".parse::<IpAddr>().unwrap());
    }
}

fn websocket_accept(key: &str) -> String {
    use base64::Engine;
    use sha1::{Digest, Sha1};
    let mut hasher = Sha1::new();
    hasher.update(key.as_bytes());
    hasher.update(b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    base64::engine::general_purpose::STANDARD.encode(hasher.finalize())
}

fn status_body(code: StatusCode, b: &'static [u8]) -> Response<Full<Bytes>> {
    Response::builder()
        .status(code)
        .body(Full::new(Bytes::from_static(b)))
        .unwrap()
}

fn servfail(request: &Message) -> Message {
    let mut m = Message::new();
    m.set_id(request.id());
    m.set_message_type(hickory_proto::op::MessageType::Response);
    m.set_op_code(hickory_proto::op::OpCode::Query);
    m.set_response_code(hickory_proto::op::ResponseCode::ServFail);
    m.set_recursion_available(true);
    if let Some(q) = request.queries().first() {
        m.add_query(q.clone());
    }
    m
}

fn base64url_decode(s: &str) -> Result<Vec<u8>, ()> {
    use base64::engine::general_purpose::{URL_SAFE, URL_SAFE_NO_PAD};
    use base64::Engine;
    URL_SAFE_NO_PAD
        .decode(s)
        .or_else(|_| URL_SAFE.decode(s))
        .map_err(|_| ())
}
