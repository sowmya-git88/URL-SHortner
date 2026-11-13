//! Minimal Cloudflare D1 client using the public REST API:
//! POST https://api.cloudflare.com/client/v4/accounts/{account}/d1/database/{db}/query
use serde_json::{json, Map, Value};

#[derive(Clone)]
pub struct D1 {
    http: reqwest::Client,
    url: String,
    token: String,
}

impl D1 {
    pub fn new(http: reqwest::Client, account_id: &str, database_id: &str, token: &str) -> Self {
        Self {
            http,
            url: format!(
                "https://api.cloudflare.com/client/v4/accounts/{account_id}/d1/database/{database_id}/query"
            ),
            token: token.to_string(),
        }
    }

    /// Run one SQL statement with positional `?` params; returns the result rows.
    pub async fn query(&self, sql: &str, params: Vec<Value>) -> Result<Vec<Map<String, Value>>, String> {
        let resp = self
            .http
            .post(&self.url)
            .bearer_auth(&self.token)
            .json(&json!({ "sql": sql, "params": params }))
            .send()
            .await
            .map_err(|e| format!("d1 request: {e}"))?;
        let status = resp.status();
        let body: Value = resp.json().await.map_err(|e| format!("d1 decode: {e}"))?;
        if !status.is_success() || body["success"] != Value::Bool(true) {
            return Err(format!("d1 error {status}: {}", body["errors"]));
        }
        let rows = body["result"][0]["results"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter_map(|v| v.as_object().cloned())
            .collect();
        Ok(rows)
    }
}
