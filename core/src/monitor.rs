//! Shared observation/recovery policy; platform effects execute outside this reducer.
use serde_json::{Value, json};
#[derive(Default)]
pub struct Monitor {
    failures: u64,
    recovery: bool,
    failed_node: Option<String>,
    round: u64,
    attempt: u32,
}
impl Monitor {
    pub fn dispatch(&mut self, request: &Value) -> Result<Value, String> {
        let mut delay = 2;
        match request["action"].as_str().ok_or("Missing monitor action")? {
            "reset" => *self = Self::default(),
            "observe" => {
                let healthy = request["heartbeat"]["isHealthy"]
                    .as_bool()
                    .ok_or("Missing heartbeat")?;
                let age = request["heartbeat"]["connectionSeconds"]
                    .as_f64()
                    .filter(|n| n.is_finite() && *n >= 0.0)
                    .ok_or("Invalid connection age")?;
                if healthy {
                    if age >= 60.0 {
                        self.failures = 0;
                    }
                } else {
                    self.failures = if age >= 60.0 {
                        0
                    } else {
                        (self.failures + 1).min(2)
                    };
                    delay = 1;
                    if self.failures >= 2 {
                        self.recovery = true;
                        self.failed_node = request["node"].as_str().map(str::to_owned);
                        self.round = 0;
                        self.attempt = 0;
                    }
                }
            }
            "disableRecovery" => self.recovery = false,
            "nextRound" => self.round = self.round.saturating_add(1),
            "retry" => {
                delay = (1u64 << self.attempt.saturating_add(1).min(5)).min(30);
                self.attempt = self.attempt.saturating_add(1);
            }
            "accept" => {
                self.failures = 0;
                self.recovery = false;
                self.round = 0;
                self.attempt = 0;
            }
            _ => return Err("Unknown monitor action".into()),
        }
        Ok(
            json!({"failures":self.failures,"recovery":self.recovery,"failedNode":self.failed_node,"round":self.round,"attempt":self.attempt,"delay":delay}),
        )
    }
}
pub fn candidates(request: &Value) -> Result<Value, String> {
    let current = request["current"].as_str().ok_or("无法解析当前节点")?;
    let origins = request["origins"]
        .as_object()
        .ok_or("Missing subscription origins")?;
    let source = if crate::clash::global_selects_direct(&request["proxies"]) {
        request["activeProfileId"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or("当前订阅不明确，无法从 DIRECT 自动切换")?
    } else {
        if crate::policy::region(current).is_none() {
            return Err("节点订阅或地区不明确，保持原节点".into());
        }
        origins
            .get(current)
            .and_then(Value::as_str)
            .ok_or("节点订阅或地区不明确，保持原节点")?
    };
    let proxies = request["proxies"].as_object().ok_or("Missing proxies")?;
    let names = request["names"].as_array().ok_or("Missing GLOBAL nodes")?;
    let mut sorted = std::collections::BTreeSet::new();
    for name in names {
        if let Some(name) = name.as_str() {
            sorted.insert(name);
        }
    }
    let mut output = serde_json::Map::new();
    for name in sorted {
        let Some(proxy) = proxies.get(name) else {
            continue;
        };
        if !proxy["all"].is_null()
            || ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"]
                .contains(&proxy["type"].as_str().unwrap_or("").to_uppercase().as_str())
            || origins.get(name).and_then(Value::as_str) != Some(source)
        {
            continue;
        }
        if let Some(region) = crate::policy::region(name) {
            output
                .entry(region)
                .or_insert(json!([]))
                .as_array_mut()
                .unwrap()
                .push(json!(name));
        }
    }
    Ok(Value::Object(output))
}
#[cfg(test)]
mod tests {
    use super::*;
    fn observe(m: &mut Monitor, healthy: bool, seconds: f64) -> Value {
        m.dispatch(&json!({"action":"observe","node":"Japan A","heartbeat":{"isHealthy":healthy,"connectionSeconds":seconds}})).unwrap()
    }
    #[test]
    fn direct_uses_active_profile_and_requires_explicit_ownership() {
        let mut r = json!({"current":"DIRECT","activeProfileId":"one",
            "origins":{"日本 A":"one","美国 B":"two","日本直连":"one","香港组":"one"},
            "names":["DIRECT","日本 A","美国 B","未知","日本直连","香港组"],
            "proxies":{"GLOBAL":{"now":"DIRECT"},"DIRECT":{"type":"Direct"},
                "日本 A":{"type":"ss"},"美国 B":{"type":"ss"},"未知":{"type":"ss"},
                "日本直连":{"type":"Direct"},"香港组":{"type":"Selector","all":[]}}});
        assert_eq!(candidates(&r).unwrap(), json!({"JP":["日本 A"]}));
        r["activeProfileId"] = Value::Null;
        assert!(candidates(&r).is_err());
        r["proxies"]["GLOBAL"]["now"] = json!("group");
        r["activeProfileId"] = json!("one");
        assert!(candidates(&r).is_err());
    }

    #[test]
    fn only_two_short_failures_trigger_recovery_and_stability_resets() {
        let mut m = Monitor::default();
        assert_eq!(observe(&mut m, false, 0.0)["failures"], 1);
        assert_eq!(observe(&mut m, true, 59.0)["failures"], 1);
        assert_eq!(observe(&mut m, true, 60.0)["failures"], 0);
        assert_eq!(observe(&mut m, false, 60.0)["failures"], 0);
        observe(&mut m, false, 9.0);
        assert_eq!(observe(&mut m, false, 9.0)["recovery"], true);
        assert_eq!(
            m.dispatch(&json!({"action":"accept"})).unwrap()["recovery"],
            false
        );
    }
    #[test]
    fn retry_sequence_is_bounded() {
        let mut m = Monitor::default();
        for delay in [2, 4, 8, 16, 30, 30, 30] {
            assert_eq!(
                m.dispatch(&json!({"action":"retry"})).unwrap()["delay"],
                delay
            );
        }
    }
    #[test]
    fn candidates_never_cross_subscriptions_or_include_groups() {
        let result=candidates(&json!({"current":"日本 A","origins":{"日本 A":"one","美国 B":"one","日本 C":"two"},"names":["美国 B","日本 C","group"],"proxies":{"美国 B":{"type":"ss"},"日本 C":{"type":"ss"},"group":{"type":"Selector","all":[]}}})).unwrap();
        assert_eq!(result, json!({"US":["美国 B"]}));
    }
}
