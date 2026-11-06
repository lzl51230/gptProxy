use serde_json::{Value, json};
use std::collections::BTreeSet;
pub const PROXY_PORT: u16 = 7890;
pub const RELAY_PORT: u16 = 17890;
pub const DNS_PORT: u16 = 17853;
pub const THRESHOLD: i64 = 800;
const ALIASES: &[(&str, &[&str])] = &[
    ("TW", &["台湾", "台灣", "taiwan"]),
    ("HK", &["香港", "hong kong", "hongkong"]),
    ("MO", &["澳门", "澳門", "macau", "macao"]),
    ("JP", &["日本", "japan"]),
    ("SG", &["新加坡", "singapore"]),
    ("US", &["美国", "美國", "united states", "usa"]),
    ("GB", &["英国", "英國", "united kingdom", "britain"]),
    ("KR", &["韩国", "韓國", "korea"]),
    ("DE", &["德国", "德國", "germany"]),
    ("FR", &["法国", "法國", "france"]),
    ("CA", &["加拿大", "canada"]),
    ("AU", &["澳大利亚", "澳洲", "australia"]),
    ("CN", &["中国", "中國", "china"]),
    ("IN", &["印度", "india"]),
    ("NL", &["荷兰", "荷蘭", "netherlands"]),
    ("RU", &["俄罗斯", "俄羅斯", "russia"]),
];
pub fn region(name: &str) -> Option<String> {
    let lower = name.to_lowercase();
    let matches: Vec<_> = ALIASES
        .iter()
        .filter(|(_, aliases)| aliases.iter().any(|a| lower.contains(a)))
        .collect();
    if matches.len() == 1 {
        return Some(matches[0].0.to_owned());
    }
    if matches.len() > 1 {
        return None;
    }
    let mut flags = BTreeSet::new();
    let mut chars = name.chars().peekable();
    while let Some(first) = chars.next() {
        if (0x1f1e6..=0x1f1ff).contains(&(first as u32)) {
            if let Some(second) = chars.next_if(|c| (0x1f1e6..=0x1f1ff).contains(&(*c as u32))) {
                flags.insert(
                    [first, second]
                        .iter()
                        .map(|c| char::from_u32(*c as u32 - 0x1f1e6 + 65).unwrap())
                        .collect::<String>(),
                );
            }
        }
    }
    if flags.len() == 1 {
        flags.into_iter().next()
    } else {
        None
    }
}
pub fn dispatch(request: &Value) -> Result<Value, String> {
    Ok(match request["op"].as_str().ok_or("Missing operation")? {
        "constants" => {
            json!({"proxyPort":PROXY_PORT,"relayPort":RELAY_PORT,"dnsPort":DNS_PORT,"threshold":THRESHOLD})
        }
        "validatePort" => {
            let text = request["value"].as_str().ok_or("Port must be a string")?;
            // Swift UInt16 accepts a leading plus; retain that compatibility.
            let port: u16 = text.parse().map_err(|_| "Invalid proxy port")?;
            if [0, 53, RELAY_PORT, DNS_PORT].contains(&port) {
                return Err("Invalid proxy port".into());
            }
            json!(port)
        }
        "region" => json!(region(request["name"].as_str().ok_or("Missing node name")?)),
        "winner" => {
            let delays = request["delays"].as_object().ok_or("Missing delays")?;
            let current = request["current"].as_str().unwrap_or("");
            let mut candidates: Vec<_> = delays
                .iter()
                .filter_map(|(name, delay)| {
                    delay
                        .as_i64()
                        .filter(|n| (1..=THRESHOLD).contains(n))
                        .map(|n| (n, name != current, name))
                })
                .collect();
            candidates.sort();
            json!(candidates.first().map(|(_, _, name)| *name))
        }
        "launchEnvironment" => {
            let mut env = request["environment"]
                .as_object()
                .ok_or("Missing environment")?
                .clone();
            for key in [
                "HTTP_PROXY",
                "HTTPS_PROXY",
                "ALL_PROXY",
                "http_proxy",
                "https_proxy",
                "all_proxy",
            ] {
                env.insert(
                    key.into(),
                    json!(format!("socks5h://127.0.0.1:{RELAY_PORT}")),
                );
            }
            for key in ["NO_PROXY", "no_proxy"] {
                env.insert(key.into(), json!("localhost,127.0.0.1,::1,192.168.0.0/16"));
            }
            json!(env)
        }
        _ => return Err("Unknown operation".into()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn region_precedence_and_ambiguity() {
        assert_eq!(region("🇭🇰 日本 01").as_deref(), Some("JP"));
        assert_eq!(region("🇺🇸 node").as_deref(), Some("US"));
        assert_eq!(region("日本 美国"), None);
        assert_eq!(region("🇺🇸🇯🇵"), None);
        assert_eq!(region("unknown"), None);
    }
    #[test]
    fn port_boundaries() {
        for port in ["0", "53", "17853", "17890", "65536", "-1", " 80", ""] {
            assert!(dispatch(&json!({"op":"validatePort","value":port})).is_err());
        }
        for port in ["1", "7890", "65535"] {
            assert!(dispatch(&json!({"op":"validatePort","value":port})).is_ok());
        }
    }
    #[test]
    fn selection_limits_and_ties() {
        let request =
            json!({"op":"winner","current":"b","delays":{"a":800,"b":800,"c":801,"d":0,"e":-1}});
        assert_eq!(dispatch(&request).unwrap(), "b");
        assert_eq!(
            dispatch(&json!({"op":"winner","current":"none","delays":{"a":800,"b":800}})).unwrap(),
            "a"
        );
    }
    #[test]
    fn environment_preserves_unrelated_and_replaces_bypass() {
        let result = dispatch(&json!({"op":"launchEnvironment","environment":{"PATH":"kept","NO_PROXY":"*","HTTPS_PROXY":"old"}})).unwrap();
        assert_eq!(result["PATH"], "kept");
        assert_eq!(result["HTTPS_PROXY"], "socks5h://127.0.0.1:17890");
        assert_eq!(result["NO_PROXY"], "localhost,127.0.0.1,::1,192.168.0.0/16");
    }
}
