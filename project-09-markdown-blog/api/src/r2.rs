//! Cloudflare R2 via its S3-compatible API, signed with AWS Signature Version 4.
//! Implemented by hand (≈60 lines) instead of pulling a heavy SDK — and it teaches
//! exactly what an "S3 signature" is.
use chrono::Utc;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

#[derive(Clone)]
pub struct R2 {
    http: reqwest::Client,
    host: String,
    bucket: String,
    access_key: String,
    secret_key: String,
}

fn hmac(key: &[u8], data: &str) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(data.as_bytes());
    mac.finalize().into_bytes().to_vec()
}

fn sha256_hex(data: &[u8]) -> String {
    hex::encode(Sha256::digest(data))
}

impl R2 {
    pub fn new(http: reqwest::Client, account_id: &str, bucket: &str, access_key: &str, secret_key: &str) -> Self {
        Self {
            http,
            host: format!("{account_id}.r2.cloudflarestorage.com"),
            bucket: bucket.to_string(),
            access_key: access_key.to_string(),
            secret_key: secret_key.to_string(),
        }
    }

    /// Returns (url, headers) for a signed request. `key` must already be URL-safe.
    fn sign(&self, method: &str, key: &str, payload: &[u8]) -> (String, Vec<(String, String)>) {
        let now = Utc::now();
        let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
        let date = now.format("%Y%m%d").to_string();
        let payload_hash = sha256_hex(payload);
        let uri = format!("/{}/{}", self.bucket, key);

        let canonical_headers = format!(
            "host:{}\nx-amz-content-sha256:{}\nx-amz-date:{}\n",
            self.host, payload_hash, amz_date
        );
        let signed_headers = "host;x-amz-content-sha256;x-amz-date";
        let canonical_request =
            format!("{method}\n{uri}\n\n{canonical_headers}\n{signed_headers}\n{payload_hash}");

        let scope = format!("{date}/auto/s3/aws4_request");
        let string_to_sign = format!(
            "AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{}",
            sha256_hex(canonical_request.as_bytes())
        );

        let k_date = hmac(format!("AWS4{}", self.secret_key).as_bytes(), &date);
        let k_region = hmac(&k_date, "auto");
        let k_service = hmac(&k_region, "s3");
        let k_signing = hmac(&k_service, "aws4_request");
        let signature = hex::encode(hmac(&k_signing, &string_to_sign));

        let auth = format!(
            "AWS4-HMAC-SHA256 Credential={}/{scope}, SignedHeaders={signed_headers}, Signature={signature}",
            self.access_key
        );
        (
            format!("https://{}{}", self.host, uri),
            vec![
                ("x-amz-date".into(), amz_date),
                ("x-amz-content-sha256".into(), payload_hash),
                ("authorization".into(), auth),
            ],
        )
    }

    pub async fn put(&self, key: &str, bytes: Vec<u8>, content_type: &str) -> Result<(), String> {
        let (url, headers) = self.sign("PUT", key, &bytes);
        let mut req = self.http.put(url).header("content-type", content_type).body(bytes);
        for (k, v) in headers {
            req = req.header(k, v);
        }
        let resp = req.send().await.map_err(|e| format!("r2 put: {e}"))?;
        if resp.status().is_success() {
            Ok(())
        } else {
            Err(format!("r2 put {}: {}", resp.status(), resp.text().await.unwrap_or_default()))
        }
    }

    pub async fn get(&self, key: &str) -> Result<Option<Vec<u8>>, String> {
        let (url, headers) = self.sign("GET", key, b"");
        let mut req = self.http.get(url);
        for (k, v) in headers {
            req = req.header(k, v);
        }
        let resp = req.send().await.map_err(|e| format!("r2 get: {e}"))?;
        match resp.status().as_u16() {
            200 => Ok(Some(resp.bytes().await.map_err(|e| e.to_string())?.to_vec())),
            404 => Ok(None),
            s => Err(format!("r2 get {s}: {}", resp.text().await.unwrap_or_default())),
        }
    }
}
