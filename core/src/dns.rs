//! Loopback-only dual-stack DNS transport. Each UDP query owns its upstream socket.
use std::{io, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream, UdpSocket},
    runtime::Runtime,
    sync::{Semaphore, oneshot},
    task::JoinSet,
    time::{Instant, timeout},
};

pub struct Frontend {
    pub port: u16,
    runtime: Runtime,
    stop: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<()>>,
}
impl Frontend {
    pub fn start(port: u16, upstream: u16) -> io::Result<Self> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()?;
        let (u4, u6, t4, t6, port) = runtime.block_on(async {
            let u4 = UdpSocket::bind(("127.0.0.1", port)).await?;
            let port = u4.local_addr()?.port();
            let u6 = UdpSocket::bind(("::1", port)).await?;
            let t4 = TcpListener::bind(("127.0.0.1", port)).await?;
            let t6 = TcpListener::bind(("::1", port)).await?;
            Ok::<_, io::Error>((u4, u6, t4, t6, port))
        })?;
        let (stop, mut stopping) = oneshot::channel();
        let task = runtime.spawn(async move {
            let mut listeners = JoinSet::new();
            let udp_limit = Arc::new(Semaphore::new(256));
            let tcp_limit = Arc::new(Semaphore::new(256));
            for socket in [u4, u6] {
                listeners.spawn(udp(socket, upstream, udp_limit.clone()));
            }
            for socket in [t4, t6] {
                listeners.spawn(tcp(socket, upstream, tcp_limit.clone()));
            }
            tokio::select! { _=&mut stopping=>{}, _=listeners.join_next()=>{} }
            listeners.abort_all();
            while listeners.join_next().await.is_some() {}
        });
        Ok(Self {
            port,
            runtime,
            stop: Some(stop),
            task: Some(task),
        })
    }
}
impl Drop for Frontend {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(task) = self.task.take() {
            let _ = self.runtime.block_on(task);
        }
        // Runtime destruction also joins any children aborted with their listener.
    }
}
async fn udp(socket: UdpSocket, upstream: u16, limit: Arc<Semaphore>) {
    let socket = Arc::new(socket);
    let mut pending = JoinSet::new();
    let mut bytes = vec![0; 65535];
    loop {
        tokio::select! {
            _=pending.join_next(), if !pending.is_empty()=>{},
            received=socket.recv_from(&mut bytes)=>{
                let (size,peer)=match received {
                    Ok(datagram)=>datagram,
                    // Windows reports an ICMP port-unreachable from a client that
                    // closed before our reply as WSAECONNRESET on the listener.
                    // It describes that datagram, not the listening socket.
                    Err(error) if matches!(error.kind(),io::ErrorKind::ConnectionReset|io::ErrorKind::ConnectionRefused|io::ErrorKind::Interrupted)=>continue,
                    Err(_)=>break,
                };
                if size<12 || !peer.ip().is_loopback() {continue}
                let Ok(permit)=limit.clone().try_acquire_owned() else {continue};
                let query=bytes[..size].to_vec(); let socket=socket.clone();
                pending.spawn(async move {
                    let _permit=permit;
                    let _=timeout(Duration::from_secs(5),async {
                        let target=UdpSocket::bind(("127.0.0.1",0)).await?;
                        target.connect(("127.0.0.1",upstream)).await?;
                        target.send(&query).await?;
                        let mut response=vec![0;65535];
                        let count=target.recv(&mut response).await?;
                        if count>=12 && response[..2]==query[..2] && response[2]&0x80!=0 {
                            socket.send_to(&response[..count],peer).await?;
                        }
                        Ok::<_,io::Error>(())
                    }).await;
                });
            }
        }
    }
}
async fn tcp(listener: TcpListener, upstream: u16, limit: Arc<Semaphore>) {
    let mut pending = JoinSet::new();
    loop {
        tokio::select! {
            _=pending.join_next(), if !pending.is_empty()=>{},
            accepted=listener.accept()=>{
                let Ok((client,peer))=accepted else {break};
                if !peer.ip().is_loopback() {continue}
                let Ok(permit)=limit.clone().try_acquire_owned() else {continue};
                pending.spawn(async move {
                    let _permit=permit;
                    let Ok(Ok(target))=timeout(Duration::from_secs(5),TcpStream::connect(("127.0.0.1",upstream))).await else {return};
                    let (cr,cw)=client.into_split(); let (tr,tw)=target.into_split();
                    let activity=Arc::new(std::sync::Mutex::new(Instant::now()));
                    let idle=async {
                        loop {tokio::time::sleep(Duration::from_secs(5)).await;
                            if activity.lock().unwrap().elapsed()>=Duration::from_secs(30) {break}
                        }
                    };
                    tokio::select! {
                        _=async {let _=tokio::try_join!(copy(cr,tw,activity.clone()),copy(tr,cw,activity.clone()));}=>{},
                        _=idle=>{}
                    }
                });
            }
        }
    }
}
async fn copy(
    mut from: tokio::net::tcp::OwnedReadHalf,
    mut to: tokio::net::tcp::OwnedWriteHalf,
    activity: Arc<std::sync::Mutex<Instant>>,
) -> io::Result<()> {
    let mut bytes = vec![0; 65536];
    loop {
        let count = from.read(&mut bytes).await?;
        if count == 0 {
            return to.shutdown().await;
        }
        *activity.lock().unwrap() = Instant::now();
        to.write_all(&bytes[..count]).await?;
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dual_stack_ports_are_released_and_partial_bind_rolls_back() {
        let frontend = Frontend::start(0, 17853).unwrap();
        let port = frontend.port;
        assert!(Frontend::start(port, 17853).is_err());
        drop(frontend);
        drop(Frontend::start(port, 17853).unwrap());
        let occupied = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = occupied.local_addr().unwrap().port();
        assert!(Frontend::start(port, 17853).is_err());
        assert!(std::net::UdpSocket::bind(("127.0.0.1", port)).is_ok());
    }
}
