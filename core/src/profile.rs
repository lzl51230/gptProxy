//! ProxyBridge wire schemas differ by platform; routing policy is shared here.
use serde_json::{Value, json};
const MAC_PROCESSES: &str = "com.openai.*;com.openai.chat;ChatGPT;codex;codex-code-mode-host;codex_chronicle*;org.sparkle-project.*";
const WINDOWS_PROCESSES: &str =
    "ChatGPT.exe;codex.exe;codex-code-mode-host.exe;codex_chronicle*.exe";
const LOCAL: &str = "localhost;127.0.0.1;::1;192.168.*.*;192.168.100.81";
pub fn generate(platform: &str) -> Result<Value, String> {
    let rules = [
        (LOCAL, "TCP", "DIRECT"),
        ("::/0", "TCP", "BLOCK"),
        ("*", "BOTH", "PROXY"),
    ];
    match platform {
        "macos" => Ok(
            json!({"name":"ChatGPT Only","dnsEnabled":false,"closeToMenuBar":true,"runAtStartup":false,"trafficLoggingEnabled":false,
            "proxyConfigs":[{"id":"chatgpt-proxy-relay","name":"ChatGPT Proxy Relay","type":"socks5","host":"127.0.0.1","port":17890}],
            "proxyRules":rules.iter().map(|(hosts,proto,action)|json!({"processNames":MAC_PROCESSES,"targetHosts":hosts,"targetPorts":"*","protocol":proto,"action":if *action=="PROXY" {"chatgpt-proxy-relay"} else {action},"enabled":true})).collect::<Vec<_>>()}),
        ),
        "windows" => Ok(
            json!({"Version":"1.0","Name":"ChatGPT Only","LocalhostViaProxy":false,"IsTrafficLoggingEnabled":false,
            "ProxyConfigs":[{"Id":1,"Name":"ChatGPT Proxy Relay","Type":"SOCKS5","Host":"127.0.0.1","Port":"17890","Username":"","Password":"","SendDomainToProxy":true}],
            "ProxyRules":rules.iter().map(|(hosts,proto,action)|json!({"ProcessName":WINDOWS_PROCESSES,"TargetHosts":hosts,"TargetPorts":"*","TargetDomains":"*","Protocol":proto,"Action":action,"IsEnabled":true,"ProxyConfigId":1})).collect::<Vec<_>>()}),
        ),
        _ => Err("Unsupported ProxyBridge platform".into()),
    }
}
fn matches(actual: &Value, expected: &Value) -> bool {
    match expected {
        Value::Object(keys) => keys
            .iter()
            .filter(|(k, _)| {
                ![
                    "name",
                    "Name",
                    "closeToMenuBar",
                    "runAtStartup",
                    "trafficLoggingEnabled",
                ]
                .contains(&k.as_str())
            })
            .all(|(key, value)| matches(&actual[key], value)),
        Value::Array(items) => actual.as_array().is_some_and(|a| {
            a.len() == items.len() && a.iter().zip(items).all(|(a, e)| matches(a, e))
        }),
        _ => actual == expected,
    }
}
pub fn dispatch(request: &Value) -> Result<Value, String> {
    let platform = request["platform"].as_str().unwrap_or("macos");
    let expected = generate(platform)?;
    if request["op"] == "proxyProfile" {
        return Ok(expected);
    }
    let actual = &request["profile"];
    let valid = matches(actual, &expected)
        && if platform == "macos" {
            actual["name"] == "ChatGPT Only"
                && actual["proxyConfigs"].as_array().is_some_and(|items| {
                    items
                        .iter()
                        .all(|p| p["username"].is_null() && p["password"].is_null())
                })
        } else {
            true
        };
    Ok(json!(valid))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bundled_mac_profile_matches_shared_policy() {
        let profile: Value =
            serde_json::from_str(include_str!("../../Resources/ChatGPT-Only.pbprofile")).unwrap();
        assert_eq!(
            dispatch(&json!({"op":"validateProxyProfile","profile":profile})).unwrap(),
            true
        );
    }
    #[test]
    fn rejects_udp_bypass_and_credentialed_relay() {
        for platform in ["macos", "windows"] {
            let mut profile = generate(platform).unwrap();
            if platform == "windows" {
                profile["ProxyRules"][0]["Protocol"] = json!("BOTH");
            } else {
                profile["proxyConfigs"][0]["username"] = json!("unexpected");
            }
            assert_eq!(
                dispatch(
                    &json!({"op":"validateProxyProfile","platform":platform,"profile":profile})
                )
                .unwrap(),
                false
            );
        }
    }
}
