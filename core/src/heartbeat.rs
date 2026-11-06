//! One SOCKS/TLS socket per observation. No pool, redirect, authentication or retry layer.
use bytes::Bytes;
use http_body_util::{BodyExt, Empty};
use hyper::{Request, client::conn::http1};
use hyper_util::rt::TokioIo;
use serde_json::{Value, json};
use std::{
    sync::{
        Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    runtime::Runtime,
    sync::watch,
};

type Failure = Box<dyn std::error::Error + Send + Sync>;
struct Connection {
    sender: http1::SendRequest<Empty<Bytes>>,
    driver: tokio::task::JoinHandle<()>,
}
impl Drop for Connection {
    fn drop(&mut self) {
        self.driver.abort();
    }
}
struct State {
    connection: Option<Connection>,
    first: Option<f64>,
    last: Option<f64>,
}
pub struct Session {
    state: Mutex<State>,
    runtime: Runtime,
    cancelled: AtomicBool,
    cancellation: watch::Sender<bool>,
    port: u16,
    target: url::Url,
    connector: tokio_native_tls::TlsConnector,
    origin: Instant,
}
impl Session {
    pub fn new(request: &Value) -> Result<Self, Failure> {
        let port = request["port"]
            .as_u64()
            .filter(|n| *n > 0 && *n <= 65535)
            .ok_or("Invalid proxy port")? as u16;
        let target = url::Url::parse(
            request["target"]
                .as_str()
                .unwrap_or("https://chatgpt.com/backend-api/codex/models"),
        )?;
        if target.scheme() != "https"
            || target.host_str().is_none()
            || !target.username().is_empty()
            || target.password().is_some()
            || target.fragment().is_some()
        {
            return Err("Invalid heartbeat URL".into());
        }
        let mut builder = native_tls::TlsConnector::builder();
        if let Some(path) = request["caFile"].as_str() {
            builder.add_root_certificate(native_tls::Certificate::from_pem(&std::fs::read(path)?)?);
        }
        let connector = tokio_native_tls::TlsConnector::from(builder.build()?);
        let (cancellation, _) = watch::channel(false);
        Ok(Self {
            state: Mutex::new(State {
                connection: None,
                first: None,
                last: None,
            }),
            runtime: tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()?,
            cancelled: AtomicBool::new(false),
            cancellation,
            port,
            target,
            connector,
            origin: Instant::now(),
        })
    }
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        self.cancellation.send_replace(true);
    }
    pub fn close(&self) -> Result<(), String> {
        self.cancel();
        let mut state = self.state.lock().map_err(|_| "Heartbeat state failed")?;
        state.connection = None;
        self.runtime.block_on(tokio::task::yield_now());
        Ok(())
    }
    pub fn heartbeat(&self, clock: Option<f64>) -> Result<Value, String> {
        let now = clock.unwrap_or_else(|| self.origin.elapsed().as_secs_f64());
        if !now.is_finite() {
            return Err("Invalid observation clock".into());
        }
        let mut state = self.state.lock().map_err(|_| "Heartbeat state failed")?;
        if self.cancelled.load(Ordering::SeqCst) {
            return Err("cancelled".into());
        }
        let remaining = state.last.map(|last| 10.0 - (now - last)).unwrap_or(10.0);
        let mut cancel = self.cancellation.subscribe();
        let start = Instant::now();
        let result: Result<(), Failure> = if remaining <= 0.0 {
            Err("连续 10 秒未收到有效心跳".into())
        } else {
            self.runtime.block_on(async {
                tokio::select! { biased;
                    _=cancel.changed()=>Err("cancelled".into()),
                    result=tokio::time::timeout(Duration::from_secs_f64(remaining.min(10.0)),self.exchange(&mut state))=>match result { Ok(result)=>result, Err(_)=>Err("连续 10 秒未收到有效心跳".into()) }
                }
            })
        };
        match result {
            Ok(()) => {
                let completed = clock.unwrap_or_else(|| self.origin.elapsed().as_secs_f64());
                let first = *state.first.get_or_insert(completed);
                state.last = Some(completed);
                Ok(
                    json!({"isHealthy":true,"latencyMilliseconds":start.elapsed().as_millis().max(1),"connectionSeconds":(completed-first).max(0.0)}),
                )
            }
            Err(error) => {
                let seconds = state
                    .first
                    .zip(state.last)
                    .map(|(first, last)| (last - first).max(0.0))
                    .unwrap_or(0.0);
                state.connection = None;
                state.first = None;
                state.last = None;
                // Drive the aborted task once so close() has released the physical socket on return.
                self.runtime.block_on(tokio::task::yield_now());
                if self.cancelled.load(Ordering::SeqCst) {
                    return Err("cancelled".into());
                }
                Ok(
                    json!({"isHealthy":false,"connectionSeconds":seconds,"failureReason":error.to_string()}),
                )
            }
        }
    }
    async fn exchange(&self, state: &mut State) -> Result<(), Failure> {
        if state.connection.is_none() {
            let host = self.target.host_str().ok_or("Missing host")?;
            let stream = socks_connect(
                self.port,
                host,
                self.target.port_or_known_default().ok_or("Missing port")?,
            )
            .await?;
            let tls = self.connector.connect(host, stream).await?;
            let (sender, connection) = http1::Builder::new()
                .max_buf_size(32768)
                .handshake(TokioIo::new(tls))
                .await?;
            let driver = tokio::spawn(async move {
                let _ = connection.await;
            });
            state.connection = Some(Connection { sender, driver });
        }
        let mut path = self.target.path().to_string();
        if let Some(query) = self.target.query() {
            path.push('?');
            path.push_str(query);
        }
        let authority = match self.target.port() {
            Some(port) => format!("{}:{port}", self.target.host_str().unwrap()),
            None => self.target.host_str().unwrap().to_owned(),
        };
        let request = Request::builder()
            .method("GET")
            .uri(path)
            .header("Host", authority)
            .header("User-Agent", "ChatGPTProxy-Probe/1.0")
            .body(Empty::<Bytes>::new())?;
        let response = state
            .connection
            .as_mut()
            .unwrap()
            .sender
            .send_request(request)
            .await?;
        let status = response.status().as_u16();
        let closing = response.headers().get_all("connection").iter().any(|v| {
            v.to_str()
                .unwrap_or("")
                .split(',')
                .any(|token| token.trim().eq_ignore_ascii_case("close"))
        });
        let mut body = response.into_body();
        let mut count = 0;
        while let Some(frame) = body.frame().await {
            if let Ok(data) = frame?.into_data() {
                count += data.len();
                if count > 65536 {
                    return Err("Codex 心跳响应超过 64 KiB".into());
                }
            }
        }
        if status != 401 {
            return Err(format!("Codex 心跳返回 HTTP {status}（预期 401）").into());
        }
        if closing {
            return Err("服务端关闭了长连接".into());
        }
        Ok(())
    }
}

pub async fn socks_connect(port: u16, host: &str, target_port: u16) -> Result<TcpStream, Failure> {
    let mut socket = TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, port)).await?;
    greeting(&mut socket).await?;
    let bytes = host.as_bytes();
    if bytes.is_empty() || bytes.len() > 255 {
        return Err("Invalid SOCKS hostname".into());
    }
    let mut request = vec![5, 1, 0, 3, bytes.len() as u8];
    request.extend(bytes);
    request.extend(target_port.to_be_bytes());
    socket.write_all(&request).await?;
    reply(&mut socket).await?;
    Ok(socket)
}
async fn greeting(socket: &mut TcpStream) -> Result<(), Failure> {
    socket.write_all(&[5, 1, 0]).await?;
    let mut response = [0; 2];
    socket.read_exact(&mut response).await?;
    if response != [5, 0] {
        return Err("该端口没有返回有效的 SOCKS5 响应".into());
    }
    Ok(())
}
async fn reply(socket: &mut TcpStream) -> Result<(), Failure> {
    let mut response = [0; 4];
    socket.read_exact(&mut response).await?;
    if response[0] != 5 || response[2] != 0 {
        return Err("Invalid SOCKS5 response".into());
    }
    if response[1] != 0 {
        return Err(format!("SOCKS5 / UDP Associate 被拒绝（错误码 {}）", response[1]).into());
    }
    let count = match response[3] {
        1 => 4,
        4 => 16,
        3 => socket.read_u8().await? as usize,
        _ => return Err("Invalid SOCKS address".into()),
    };
    socket.read_exact(&mut vec![0; count + 2]).await?;
    Ok(())
}
pub fn probe_udp(port: u16) -> Result<Value, String> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;
    runtime.block_on(async {
        tokio::time::timeout(Duration::from_secs(5), async {
            let mut socket = TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, port)).await?;
            greeting(&mut socket).await?;
            socket.write_all(&[5, 3, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
            reply(&mut socket).await?;
            Ok::<_, Failure>(json!(true))
        })
        .await
        .map_err(|_| "UDP Associate 检测超时".to_string())?
        .map_err(|e| e.to_string())
    })
}
