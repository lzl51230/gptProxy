//! Mihomo protocol semantics; hosts only transport HTTP over their native socket.
use serde_json::{Value, json};
use std::collections::BTreeSet;
fn encoded(value: &str) -> String {
    value
        .as_bytes()
        .iter()
        .map(|b| {
            if b.is_ascii_alphanumeric() || *b == b'-' {
                (*b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}
/// Only a direct GLOBAL selection opts into immediate recovery.
pub fn global_selects_direct(proxies: &Value) -> bool {
    proxies["GLOBAL"]["now"]
        .as_str()
        .is_some_and(|n| n.eq_ignore_ascii_case("DIRECT"))
}
pub fn dispatch(r: &Value) -> Result<Value, String> {
    match r["op"].as_str().unwrap_or("") {
        "clashSnapshot" => {
            let proxies = &r["proxies"];
            let mut current = Some("GLOBAL".to_string());
            let mut selection = serde_json::Map::new();
            let mut seen = BTreeSet::new();
            while let Some(name) = current.clone() {
                if !seen.insert(name.clone()) || proxies.get(&name).is_none() {
                    current = None;
                    break;
                }
                if proxies[&name]["all"].is_null() {
                    break;
                }
                current = proxies[&name]["now"].as_str().map(str::to_owned);
                if let Some(next) = &current {
                    selection.insert(name, json!(next));
                }
            }
            Ok(json!({"current":current,"selection":selection}))
        }
        "clashRequest" => {
            let operation = r["command"].as_str().ok_or("Missing Clash command")?;
            let mut body = Value::Null;
            let mut method = "GET";
            let path = match operation {
                "version" => "/version".into(),
                "configs" => "/configs".into(),
                "proxies" => "/proxies".into(),
                "connections" => "/connections".into(),
                "delay" => format!(
                    "/proxies/{}/delay?url={}&timeout=10000&expected=401",
                    encoded(r["name"].as_str().ok_or("Missing node")?),
                    encoded("https://chatgpt.com/backend-api/codex/models")
                ),
                "select" => {
                    method = "PUT";
                    body = json!({"name":r["name"].as_str().ok_or("Missing node")?});
                    format!(
                        "/proxies/{}",
                        encoded(r["group"].as_str().unwrap_or("GLOBAL"))
                    )
                }
                "close" => {
                    method = "DELETE";
                    format!(
                        "/connections/{}",
                        encoded(r["id"].as_str().ok_or("Missing connection ID")?)
                    )
                }
                "closeAll" => {
                    method = "DELETE";
                    "/connections".into()
                }
                "reload" => {
                    method = "PUT";
                    body = json!({"payload":r["yaml"].as_str().ok_or("Missing runtime configuration")?});
                    "/configs?force=false".into()
                }
                "flushDNS" => {
                    method = "POST";
                    "/cache/dns/flush".into()
                }
                _ => return Err("Unsupported Clash command".into()),
            };
            Ok(
                json!({"method":method,"path":path,"body":body,"timeout":if operation=="delay"{12}else if operation=="reload"{10}else{2}}),
            )
        }
        "clashSelections" => {
            let mut selection = serde_json::Map::new();
            for (name, p) in r["proxies"].as_object().ok_or("Missing Clash proxies")? {
                if p["type"]
                    .as_str()
                    .is_some_and(|t| t.eq_ignore_ascii_case("selector"))
                {
                    if let Some(now) = p["now"].as_str() {
                        selection.insert(name.clone(), json!(now));
                    }
                }
            }
            Ok(Value::Object(selection))
        }
        "clashSelectionsReady" => {
            let desired = r["selection"].as_object().ok_or("Missing saved selections")?;
            let proxies = r["proxies"].as_object().ok_or("Missing Clash proxies")?;
            // A successful reload can precede asynchronous provider initialization.
            // Do not replace a saved node with the selector's temporary default.
            Ok(json!(desired.iter().all(|(group, node)| {
                node.is_string() && proxies.get(group).is_some_and(|proxy| {
                    proxy["type"].as_str().is_some_and(|t| t.eq_ignore_ascii_case("selector"))
                        && proxy["all"].as_array().is_some_and(|nodes| nodes.contains(node))
                        && proxies.contains_key(node.as_str().unwrap())
                })
            })))
        }
        "clashConnectionIds" => {
            let node = r["node"].as_str();
            let ids: Vec<_> = r["connections"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|c| {
                    if r["dns"] == true {
                        return c["chains"]
                            .as_array()
                            .is_some_and(|a| a.contains(&json!("GLOBAL")))
                            && ["1.1.1.1", "8.8.8.8"]
                                .contains(&c["metadata"]["destinationIP"].as_str().unwrap_or(""))
                            && (c["metadata"]["destinationPort"].as_str() == Some("443")
                                || c["metadata"]["destinationPort"].as_u64() == Some(443));
                    }
                    c["chains"].as_array().is_some_and(|chains| {
                        chains.contains(&json!("GLOBAL"))
                            && node.is_some_and(|n| chains.contains(&json!(n)))
                    })
                })
                .filter_map(|c| c["id"].as_str())
                .collect();
            Ok(json!(ids))
        }
        _ => Err("Unsupported Clash operation".into()),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_literal_global_direct_selection_triggers() {
        for name in ["DIRECT", "direct", "DiReCt"] {
            assert!(global_selects_direct(&json!({"GLOBAL":{"now":name}})));
        }
        for proxies in [
            json!({}),
            json!({"GLOBAL":{"now":"group"},"group":{"now":"DIRECT","all":["DIRECT"]}}),
            json!({"GLOBAL":{"now":"自定义直连"},"自定义直连":{"type":"Direct"}}),
            json!({"GLOBAL":{"now":"DIRECT-US"}}),
        ] {
            assert!(!global_selects_direct(&proxies));
        }
    }

    #[test]
    fn restoring_selection_waits_for_provider_nodes_after_reload() {
        let selection = json!({"GLOBAL":"provider-node"});
        for proxies in [
            json!({}),
            json!({"GLOBAL":{"type":"Selector","all":["DIRECT"]}}),
            json!({"GLOBAL":{"type":"Selector","all":["provider-node"]}}),
        ] {
            assert_eq!(dispatch(&json!({"op":"clashSelectionsReady","selection":selection,"proxies":proxies})).unwrap(), false);
        }
        assert_eq!(dispatch(&json!({"op":"clashSelectionsReady","selection":selection,"proxies":{
            "GLOBAL":{"type":"Selector","all":["provider-node"]},"provider-node":{"type":"Shadowsocks"}
        }})).unwrap(), true);
    }
    #[test]
    fn cyclic_and_missing_groups_are_not_real_nodes() {
        for proxies in [
            json!({"GLOBAL":{"all":[],"now":"GLOBAL"}}),
            json!({"GLOBAL":{"all":[],"now":"missing"}}),
        ] {
            assert!(
                dispatch(&json!({"op":"clashSnapshot","proxies":proxies})).unwrap()["current"]
                    .is_null()
            );
        }
    }
    #[test]
    fn connection_identifiers_keep_literal_hyphens() {
        assert_eq!(
            dispatch(&json!({"op":"clashRequest","command":"close","id":"abc-def"})).unwrap()["path"],
            "/connections/abc-def"
        );
    }
}
