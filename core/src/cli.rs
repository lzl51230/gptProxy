use serde_json::{Value, json};

pub fn consume(request: &Value) -> Result<Value, String> {
    let mut state = request["state"]
        .as_object()
        .ok_or("Missing CLI state")?
        .clone();
    let line = request["line"].as_str().ok_or("Missing CLI line")?;
    let windows = request["platform"] == "windows";
    if windows {
        // Windows 4.1.1's CLI banner still reports 4.1.0. Installation identity is
        // validated separately; readiness depends on successful rule registration.
        if line.contains("3 added, 0 failed") {
            state.insert("profileApplied".into(), json!(true));
        }
        if line == "ProxyBridge is running. Press Ctrl+C to stop." {
            state.insert("redirecting".into(), json!(true));
        }
        if line.contains("WARNING: Failed to add rule") || line.contains("fall back") {
            state.insert("failure".into(), json!(line));
        }
    } else {
        if line == "ProxyBridge CLI 4.1.1" {
            state.insert("versionMatches".into(), json!(true));
        }
        if line == "Profile \"ChatGPT Only\": 1 proxies, 3 rules applied" {
            state.insert("profileApplied".into(), json!(true));
        }
        if line == "Redirecting traffic. Press Ctrl+C to stop." {
            state.insert("redirecting".into(), json!(true));
        }
        if line == "DNS proxy: off (host name rules and send hostname do not work)" {
            state.insert("dnsDisabled".into(), json!(true));
        }
        if line.contains("waiting for your approval") {
            state.insert("waitingForApproval".into(), json!(true));
        }
    }
    if line.starts_with("ERROR:")
        || line.contains("rule(s) were rejected")
        || line.contains("will go direct")
        || line.contains("Could not switch the DNS proxy off")
    {
        state.insert("failure".into(), json!(line));
    }
    Ok(Value::Object(state))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn readiness_cannot_survive_runtime_error() {
        let result=consume(&json!({"op":"cliConsume","state":{"redirecting":true,"profileApplied":true},"line":"ERROR: engine stopped","platform":"macos"})).unwrap();
        assert_eq!(result["failure"], "ERROR: engine stopped");
    }
    #[test]
    fn windows_partial_rules_are_not_ready() {
        let result =
            consume(&json!({"state":{},"line":"2 added, 1 failed","platform":"windows"})).unwrap();
        assert_ne!(result["profileApplied"], true);
    }
}

#[derive(Default)]
pub struct Lines {
    bytes: Vec<u8>,
    discarding: bool,
}
impl Lines {
    pub fn consume(&mut self, input: &[u8], finish: bool) -> Vec<String> {
        let mut output = Vec::new();
        for &byte in input {
            if byte == b'\n' {
                if !self.discarding {
                    output.push(String::from_utf8_lossy(&self.bytes).trim().to_owned());
                }
                self.bytes.clear();
                self.discarding = false;
            } else if !self.discarding {
                if self.bytes.len() == 65536 {
                    self.bytes.clear();
                    self.discarding = true;
                    output.push("ERROR: CLI 输出行过长。".into());
                } else {
                    self.bytes.push(byte);
                }
            }
        }
        if finish {
            if !self.discarding && !self.bytes.is_empty() {
                output.push(String::from_utf8_lossy(&self.bytes).trim().to_owned());
            }
            self.bytes.clear();
            self.discarding = false;
        }
        output
    }
    pub fn dispatch(&mut self, r: &Value) -> Result<Value, String> {
        let input: Vec<u8> = r["bytes"]
            .as_array()
            .ok_or("Missing CLI bytes")?
            .iter()
            .map(|n| {
                n.as_u64()
                    .filter(|n| *n <= 255)
                    .map(|n| n as u8)
                    .ok_or("Invalid CLI byte")
            })
            .collect::<Result<_, _>>()?;
        if input.len() > 65536 {
            return Err("CLI chunk too large".into());
        }
        let lines = self.consume(&input, r["finish"] == true);
        Ok(json!({"lines":lines,"bufferedBytes":self.bytes.len()}))
    }
}

pub fn status(r: &Value) -> Result<Value, String> {
    let state = &r["state"];
    let ready = state["failure"].is_null()
        && state["profileApplied"] == true
        && state["redirecting"] == true
        && (r["platform"] == "windows"
            || state["versionMatches"] == true && state["dnsDisabled"] == true);
    let failure = state["failure"].as_str().map(str::to_owned).or_else(|| {
        if r["alive"] == false {
            Some(format!(
                "ProxyBridge CLI 已退出（{}）",
                r["exitCode"].as_i64().unwrap_or(-1)
            ))
        } else if !ready
            && r["elapsed"].as_f64().unwrap_or(0.) >= r["timeout"].as_f64().unwrap_or(330.)
        {
            Some("ProxyBridge CLI 启动超时，请检查组件状态及网络扩展授权。".into())
        } else {
            None
        }
    });
    let phase = if failure.is_some() {
        "failed"
    } else if ready {
        "running"
    } else if state["waitingForApproval"] == true {
        "waitingForApproval"
    } else {
        "starting"
    };
    Ok(json!({"phase":phase,"ready":ready&&failure.is_none(),"failure":failure}))
}
