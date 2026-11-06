use std::{
    io,
    net::{Ipv4Addr, SocketAddrV4},
};
use tokio::{
    net::{TcpListener, TcpStream},
    runtime::Runtime,
    sync::oneshot,
    task::JoinSet,
};

pub struct Relay {
    pub port: u16,
    runtime: Runtime,
    stop: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<()>>,
}
impl Relay {
    pub fn start(port: u16, upstream: u16) -> io::Result<Self> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()?;
        let listener = runtime.block_on(TcpListener::bind(SocketAddrV4::new(
            Ipv4Addr::LOCALHOST,
            port,
        )))?;
        let port = listener.local_addr()?.port();
        let (stop, mut stopping) = oneshot::channel();
        let task = runtime.spawn(async move {
            let mut connections = JoinSet::new();
            loop {
                tokio::select! {
                    biased;
                    _ = &mut stopping => break,
                    completed = connections.join_next(), if !connections.is_empty() => { let _ = completed; }
                    accepted = listener.accept() => match accepted {
                        Ok((mut client, _)) => { connections.spawn(async move {
                            if let Ok(mut target) = TcpStream::connect((Ipv4Addr::LOCALHOST, upstream)).await {
                                // copy_bidirectional propagates half closes and waits for both directions.
                                let _ = tokio::io::copy_bidirectional(&mut client, &mut target).await;
                            }
                        }); }
                        Err(_) => break,
                    }
                }
            }
            drop(listener);
            connections.abort_all();
            while connections.join_next().await.is_some() {}
        });
        Ok(Self {
            port,
            runtime,
            stop: Some(stop),
            task: Some(task),
        })
    }
    pub fn stop(mut self) {
        self.shutdown();
    }
    fn shutdown(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(task) = self.task.take() {
            let _ = self.runtime.block_on(task);
        }
    }
}
impl Drop for Relay {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::{Shutdown, TcpListener as Listener, TcpStream as Stream},
        thread,
    };
    #[test]
    fn release_active_sockets_and_port() {
        let upstream = Listener::bind("127.0.0.1:0").unwrap();
        let relay = Relay::start(0, upstream.local_addr().unwrap().port()).unwrap();
        let port = relay.port;
        let client = Stream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
        relay.stop();
        drop(client);
        for _ in 0..100 {
            Relay::start(port, 7890).unwrap().stop();
        }
    }
    #[test]
    fn forward_response_after_write_eof() {
        let upstream = Listener::bind("127.0.0.1:0").unwrap();
        let relay = Relay::start(0, upstream.local_addr().unwrap().port()).unwrap();
        let worker = thread::spawn(move || {
            let (mut socket, _) = upstream.accept().unwrap();
            let mut request = Vec::new();
            socket.read_to_end(&mut request).unwrap();
            assert_eq!(request, b"request");
            socket.write_all(b"response").unwrap();
        });
        let mut client = Stream::connect((Ipv4Addr::LOCALHOST, relay.port)).unwrap();
        client
            .set_read_timeout(Some(std::time::Duration::from_secs(3)))
            .unwrap();
        client.write_all(b"request").unwrap();
        client.shutdown(Shutdown::Write).unwrap();
        let mut response = Vec::new();
        client.read_to_end(&mut response).unwrap();
        assert_eq!(response, b"response");
        worker.join().unwrap();
        relay.stop();
    }
}
