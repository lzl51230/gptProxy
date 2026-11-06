use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    net::{IpAddr, SocketAddr, TcpStream, UdpSocket},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
pub fn query(name: &str, kind: u16, id: u16) -> Result<Vec<u8>, String> {
    let mut bytes = vec![(id >> 8) as u8, id as u8, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0];
    if name.len() > 253 {
        return Err("DNS name too long".into());
    }
    for label in name.trim_end_matches('.').split('.') {
        if label.is_empty() || label.len() > 63 {
            return Err("Invalid DNS label".into());
        }
        bytes.push(label.len() as u8);
        bytes.extend(label.as_bytes());
    }
    bytes.extend([0, (kind >> 8) as u8, kind as u8, 0, 1]);
    Ok(bytes)
}
pub fn valid(a: &[u8], q: &[u8]) -> bool {
    q.len() >= 12
        && a.len() >= q.len()
        && a[..2] == q[..2]
        && a[2] & 0x80 != 0
        && a[2] & 2 == 0
        && [0, 3].contains(&(a[3] & 15))
        && a[4] == 0
        && a[5] == 1
        && a[12..q.len()] == q[12..]
}
fn exchange(q: &[u8], host: &str, port: u16, tcp: bool, seconds: u64) -> Result<Vec<u8>, String> {
    let ip: IpAddr = host.parse().map_err(|_| "DNS probe requires IP literal")?;
    let addr = SocketAddr::new(ip, port);
    let deadline = Duration::from_secs(seconds.clamp(1, 10));
    let result = (|| -> std::io::Result<Vec<u8>> {
        if tcp {
            let mut socket = TcpStream::connect_timeout(&addr, deadline)?;
            socket.set_read_timeout(Some(deadline))?;
            socket.set_write_timeout(Some(deadline))?;
            socket.write_all(&(q.len() as u16).to_be_bytes())?;
            socket.write_all(q)?;
            let mut size = [0; 2];
            socket.read_exact(&mut size)?;
            let mut response = vec![0; u16::from_be_bytes(size) as usize];
            socket.read_exact(&mut response)?;
            Ok(response)
        } else {
            let socket = UdpSocket::bind(if ip.is_ipv6() { "[::]:0" } else { "0.0.0.0:0" })?;
            socket.set_read_timeout(Some(deadline))?;
            socket.set_write_timeout(Some(deadline))?;
            socket.connect(addr)?;
            socket.send(q)?;
            let mut response = vec![0; 65535];
            let size = socket.recv(&mut response)?;
            response.truncate(size);
            Ok(response)
        }
    })()
    .map_err(|e| format!("DNS probe: {e}"))?;
    if !valid(&result, q) {
        return Err("代理内 DNS 返回无效响应".into());
    }
    Ok(result)
}
fn bytes(r: &Value, key: &str) -> Result<Vec<u8>, String> {
    r[key]
        .as_array()
        .ok_or("Missing DNS packet")?
        .iter()
        .map(|v| {
            v.as_u64()
                .filter(|n| *n <= 255)
                .map(|n| n as u8)
                .ok_or("Invalid DNS packet".into())
        })
        .collect()
}
fn ipv4(a: &[u8], q: &[u8], aaaa: &[u8], q6: &[u8]) -> Result<(), String> {
    if !valid(a, q) || a[3] & 15 != 0 || u16::from_be_bytes([a[6], a[7]]) == 0 {
        return Err("代理内 IPv4 DNS 解析不可用".into());
    }
    if !valid(aaaa, q6) || aaaa[3] & 15 != 0 || aaaa[6] != 0 || aaaa[7] != 0 {
        return Err("DNS 仍返回 AAAA 或查询失败，IPv4 保护未生效".into());
    }
    Ok(())
}
pub fn dispatch(r: &Value) -> Result<Value, String> {
    let id = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos() as u16;
    match r["op"].as_str().unwrap_or("") {
        "dnsQuery" => Ok(json!(query(
            r["name"].as_str().ok_or("Missing DNS name")?,
            r["type"].as_u64().unwrap_or(1) as u16,
            r["id"].as_u64().unwrap_or(id as u64) as u16
        )?)),
        "dnsValid" => Ok(json!(valid(&bytes(r, "response")?, &bytes(r, "query")?))),
        "dnsAssertIPv4" => {
            ipv4(
                &bytes(r, "a")?,
                &bytes(r, "aQuery")?,
                &bytes(r, "aaaa")?,
                &bytes(r, "aaaaQuery")?,
            )?;
            Ok(json!(true))
        }
        "dnsProbe" => {
            let port = r["port"]
                .as_u64()
                .filter(|n| *n > 0 && *n <= 65535)
                .ok_or("Invalid DNS port")? as u16;
            let host = r["host"].as_str().unwrap_or("127.0.0.1");
            let tcp = r["tcp"] == true;
            let seconds = r["timeout"].as_u64().unwrap_or(3);
            if r["ipv4Only"] == true {
                let q = query("one.one.one.one", 1, id)?;
                let q6 = query("one.one.one.one", 28, id.wrapping_add(1))?;
                ipv4(
                    &exchange(&q, host, port, tcp, seconds)?,
                    &q,
                    &exchange(&q6, host, port, tcp, seconds)?,
                    &q6,
                )?;
            } else {
                let q = query(&format!("gptproxy-{id}.example.com"), 1, id)?;
                exchange(&q, host, port, tcp, seconds)?;
            }
            Ok(json!(true))
        }
        _ => Err("Unknown DNS operation".into()),
    }
}
