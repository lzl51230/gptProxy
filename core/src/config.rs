use serde_json::{Value, json};
use std::net::{IpAddr, Ipv4Addr};

fn yaml(text: &Value) -> Result<Value, String> {
    let text = text
        .as_str()
        .ok_or("Missing YAML")?
        .trim_start_matches('\u{feff}');
    let value: Value = serde_yaml_ng::from_str(text).map_err(|e| format!("配置解析失败：{e}"))?;
    if !value.is_object() {
        return Err("配置必须为映射".into());
    }
    Ok(value)
}
fn serialize(value: &Value) -> Result<Value, String> {
    serde_yaml_ng::to_string(value)
        .map(|s| json!(s))
        .map_err(|e| e.to_string())
}
fn encrypted(value: &str, literal: bool) -> bool {
    let Ok(url) = url::Url::parse(value) else {
        return false;
    };
    if !["https", "tls"].contains(&url.scheme())
        || url.fragment().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return false;
    }
    let Some(host) = url.host_str() else {
        return false;
    };
    let host = host.trim_matches(['[', ']']);
    if matches!(host.parse::<IpAddr>(), Ok(IpAddr::V6(_))) {
        return false;
    }
    if literal {
        host.parse::<Ipv4Addr>().is_ok()
    } else {
        !["localhost", "127.0.0.1"].contains(&host)
    }
}
fn merge(source: &Value, general: &Value) -> Result<Value, String> {
    let mut config = yaml(source)?;
    let live = yaml(general)?;
    for key in [
        "mode",
        "log-level",
        "ipv6",
        "allow-lan",
        "bind-address",
        "port",
        "socks-port",
        "mixed-port",
        "redir-port",
        "tproxy-port",
        "tun",
    ] {
        if let Some(value) = live.get(key).filter(|v| !v.is_null()) {
            config[key] = value.clone();
        }
    }
    Ok(config)
}
pub fn dispatch(request: &Value) -> Result<Value, String> {
    match request["op"].as_str().unwrap_or("") {
        "encryptedResolver" => Ok(json!(encrypted(
            request["value"].as_str().ok_or("Missing resolver")?,
            request["requiresIP"].as_bool().unwrap_or(false)
        ))),
        "runtimeIPv6" => yaml(&request["general"])?["ipv6"]
            .as_bool()
            .map(|b| json!(b))
            .ok_or("无法确认 Clash 的 IPv6 设置".into()),
        "runtimeYAML" => serialize(&merge(&request["source"], &request["general"])?),
        "restoredYAML" => {
            let mut config = merge(&request["source"], &request["general"])?;
            if request["ipv4PolicyApplied"] == true {
                if request["sourceChanged"] == true {
                    let baseline = yaml(&request["source"])?;
                    if let Some(v) = baseline.get("ipv6") {
                        config["ipv6"] = v.clone();
                    } else {
                        config.as_object_mut().unwrap().remove("ipv6");
                    }
                } else {
                    let live = yaml(&request["general"])?["ipv6"]
                        .as_bool()
                        .ok_or("无法确认 Clash 的 IPv6 设置")?;
                    if !live {
                        if let Some(original) = request["originalIPv6"].as_bool() {
                            config["ipv6"] = json!(original);
                        }
                    }
                }
            }
            serialize(&config)
        }
        "protectedYAML" => {
            let mut config = yaml(&request["source"])?;
            if !config["dns"].is_object() {
                return Err("Clash 配置缺少 DNS 设置".into());
            }
            if config["mode"].as_str().unwrap_or("").to_lowercase() != "global"
                || config["tun"]["enable"] == true
            {
                return Err("DNS 保护要求 Clash Party 全局模式，并关闭 TUN，避免重复接管".into());
            }
            for (key, literal) in [
                ("default-nameserver", true),
                ("proxy-server-nameserver", false),
            ] {
                let valid = config["dns"][key].as_array().is_some_and(|a| {
                    !a.is_empty()
                        && a.iter()
                            .all(|v| v.as_str().is_some_and(|s| encrypted(s, literal)))
                });
                if !valid {
                    return Err("Clash 的 default-nameserver 和 proxy-server-nameserver 必须使用独立加密解析，且引导服务器须为 IPv4 地址；不支持 IPv6 引导地址".into());
                }
            }
            config["ipv6"] = json!(false);
            if let Some(proxies) = config["proxies"].as_array_mut() {
                for proxy in proxies {
                    proxy["ip-version"] = json!("ipv4");
                }
            }
            if let Some(providers) = config["proxy-providers"].as_object_mut() {
                for provider in providers.values_mut() {
                    if !provider["override"].is_object() {
                        provider["override"] = json!({});
                    }
                    provider["override"]["ip-version"] = json!("ipv4");
                }
            }
            let dns = config["dns"].as_object_mut().unwrap();
            for (key, value) in [
                ("enable", json!(true)),
                ("ipv6", json!(false)),
                ("listen", json!("127.0.0.1:17853")),
                ("enhanced-mode", json!("redir-host")),
                ("prefer-h3", json!(false)),
                ("respect-rules", json!(false)),
                (
                    "nameserver",
                    json!([
                        "https://1.1.1.1/dns-query#GLOBAL",
                        "https://8.8.8.8/dns-query#GLOBAL"
                    ]),
                ),
                (
                    "direct-nameserver",
                    json!([
                        "https://1.1.1.1/dns-query#GLOBAL",
                        "https://8.8.8.8/dns-query#GLOBAL"
                    ]),
                ),
                ("nameserver-policy", json!({})),
                ("proxy-server-nameserver-policy", json!({})),
                ("fallback", json!([])),
            ] {
                dns.insert(key.into(), value);
            }
            serialize(&config)
        }
        _ => Err("Unknown configuration operation".into()),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn resolver_validation() {
        assert!(encrypted("https://1.1.1.1/dns-query", true));
        for value in [
            "1.1.1.1",
            "http://1.1.1.1",
            "https://[2606:4700::1111]/dns-query",
            "https://user:pass@1.1.1.1/",
            "https://1.1.1.1/#GLOBAL",
        ] {
            assert!(!encrypted(value, true), "{value}");
        }
    }
    #[test]
    fn restore_preserves_later_user_ipv6_choice() {
        let result=dispatch(&json!({"op":"restoredYAML","source":"ipv6: false","general":"ipv6: true","originalIPv6":false,"ipv4PolicyApplied":true,"sourceChanged":false})).unwrap();
        assert_eq!(yaml(&result).unwrap()["ipv6"], true);
    }
}
