use std::net::SocketAddr;
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

async fn handle_dot_conn<S>(
    state: &AppState,
    stream: &mut S,
    peer: SocketAddr,
) -> Result<()>
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

/// DNS-over-HTTPS with configurable path.
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
            if let Err(e) = http1::Builder::new().serve_connection(io, svc).await {
                // http2 may fail on http1 builder — try hyper_util auto if needed
                warn!(%peer, error=%e, "doh http conn");
            }
        });
    }
}

async fn handle_doh_http(
    state: Arc<AppState>,
    req: Request<Incoming>,
    peer: SocketAddr,
) -> Result<Response<Full<Bytes>>, std::convert::Infallible> {
    // Optional bearer
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
        .handle_query(&request, Some(peer.ip()), &profile)
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
