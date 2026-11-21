//! Opaque-byte Iroh transport spike for Apple clients.
//!
//! This crate intentionally knows nothing about RepoPrompt's application protocol. Swift owns
//! persistence and supplies the 32-byte endpoint secret only when an endpoint starts.

use std::{
    future::Future,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use iroh::{Endpoint, EndpointAddr, SecretKey, endpoint::presets};
use once_cell::sync::Lazy;
use thiserror::Error;
use tokio::{
    runtime::Runtime,
    sync::{OwnedSemaphorePermit, Semaphore, mpsc},
    task::JoinHandle,
};
use zeroize::Zeroizing;

pub const MAX_FRAME_BYTES: usize = 1_048_576;
pub const MAX_RESPONSE_FRAME_BYTES: usize = 8_388_608;
pub const MAX_CONCURRENT_STREAMS: usize = 8;
pub const MAX_ACCEPTED_CONNECTIONS: usize = 16;
pub const REPOPROMPT_ALPN: &[u8] = b"repoprompt-remote/1";

const FRAME_IO_TIMEOUT: Duration = Duration::from_secs(15);
const CONNECTION_IDLE_TIMEOUT: Duration = Duration::from_secs(120);

static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .thread_name("repoprompt-iroh")
        .build()
        .expect("failed to create the RepoPrompt Iroh runtime")
});

#[derive(Debug, Error, uniffi::Error)]
pub enum TransportError {
    #[error("{0}")]
    Failure(String),
}

impl TransportError {
    fn from_display(context: &str, error: impl std::fmt::Display) -> Self {
        Self::Failure(format!("{context}: {error}"))
    }

    fn message(message: impl Into<String>) -> Self {
        Self::Failure(message.into())
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct EndpointSnapshot {
    pub endpoint_id: String,
    pub address_json: String,
    pub generation: u64,
    pub relay_enabled: bool,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct IncomingConnection {
    pub peer_endpoint_id: String,
    pub generation: u64,
    pub path_summary: String,
}

#[derive(uniffi::Object)]
pub struct IncomingRequest {
    connection: iroh::endpoint::Connection,
    peer_endpoint_id: String,
    generation: u64,
    path_summary: String,
    payload: Vec<u8>,
    send: tokio::sync::Mutex<Option<iroh::endpoint::SendStream>>,
    permit: tokio::sync::Mutex<Option<OwnedSemaphorePermit>>,
}

#[uniffi::export]
impl IncomingRequest {
    pub fn peer_endpoint_id(&self) -> String {
        self.peer_endpoint_id.clone()
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn path_summary(&self) -> String {
        self.path_summary.clone()
    }

    pub fn payload(&self) -> Vec<u8> {
        self.payload.clone()
    }

    pub async fn respond(self: Arc<Self>, payload: Vec<u8>) -> Result<(), TransportError> {
        if payload.len() > MAX_RESPONSE_FRAME_BYTES {
            return Err(TransportError::message(format!(
                "response frame length {} exceeds {MAX_RESPONSE_FRAME_BYTES}",
                payload.len()
            )));
        }
        let request = self.clone();
        on_runtime(async move {
            let mut send = request
                .send
                .lock()
                .await
                .take()
                .ok_or_else(|| TransportError::message("request already completed"))?;
            let result = tokio::time::timeout(FRAME_IO_TIMEOUT, async {
                write_frame_with_limit(&mut send, &payload, MAX_RESPONSE_FRAME_BYTES).await?;
                send.finish().map_err(|error| {
                    TransportError::from_display("finish response stream", error)
                })?;
                Ok(())
            })
            .await
            .map_err(|_| TransportError::message("response frame I/O timed out"))?;
            request.permit.lock().await.take();
            result
        })
        .await?
    }

    pub fn close(&self) {
        self.connection
            .close(0_u32.into(), b"request closed by Swift");
    }
}

struct AbortOnDrop<T>(Option<JoinHandle<T>>);

impl<T> AbortOnDrop<T> {
    fn new(handle: JoinHandle<T>) -> Self {
        Self(Some(handle))
    }

    async fn join(mut self) -> Result<T, TransportError> {
        let result = self
            .0
            .as_mut()
            .expect("join handle must exist")
            .await
            .map_err(|error| TransportError::from_display("runtime task failed", error))?;
        self.0.take();
        Ok(result)
    }
}

impl<T> Drop for AbortOnDrop<T> {
    fn drop(&mut self) {
        if let Some(handle) = self.0.take() {
            handle.abort();
        }
    }
}

async fn on_runtime<F, T>(future: F) -> Result<T, TransportError>
where
    F: Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    AbortOnDrop::new(RUNTIME.spawn(future)).join().await
}

fn secret_key_from_swift(secret_key: Vec<u8>) -> Result<SecretKey, TransportError> {
    let secret_key = Zeroizing::new(secret_key);
    if secret_key.len() != 32 {
        return Err(TransportError::message(
            "endpoint secret must contain exactly 32 bytes",
        ));
    }

    let mut bytes = Zeroizing::new([0_u8; 32]);
    bytes.copy_from_slice(secret_key.as_slice());
    Ok(SecretKey::from_bytes(&bytes))
}

#[uniffi::export]
pub fn endpoint_id_for_secret(secret_key: Vec<u8>) -> Result<String, TransportError> {
    Ok(secret_key_from_swift(secret_key)?.public().to_string())
}

#[derive(uniffi::Object)]
pub struct TransportEndpoint {
    endpoint: Endpoint,
    alpn: Vec<u8>,
    generation: u64,
    relay_enabled: bool,
    incoming: tokio::sync::Mutex<mpsc::Receiver<IncomingConnection>>,
    requests: tokio::sync::Mutex<mpsc::Receiver<Arc<IncomingRequest>>>,
    accept_task: Mutex<Option<JoinHandle<()>>>,
    stopped: AtomicBool,
}

#[uniffi::export]
pub async fn start_endpoint(
    secret_key: Vec<u8>,
    alpn: Vec<u8>,
    relay_enabled: bool,
    generation: u64,
) -> Result<Arc<TransportEndpoint>, TransportError> {
    start_endpoint_internal(secret_key, alpn, relay_enabled, generation, true).await
}

#[uniffi::export]
pub async fn start_application_endpoint(
    secret_key: Vec<u8>,
    alpn: Vec<u8>,
    relay_enabled: bool,
    generation: u64,
) -> Result<Arc<TransportEndpoint>, TransportError> {
    start_endpoint_internal(secret_key, alpn, relay_enabled, generation, false).await
}

async fn start_endpoint_internal(
    secret_key: Vec<u8>,
    alpn: Vec<u8>,
    relay_enabled: bool,
    generation: u64,
    echo_mode: bool,
) -> Result<Arc<TransportEndpoint>, TransportError> {
    if alpn.is_empty() || alpn.len() > 255 {
        return Err(TransportError::message(
            "ALPN must contain between 1 and 255 bytes",
        ));
    }

    let secret_key = secret_key_from_swift(secret_key)?;
    on_runtime(async move {
        let mut builder = Endpoint::builder(presets::N0)
            .secret_key(secret_key)
            .alpns(vec![alpn.clone()]);
        if !relay_enabled {
            builder = builder.relay_mode(iroh::RelayMode::Disabled);
        }
        let endpoint = builder
            .bind()
            .await
            .map_err(|error| TransportError::from_display("bind endpoint", error))?;
        let (incoming_tx, incoming_rx) = mpsc::channel(MAX_ACCEPTED_CONNECTIONS);
        let (request_tx, request_rx) =
            mpsc::channel(MAX_ACCEPTED_CONNECTIONS * MAX_CONCURRENT_STREAMS);
        let accept_endpoint = endpoint.clone();
        let connection_limit = Arc::new(Semaphore::new(MAX_ACCEPTED_CONNECTIONS));
        let accept_task = tokio::spawn(async move {
            run_accept_loop(
                accept_endpoint,
                generation,
                incoming_tx,
                request_tx,
                connection_limit,
                echo_mode,
            )
            .await;
        });

        Ok(Arc::new(TransportEndpoint {
            endpoint,
            alpn,
            generation,
            relay_enabled,
            incoming: tokio::sync::Mutex::new(incoming_rx),
            requests: tokio::sync::Mutex::new(request_rx),
            accept_task: Mutex::new(Some(accept_task)),
            stopped: AtomicBool::new(false),
        }))
    })
    .await?
}

async fn run_accept_loop(
    endpoint: Endpoint,
    generation: u64,
    incoming_tx: mpsc::Sender<IncomingConnection>,
    request_tx: mpsc::Sender<Arc<IncomingRequest>>,
    connection_limit: Arc<Semaphore>,
    echo_mode: bool,
) {
    while let Some(incoming) = endpoint.accept().await {
        let Ok(connection) = incoming.await else {
            continue;
        };
        connection.set_max_concurrent_bi_streams((MAX_CONCURRENT_STREAMS as u32).into());
        let Ok(connection_permit) = connection_limit.clone().try_acquire_owned() else {
            connection.close(2_u32.into(), b"too many accepted connections");
            continue;
        };
        let info = IncomingConnection {
            peer_endpoint_id: connection.remote_id().to_string(),
            generation,
            path_summary: format!("{:?}", connection.paths()),
        };
        if echo_mode && incoming_tx.send(info).await.is_err() {
            connection.close(0_u32.into(), b"endpoint stopped");
            break;
        }
        if echo_mode {
            tokio::spawn(run_echo_connection(connection, connection_permit));
        } else {
            tokio::spawn(run_application_connection(
                connection,
                connection_permit,
                generation,
                request_tx.clone(),
            ));
        }
    }
}

async fn run_echo_connection(
    connection: iroh::endpoint::Connection,
    _connection_permit: OwnedSemaphorePermit,
) {
    let stream_limit = Arc::new(Semaphore::new(MAX_CONCURRENT_STREAMS));
    loop {
        let stream = tokio::time::timeout(CONNECTION_IDLE_TIMEOUT, connection.accept_bi()).await;
        let Ok(Ok((send, recv))) = stream else {
            connection.close(3_u32.into(), b"connection idle or closed");
            break;
        };
        let Ok(permit) = stream_limit.clone().try_acquire_owned() else {
            connection.close(2_u32.into(), b"too many concurrent streams");
            break;
        };
        let stream_connection = connection.clone();
        tokio::spawn(async move {
            let _permit = permit;
            let result = tokio::time::timeout(FRAME_IO_TIMEOUT, echo_one_frame(send, recv)).await;
            if !matches!(result, Ok(Ok(()))) {
                stream_connection.close(3_u32.into(), b"frame I/O failed or timed out");
            }
        });
    }
}

async fn run_application_connection(
    connection: iroh::endpoint::Connection,
    _connection_permit: OwnedSemaphorePermit,
    generation: u64,
    request_tx: mpsc::Sender<Arc<IncomingRequest>>,
) {
    let stream_limit = Arc::new(Semaphore::new(MAX_CONCURRENT_STREAMS));
    loop {
        let stream = tokio::time::timeout(CONNECTION_IDLE_TIMEOUT, connection.accept_bi()).await;
        let Ok(Ok((send, mut recv))) = stream else {
            connection.close(3_u32.into(), b"connection idle or closed");
            break;
        };
        let Ok(permit) = stream_limit.clone().try_acquire_owned() else {
            connection.close(2_u32.into(), b"too many concurrent streams");
            break;
        };
        let stream_connection = connection.clone();
        let stream_requests = request_tx.clone();
        tokio::spawn(async move {
            let payload = tokio::time::timeout(
                FRAME_IO_TIMEOUT,
                read_frame_with_limit(&mut recv, MAX_FRAME_BYTES),
            )
            .await;
            let Ok(Ok(payload)) = payload else {
                stream_connection.close(3_u32.into(), b"request frame I/O failed or timed out");
                return;
            };
            let request = Arc::new(IncomingRequest {
                peer_endpoint_id: stream_connection.remote_id().to_string(),
                generation,
                path_summary: format!("{:?}", stream_connection.paths()),
                connection: stream_connection.clone(),
                payload,
                send: tokio::sync::Mutex::new(Some(send)),
                permit: tokio::sync::Mutex::new(Some(permit)),
            });
            if stream_requests.send(request).await.is_err() {
                stream_connection.close(0_u32.into(), b"endpoint stopped");
            }
        });
    }
}

async fn echo_one_frame(
    mut send: iroh::endpoint::SendStream,
    mut recv: iroh::endpoint::RecvStream,
) -> Result<(), TransportError> {
    let payload = read_frame(&mut recv).await?;
    write_frame(&mut send, &payload).await?;
    send.finish()
        .map_err(|error| TransportError::from_display("finish echo stream", error))?;
    Ok(())
}

#[uniffi::export]
impl TransportEndpoint {
    pub fn snapshot(&self) -> Result<EndpointSnapshot, TransportError> {
        let address_json = serde_json::to_string(&self.endpoint.addr())
            .map_err(|error| TransportError::from_display("encode endpoint address", error))?;
        Ok(EndpointSnapshot {
            endpoint_id: self.endpoint.id().to_string(),
            address_json,
            generation: self.generation,
            relay_enabled: self.relay_enabled,
        })
    }

    pub async fn wait_until_online(
        self: Arc<Self>,
        timeout_millis: u64,
    ) -> Result<EndpointSnapshot, TransportError> {
        let endpoint = self.endpoint.clone();
        let relay_enabled = self.relay_enabled;
        on_runtime(async move {
            if relay_enabled {
                tokio::time::timeout(Duration::from_millis(timeout_millis), endpoint.online())
                    .await
                    .map_err(|_| {
                        TransportError::message("timed out waiting for relay registration")
                    })?;
            }
            Ok(())
        })
        .await??;
        self.snapshot()
    }

    pub async fn connect(
        self: Arc<Self>,
        address_json: String,
        alpn: Vec<u8>,
    ) -> Result<Arc<TransportConnection>, TransportError> {
        self.connect_with_policy(address_json, alpn, true, false, 30_000)
            .await
    }

    pub async fn connect_with_policy(
        self: Arc<Self>,
        address_json: String,
        alpn: Vec<u8>,
        allow_relay: bool,
        local_only: bool,
        timeout_millis: u64,
    ) -> Result<Arc<TransportConnection>, TransportError> {
        if self.stopped.load(Ordering::Acquire) {
            return Err(TransportError::message("endpoint is stopped"));
        }
        let mut address: EndpointAddr = serde_json::from_str(&address_json)
            .map_err(|error| TransportError::from_display("decode endpoint address", error))?;
        if !allow_relay {
            address.addrs.retain(|address| !address.is_relay());
        }
        if local_only {
            address.addrs.retain(|address| match address {
                iroh::TransportAddr::Ip(address) => is_local_ip(address.ip()),
                _ => false,
            });
        }
        if address.is_empty() {
            return Err(TransportError::message(
                "no endpoint addresses satisfy the connection policy",
            ));
        }
        let timeout = Duration::from_millis(timeout_millis.clamp(250, 30_000));
        let endpoint = self.endpoint.clone();
        let generation = self.generation;
        on_runtime(async move {
            let connection = tokio::time::timeout(timeout, endpoint.connect(address, &alpn))
                .await
                .map_err(|_| TransportError::message("timed out connecting endpoint"))?
                .map_err(|error| TransportError::from_display("connect endpoint", error))?;
            connection.set_max_concurrent_bi_streams((MAX_CONCURRENT_STREAMS as u32).into());
            Ok(Arc::new(TransportConnection {
                peer_endpoint_id: connection.remote_id().to_string(),
                connection,
                generation,
                stream_limit: Arc::new(Semaphore::new(MAX_CONCURRENT_STREAMS)),
                closed: AtomicBool::new(false),
            }))
        })
        .await?
    }

    pub async fn accept_request(self: Arc<Self>) -> Result<Arc<IncomingRequest>, TransportError> {
        if self.stopped.load(Ordering::Acquire) {
            return Err(TransportError::message("endpoint is stopped"));
        }
        let endpoint = self.clone();
        on_runtime(async move {
            endpoint
                .requests
                .lock()
                .await
                .recv()
                .await
                .ok_or_else(|| TransportError::message("endpoint request loop stopped"))
        })
        .await?
    }

    pub async fn accept(self: Arc<Self>) -> Result<IncomingConnection, TransportError> {
        if self.stopped.load(Ordering::Acquire) {
            return Err(TransportError::message("endpoint is stopped"));
        }
        let endpoint = self.clone();
        on_runtime(async move {
            endpoint
                .incoming
                .lock()
                .await
                .recv()
                .await
                .ok_or_else(|| TransportError::message("endpoint accept loop stopped"))
        })
        .await?
    }

    pub async fn shutdown(self: Arc<Self>) -> Result<(), TransportError> {
        if self.stopped.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        let task = self
            .accept_task
            .lock()
            .map_err(|_| TransportError::message("accept task lock was poisoned"))?
            .take();
        let endpoint = self.endpoint.clone();
        on_runtime(async move {
            if let Some(task) = task {
                task.abort();
                let _ = task.await;
            }
            endpoint.close().await;
        })
        .await
    }

    pub fn configured_alpn(&self) -> Vec<u8> {
        self.alpn.clone()
    }
}

fn is_local_ip(address: std::net::IpAddr) -> bool {
    match address {
        std::net::IpAddr::V4(address) => {
            address.is_private() || address.is_link_local() || address.is_loopback()
        }
        std::net::IpAddr::V6(address) => {
            address.is_unique_local() || address.is_unicast_link_local() || address.is_loopback()
        }
    }
}

impl Drop for TransportEndpoint {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::Release);
        if let Ok(task) = self.accept_task.get_mut()
            && let Some(task) = task.take()
        {
            task.abort();
        }
        let endpoint = self.endpoint.clone();
        RUNTIME.spawn(async move {
            endpoint.close().await;
        });
    }
}

#[derive(uniffi::Object)]
pub struct TransportConnection {
    connection: iroh::endpoint::Connection,
    peer_endpoint_id: String,
    generation: u64,
    stream_limit: Arc<Semaphore>,
    closed: AtomicBool,
}

#[uniffi::export]
impl TransportConnection {
    pub fn peer_endpoint_id(&self) -> String {
        self.peer_endpoint_id.clone()
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn path_summary(&self) -> String {
        format!("{:?}", self.connection.paths())
    }

    pub async fn send_frame(self: Arc<Self>, payload: Vec<u8>) -> Result<Vec<u8>, TransportError> {
        if payload.len() > MAX_FRAME_BYTES {
            return Err(TransportError::message(format!(
                "frame length {} exceeds {MAX_FRAME_BYTES}",
                payload.len()
            )));
        }
        if self.closed.load(Ordering::Acquire) {
            return Err(TransportError::message("connection is closed"));
        }
        let permit = self
            .stream_limit
            .clone()
            .try_acquire_owned()
            .map_err(|_| TransportError::message("eight streams are already active"))?;
        let connection = self.connection.clone();
        on_runtime(async move {
            let _permit = permit;
            let timeout_connection = connection.clone();
            let result = tokio::time::timeout(FRAME_IO_TIMEOUT, async move {
                let (mut send, mut recv) = connection
                    .open_bi()
                    .await
                    .map_err(|error| TransportError::from_display("open stream", error))?;
                write_frame(&mut send, &payload).await?;
                send.finish().map_err(|error| {
                    TransportError::from_display("finish request stream", error)
                })?;
                read_frame_with_limit(&mut recv, MAX_RESPONSE_FRAME_BYTES).await
            })
            .await;
            match result {
                Ok(result) => result,
                Err(_) => {
                    timeout_connection.close(3_u32.into(), b"frame I/O timed out");
                    Err(TransportError::message("frame I/O timed out"))
                }
            }
        })
        .await?
    }

    pub fn close(&self) {
        if !self.closed.swap(true, Ordering::AcqRel) {
            self.connection.close(0_u32.into(), b"closed by Swift");
        }
    }
}

async fn write_frame(
    send: &mut iroh::endpoint::SendStream,
    payload: &[u8],
) -> Result<(), TransportError> {
    write_frame_with_limit(send, payload, MAX_FRAME_BYTES).await
}

async fn write_frame_with_limit(
    send: &mut iroh::endpoint::SendStream,
    payload: &[u8],
    maximum: usize,
) -> Result<(), TransportError> {
    if payload.len() > maximum {
        return Err(TransportError::message(format!(
            "frame length {} exceeds {maximum}",
            payload.len()
        )));
    }
    let length = u32::try_from(payload.len())
        .map_err(|_| TransportError::message("frame length does not fit in four bytes"))?;
    send.write_all(&length.to_be_bytes())
        .await
        .map_err(|error| TransportError::from_display("write frame length", error))?;
    send.write_all(payload)
        .await
        .map_err(|error| TransportError::from_display("write frame body", error))?;
    Ok(())
}

async fn read_frame(recv: &mut iroh::endpoint::RecvStream) -> Result<Vec<u8>, TransportError> {
    read_frame_with_limit(recv, MAX_FRAME_BYTES).await
}

async fn read_frame_with_limit(
    recv: &mut iroh::endpoint::RecvStream,
    maximum: usize,
) -> Result<Vec<u8>, TransportError> {
    let mut prefix = [0_u8; 4];
    recv.read_exact(&mut prefix)
        .await
        .map_err(|error| TransportError::from_display("read frame length", error))?;
    let length = u32::from_be_bytes(prefix) as usize;
    if length > maximum {
        return Err(TransportError::message(format!(
            "declared frame length {length} exceeds {maximum}"
        )));
    }
    let mut payload = vec![0_u8; length];
    recv.read_exact(&mut payload)
        .await
        .map_err(|error| TransportError::from_display("read frame body", error))?;
    Ok(payload)
}

uniffi::setup_scaffolding!();

#[cfg(test)]
mod tests {
    use super::*;

    fn secret(byte: u8) -> Vec<u8> {
        vec![byte; 32]
    }

    #[test]
    fn stable_endpoint_id_comes_only_from_supplied_secret() {
        let first = endpoint_id_for_secret(secret(7)).unwrap();
        let second = endpoint_id_for_secret(secret(7)).unwrap();
        let different = endpoint_id_for_secret(secret(8)).unwrap();
        assert_eq!(first, second);
        assert_ne!(first, different);
    }

    #[test]
    fn rejects_invalid_secret_lengths() {
        assert!(endpoint_id_for_secret(vec![0; 31]).is_err());
        assert!(endpoint_id_for_secret(vec![0; 33]).is_err());
    }

    #[tokio::test]
    async fn loopback_echo_and_limits() {
        let server = start_endpoint(secret(1), REPOPROMPT_ALPN.to_vec(), false, 10)
            .await
            .unwrap();
        let client = start_endpoint(secret(2), REPOPROMPT_ALPN.to_vec(), false, 11)
            .await
            .unwrap();
        // Dropping a cancelled UniFFI-style accept future must abort its runtime task and release
        // the receiver lock so the next accept can proceed.
        assert!(
            tokio::time::timeout(Duration::from_millis(10), server.clone().accept())
                .await
                .is_err()
        );

        let address_json = server.snapshot().unwrap().address_json;
        assert!(
            client
                .clone()
                .connect(address_json.clone(), b"wrong-alpn".to_vec())
                .await
                .is_err()
        );
        let connection = client
            .clone()
            .connect(address_json, REPOPROMPT_ALPN.to_vec())
            .await
            .unwrap();
        let incoming = server.clone().accept().await.unwrap();
        assert_eq!(
            incoming.peer_endpoint_id,
            client.snapshot().unwrap().endpoint_id
        );
        assert_eq!(connection.generation(), 11);

        let payload = b"opaque echo".to_vec();
        assert_eq!(
            connection
                .clone()
                .send_frame(payload.clone())
                .await
                .unwrap(),
            payload
        );
        assert!(
            connection
                .clone()
                .send_frame(vec![0; MAX_FRAME_BYTES + 1])
                .await
                .is_err()
        );

        server.shutdown().await.unwrap();
        let peer_shutdown = tokio::time::timeout(
            Duration::from_secs(2),
            connection.clone().send_frame(b"after shutdown".to_vec()),
        )
        .await
        .expect("peer shutdown error must be bounded");
        assert!(peer_shutdown.is_err());
        connection.close();
        client.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn application_endpoint_surfaces_authenticated_request_and_response() {
        let server = start_application_endpoint(secret(9), REPOPROMPT_ALPN.to_vec(), false, 40)
            .await
            .unwrap();
        let client = start_endpoint(secret(10), REPOPROMPT_ALPN.to_vec(), false, 41)
            .await
            .unwrap();
        let connection = client
            .clone()
            .connect(
                server.snapshot().unwrap().address_json,
                REPOPROMPT_ALPN.to_vec(),
            )
            .await
            .unwrap();
        let payload = b"application request".to_vec();
        let send_task = tokio::spawn({
            let connection = connection.clone();
            let payload = payload.clone();
            async move { connection.send_frame(payload).await }
        });
        let request = server.clone().accept_request().await.unwrap();
        assert_eq!(
            request.peer_endpoint_id(),
            client.snapshot().unwrap().endpoint_id
        );
        assert_eq!(request.payload(), payload);
        request
            .respond(b"application response".to_vec())
            .await
            .unwrap();
        assert_eq!(
            send_task.await.unwrap().unwrap(),
            b"application response".to_vec()
        );
        connection.close();
        client.shutdown().await.unwrap();
        server.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn ten_thousand_framed_messages_do_not_corrupt() {
        let server = start_endpoint(secret(3), REPOPROMPT_ALPN.to_vec(), false, 20)
            .await
            .unwrap();
        let client = start_endpoint(secret(4), REPOPROMPT_ALPN.to_vec(), false, 21)
            .await
            .unwrap();
        let connection = client
            .clone()
            .connect(
                server.snapshot().unwrap().address_json,
                REPOPROMPT_ALPN.to_vec(),
            )
            .await
            .unwrap();
        let _ = server.clone().accept().await.unwrap();

        for sequence in 0_u32..10_000 {
            let payload = sequence.to_be_bytes().repeat(8);
            let echoed = connection
                .clone()
                .send_frame(payload.clone())
                .await
                .unwrap();
            assert_eq!(echoed, payload);
        }

        connection.close();
        client.shutdown().await.unwrap();
        server.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn invalid_addresses_are_bounded_errors() {
        let endpoint = start_endpoint(secret(5), REPOPROMPT_ALPN.to_vec(), false, 30)
            .await
            .unwrap();
        assert!(
            endpoint
                .clone()
                .connect("not-json".to_owned(), REPOPROMPT_ALPN.to_vec())
                .await
                .is_err()
        );
        endpoint.shutdown().await.unwrap();
    }
}
