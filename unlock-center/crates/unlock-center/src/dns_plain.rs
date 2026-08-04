use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::Result;
use hickory_proto::op::Message;
use hickory_proto::serialize::binary::{BinDecodable, BinEncodable};
use tokio::net::{TcpListener, UdpSocket};
use tracing::{error, info, warn};

use crate::profile::Profile;
use crate::resolve::{AppState, ResolveResult};

pub async fn serve_udp(state: Arc<AppState>, addr: SocketAddr) -> Result<()> {
    // Prefer reuse so restarts / dual-stack edge cases are less flaky in containers.
    let std_sock = std::net::UdpSocket::bind(addr)?;
    std_sock.set_nonblocking(true)?;
    let sock = Arc::new(UdpSocket::from_std(std_sock)?);
    info!(%addr, "plain DNS UDP listening");
    let mut buf = vec![0u8; 4096];
    loop {
        let (n, peer) = match sock.recv_from(&mut buf).await {
            Ok(v) => v,
            Err(e) => {
                warn!(error=%e, "udp recv");
                continue;
            }
        };
        let data = buf[..n].to_vec();
        let sock2 = Arc::clone(&sock);
        let state2 = Arc::clone(&state);
        tokio::spawn(async move {
            if let Err(e) = handle_udp(&state2, &sock2, peer, &data).await {
                warn!(%peer, error=%e, "udp handle");
            }
        });
    }
}

async fn handle_udp(
    state: &AppState,
    sock: &UdpSocket,
    peer: SocketAddr,
    data: &[u8],
) -> Result<()> {
    let request = Message::from_bytes(data)?;
    let profile = Profile::default_from_config(&state.cfg);
    let resp = match state
        .handle_query(&request, Some(peer.ip()), &profile)
        .await
    {
        ResolveResult::Message(m) => m,
        ResolveResult::ServFail => servfail(&request),
    };
    let out = resp.to_bytes()?;
    sock.send_to(&out, peer).await?;
    Ok(())
}

pub async fn serve_tcp(state: Arc<AppState>, addr: SocketAddr) -> Result<()> {
    let listener = TcpListener::bind(addr).await?;
    info!(%addr, "plain DNS TCP listening");
    loop {
        let (mut stream, peer) = listener.accept().await?;
        let state2 = Arc::clone(&state);
        tokio::spawn(async move {
            if let Err(e) = handle_tcp(&state2, &mut stream, peer).await {
                warn!(%peer, error=%e, "tcp dns handle");
            }
        });
    }
}

async fn handle_tcp(
    state: &AppState,
    stream: &mut tokio::net::TcpStream,
    peer: SocketAddr,
) -> Result<()> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut len_buf = [0u8; 2];
    stream.read_exact(&mut len_buf).await?;
    let len = u16::from_be_bytes(len_buf) as usize;
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
    Ok(())
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

#[allow(dead_code)]
fn _error_log(e: impl std::fmt::Display) {
    error!(error=%e, "dns");
}
