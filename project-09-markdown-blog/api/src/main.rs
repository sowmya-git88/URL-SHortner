//! Project 09 — Markdown blog API (Rust / Actix-web).
//! Posts live in Cloudflare D1, images in R2 (cached on local disk under /var/cache/mdblog).
mod d1;
mod r2;

use actix_web::{delete, get, http::header, post, web, App, HttpRequest, HttpResponse, HttpServer};
use pulldown_cmark::{html, Options, Parser};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{io::Write, path::PathBuf, time::Instant};

struct AppState {
    db: d1::D1,
    r2: r2::R2,
    admin_token: String,
    cache_dir: PathBuf,
    auth_log: PathBuf,
    started: Instant,
}

type State = web::Data<AppState>;

fn env(key: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| panic!("missing environment variable {key}"))
}

fn client_ip(req: &HttpRequest) -> String {
    // Caddy sets X-Forwarded-For; realip_remote_addr() reads it (first hop)
    req.connection_info().realip_remote_addr().unwrap_or("unknown").to_string()
}

/// Bearer-token check. Failures are appended to AUTH_LOG in a stable format for Fail2Ban:
///   2025-01-31T10:00:00Z mdblog auth failure from 203.0.113.9 path=/api/posts
fn authorize(req: &HttpRequest, st: &State) -> Result<(), HttpResponse> {
    let ok = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(|t| constant_time_eq(t.as_bytes(), st.admin_token.as_bytes()))
        .unwrap_or(false);
    if ok {
        return Ok(());
    }
    let line = format!(
        "{} mdblog auth failure from {} path={}\n",
        chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ"),
        client_ip(req),
        req.path()
    );
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&st.auth_log) {
        let _ = f.write_all(line.as_bytes());
    }
    log::warn!("{}", line.trim_end());
    Err(HttpResponse::Unauthorized().json(json!({ "error": "invalid or missing admin token" })))
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn render_markdown(md: &str) -> String {
    let mut opts = Options::empty();
    opts.insert(Options::ENABLE_TABLES);
    opts.insert(Options::ENABLE_STRIKETHROUGH);
    opts.insert(Options::ENABLE_TASKLISTS);
    let mut out = String::new();
    html::push_html(&mut out, Parser::new_ext(md, opts));
    out
}

fn valid_slug(s: &str) -> bool {
    !s.is_empty() && s.len() <= 80 && s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

fn bad_gateway(e: String) -> HttpResponse {
    log::error!("{e}");
    HttpResponse::BadGateway().json(json!({ "error": "storage backend error" }))
}

#[get("/api/health")]
async fn health(st: State) -> HttpResponse {
    let t0 = Instant::now();
    let db = st.db.query("SELECT 1 AS ok", vec![]).await;
    let cache_mb = dir_size(&st.cache_dir) / 1_048_576;
    let body = json!({
        "status": if db.is_ok() { "ok" } else { "degraded" },
        "database": "cloudflare-d1",
        "db_ok": db.is_ok(),
        "db_ms": t0.elapsed().as_millis(),
        "pid": std::process::id(),
        "uptime_s": st.started.elapsed().as_secs(),
        "media_cache_mb": cache_mb,
        "error": db.err(),
    });
    if body["db_ok"] == Value::Bool(true) {
        HttpResponse::Ok().json(body)
    } else {
        HttpResponse::ServiceUnavailable().json(body)
    }
}

fn dir_size(p: &PathBuf) -> u64 {
    std::fs::read_dir(p)
        .map(|it| it.filter_map(|e| e.ok()).filter_map(|e| e.metadata().ok()).map(|m| m.len()).sum())
        .unwrap_or(0)
}

#[get("/api/posts")]
async fn list_posts(st: State) -> HttpResponse {
    match st
        .db
        .query(
            "SELECT slug, title, summary, cover_key, created_at FROM posts WHERE published = 1 ORDER BY created_at DESC LIMIT 100",
            vec![],
        )
        .await
    {
        Ok(rows) => HttpResponse::Ok().json(rows),
        Err(e) => bad_gateway(e),
    }
}

#[get("/api/posts/{slug}")]
async fn get_post(st: State, slug: web::Path<String>) -> HttpResponse {
    match st.db.query("SELECT * FROM posts WHERE slug = ?", vec![json!(slug.as_str())]).await {
        Ok(rows) if rows.is_empty() => HttpResponse::NotFound().json(json!({ "error": "post not found" })),
        Ok(mut rows) => {
            let mut post = rows.remove(0);
            let md = post.get("body_md").and_then(|v| v.as_str()).unwrap_or("").to_string();
            post.insert("html".into(), json!(render_markdown(&md)));
            HttpResponse::Ok().json(post)
        }
        Err(e) => bad_gateway(e),
    }
}

#[derive(Deserialize)]
struct PostIn {
    slug: String,
    title: String,
    #[serde(default)]
    summary: String,
    body_md: String,
    cover_key: Option<String>,
    #[serde(default = "default_true")]
    published: bool,
}
fn default_true() -> bool {
    true
}

#[post("/api/posts")]
async fn upsert_post(req: HttpRequest, st: State, body: web::Json<PostIn>) -> HttpResponse {
    if let Err(r) = authorize(&req, &st) {
        return r;
    }
    let p = body.into_inner();
    if !valid_slug(&p.slug) || p.title.trim().is_empty() || p.body_md.trim().is_empty() {
        return HttpResponse::UnprocessableEntity()
            .json(json!({ "error": "slug (a-z0-9-), title and body_md are required" }));
    }
    let sql = "INSERT INTO posts(slug, title, summary, body_md, cover_key, published) VALUES (?, ?, ?, ?, ?, ?) \
               ON CONFLICT(slug) DO UPDATE SET title = excluded.title, summary = excluded.summary, \
               body_md = excluded.body_md, cover_key = excluded.cover_key, published = excluded.published, \
               updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')";
    let params = vec![
        json!(p.slug),
        json!(p.title.trim()),
        json!(p.summary.trim()),
        json!(p.body_md),
        json!(p.cover_key),
        json!(if p.published { 1 } else { 0 }),
    ];
    match st.db.query(sql, params).await {
        Ok(_) => HttpResponse::Created().json(json!({ "slug": p.slug, "url": format!("/post/?slug={}", p.slug) })),
        Err(e) => bad_gateway(e),
    }
}

#[delete("/api/posts/{slug}")]
async fn delete_post(req: HttpRequest, st: State, slug: web::Path<String>) -> HttpResponse {
    if let Err(r) = authorize(&req, &st) {
        return r;
    }
    match st.db.query("DELETE FROM posts WHERE slug = ?", vec![json!(slug.as_str())]).await {
        Ok(_) => HttpResponse::NoContent().finish(),
        Err(e) => bad_gateway(e),
    }
}

#[derive(Deserialize)]
struct UploadQuery {
    filename: String,
}

fn content_type_for(name: &str) -> &'static str {
    match name.rsplit('.').next().unwrap_or("").to_ascii_lowercase().as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        _ => "application/octet-stream",
    }
}

/// Upload raw bytes: POST /api/media?filename=diagram.png  (body = file, max 5 MB)
#[post("/api/media")]
async fn upload_media(req: HttpRequest, st: State, q: web::Query<UploadQuery>, body: web::Bytes) -> HttpResponse {
    if let Err(r) = authorize(&req, &st) {
        return r;
    }
    let clean: String = q
        .filename
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_' { c } else { '-' })
        .collect();
    if body.is_empty() || clean.is_empty() || clean.starts_with('.') {
        return HttpResponse::BadRequest().json(json!({ "error": "filename and non-empty body required" }));
    }
    let key = format!("{}-{}", chrono::Utc::now().format("%Y%m%d%H%M%S"), clean);
    match st.r2.put(&key, body.to_vec(), content_type_for(&clean)).await {
        Ok(()) => HttpResponse::Created().json(json!({ "key": key, "url": format!("/api/media/{key}") })),
        Err(e) => bad_gateway(e),
    }
}

/// Serve media: local disk cache first (fast, free), then R2 (and populate the cache).
#[get("/api/media/{key}")]
async fn get_media(st: State, key: web::Path<String>) -> HttpResponse {
    let key = key.into_inner();
    if key.contains('/') || key.starts_with('.') || key.len() > 200 {
        return HttpResponse::BadRequest().finish();
    }
    let cached = st.cache_dir.join(&key);
    let ctype = content_type_for(&key);
    if let Ok(bytes) = std::fs::read(&cached) {
        return HttpResponse::Ok()
            .insert_header((header::CONTENT_TYPE, ctype))
            .insert_header((header::CACHE_CONTROL, "public, max-age=86400"))
            .insert_header(("X-Cache", "HIT"))
            .body(bytes);
    }
    match st.r2.get(&key).await {
        Ok(Some(bytes)) => {
            if let Err(e) = std::fs::write(&cached, &bytes) {
                log::warn!("cache write failed for {}: {e} (disk full?)", cached.display());
            }
            HttpResponse::Ok()
                .insert_header((header::CONTENT_TYPE, ctype))
                .insert_header((header::CACHE_CONTROL, "public, max-age=86400"))
                .insert_header(("X-Cache", "MISS"))
                .body(bytes)
        }
        Ok(None) => HttpResponse::NotFound().finish(),
        Err(e) => bad_gateway(e),
    }
}

async fn migrate(db: &d1::D1) -> Result<(), String> {
    // schema.sql is compiled INTO the binary; split on ';' and drop comment lines
    let schema = include_str!("../../db/schema.sql");
    for raw in schema.split(';') {
        let stmt = raw
            .lines()
            .filter(|l| !l.trim_start().starts_with("--"))
            .collect::<Vec<_>>()
            .join("\n");
        if !stmt.trim().is_empty() {
            db.query(stmt.trim(), vec![]).await?;
        }
    }
    let rows = db.query("SELECT COUNT(*) AS n FROM posts", vec![]).await?;
    if rows.first().and_then(|r| r.get("n")).and_then(|v| v.as_i64()) == Some(0) {
        db.query(
            "INSERT INTO posts(slug, title, summary, body_md) VALUES (?, ?, ?, ?)",
            vec![
                json!("hello-disk-management"),
                json!("Hello, disk management"),
                json!("df, du, lsblk and why logs eat your 15 GB"),
                json!("# Welcome\n\nThis post lives in **Cloudflare D1** and is rendered by **Rust**.\n\n| Command | Shows |\n|---|---|\n| `df -h` | free space per filesystem |\n| `du -sh *` | size per directory |\n| `lsblk` | block devices |\n\n- [x] Deploy the API\n- [ ] Configure Fail2Ban\n"),
            ],
        )
        .await?;
        log::info!("seeded first post");
    }
    Ok(())
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .user_agent("mdblog/1.0")
        .build()
        .expect("http client");
    let account = env("CF_ACCOUNT_ID");
    let db = d1::D1::new(http.clone(), &account, &env("D1_DATABASE_ID"), &env("CF_API_TOKEN"));
    let r2 = r2::R2::new(http, &account, &env("R2_BUCKET"), &env("R2_ACCESS_KEY_ID"), &env("R2_SECRET_ACCESS_KEY"));

    if let Err(e) = migrate(&db).await {
        log::error!("D1 migration failed: {e}");
        std::process::exit(1);
    }

    let cache_dir = PathBuf::from(std::env::var("MEDIA_CACHE_DIR").unwrap_or_else(|_| "/var/cache/mdblog/media".into()));
    std::fs::create_dir_all(&cache_dir)?;
    let state = web::Data::new(AppState {
        db,
        r2,
        admin_token: env("ADMIN_TOKEN"),
        cache_dir,
        auth_log: PathBuf::from(std::env::var("AUTH_LOG").unwrap_or_else(|_| "/var/log/mdblog/auth.log".into())),
        started: Instant::now(),
    });
    if state.admin_token.len() < 24 {
        log::error!("ADMIN_TOKEN must be at least 24 characters");
        std::process::exit(78);
    }

    let bind = std::env::var("BIND_ADDR").unwrap_or_else(|_| "127.0.0.1:5009".into());
    log::info!("listening on {bind} pid={}", std::process::id());
    HttpServer::new(move || {
        App::new()
            .app_data(state.clone())
            .app_data(web::PayloadConfig::new(5 * 1024 * 1024))
            .app_data(web::JsonConfig::default().limit(512 * 1024))
            .wrap(actix_web::middleware::Logger::new("%a \"%r\" %s %b %Dms"))
            .service(health)
            .service(list_posts)
            .service(get_post)
            .service(upsert_post)
            .service(delete_post)
            .service(upload_media)
            .service(get_media)
    })
    .workers(2)
    .shutdown_timeout(10)
    .bind(bind)?
    .run()
    .await
}
