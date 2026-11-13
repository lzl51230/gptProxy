use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
    io::Read,
};

fn load(directory: &Path, name: &str, hash: &mut Sha256) -> Result<Value, String> {
    const MAX_CONFIGURATION: u64 = 32 * 1024 * 1024;
    let file = std::fs::File::open(directory.join(name)).map_err(|e| format!("无法读取 {name}：{e}"))?;
    let size = file.metadata().map_err(|e| e.to_string())?.len();
    if size > MAX_CONFIGURATION {
        return Err(format!("配置文件 {name} 大小为 {size} 字节，超过 32 MiB 上限"));
    }
    let mut bytes = Vec::new();
    file.take(MAX_CONFIGURATION + 1).read_to_end(&mut bytes).map_err(|e| format!("无法读取 {name}：{e}"))?;
    if bytes.len() as u64 > MAX_CONFIGURATION {
        return Err(format!("配置文件 {name} 大小超过 32 MiB 上限"));
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn accepts_32_mib_configuration_and_rejects_one_extra_byte() {
        let directory = std::env::temp_dir().join(format!("gptproxy-origins-{}-{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("config.yaml");
        let mut bytes = b"proxies: []\n#".to_vec();
        bytes.resize(32 * 1024 * 1024, b'x');
        std::fs::write(&path, &bytes).unwrap();
        let result = load(&directory, "config.yaml", &mut Sha256::new()).unwrap();
        assert_eq!(result["proxies"], json!([]));
        bytes.push(b'x');
        std::fs::write(&path, &bytes).unwrap();
        assert!(load(&directory, "config.yaml", &mut Sha256::new()).unwrap_err().contains("32 MiB"));
        std::fs::remove_dir_all(directory).unwrap();
    }
}
