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
use tokio::sync::{mpsc, oneshot, watch};
use tokio_tungstenite::tungstenite::{protocol::Message as WsMessage, protocol::Role};
use tokio_tungstenite::WebSocketStream;
use tracing::{info, warn};

const CONTROL_PROTOCOL: &str = "proxym-unlock-control-v1";
const SESSION_WRITE_TIMEOUT: Duration = Duration::from_secs(10);
const SESSION_QUEUE_CAPACITY: usize = 1024;
const SESSION_MAX_PENDING: usize = 1024;

#[derive(Debug)]
pub struct ControlHub {
    token: String,
    path: String,
    sessions: DashMap<String, SessionHandle>,
    updates: watch::Sender<Vec<String>>,
}

#[derive(Debug, Clone)]
struct SessionHandle {
    tx: mpsc::Sender<Command>,
    shutdown: watch::Sender<bool>,
}

#[derive(Debug)]
enum Command {
    Query {
        id: u64,
        dns_message_b64: String,
        deadline: tokio::time::Instant,
        reply: oneshot::Sender<std::result::Result<Message, String>>,
    },
}

struct PendingQuery {
    deadline: tokio::time::Instant,
    reply: oneshot::Sender<std::result::Result<Message, String>>,
}

fn expire_pending(pending: &mut HashMap<u64, PendingQuery>, now: tokio::time::Instant) {
    let expired: Vec<u64> = pending
        .iter()
        .filter(|(_, query)| query.deadline <= now || query.reply.is_closed())
        .map(|(id, _)| *id)
        .collect();
    for id in expired {
        if let Some(query) = pending.remove(&id) {
            let _ = query
                .reply
                .send(Err("unlock control DNS query expired".into()));
        }
    }
}

struct SessionRegistration {
    hub: Arc<ControlHub>,
    node_id: String,
    session: SessionHandle,
}

impl Drop for SessionRegistration {
    fn drop(&mut self) {
        self.hub
            .remove_session_if_current(&self.node_id, &self.session);
    }
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
    pub fn new(token: String, path: String, initial_acl: Vec<String>) -> Arc<Self> {
        let (updates, _) = watch::channel(initial_acl);
        Arc::new(Self {
            token,
            path,
            sessions: DashMap::new(),
            updates,
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

    /// Whether a data-plane node currently holds a live control session.
    /// Used by the resolver to prefer nodes that are actually reachable over
    /// the authenticated channel instead of burning a timeout on dead ones.
    pub fn connected(&self, node_id: &str) -> bool {
        self.sessions
            .get(node_id)
            .is_some_and(|session| !session.tx.is_closed())
    }

    /// Replace the latest ACL snapshot and wake every active session without
    /// serially waiting on any one node's socket writer.
    pub async fn broadcast_acl(&self, cidrs: Vec<String>) {
        self.updates.send_replace(cidrs);
    }

    fn remove_session_if_current(&self, node_id: &str, session: &SessionHandle) {
        self.sessions
            .remove_if(node_id, |_, current| current.tx.same_channel(&session.tx));
    }

    fn is_current_session(&self, node_id: &str, tx: &mpsc::Sender<Command>) -> bool {
        self.sessions
            .get(node_id)
            .is_some_and(|current| current.tx.same_channel(tx))
    }

    pub async fn query(
        &self,
        node_id: &str,
        request: &Message,
        timeout: Duration,
    ) -> Result<Message> {
        let deadline = tokio::time::Instant::now() + timeout;
        let session = self
            .sessions
            .get(node_id)
            .map(|item| item.value().clone())
            .ok_or_else(|| anyhow!("unlock control node {node_id} is not connected"))?;
        let wire = request.to_bytes().context("encode control DNS request")?;
        let id = random_id();
        let (reply_tx, reply_rx) = oneshot::channel();
        let command = Command::Query {
            id,
            dns_message_b64: base64url_encode(&wire),
            deadline,
            reply: reply_tx,
        };
        if tokio::time::timeout_at(deadline, session.tx.send(command))
            .await
            .map_err(|_| anyhow!("unlock control DNS query queue timed out"))?
            .is_err()
        {
            self.remove_session_if_current(node_id, &session);
            let _ = session.shutdown.send(true);
            return Err(anyhow!("unlock control node {node_id} disconnected"));
        }
        match tokio::time::timeout_at(deadline, reply_rx).await {
            Ok(Ok(Ok(message))) => Ok(message),
            Ok(Ok(Err(error))) => Err(anyhow!(error)),
            Ok(Err(_)) => Err(anyhow!("unlock control reply channel closed")),
            Err(_) => Err(anyhow!("unlock control DNS query timed out")),
        }
    }

    pub async fn serve<S>(self: Arc<Self>, stream: S) -> Result<()>
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

        let (tx, mut rx) = mpsc::channel(SESSION_QUEUE_CAPACITY);
        let (shutdown, mut shutdown_rx) = watch::channel(false);
        // Subscribe before registering, then read the latest ACL after we are
        // current. This closes the upgrade-snapshot / subscribe lost-update gap.
        let mut updates = self.updates.subscribe();
        let session = SessionHandle {
            tx: tx.clone(),
            shutdown: shutdown.clone(),
        };
        if let Some(previous) = self.sessions.insert(node_id.clone(), session.clone()) {
            let _ = previous.shutdown.send(true);
            warn!(%node_id, "replaced previous unlock control connection");
        }
        let _registration = SessionRegistration {
            hub: Arc::clone(&self),
            node_id: node_id.clone(),
            session,
        };
        info!(%node_id, "unlock control node connected");
        send_json_bounded(
            &mut write,
            &CenterMessage::Hello {
                protocol: CONTROL_PROTOCOL,
            },
        )
        .await?;
        let acl = updates.borrow_and_update().clone();
        send_json_bounded(&mut write, &CenterMessage::Acl { cidrs: acl }).await?;

        let mut pending: HashMap<u64, PendingQuery> = HashMap::new();
        let mut ping = tokio::time::interval(Duration::from_secs(20));
        ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut cleanup = tokio::time::interval(Duration::from_secs(1));
        cleanup.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut last_seen = tokio::time::Instant::now();
        const IDLE_TIMEOUT: Duration = Duration::from_secs(75);
        loop {
            if !self.is_current_session(&node_id, &tx) {
                let _ = shutdown.send(true);
                break;
            }
            tokio::select! {
                changed = shutdown_rx.changed() => {
                    if changed.is_err() || *shutdown_rx.borrow() { break; }
                }
                _ = cleanup.tick() => {
                    expire_pending(&mut pending, tokio::time::Instant::now());
                }
                _ = ping.tick() => {
                    if last_seen.elapsed() > IDLE_TIMEOUT {
                        warn!(%node_id, "unlock control node idle; closing half-open session");
                        break;
                    }
                    tokio::time::timeout(
                        SESSION_WRITE_TIMEOUT,
                        write.send(WsMessage::Ping(vec![].into())),
                    )
                    .await
                    .context("control ping write timed out")?
                    .context("control ping")?;
                }
                changed = updates.changed() => {
                    if changed.is_err() { break; }
                    let cidrs = updates.borrow_and_update().clone();
                    send_json_bounded(&mut write, &CenterMessage::Acl { cidrs}).await?;
                }
                command = rx.recv() => {
                    let Some(command) = command else { break; };
                    match command {
                        Command::Query { id, dns_message_b64, deadline, reply } => {
                            if deadline <= tokio::time::Instant::now() || reply.is_closed() {
                                let _ = reply.send(Err("unlock control DNS query expired".into()));
                                continue;
                            }
                            expire_pending(&mut pending, tokio::time::Instant::now());
                            if pending.len() >= SESSION_MAX_PENDING {
                                let _ = reply.send(Err("unlock control node has too many pending DNS queries".into()));
                                continue;
                            }
                            send_json_bounded(&mut write, &CenterMessage::Query { id, dns_message_b64 }).await?;
                            pending.insert(id, PendingQuery { deadline, reply });
                        }
                    }
                }
                incoming = read.next() => {
                    let Some(incoming) = incoming else { break; };
                    last_seen = tokio::time::Instant::now();
                    match incoming.context("read unlock control WebSocket")? {
                        WsMessage::Text(text) => {
                            let message: NodeMessage = serde_json::from_str(&text)
                                .context("decode unlock control message")?;
                            match message {
                                NodeMessage::QueryResult { id, dns_message_b64, error } => {
                                    let result = decode_query_result(dns_message_b64, error);
                                    if let Some(query) = pending.remove(&id) { let _ = query.reply.send(result); }
                                }
                                NodeMessage::Error { message } => return Err(anyhow!("unlock node error: {message}")),
                                NodeMessage::Hello { .. } => return Err(anyhow!("duplicate unlock control hello")),
                            }
                        }
                        WsMessage::Ping(payload) => {
                            tokio::time::timeout(SESSION_WRITE_TIMEOUT, write.send(WsMessage::Pong(payload)))
                                .await.context("control pong write timed out")?.context("control pong")?;
                        }
                        WsMessage::Close(_) => break,
                        _ => {}
                    }
                }
            }
        }
        for (_, query) in pending {
            let _ = query
                .reply
                .send(Err("unlock control node disconnected".into()));
        }
        info!(%node_id, "unlock control node disconnected");
        Ok(())
    }
}

async fn send_json_bounded<S>(write: &mut S, value: &CenterMessage) -> Result<()>
where
    S: Sink<WsMessage> + Unpin,
    S::Error: std::error::Error + Send + Sync + 'static,
{
    tokio::time::timeout(SESSION_WRITE_TIMEOUT, send_json(write, value))
        .await
        .context("control WebSocket write timed out")??;
    Ok(())
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
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(1);
    let seq = COUNTER.fetch_add(1, Ordering::Relaxed);
    let pid = std::process::id() as u64;
    now ^ seq.wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ pid.rotate_left(32)
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

    #[test]
    fn old_session_close_does_not_remove_replacement() {
        let hub = ControlHub::new("token".into(), "/control".into(), Vec::new());
        let (old_tx, _old_rx) = mpsc::channel(1);
        let (old_shutdown, _) = watch::channel(false);
        let old = SessionHandle {
            tx: old_tx.clone(),
            shutdown: old_shutdown,
        };
        let (new_tx, _new_rx) = mpsc::channel(1);
        let (new_shutdown, _) = watch::channel(false);
        let new = SessionHandle {
            tx: new_tx.clone(),
            shutdown: new_shutdown,
        };
        hub.sessions.insert("jp-1".into(), old.clone());
        hub.sessions.insert("jp-1".into(), new.clone());
        hub.remove_session_if_current("jp-1", &old);
        let current = hub.sessions.get("jp-1").unwrap();
        assert!(current.tx.same_channel(&new_tx));
    }

    #[tokio::test]
    async fn pending_expiration_reclaims_timeouts_and_cancelled_receivers() {
        let now = tokio::time::Instant::now();
        let (expired_tx, expired_rx) = oneshot::channel();
        let (cancelled_tx, cancelled_rx) = oneshot::channel();
        let (live_tx, _live_rx) = oneshot::channel();
        drop(cancelled_rx);
        let mut pending = HashMap::new();
        pending.insert(
            1,
            PendingQuery {
                deadline: now,
                reply: expired_tx,
            },
        );
        pending.insert(
            2,
            PendingQuery {
                deadline: now + Duration::from_secs(10),
                reply: cancelled_tx,
            },
        );
        pending.insert(
            3,
            PendingQuery {
                deadline: now + Duration::from_secs(10),
                reply: live_tx,
            },
        );
        expire_pending(&mut pending, now);
        assert_eq!(pending.len(), 1);
        assert!(pending.contains_key(&3));
        assert!(expired_rx.await.unwrap().unwrap_err().contains("expired"));
        expire_pending(&mut pending, now + Duration::from_secs(11));
        assert!(pending.is_empty());
    }

    #[tokio::test]
    async fn acl_snapshot_is_available_to_later_sessions_without_prior_subscribers() {
        let hub = ControlHub::new(
            "token".into(),
            "/control".into(),
            vec!["198.51.100.1/32".into()],
        );
        hub.broadcast_acl(vec!["198.51.100.0/24".into()]).await;
        let mut updates = hub.updates.subscribe();
        let latest = updates.borrow_and_update().clone();
        assert_eq!(latest, vec!["198.51.100.0/24"]);
    }

    #[tokio::test]
    async fn query_deadline_covers_time_waiting_for_queue_capacity() {
        let hub = ControlHub::new("token".into(), "/control".into(), Vec::new());
        let (tx, _rx) = mpsc::channel(1);
        let (shutdown, _) = watch::channel(false);
        let (queued_reply, _queued_result) = oneshot::channel();
        tx.try_send(Command::Query {
            id: 1,
            dns_message_b64: String::new(),
            deadline: tokio::time::Instant::now() + Duration::from_secs(5),
            reply: queued_reply,
        })
        .unwrap();
        assert_eq!(tx.capacity(), 0, "queue must really be full");
        hub.sessions
            .insert("jp-1".into(), SessionHandle { tx, shutdown });
        let mut request = Message::new();
        request.set_id(1);
        let started = tokio::time::Instant::now();
        let result = tokio::time::timeout(
            Duration::from_millis(200),
            hub.query("jp-1", &request, Duration::from_millis(25)),
        )
        .await
        .expect("queue send must honor the query budget");
        assert!(result.unwrap_err().to_string().contains("queue timed out"));
        assert!(started.elapsed() < Duration::from_millis(200));
    }

    #[tokio::test]
    async fn dropping_session_registration_removes_only_its_generation() {
        let hub = ControlHub::new("token".into(), "/control".into(), Vec::new());
        let (old_tx, _old_rx) = mpsc::channel(1);
        let (old_shutdown, _) = watch::channel(false);
        let old = SessionHandle {
            tx: old_tx,
            shutdown: old_shutdown,
        };
        hub.sessions.insert("jp-1".into(), old.clone());
        let guard = SessionRegistration {
            hub: Arc::clone(&hub),
            node_id: "jp-1".into(),
            session: old,
        };
        let (new_tx, _new_rx) = mpsc::channel(1);
        let (new_shutdown, _) = watch::channel(false);
        let new = SessionHandle {
            tx: new_tx.clone(),
            shutdown: new_shutdown,
        };
        hub.sessions.insert("jp-1".into(), new);
        drop(guard);
        assert!(hub
            .sessions
            .get("jp-1")
            .is_some_and(|current| current.tx.same_channel(&new_tx)));
    }

    #[tokio::test]
    async fn post_registration_protocol_error_cleans_only_its_own_session() {
        use futures_util::{SinkExt, StreamExt};

        let hub = ControlHub::new(
            "token".into(),
            "/control".into(),
            vec!["198.51.100.0/24".into()],
        );
        let (client_io, server_io) = tokio::io::duplex(64 * 1024);
        let serve_hub = Arc::clone(&hub);
        let server = tokio::spawn(async move { serve_hub.serve(server_io).await });
        let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;
        client
            .send(WsMessage::Text(
                r#"{"type":"hello","protocol":"proxym-unlock-control-v1","node_id":"jp-1"}"#.into(),
            ))
            .await
            .unwrap();
        assert!(matches!(
            client.next().await.unwrap().unwrap(),
            WsMessage::Text(_)
        ));
        let acl = client.next().await.unwrap().unwrap();
        assert!(acl.to_text().unwrap().contains("198.51.100.0/24"));
        assert!(hub.connected("jp-1"));
        client
            .send(WsMessage::Text(
                r#"{"type":"error","message":"forced test failure"}"#.into(),
            ))
            .await
            .unwrap();
        let result = tokio::time::timeout(Duration::from_secs(2), server)
            .await
            .expect("server session should leave promptly")
            .unwrap();
        assert!(result.is_err());
        assert!(!hub.connected("jp-1"));
    }

    async fn read_test_text(client: &mut WebSocketStream<tokio::io::DuplexStream>) -> String {
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                match client
                    .next()
                    .await
                    .expect("session ended")
                    .expect("WebSocket read")
                {
                    WsMessage::Text(text) => return text.to_string(),
                    WsMessage::Ping(payload) => {
                        client
                            .send(WsMessage::Pong(payload))
                            .await
                            .expect("test pong");
                    }
                    WsMessage::Pong(_) => {}
                    other => panic!("unexpected frame: {other:?}"),
                }
            }
        })
        .await
        .expect("expected a text frame before timeout")
    }

    async fn connect_test_node(
        hub: Arc<ControlHub>,
        node_id: &'static str,
    ) -> (
        WebSocketStream<tokio::io::DuplexStream>,
        tokio::task::JoinHandle<Result<()>>,
    ) {
        let (client_io, server_io) = tokio::io::duplex(64 * 1024);
        let serve_hub = Arc::clone(&hub);
        let server = tokio::spawn(async move { serve_hub.serve(server_io).await });
        let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;
        let hello = serde_json::json!({
            "type": "hello",
            "protocol": CONTROL_PROTOCOL,
            "node_id": node_id,
        });
        client
            .send(WsMessage::Text(hello.to_string().into()))
            .await
            .unwrap();
        assert!(matches!(
            client.next().await.unwrap().unwrap(),
            WsMessage::Text(_)
        ));
        assert!(matches!(
            client.next().await.unwrap().unwrap(),
            WsMessage::Text(_)
        ));
        (client, server)
    }

    #[tokio::test]
    async fn replacement_closes_old_socket_and_new_session_answers_queries() {
        use futures_util::SinkExt;

        let hub = ControlHub::new(
            "token".into(),
            "/control".into(),
            vec!["198.51.100.0/24".into()],
        );
        let (old_client, old_server) = connect_test_node(Arc::clone(&hub), "jp-1").await;
        assert!(hub.connected("jp-1"));
        let (mut new_client, new_server) = connect_test_node(Arc::clone(&hub), "jp-1").await;
        tokio::time::timeout(Duration::from_secs(1), old_server)
            .await
            .expect("replacement should end old session")
            .unwrap()
            .unwrap();
        assert!(hub.connected("jp-1"));
        let request = Message::new();
        let query_hub = Arc::clone(&hub);
        let query = tokio::spawn(async move {
            query_hub
                .query("jp-1", &request, Duration::from_secs(1))
                .await
        });
        let text = read_test_text(&mut new_client).await;
        let message: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(message["type"], "query");
        let reply = serde_json::json!({
            "type": "query_result",
            "id": message["id"],
            "dns_message_b64": message["dns_message_b64"],
        });
        new_client
            .send(WsMessage::Text(reply.to_string().into()))
            .await
            .unwrap();
        assert!(query.await.unwrap().is_ok());
        hub.broadcast_acl(vec!["203.0.113.0/24".into()]).await;
        let acl = read_test_text(&mut new_client).await;
        assert!(acl.contains("203.0.113.0/24"));
        new_client.close(None).await.unwrap();
        tokio::time::timeout(Duration::from_secs(1), new_server)
            .await
            .expect("closing replacement should end session")
            .unwrap()
            .unwrap();
        assert!(!hub.connected("jp-1"));
        drop(old_client);
    }

    #[tokio::test]
    async fn cancelled_session_cleans_registry_and_pending_replies() {
        let hub = ControlHub::new(
            "token".into(),
            "/control".into(),
            vec!["127.0.0.0/8".into()],
        );
        let (mut client, server) = connect_test_node(Arc::clone(&hub), "jp-1").await;
        let query_hub = Arc::clone(&hub);
        let query = tokio::spawn(async move {
            query_hub
                .query("jp-1", &Message::new(), Duration::from_secs(5))
                .await
        });
        let text = read_test_text(&mut client).await;
        assert!(text.contains("\"type\":\"query\""));
        server.abort();
        assert!(server.await.unwrap_err().is_cancelled());
        assert!(!hub.connected("jp-1"));
        let result = tokio::time::timeout(Duration::from_secs(1), query)
            .await
            .unwrap()
            .unwrap();
        assert!(
            result.is_err(),
            "pending request should fail without waiting five seconds"
        );
    }

    #[tokio::test]
    async fn blocked_initial_writer_times_out_and_cleans_registry() {
        let hub = ControlHub::new(
            "token".into(),
            "/control".into(),
            vec!["127.0.0.0/8".into()],
        );
        let (client_io, server_io) = tokio::io::duplex(1);
        let serve_hub = Arc::clone(&hub);
        let server = tokio::spawn(async move { serve_hub.serve(server_io).await });
        let mut client = WebSocketStream::from_raw_socket(client_io, Role::Client, None).await;
        client
            .send(WsMessage::Text(
                r#"{"type":"hello","protocol":"proxym-unlock-control-v1","node_id":"jp-1"}"#.into(),
            ))
            .await
            .unwrap();
        // Do not read the server Hello: its tiny output buffer stays full.
        tokio::task::yield_now().await;
        assert!(hub.connected("jp-1"));
        let result = tokio::time::timeout(SESSION_WRITE_TIMEOUT + Duration::from_secs(2), server)
            .await
            .expect("a blocked socket must not outlive the write budget")
            .unwrap();
        assert!(result.unwrap_err().to_string().contains("write timed out"));
        assert!(!hub.connected("jp-1"));
    }

    #[tokio::test]
    async fn malformed_frame_and_transport_eof_do_not_leave_false_online_nodes() {
        for malformed in [true, false] {
            let hub = ControlHub::new(
                "token".into(),
                "/control".into(),
                vec!["127.0.0.0/8".into()],
            );
            let (mut client, server) = connect_test_node(Arc::clone(&hub), "jp-1").await;
            if malformed {
                client
                    .send(WsMessage::Text("{not valid json".into()))
                    .await
                    .unwrap();
            } else {
                drop(client);
            }
            let result = tokio::time::timeout(Duration::from_secs(2), server)
                .await
                .unwrap()
                .unwrap();
            assert!(result.is_err());
            assert!(!hub.connected("jp-1"));
        }
    }

    #[tokio::test]
    async fn repeated_replacement_and_disconnect_cycles_leave_no_sessions() {
        let hub = ControlHub::new(
            "token".into(),
            "/control".into(),
            vec!["127.0.0.0/8".into()],
        );
        for iteration in 0..100 {
            let (client, server) = connect_test_node(Arc::clone(&hub), "jp-1").await;
            let (replacement, replacement_server) =
                connect_test_node(Arc::clone(&hub), "jp-1").await;
            tokio::time::timeout(Duration::from_secs(2), server)
                .await
                .unwrap()
                .unwrap()
                .unwrap();
            assert_eq!(hub.sessions.len(), 1, "cycle {iteration}");
            drop(client);
            drop(replacement);
            let _ = tokio::time::timeout(Duration::from_secs(2), replacement_server)
                .await
                .unwrap()
                .unwrap();
            assert!(
                hub.sessions.is_empty(),
                "cycle {iteration} leaked a registered session"
            );
        }
    }
}
