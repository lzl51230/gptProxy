//! Shared policy and network implementation. Native hosts own UI and OS permissions.
mod clash;
mod cli;
mod config;
mod dns;
mod dns_packet;
mod firewall;
mod heartbeat;
mod monitor;
mod origins;
mod policy;
mod profile;
mod protection;
mod relay;
mod workflow;
use serde_json::{Value, json};
use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    ptr,
    sync::{Arc, Mutex},
};

pub const ABI_VERSION: u32 = 1;
const MAX_MESSAGE: usize = 4 * 1024 * 1024;

#[repr(C)]
pub struct Buffer {
    pub data: *mut u8,
    pub len: usize,
}
impl Buffer {
    fn from_value(value: Value) -> Self {
        let bytes = serde_json::to_vec(&value)
            .expect("JSON value serialization")
            .into_boxed_slice();
        let len = bytes.len();
        Self {
            data: Box::into_raw(bytes) as *mut u8,
            len,
        }
    }
}

pub struct Engine {
    relay: Mutex<Option<relay::Relay>>,
    dns: Mutex<Option<dns::Frontend>>,
    firewall: Mutex<Option<firewall::Firewall>>,
    heartbeat: Mutex<Option<Arc<heartbeat::Session>>>,
    lines: Mutex<cli::Lines>,
    monitor: Mutex<monitor::Monitor>,
    workflow: Mutex<workflow::Workflow>,
    protection: Mutex<protection::Protection>,
}

#[unsafe(no_mangle)]
pub extern "C" fn cgp_core_abi_version() -> u32 {
    ABI_VERSION
}

#[unsafe(no_mangle)]
pub extern "C" fn cgp_core_create() -> *mut Engine {
    Box::into_raw(Box::new(Engine {
        relay: Mutex::new(None),
        dns: Mutex::new(None),
        firewall: Mutex::new(None),
        heartbeat: Mutex::new(None),
        lines: Mutex::new(cli::Lines::default()),
        monitor: Mutex::new(monitor::Monitor::default()),
        workflow: Mutex::new(workflow::Workflow::default()),
        protection: Mutex::new(protection::Protection::default()),
    }))
}

/// The caller must keep the handle and input alive until this call returns.
/// Calls on one handle are serialized. Destruction requires exclusive ownership.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cgp_core_call(
    engine: *mut Engine,
    input: *const u8,
    len: usize,
) -> Buffer {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<Value, String> {
        if engine.is_null() || input.is_null() || len > MAX_MESSAGE {
            return Err("Invalid handle or message size".into());
        }
        let bytes = unsafe { std::slice::from_raw_parts(input, len) };
        let request: Value = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        let engine = unsafe { &*engine };
        match request["op"].as_str().ok_or("Missing operation")? {
            "firewallStart" => {
                let mut slot = engine
                    .firewall
                    .lock()
                    .map_err(|_| "Firewall engine failed")?;
                if slot.is_none() {
                    *slot = Some(firewall::Firewall::start()?);
                }
                Ok(json!(true))
            }
            "firewallStop" => {
                engine
                    .firewall
                    .lock()
                    .map_err(|_| "Firewall engine failed")?
                    .take();
                Ok(json!(true))
            }
            "dnsQuery" | "dnsValid" | "dnsAssertIPv4" | "dnsProbe" => {
                dns_packet::dispatch(&request)
            }
            "dnsStart" => {
                let mut slot = engine.dns.lock().map_err(|_| "DNS engine failed")?;
                if slot.is_some() {
                    return Err("DNS frontend already started".into());
                }
                let port = request["listenPort"]
                    .as_u64()
                    .filter(|n| *n <= 65535)
                    .ok_or("Invalid DNS listen port")? as u16;
                let upstream = request["upstreamPort"]
                    .as_u64()
                    .filter(|n| *n > 0 && *n <= 65535)
                    .ok_or("Invalid DNS upstream port")? as u16;
                if port != 0 && port == upstream {
                    return Err("DNS forwarding loop".into());
                }
                let frontend = dns::Frontend::start(port, upstream).map_err(|e| e.to_string())?;
                let port = frontend.port;
                *slot = Some(frontend);
                Ok(json!(port))
            }
            "dnsStop" => {
                engine.dns.lock().map_err(|_| "DNS engine failed")?.take();
                Ok(json!(true))
            }
            "installationSpec" => {
                let specs: Value =
                    serde_json::from_str(include_str!("../resources/proxybridge-release.json"))
                        .map_err(|e| e.to_string())?;
                let platform = request["platform"]
                    .as_str()
                    .ok_or("Missing installation platform")?;
                specs
                    .get(platform)
                    .cloned()
                    .ok_or("Unsupported installation platform".into())
            }
            "clashSnapshot" | "clashRequest" | "clashSelections" | "clashSelectionsReady" | "clashConnectionIds" => {
                clash::dispatch(&request)
            }
            "nodeOrigins" => origins::resolve(&request),
            "protection" => engine
                .protection
                .lock()
                .map_err(|_| "Protection state failed")?
                .dispatch(&request),
            "monitorWorkflow" => engine
                .workflow
                .lock()
                .map_err(|_| "Monitor workflow failed")?
                .dispatch(&request),
            "monitor" => engine
                .monitor
                .lock()
                .map_err(|_| "Monitor state failed")?
                .dispatch(&request),
            "monitorCandidates" => monitor::candidates(&request),
            "proxyProfile" | "validateProxyProfile" => profile::dispatch(&request),
            "lineChunk" => engine
                .lines
                .lock()
                .map_err(|_| "CLI decoder failed")?
                .dispatch(&request),
            "cliStatus" => cli::status(&request),
            "cliConsume" => cli::consume(&request),
            "heartbeatOpen" => {
                let mut slot = engine
                    .heartbeat
                    .lock()
                    .map_err(|_| "Heartbeat engine failed")?;
                if slot.is_some() {
                    return Err("Heartbeat already configured".into());
                }
                *slot = Some(Arc::new(
                    heartbeat::Session::new(&request).map_err(|e| e.to_string())?,
                ));
                Ok(json!(true))
            }
            "heartbeat" | "heartbeatCancel" | "heartbeatClose" => {
                let session = engine
                    .heartbeat
                    .lock()
                    .map_err(|_| "Heartbeat engine failed")?
                    .clone();
                if let Some(session) = session {
                    if request["op"] == "heartbeat" {
                        session.heartbeat(match request.get("nowSeconds") {
                            Some(value) => Some(value.as_f64().ok_or("Invalid observation clock")?),
                            None => None,
                        })
                    } else {
                        if request["op"] == "heartbeatClose" {
                            session.close()?;
                            engine
                                .heartbeat
                                .lock()
                                .map_err(|_| "Heartbeat engine failed")?
                                .take();
                        } else {
                            session.cancel();
                        }
                        Ok(json!(true))
                    }
                } else if request["op"] == "heartbeat" {
                    Err("Heartbeat not configured".into())
                } else {
                    Ok(json!(true))
                }
            }
            "probeUDP" => heartbeat::probe_udp(
                request["port"]
                    .as_u64()
                    .filter(|n| *n > 0 && *n <= 65535)
                    .ok_or("Invalid proxy port")? as u16,
            ),
            "relayStart" => {
                let mut slot = engine.relay.lock().map_err(|_| "Engine failed")?;
                if slot.is_some() {
                    return Err("Relay instance already started".into());
                }
                let listen = request["listenPort"]
                    .as_u64()
                    .filter(|n| *n <= 65535)
                    .ok_or("Invalid listen port")? as u16;
                let upstream = request["upstreamPort"]
                    .as_u64()
                    .filter(|n| *n > 0 && *n <= 65535)
                    .ok_or("Invalid upstream port")? as u16;
                let relay = relay::Relay::start(listen, upstream).map_err(|e| e.to_string())?;
                let port = relay.port;
                *slot = Some(relay);
                Ok(json!(port))
            }
            "relayStop" => {
                // Keep the lock until sockets are released so a concurrent start cannot race teardown.
                let mut slot = engine.relay.lock().map_err(|_| "Engine failed")?;
                if let Some(relay) = slot.take() {
                    relay.stop();
                }
                Ok(Value::Null)
            }
            "protectedYAML" | "runtimeYAML" | "runtimeIPv6" | "restoredYAML"
            | "encryptedResolver" => config::dispatch(&request),
            _ => policy::dispatch(&request),
        }
    }));
    Buffer::from_value(match result {
        Ok(Ok(value)) => json!({"ok":true,"value":value}),
        Ok(Err(error)) => json!({"ok":false,"error":error}),
        Err(_) => json!({"ok":false,"error":"Rust core failed"}),
    })
}

/// Free exactly once using the original buffer returned by cgp_core_call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cgp_core_buffer_free(buffer: Buffer) {
    if !buffer.data.is_null() {
        unsafe {
            drop(Box::from_raw(ptr::slice_from_raw_parts_mut(
                buffer.data,
                buffer.len,
            )));
        }
    }
}

/// No call may overlap destruction. All relay sockets are released before returning.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cgp_core_destroy(engine: *mut Engine) {
    if !engine.is_null() {
        unsafe {
            drop(Box::from_raw(engine));
        }
    }
}

#[cfg(test)]
mod ffi_tests {
    use super::*;
    unsafe fn request(handle: *mut Engine, input: &[u8]) -> Value {
        let buffer = unsafe { cgp_core_call(handle, input.as_ptr(), input.len()) };
        let value =
            serde_json::from_slice(unsafe { std::slice::from_raw_parts(buffer.data, buffer.len) })
                .unwrap();
        unsafe {
            cgp_core_buffer_free(buffer);
        }
        value
    }
    #[test]
    fn malformed_messages_remain_errors_and_handle_remains_usable() {
        let handle = cgp_core_create();
        unsafe {
            for input in [
                b"{".as_slice(),
                b"{}",
                b"{\"op\":\"unknown\"}",
                b"{\"op\":\"validatePort\",\"value\":3}",
            ] {
                assert_eq!(request(handle, input)["ok"], false);
            }
            assert_eq!(
                request(handle, br#"{"op":"validatePort","value":"7890"}"#)["value"],
                7890
            );
            cgp_core_destroy(handle);
        }
    }
    #[test]
    fn null_and_oversize_inputs_are_rejected_before_dereference() {
        let handle = cgp_core_create();
        unsafe {
            let buffer = cgp_core_call(handle, ptr::null(), 1);
            cgp_core_buffer_free(buffer);
            let buffer = cgp_core_call(handle, b"x".as_ptr(), MAX_MESSAGE + 1);
            let result: Value =
                serde_json::from_slice(std::slice::from_raw_parts(buffer.data, buffer.len))
                    .unwrap();
            assert_eq!(result["ok"], false);
            cgp_core_buffer_free(buffer);
            cgp_core_destroy(handle);
        }
    }
    #[test]
    fn destroying_engine_releases_running_listener() {
        let handle = cgp_core_create();
        unsafe {
            let result = request(
                handle,
                br#"{"op":"relayStart","listenPort":0,"upstreamPort":7890}"#,
            );
            assert_eq!(result["ok"], true);
            let port = result["value"].as_u64().unwrap() as u16;
            cgp_core_destroy(handle);
            let listener =
                std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port)).unwrap();
            drop(listener);
        }
    }
}
