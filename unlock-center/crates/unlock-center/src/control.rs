//! WebSocket control channel multiplexed on the center's existing DoH TLS port.
//!
//! Data-plane unlock nodes initiate the connection. The center pushes its ACL
//! snapshot over that connection and forwards `other` DNS packets through it.
//! There is no new listener or public port.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use dashmap::DashMap;
use futures_util::{Sink, SinkExt, StreamExt};
use hickory_proto::op::Message;
use hickory_proto::serialize::binary::{BinDecodable, BinEncodable};
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::{protocol::Message as WsMessage, protocol::Role};
use tokio_tungstenite::WebSocketStream;
use tracing::{info, warn};

const CONTROL_PROTOCOL: &str = "proxym-unlock-control-v1";

#[derive(Debug)]
pub struct ControlHub {
    token: String,
    path: String,
    sessions: DashMap<String, mpsc::Sender<Command>>,
}

#[derive(Debug)]
enum Command {
    Acl(Vec<String>),
    Query {
        id: u64,
        dns_message_b64: String,
        reply: oneshot::Sender<std::result::Result<Message, String>>,
    },
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum NodeMessage {
    Hello {
        protocol: String,
        node_id: String,
    },
    QueryResult {
        id: u64,
        dns_message_b64: Option<String>,
        error: Option<String>,
    },
    Error {
        message: String,
    },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum CenterMessage {
    Hello { protocol: &'static str },
    Acl { cidrs: Vec<String> },
    Query { id: u64, dns_message_b64: String },
}

impl ControlHub {
    pub fn new(token: String, path: String) -> Arc<Self> {
        Arc::new(Self {
            token,
            path,
            sessions: DashMap::new(),
        })
    }

    pub fn enabled(&self) -> bool {
        !self.token.is_empty()
    }

    pub fn path(&self) -> &str {
        &self.path
    }

    pub fn authorize(&self, authorization: Option<&str>) -> bool {
        self.enabled()
            && authorization
                .map(|value| value == self.token || value == format!("Bearer {}", self.token))
                .unwrap_or(false)
    }

    pub async fn broadcast_acl(&self, cidrs: Vec<String>) {
        let sessions: Vec<(String, mpsc::Sender<Command>)> = self
            .sessions
            .iter()
            .map(|item| (item.key().clone(), item.value().clone()))
            .collect();
        for (node_id, tx) in sessions {
            if tx.send(Command::Acl(cidrs.clone())).await.is_err() {
                self.sessions.remove(&node_id);
            }
        }
    }

    pub async fn query(
        &self,
        node_id: &str,
        request: &Message,
        timeout: Duration,
    ) -> Result<Message> {
        let session = self
            .sessions
            .get(node_id)
            .map(|item| item.value().clone())
            .ok_or_else(|| anyhow!("unlock control node {node_id} is not connected"))?;
        let wire = request.to_bytes().context("encode control DNS request")?;
        let (reply_tx, reply_rx) = oneshot::channel();
        session
            .send(Command::Query {
                id: random_id(),
                dns_message_b64: base64url_encode(&wire),
                reply: reply_tx,
            })
            .await
            .map_err(|_| anyhow!("unlock control node {node_id} disconnected"))?;
        match tokio::time::timeout(timeout, reply_rx).await {
            Ok(Ok(Ok(message))) => Ok(message),
            Ok(Ok(Err(error))) => Err(anyhow!(error)),
            Ok(Err(_)) => Err(anyhow!("unlock control reply channel closed")),
            Err(_) => Err(anyhow!("unlock control DNS query timed out")),
        }
    }

    pub async fn serve<S>(self: Arc<Self>, stream: S, acl: Vec<String>) -> Result<()>
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
    {
        let ws = WebSocketStream::from_raw_socket(stream, Role::Server, None).await;
        let (mut write, mut read) = ws.split();
        let hello = match tokio::time::timeout(Duration::from_secs(10), read.next()).await {
            Ok(Some(Ok(WsMessage::Text(text)))) => {
                serde_json::from_str::<NodeMessage>(&text).context("decode control node hello")?
            }
            _ => return Err(anyhow!("unlock control node did not send hello")),
        };
        let (protocol, node_id) = match hello {
            NodeMessage::Hello { protocol, node_id } => (protocol, node_id),
            _ => return Err(anyhow!("unlock control node must send hello first")),
        };
        if protocol != CONTROL_PROTOCOL || !valid_node_id(&node_id) {
            return Err(anyhow!("invalid unlock control node hello"));
        }

        let (tx, mut rx) = mpsc::channel(1024);
        if let Some(previous) = self.sessions.insert(node_id.clone(), tx) {
            drop(previous);
            warn!(%node_id, "replaced previous unlock control connection");
        }
        info!(%node_id, "unlock control node connected");
        send_json(
            &mut write,
            &CenterMessage::Hello {
                protocol: CONTROL_PROTOCOL,
            },
        )
        .await?;
        send_json(&mut write, &CenterMessage::Acl { cidrs: acl }).await?;

        let mut pending: HashMap<u64, oneshot::Sender<std::result::Result<Message, String>>> =
            HashMap::new();
        loop {
            tokio::select! {
                command = rx.recv() => {
                    let Some(command) = command else { break; };
                    match command {
                        Command::Acl(cidrs) => send_json(&mut write, &CenterMessage::Acl { cidrs }).await?,
                        Command::Query { id, dns_message_b64, reply } => {
                            send_json(&mut write, &CenterMessage::Query { id, dns_message_b64 }).await?;
                            pending.insert(id, reply);
                        }
                    }
                }
                incoming = read.next() => {
                    let Some(incoming) = incoming else { break; };
                    match incoming.context("read unlock control WebSocket")? {
                        WsMessage::Text(text) => {
                            let message: NodeMessage = serde_json::from_str(&text)
                                .context("decode unlock control message")?;
                            match message {
                                NodeMessage::QueryResult { id, dns_message_b64, error } => {
                                    let result = decode_query_result(dns_message_b64, error);
                                    if let Some(reply) = pending.remove(&id) {
                                        let _ = reply.send(result);
                                    }
                                }
                                NodeMessage::Error { message } => return Err(anyhow!("unlock node error: {message}")),
                                NodeMessage::Hello { .. } => return Err(anyhow!("duplicate unlock control hello")),
                            }
                        }
                        WsMessage::Ping(payload) => write.send(WsMessage::Pong(payload)).await.context("control pong")?,
                        WsMessage::Close(_) => break,
                        _ => {}
                    }
                }
            }
        }
        self.sessions.remove(&node_id);
        for (_, reply) in pending {
            let _ = reply.send(Err("unlock control node disconnected".into()));
        }
        info!(%node_id, "unlock control node disconnected");
        Ok(())
    }
}

async fn send_json<S>(write: &mut S, value: &CenterMessage) -> Result<()>
where
    S: Sink<WsMessage> + Unpin,
    S::Error: std::error::Error + Send + Sync + 'static,
{
    let text = serde_json::to_string(value).context("encode unlock control message")?;
    write
        .send(WsMessage::Text(text.into()))
        .await
        .context("write unlock control message")
}

fn decode_query_result(
    dns_message_b64: Option<String>,
    error: Option<String>,
) -> std::result::Result<Message, String> {
    match (dns_message_b64, error) {
        (_, Some(error)) => Err(error),
        (Some(encoded), None) => base64url_decode(&encoded)
            .map_err(|_| "invalid control DNS reply encoding".to_string())
            .and_then(|wire| {
                Message::from_bytes(&wire)
                    .map_err(|error| format!("invalid control DNS reply: {error}"))
            }),
        (None, None) => Err("empty control DNS reply".to_string()),
    }
}

fn valid_node_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

fn random_id() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(1);
    now ^ now.rotate_left(17)
}

fn base64url_encode(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

fn base64url_decode(value: &str) -> Result<Vec<u8>, ()> {
    use base64::Engine;
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| ())
}

pub const fn protocol() -> &'static str {
    CONTROL_PROTOCOL
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_control_node_ids() {
        assert!(valid_node_id("jp-1"));
        assert!(valid_node_id("us.node_01"));
        assert!(!valid_node_id(""));
        assert!(!valid_node_id("bad/id"));
        assert!(!valid_node_id(&"a".repeat(129)));
    }

    #[test]
    fn decodes_dns_result_errors_without_panicking() {
        assert!(decode_query_result(None, None).is_err());
        assert!(decode_query_result(Some("%%%".into()), None).is_err());
        assert_eq!(
            decode_query_result(None, Some("node failed".into())).unwrap_err(),
            "node failed"
        );
    }
}
