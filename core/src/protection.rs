//! Crash-recoverable DNS transaction ordering shared by privileged hosts.
//! Hosts persist the supplied journal atomically before executing mutations.
use serde_json::{Value, json};
use std::collections::VecDeque;
#[derive(Default)]
pub struct Protection {
    journal: Value,
    queue: VecDeque<String>,
    pending: Option<Value>,
    sequence: u64,
    phase: String,
    errors: Vec<String>,
    last_stop_reason: Option<String>,
    stop_sequence: u64,
    last_heartbeat: f64,
    verify_failures: u32,
    last_verify: f64,
    restoring: bool,
    protected: Value,
    restore_yaml: Value,
    restore_selection: Value,
}
impl Protection {
    pub fn dispatch(&mut self, r: &Value) -> Result<Value, String> {
        match r["action"].as_str().ok_or("Missing protection action")? {
            "load" => {
                if self.pending.is_some() {
                    return Err("Protection transaction busy".into());
                }
                let journal = &r["journal"];
                if !journal.is_null() && journal["version"] != 1 {
                    return Err("Unknown DNS recovery journal version; retained for recovery by its original helper".into());
                }
                self.journal = journal.clone();
                self.phase = if journal.is_null() {
                    "disabled"
                } else {
                    "restoring"
                }
                .into();
            }
            "enable" => {
                if self.pending.is_some() || !self.journal.is_null() {
                    return Err("Restore existing DNS transaction before enabling".into());
                }
                self.errors.clear();
                self.verify_failures = 0;
                self.restoring = false;
                self.phase = "enabling".into();
                self.last_heartbeat = now(r)?;
                self.queue = VecDeque::from(["preflight".into()]);
            }
            "restore" => {
                if self.pending.is_some() {
                    return Err("Protection transaction busy".into());
                }
                self.errors.clear();
                self.restore();
            }
            "heartbeat" => self.last_heartbeat = now(r)?,
            "watchdog" => {
                if self.pending.is_none() && !self.journal.is_null() {
                    if self.phase != "enabled"
                        || now(r)? - self.last_heartbeat >= 8.
                        || r["ownerAlive"] != true
                    {
                        if self.phase == "enabled" {
                            self.record_stop(if r["ownerAlive"] != true {
                                "启动器已退出".into()
                            } else { "启动器心跳超时".into() });
                        }
                        self.errors.clear();
                        self.restore();
                    } else if now(r)? - self.last_verify >= 5. {
                        self.last_verify = now(r)?;
                        self.queue.push_back("verify".into());
                    }
                }
            }
            "complete" => {
                let effect = self.pending.as_ref().ok_or("No pending DNS effect")?;
                if effect["id"] != r["id"] {
                    return Err("Stale DNS effect response".into());
                }
                let op = effect["op"].as_str().unwrap().to_owned();
                if op == "enabled" {
                    self.last_heartbeat = now(r)?;
                    self.last_verify = now(r)?;
                }
                self.pending = None;
                if let Some(token) = r["nativeState"]["firewallToken"].as_str() {
                    self.journal["firewallToken"] = json!(token);
                }
                if let Some(error) = r["error"].as_str() {
                    if op == "verify" && self.phase == "enabled" && !self.restoring {
                        self.verify_failures += 1;
                        if self.verify_failures >= 2 {
                            self.record_stop(format!("{op}: {error}"));
                            self.errors.push(format!("{op}: {error}"));
                            self.restore();
                        }
                    } else {
                        if !self.restoring { self.record_stop(format!("{op}: {error}")); }
                        self.errors.push(format!("{op}: {error}"));
                        if !self.restoring {
                            self.restore();
                        }
                    }
                } else if let Err(error) = self.completed(&op, &r["value"]) {
                    if !self.restoring { self.record_stop(error.clone()); }
                    self.errors.push(error);
                    if !self.restoring {
                        self.restore();
                    }
                }
            }
            "status" => {}
            _ => return Err("Unknown protection action".into()),
        }
        if self.pending.is_none() {
            if let Some(op) = self.queue.pop_front() {
                self.sequence = self
                    .sequence
                    .checked_add(1)
                    .ok_or("DNS sequence overflow")?;
                self.pending = Some(
                    json!({"id":self.sequence,"op":op,"journal":self.journal,"protectedYAML":self.protected,"restoreYAML":self.restore_yaml,"restoreSelection":self.restore_selection}),
                );
            } else if self.restoring {
                self.phase = if self.journal.is_null() {
                    "disabled"
                } else {
                    "failed"
                }
                .into();
                self.restoring = false;
            }
        }
        Ok(
            json!({"phase":self.phase,"errors":self.errors,"effect":self.pending,"done":self.pending.is_none(),"hasJournal":!self.journal.is_null(),"lastStopReason":self.last_stop_reason,"stopSequence":self.stop_sequence}),
        )
    }
    fn record_stop(&mut self, reason: String) {
        self.last_stop_reason = Some(reason);
        self.stop_sequence = self.stop_sequence.saturating_add(1);
    }
    fn restore(&mut self) {
        self.queue.clear();
        self.restoring = true;
        self.phase = "restoring".into();
        if !self.journal.is_null() {
            self.queue = VecDeque::from(
                [
                    "firewallDisable",
                    "systemDNSRestore",
                    "clashRestorePrepare",
                    "frontendStop",
                    "cacheFlush",
                    "finishRestore",
                ]
                .map(str::to_owned),
            );
        }
    }
    fn completed(&mut self, op: &str, value: &Value) -> Result<(), String> {
        match op {
            "preflight" => {
                if value["snapshot"]["mode"] != "global"
                    || value["snapshot"]["current"].as_str().is_none_or(|n| {
                        ["DIRECT", "REJECT", "PASS"].contains(&n.to_uppercase().as_str())
                    })
                {
                    return Err("DNS 保护要求全局模式并选择真实代理节点".into());
                }
                if value["services"].as_array().is_none_or(Vec::is_empty) {
                    return Err("没有可接管的网络接口".into());
                }
                let original = crate::config::dispatch(
                    &json!({"op":"runtimeYAML","source":value["source"],"general":value["general"]}),
                )?;
                self.protected = crate::config::dispatch(&json!({
                    "op":"protectedYAML", "source":original, "bootstrapRepair":value["bootstrapRepair"]
                }))?;
                let ipv6 = crate::config::dispatch(
                    &json!({"op":"runtimeIPv6","general":value["general"]}),
                )?;
                self.journal = value.clone();
                self.journal["version"] = json!(1);
                self.journal["originalYAML"] = original;
                self.journal["originalIPv6"] = ipv6;
                // Mark intended writes before they occur: a lost acknowledgement must still restore them.
                self.journal["clashChanged"] = json!(true);
                self.journal["ipv4PolicyApplied"] = json!(true);
                self.journal["selectionApplied"] = json!(false);
                self.queue = VecDeque::from(
                    [
                        "persist",
                        "frontendStart",
                        "clashApply",
                        "dnsReady",
                        "systemDNSApply",
                        "firewallEnable",
                        "cacheFlush",
                        "verify",
                        "enabled",
                    ]
                    .map(str::to_owned),
                );
            }
            "firewallEnable" => {
                if let Some(token) = value.get("firewallToken") {
                    self.journal["firewallToken"] = token.clone();
                }
            }
            "clashApply" => {
                self.journal["selectionApplied"] = json!(true);
                self.queue.push_front("persist".into());
            }
            "enabled" => self.phase = "enabled".into(),
            "verify" => {
                self.verify_failures = 0;
                if let Some(additions) = value["newServices"].as_array().filter(|a| !a.is_empty()) {
                    self.journal["services"]
                        .as_array_mut()
                        .ok_or("Missing saved interfaces")?
                        .extend(additions.iter().cloned());
                    for action in ["verify", "systemDNSApply", "persist"] {
                        self.queue.push_front(action.into());
                    }
                }
            }
            "clashRestorePrepare" => {
                if !value.is_null() && self.journal["clashChanged"] == true {
                    self.restore_selection = if self.journal["selectionApplied"] == false {
                        // Reload may have installed temporary defaults before providers
                        // became available. A failed activation must keep its saved node.
                        self.journal["selection"].clone()
                    } else {
                        value["selection"].clone()
                    };
                    let changed = value["sourceChanged"] == true;
                    let source = if changed {
                        &value["source"]
                    } else {
                        &self.journal["originalYAML"]
                    };
                    self.restore_yaml = crate::config::dispatch(
                        &json!({"op":"restoredYAML","source":source,"general":value["general"],"sourceChanged":changed,"originalIPv6":self.journal["originalIPv6"],"ipv4PolicyApplied":self.journal["ipv4PolicyApplied"]}),
                    )?;
                    self.queue.push_front("clashRestoreApply".into());
                }
            }
            "clashRestoreApply" => {
                self.journal["clashChanged"] = json!(false);
                self.journal["ipv4PolicyApplied"] = json!(false);
                self.queue.push_front("persist".into());
            }
            "finishRestore" => {
                if self.errors.is_empty() {
                    self.queue.push_back("removeJournal".into());
                }
            }
            "removeJournal" => self.journal = Value::Null,
            _ => {}
        }
        Ok(())
    }
}
fn now(r: &Value) -> Result<f64, String> {
    r["now"]
        .as_f64()
        .filter(|n| n.is_finite() && *n >= 0.)
        .ok_or("Invalid watchdog clock".into())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn slow_activation_starts_a_fresh_owner_lease() {
        let (mut p, mut state) = prepared();
        while state["done"] != true {
            state = p.dispatch(&json!({"action":"complete","id":state["effect"]["id"],"now":30,"value":null})).unwrap();
        }
        state = p.dispatch(&json!({"action":"watchdog","now":31,"ownerAlive":true})).unwrap();
        assert_eq!(state["phase"], "enabled");
        assert_eq!(state["done"], true);
        state = p.dispatch(&json!({"action":"watchdog","now":38,"ownerAlive":true})).unwrap();
        assert_eq!(state["phase"], "restoring");
        assert_eq!(state["lastStopReason"], "启动器心跳超时");
    }

    #[test]
    fn automatic_restore_keeps_the_trigger_after_recovery_succeeds() {
        let (mut p, mut state) = prepared();
        while state["done"] != true { state = complete(&mut p, &state); }
        for time in [7, 12] {
            p.dispatch(&json!({"action":"heartbeat","now":time})).unwrap();
            state = p.dispatch(&json!({"action":"watchdog","now":time,"ownerAlive":true})).unwrap();
            state = p.dispatch(&json!({"action":"complete","id":state["effect"]["id"],"error":"DNS probe timed out"})).unwrap();
            while state["done"] != true { state = complete(&mut p, &state); }
        }
        state = p.dispatch(&json!({"action":"watchdog","now":13,"ownerAlive":true})).unwrap();
        while state["done"] != true { state = complete(&mut p, &state); }
        assert_eq!(state["phase"], "disabled");
        assert_eq!(state["errors"], json!([]));
        assert_eq!(state["lastStopReason"], "verify: DNS probe timed out");
    }

    #[test]
    fn bootstrap_repair_is_applied_only_to_the_temporary_configuration() {
        let mut p = Protection::default();
        let plain = "mode: global\nipv6: true\ndns:\n  default-nameserver: [223.5.5.5]\n  proxy-server-nameserver: [223.5.5.5]";
        let inspection = crate::config::dispatch(&json!({"op":"bootstrapRepair","source":plain,"saved":"dns: {default-nameserver: [system]}"})).unwrap();
        p.completed("preflight", &json!({
            "source":plain, "general":"ipv6: true", "snapshot":{"mode":"global","current":"node"},
            "services":[{"id":"wifi"}], "bootstrapRepair":inspection["replacements"]
        })).unwrap();
        let parse_dns = |value: &Value| -> Value {
            serde_yaml_ng::from_str::<Value>(value.as_str().unwrap()).unwrap()["dns"].clone()
        };
        for key in ["default-nameserver", "proxy-server-nameserver"] {
            assert_eq!(parse_dns(&p.protected)[key], json!(["https://223.5.5.5/dns-query", "https://1.1.1.1/dns-query"]));
        }
        let mut recovered = Protection::default();
        recovered.dispatch(&json!({"action":"load","journal":p.journal})).unwrap();
        for changed in [false, true] {
            let updated = plain.replace("223.5.5.5", "119.29.29.29");
            recovered.completed("clashRestorePrepare", &json!({
                "sourceChanged":changed, "source":updated, "general":"ipv6: false"
            })).unwrap();
            let expected = if changed { updated.as_str() } else { plain };
            assert_eq!(parse_dns(&recovered.restore_yaml), parse_dns(&json!(expected)));
        }
    }
    #[test]
    fn interrupted_reload_restores_saved_selection_but_enabled_sessions_preserve_user_choice() {
        for applied in [false, true] {
            let (mut p, _) = prepared();
            p.journal["selection"] = json!({"GLOBAL":"original"});
            p.journal["selectionApplied"] = json!(applied);
            p.completed("clashRestorePrepare", &json!({"general":"{\"ipv6\":false}","sourceChanged":false,"selection":{"GLOBAL":"current"}})).unwrap();
            assert_eq!(p.restore_selection["GLOBAL"], if applied {"current"} else {"original"});
        }
    }
    #[test]
    fn unknown_journals_are_never_overwritten() {
        let mut p = Protection::default();
        assert!(
            p.dispatch(&json!({"action":"load","journal":{"version":99}}))
                .is_err()
        );
    }
    #[test]
    fn restore_continues_after_error_and_retains_journal() {
        let mut p = Protection::default();
        p.dispatch(&json!({"action":"load","journal":{"version":1}}))
            .unwrap();
        let mut state = p.dispatch(&json!({"action":"restore"})).unwrap();
        let mut operations = vec![];
        while state["done"] != true {
            let effect = &state["effect"];
            let op = effect["op"].as_str().unwrap();
            operations.push(op.to_owned());
            let request = if op == "systemDNSRestore" {
                json!({"action":"complete","id":effect["id"],"error":"adapter offline"})
            } else {
                json!({"action":"complete","id":effect["id"],"value":null})
            };
            state = p.dispatch(&request).unwrap();
        }
        assert!(operations.contains(&"frontendStop".into()));
        assert!(!operations.contains(&"removeJournal".into()));
        assert_eq!(state["hasJournal"], true);
    }
    fn prepared() -> (Protection, Value) {
        let mut protection = Protection::default();
        let state = protection
            .dispatch(&json!({"action":"enable","now":1}))
            .unwrap();
        let state=protection.dispatch(&json!({"action":"complete","id":state["effect"]["id"],"value":{
            "source":"mode: global\nipv6: true\ndns:\n  enable: true\n  default-nameserver: [https://1.1.1.1/dns-query]\n  proxy-server-nameserver: [https://1.1.1.1/dns-query]\n", "general":"{\"mode\":\"global\",\"ipv6\":true}",
            "snapshot":{"mode":"global","current":"node"},"services":[{"id":"original","Tcpip":""}]
        }})).unwrap();
        (protection, state)
    }
    fn complete(p: &mut Protection, state: &Value) -> Value {
        p.dispatch(&json!({"action":"complete","id":state["effect"]["id"],"now":2,"value":null}))
            .unwrap()
    }
    #[test]
    fn every_activation_failure_retains_recoverable_intent() {
        for failed in [
            "persist",
            "frontendStart",
            "clashApply",
            "dnsReady",
            "systemDNSApply",
            "firewallEnable",
            "cacheFlush",
            "verify",
        ] {
            let (mut p, mut state) = prepared();
            assert_eq!(state["effect"]["op"], "persist");
            assert_eq!(state["effect"]["journal"]["clashChanged"], true);
            while state["effect"]["op"] != failed {
                state = complete(&mut p, &state);
            }
            state=p.dispatch(&json!({"action":"complete","id":state["effect"]["id"],"error":"injected failure"})).unwrap();
            let mut operations = vec![];
            while state["done"] != true {
                operations.push(state["effect"]["op"].as_str().unwrap().to_owned());
                state = complete(&mut p, &state);
            }
            assert!(operations.contains(&"systemDNSRestore".to_owned()));
            assert!(operations.contains(&"firewallDisable".to_owned()));
            assert_eq!(state["hasJournal"], true);
            state = p.dispatch(&json!({"action":"restore"})).unwrap();
            while state["done"] != true {
                state = complete(&mut p, &state);
            }
            assert_eq!(state["phase"], "disabled");
            assert_eq!(state["hasJournal"], false);
        }
    }
    #[test]
    fn watchdog_renews_owner_and_journals_hotplug_before_mutation() {
        let (mut p, mut state) = prepared();
        while state["done"] != true {
            state = complete(&mut p, &state);
        }
        assert_eq!(state["phase"], "enabled");
        p.dispatch(&json!({"action":"heartbeat","now":6})).unwrap();
        state = p
            .dispatch(&json!({"action":"watchdog","now":10,"ownerAlive":true}))
            .unwrap();
        assert_eq!(state["effect"]["op"], "verify");
        state=p.dispatch(&json!({"action":"complete","id":state["effect"]["id"],"value":{"newServices":[{"id":"new"}]}})).unwrap();
        assert_eq!(state["effect"]["op"], "persist");
        assert_eq!(
            state["effect"]["journal"]["services"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        state = complete(&mut p, &state);
        assert_eq!(state["effect"]["op"], "systemDNSApply");
        while state["done"] != true {
            state = complete(&mut p, &state);
        }
        state = p
            .dispatch(&json!({"action":"watchdog","now":14,"ownerAlive":true}))
            .unwrap();
        assert_eq!(state["effect"]["op"], "firewallDisable");
    }
    #[test]
    fn watchdog_requires_two_consecutive_verification_failures() {
        let (mut p, mut state) = prepared();
        while state["done"] != true {
            state = complete(&mut p, &state);
        }
        for (time, fails, phase) in [
            (7, true, "enabled"),
            (12, false, "enabled"),
            (17, true, "enabled"),
            (22, true, "restoring"),
        ] {
            p.dispatch(&json!({"action":"heartbeat","now":time}))
                .unwrap();
            state = p
                .dispatch(&json!({"action":"watchdog","now":time,"ownerAlive":true}))
                .unwrap();
            state=p.dispatch(&json!({"action":"complete","id":state["effect"]["id"],"value":null,"error":if fails{json!("probe failed")}else{Value::Null}})).unwrap();
            assert_eq!(state["phase"], phase);
        }
    }
    #[test]
    fn liveness_checks_do_not_repeat_expensive_network_verification_every_second() {
        let (mut p, mut state) = prepared();
        while state["done"] != true {
            state = complete(&mut p, &state);
        }
        for now in 3..7 {
            state = p
                .dispatch(&json!({"action":"watchdog","now":now,"ownerAlive":true}))
                .unwrap();
            assert_eq!(state["done"], true);
        }
        state = p
            .dispatch(&json!({"action":"watchdog","now":7,"ownerAlive":false}))
            .unwrap();
        assert_eq!(state["effect"]["op"], "firewallDisable");
    }
}
