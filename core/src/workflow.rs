//! Host-driven async workflow. One bounded effect is exposed at a time; stale
//! replies cannot advance a cancelled generation. No executor or native callback crosses FFI.
use serde_json::{Value, json};
use std::{
    future::Future,
    pin::Pin,
    sync::{Arc, Mutex},
    task::{Context, Poll, Wake, Waker},
};
#[derive(Default)]
struct Mailbox {
    sequence: u64,
    command: Option<Value>,
    response: Option<Result<Value, String>>,
    now: f64,
}
#[derive(Clone)]
struct Model {
    context: Value,
    phase: String,
    status: String,
    node: String,
    latency: Value,
    age: f64,
    failures: u64,
    reason: Value,
    retry: Value,
    last_switch: String,
    delay: f64,
    recovery: bool,
    failed_node: String,
    round: u64,
    attempt: u32,
    retry_at: f64,
    cooldown: f64,
    candidates: Value,
}
impl Default for Model {
    fn default() -> Self {
        Self {
            context: Value::Null,
            phase: "stopped".into(),
            status: "等待监控".into(),
            node: "未知".into(),
            latency: Value::Null,
            age: 0.,
            failures: 0,
            reason: Value::Null,
            retry: Value::Null,
            last_switch: "尚未切换".into(),
            delay: 2.,
            recovery: false,
            failed_node: String::new(),
            round: 0,
            attempt: 0,
            retry_at: 0.,
            cooldown: 0.,
            candidates: json!({}),
        }
    }
}
impl Model {
    fn reset(&mut self) {
        let last = self.last_switch.clone();
        let cooldown = self.cooldown;
        let candidates = self.candidates.clone();
        *self = Self::default();
        self.last_switch = last;
        self.cooldown = cooldown;
        self.candidates = candidates;
    }
    fn phase(&mut self, phase: &str, status: impl Into<String>) {
        self.phase = phase.into();
        self.status = status.into();
    }
    fn retry(&mut self, now: f64) {
        let delay = (1u32 << self.attempt.saturating_add(1).min(5)).min(30);
        self.attempt = self.attempt.saturating_add(1);
        self.retry = json!(delay);
        self.delay = delay as f64;
        self.retry_at = now + self.delay;
        self.phase("retrying", format!("全部候选暂不可用，{delay} 秒后重试"));
    }
    fn snapshot(&self) -> Value {
        json!({"phase":self.phase,"status":self.status,"currentNode":self.node,"latency":self.latency,"connectionSeconds":self.age,"consecutiveFailures":self.failures,"disconnectReason":self.reason,"retrySeconds":self.retry,"lastSwitch":self.last_switch,"nextDelay":self.delay,"candidates":self.candidates})
    }
}
type Job = Pin<Box<dyn Future<Output = Result<(), String>> + Send>>;
#[derive(Default)]
pub struct Workflow {
    mail: Arc<Mutex<Mailbox>>,
    model: Arc<Mutex<Model>>,
    job: Option<Job>,
}
struct NoWake;
impl Wake for NoWake {
    fn wake(self: Arc<Self>) {}
}
impl Workflow {
    pub fn dispatch(&mut self, r: &Value) -> Result<Value, String> {
        match r["action"].as_str().ok_or("Missing workflow action")? {
            "reset" => {
                self.job = None;
                let mut mail = self.mail.lock().unwrap();
                mail.command = None;
                mail.response = None;
                self.model.lock().unwrap().reset();
            }
            "begin" => {
                if self.job.is_some() {
                    return Err("Monitor tick already running".into());
                }
                self.mail.lock().unwrap().now = clock(r)?;
                let driver = Driver {
                    mail: self.mail.clone(),
                    model: self.model.clone(),
                    regions: r["regions"].clone(),
                };
                self.job = Some(Box::pin(async move { driver.tick().await }));
            }
            "complete" => {
                let mut mail = self.mail.lock().unwrap();
                if mail.command.as_ref().and_then(|c| c["id"].as_u64()) != r["id"].as_u64()
                    || mail.command.is_none()
                {
                    return Err("Stale monitor effect response".into());
                }
                mail.now = clock(r)?;
                mail.command = None;
                mail.response = Some(if let Some(error) = r["error"].as_str() {
                    Err(error.into())
                } else {
                    Ok(r["value"].clone())
                });
            }
            _ => return Err("Unknown workflow action".into()),
        }
        if let Some(job) = self.job.as_mut() {
            let waker = Waker::from(Arc::new(NoWake));
            let mut context = Context::from_waker(&waker);
            if let Poll::Ready(result) = job.as_mut().poll(&mut context) {
                self.job = None;
                if let Err(error) = result {
                    let mut m = self.model.lock().unwrap();
                    m.phase("retrying", error);
                }
            }
        }
        Ok(
            json!({"state":self.model.lock().unwrap().snapshot(),"effect":self.mail.lock().unwrap().command,"done":self.job.is_none()}),
        )
    }
}
fn clock(r: &Value) -> Result<f64, String> {
    r["now"]
        .as_f64()
        .filter(|v| v.is_finite() && *v >= 0.)
        .ok_or("Invalid monotonic clock".into())
}
struct Effect {
    mail: Arc<Mutex<Mailbox>>,
    command: Option<Value>,
}
impl Future for Effect {
    type Output = Result<Value, String>;
    fn poll(mut self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<Self::Output> {
        if let Some(mut command) = self.command.take() {
            let mut mail = self.mail.lock().unwrap();
            mail.sequence = mail
                .sequence
                .checked_add(1)
                .expect("Effect sequence overflow");
            command["id"] = json!(mail.sequence);
            mail.command = Some(command);
            return Poll::Pending;
        }
        match self.mail.lock().unwrap().response.take() {
            Some(result) => Poll::Ready(result),
            None => Poll::Pending,
        }
    }
}
struct Driver {
    mail: Arc<Mutex<Mailbox>>,
    model: Arc<Mutex<Model>>,
    regions: Value,
}
impl Driver {
    fn effect(&self, op: &str, args: Value) -> Effect {
        Effect {
            mail: self.mail.clone(),
            command: Some(json!({"op":op,"args":args})),
        }
    }
    fn now(&self) -> f64 {
        self.mail.lock().unwrap().now
    }
    fn change(&self, f: impl FnOnce(&mut Model)) {
        f(&mut self.model.lock().unwrap())
    }
    fn state(&self) -> Model {
        self.model.lock().unwrap().clone()
    }
    async fn close(&self) -> Result<(), String> {
        self.effect("closeConnection", Value::Null)
            .await
            .map(|_| ())
    }
    async fn snapshot(&self) -> Result<Value, String> {
        self.effect("snapshot", Value::Null).await
    }
    async fn checked(&self, expected: &Value) -> Result<Value, String> {
        let fresh = self.snapshot().await?;
        if context(&fresh) != context(expected) {
            return Err("节点或配置已变化，重新建立 Codex 长连接".into());
        }
        Ok(fresh)
    }
    async fn heartbeat(&self, expected: &Value) -> Result<Value, String> {
        let h = self.effect("heartbeat", Value::Null).await?;
        if !expected.is_null() {
            self.checked(expected).await?;
        }
        let age = h["connectionSeconds"]
            .as_f64()
            .filter(|v| v.is_finite() && *v >= 0.)
            .ok_or("Invalid heartbeat age")?;
        let healthy = h["isHealthy"].as_bool().ok_or("Invalid heartbeat result")?;
        self.change(|m| {
            m.latency = h["latencyMilliseconds"].clone();
            m.age = age;
            if !healthy {
                m.reason = h["failureReason"].clone();
            }
        });
        Ok(h)
    }
    async fn tick(&self) -> Result<(), String> {
        self.change(|m| m.delay = 2.);
        if let Err(error) = self.observe().await {
            self.close().await?;
            if error.contains("变化") {
                self.change(|m| {
                    m.reset();
                    m.phase("connecting", error);
                });
            } else {
                self.change(|m| {
                    m.latency = Value::Null;
                    m.phase("retrying", error);
                    if m.recovery {
                        m.retry(self.now());
                    }
                });
            }
        }
        Ok(())
    }
    async fn observe(&self) -> Result<(), String> {
        let snapshot = self.snapshot().await.unwrap_or(Value::Null);
        if let Ok(catalog) = crate::monitor::candidates(
            &json!({"current":snapshot["current"],"origins":snapshot["origins"],"names":snapshot["proxies"]["GLOBAL"]["all"],"proxies":snapshot["proxies"]}),
        ) {
            self.change(|m| m.candidates = catalog);
        }
        let latest = context(&snapshot);
        if latest != self.state().context {
            self.close().await?;
            self.change(|m| {
                m.reset();
                m.context = latest;
            });
        }
        self.change(|m| {
            m.node = snapshot["current"].as_str().unwrap_or("未知").into();
            if snapshot["mode"] != "global" || snapshot["signature"].is_null() {
                m.recovery = false;
            }
        });
        if !self.state().recovery {
            let h = self.heartbeat(&snapshot).await?;
            let healthy = h["isHealthy"] == true;
            self.change(|m| {
                if healthy {
                    if m.age >= 60. {
                        m.failures = 0;
                    }
                    m.phase(
                        "maintaining",
                        if snapshot["mode"] == "global" {
                            "Codex 长连接正常"
                        } else {
                            "Codex 长连接正常；仅全局模式支持自动切换"
                        },
                    );
                } else {
                    m.failures = if m.age >= 60. {
                        0
                    } else {
                        (m.failures + 1).min(2)
                    };
                    m.phase(
                        "connecting",
                        format!("Codex 连接断开（未满 60 秒失败 {}/2）", m.failures),
                    );
                    m.delay = 1.;
                    if m.failures >= 2 {
                        m.recovery = true;
                        m.failed_node = m.node.clone();
                        m.round = 0;
                        m.attempt = 0;
                    }
                }
            });
            if healthy {
                return Ok(());
            }
            self.close().await?;
            if self.state().failures < 2 {
                return Ok(());
            }
        }
        if snapshot["mode"] != "global" || snapshot["signature"].is_null() {
            self.change(|m| {
                m.phase(
                    "retrying",
                    "Codex 连接不可用；等待 Clash Party 全局模式及订阅配置",
                )
            });
            return Ok(());
        }
        if self.now() < self.state().retry_at {
            self.change(|m| m.delay = m.retry_at - self.now());
            return Ok(());
        }
        self.change(|m| {
            m.retry = Value::Null;
            m.retry_at = 0.;
        });
        self.recover(snapshot).await?;
        if self.state().recovery {
            self.change(|m| m.retry(self.now()));
        }
        Ok(())
    }
    async fn recover(&self, original: Value) -> Result<(), String> {
        let current = original["current"]
            .as_str()
            .ok_or("无法解析当前节点")?
            .to_owned();
        let candidates = match crate::monitor::candidates(
            &json!({"current":current,"origins":original["origins"],"names":original["proxies"]["GLOBAL"]["all"],"proxies":original["proxies"]}),
        ) {
            Ok(value) => value,
            Err(error) => {
                self.change(|m| m.recovery = false);
                return Err(error);
            }
        };
        self.change(|m| {
            m.candidates = candidates.clone();
            m.round = m.round.saturating_add(1);
        });
        let region = crate::policy::region(&current).ok_or("节点地区不明确")?;
        let mut order = vec![region.clone()];
        if let Some(preferences) = self.regions.as_array() {
            for p in preferences {
                if p["isEnabled"] == true {
                    if let Some(code) = p["code"].as_str() {
                        if !order.iter().any(|c| c == code) {
                            order.push(code.into());
                        }
                    }
                }
            }
        }
        let mut expected = original;
        for region in order {
            let state = self.state();
            let nodes: Vec<String> = candidates[&region]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .filter(|n| state.round > 1 || *n != state.failed_node)
                .map(str::to_owned)
                .collect();
            self.change(|m| {
                m.phase(
                    "testing",
                    format!("Codex 测速 {region} · {} 个节点（≤800 ms）", nodes.len()),
                )
            });
            let mut ranked = Vec::new();
            for batch in nodes.chunks(4) {
                let result = self
                    .effect("delays", json!({"socket":expected["socket"],"names":batch}))
                    .await?;
                for name in batch {
                    if let Some(delay) = result[name].as_u64().filter(|n| *n > 0 && *n <= 800) {
                        ranked.push((delay, name.clone()));
                    }
                }
            }
            ranked.sort();
            for (delay, candidate) in ranked {
                let mut before = self.checked(&expected).await?;
                if before["current"] != candidate {
                    let wait = self.state().cooldown - self.now();
                    if wait > 0. {
                        self.effect("sleep", json!(wait)).await?;
                        before = self.checked(&expected).await?;
                    }
                    self.close().await?;
                    let ids = self
                        .effect(
                            "connections",
                            json!({"socket":before["socket"],"node":before["current"]}),
                        )
                        .await
                        .unwrap_or(json!([]));
                    self.checked(&before).await?;
                    self.change(|m| m.cooldown = self.now() + 5.);
                    let _ = self
                        .effect(
                            "select",
                            json!({"socket":before["socket"],"name":candidate}),
                        )
                        .await;
                    let confirmed = self.snapshot().await?;
                    if confirmed["socket"] != before["socket"]
                        || confirmed["mode"] != "global"
                        || confirmed["proxies"]["GLOBAL"]["all"]
                            != before["proxies"]["GLOBAL"]["all"]
                        || confirmed["signature"] != before["signature"]
                        || confirmed["current"] != candidate
                    {
                        return Err("节点或配置已变化，重新建立 Codex 长连接".into());
                    }
                    expected = confirmed;
                    self.change(|m| {
                        m.context = context(&expected);
                        m.node = candidate.clone();
                    });
                    for id in ids.as_array().into_iter().flatten() {
                        let _ = self
                            .effect("close", json!({"socket":before["socket"],"id":id}))
                            .await;
                    }
                }
                self.close().await?;
                self.change(|m| {
                    m.age = 0.;
                    m.latency = Value::Null;
                    m.phase(
                        "validating",
                        format!("验证 {candidate} · 需保持 10 秒 Codex 长连接"),
                    );
                });
                loop {
                    let h = self.heartbeat(&expected).await?;
                    if h["isHealthy"] != true {
                        break;
                    }
                    if self.state().age >= 10. {
                        self.change(|m| {
                            m.failures = 0;
                            m.recovery = false;
                            m.round = 0;
                            m.attempt = 0;
                            m.retry = Value::Null;
                            m.retry_at = 0.;
                            m.phase("maintaining", "Codex 长连接验收通过");
                            m.last_switch = format!("{current} → {candidate}（{delay}ms）");
                        });
                        return Ok(());
                    }
                    self.effect("sleep", json!(2.)).await?;
                }
                self.close().await?;
            }
        }
        self.close().await
    }
}
fn context(s: &Value) -> Value {
    if s.is_null() {
        Value::Null
    } else {
        json!({"socket":s["socket"],"mode":s["mode"],"selection":s["selection"],"nodes":s["proxies"]["GLOBAL"]["all"],"signature":s["signature"]})
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stale_effect_cannot_complete_new_generation() {
        let mut w = Workflow::default();
        let old = w.dispatch(&json!({"action":"begin","now":0})).unwrap()["effect"]["id"].clone();
        w.dispatch(&json!({"action":"reset"})).unwrap();
        let new = w.dispatch(&json!({"action":"begin","now":0})).unwrap()["effect"]["id"].clone();
        assert_ne!(old, new);
        assert!(
            w.dispatch(&json!({"action":"complete","id":old,"now":1,"value":null}))
                .is_err()
        );
    }
}
