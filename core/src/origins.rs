use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};

fn load(directory: &Path, name: &str, hash: &mut Sha256) -> Result<Value, String> {
    let bytes = std::fs::read(directory.join(name)).map_err(|e| format!("无法读取 {name}：{e}"))?;
    if bytes.len() > 4 * 1024 * 1024 {
        return Err(format!("配置文件过大（{name}）"));
    }
    hash.update(&bytes);
    serde_yaml_ng::from_str(String::from_utf8_lossy(&bytes).trim_start_matches('\u{feff}'))
        .map_err(|_| format!("配置解析失败（{name}）"))
}
fn identity(node: &Value) -> Result<String, String> {
    let mut object = node.as_object().ok_or("Invalid proxy mapping")?.clone();
    object.remove("name");
    serde_json::to_string(&object).map_err(|e| e.to_string())
}
pub fn resolve(request: &Value) -> Result<Value, String> {
    let directory = Path::new(
        request["directory"]
            .as_str()
            .ok_or("Missing configuration directory")?,
    );
    let mut hash = Sha256::new();
    let profiles = load(directory, "profile.yaml", &mut hash)?;
    let active_profile = profiles["current"].as_str().filter(|id| {
        !id.is_empty()
            && id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
            && profiles["items"]
                .as_array()
                .is_some_and(|items| items.iter().any(|p| p["id"].as_str() == Some(*id)))
    });
    let mut names: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut identities: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for profile in profiles["items"].as_array().into_iter().flatten() {
        let Some(id) = profile["id"].as_str().filter(|s| {
            !s.is_empty()
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        }) else {
            continue;
        };
        let nodes = load(directory, &format!("profiles/{id}.yaml"), &mut hash)?;
        for node in nodes["proxies"].as_array().into_iter().flatten() {
            if let Some(name) = node["name"].as_str() {
                names.entry(name.into()).or_default().insert(id.into());
            }
            identities
                .entry(identity(node)?)
                .or_default()
                .insert(id.into());
        }
    }
    let mut origins: BTreeMap<String, String> = names
        .into_iter()
        .filter_map(|(name, ids)| {
            if ids.len() == 1 {
                Some((name, ids.into_iter().next().unwrap()))
            } else {
                None
            }
        })
        .collect();
    let runtime = load(directory, "work/config.yaml", &mut hash)?;
    for node in runtime["proxies"].as_array().into_iter().flatten() {
        let Some(name) = node["name"].as_str() else {
            continue;
        };
        if let Some(ids) = identities
            .get(&identity(node)?)
            .filter(|ids| ids.len() == 1)
        {
            origins.insert(name.into(), ids.first().unwrap().clone());
        } else {
            origins.remove(name);
        }
    }
    Ok(
        json!({"activeProfileId":active_profile,"origins":origins,"signature":hash.finalize().to_vec()}),
    )
}
