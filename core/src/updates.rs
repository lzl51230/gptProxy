//! Release selection shared by both desktop hosts. No network or filesystem effects.
use serde_json::{Value, json};
fn version(raw: &str) -> Result<[u64; 3], String> {
    let raw = raw.strip_prefix('v').unwrap_or(raw);
    let raw = raw.split('+').next().unwrap_or("");
    let parts: Vec<_> = raw.split('.').collect();
    if parts.len() != 3 { return Err("版本格式无效".into()); }
    let mut result = [0; 3];
    for (i, p) in parts.iter().enumerate() {
        if p.is_empty() || !p.bytes().all(|c| c.is_ascii_digit()) { return Err("版本格式无效".into()); }
        result[i] = p.parse().map_err(|_| "版本数字过大")?;
    }
    Ok(result)
}
pub fn select(request: &Value) -> Result<Value, String> {
    let r = &request["release"];
    if r["draft"] != false || r["prerelease"] != false { return Ok(Value::Null); }
    let tag = r["tag_name"].as_str().ok_or("缺少版本")?;
    if version(tag)? <= version(request["current"].as_str().ok_or("缺少当前版本")?)? { return Ok(Value::Null); }
    let suffix = match request["platform"].as_str() { Some("macos") => "Universal", Some("windows") => "Windows-x64-Portable", _ => return Err("平台无效".into()) };
    let v = tag.strip_prefix('v').unwrap_or(tag);
    let name = format!("ChatGPT-Proxy-{v}-{suffix}.zip");
    let assets = r["assets"].as_array().ok_or("缺少资产")?;
    let matches: Vec<_> = assets.iter().filter(|a| a["name"] == name).collect();
    if matches.len() != 1 { return Err("新版尚未提供唯一的平台安装包".into()); }
    let a = matches[0];
    let url = a["browser_download_url"].as_str().ok_or("缺少下载地址")?;
    if !url.starts_with("https://github.com/lzl51230/gptProxy/releases/download/") { return Err("下载来源无效".into()); }
    let checksums = assets.iter().find(|a| a["name"] == format!("{name}.sha256")).and_then(|a| a["browser_download_url"].as_str());
    if let Some(u) = checksums { if !u.starts_with("https://github.com/lzl51230/gptProxy/releases/download/") { return Err("校验来源无效".into()); } }
    let size = a["size"].as_u64().filter(|s| *s > 0 && *s <= 512 * 1024 * 1024).ok_or("安装包大小无效")?;
    Ok(json!({"version":v,"url":url,"digest":a["digest"],"checksums":checksums,"size":size,"name":name}))
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn numeric_versions() { assert!(version("v2.10.0").unwrap() > version("2.9.9").unwrap()); assert!(version("2.4.0-beta").is_err()); assert!(version("2.4").is_err()); }
    #[test] fn releases() {
        let mut r=json!({"current":"2.3.9","platform":"macos","release":{"tag_name":"v2.4.0","draft":false,"prerelease":false,"assets":[{"name":"ChatGPT-Proxy-2.4.0-Universal.zip","size":100,"browser_download_url":"https://github.com/lzl51230/gptProxy/releases/download/v2.4.0/test.zip"}]}});
        assert_eq!(select(&r).unwrap()["version"],"2.4.0");
        r["platform"]=json!("windows"); assert!(select(&r).is_err());
        r["release"]["prerelease"]=json!(true); assert!(select(&r).unwrap().is_null());
        r["release"]["prerelease"]=json!(false); r["current"]=json!("2.4.0"); assert!(select(&r).unwrap().is_null());
    }
}
