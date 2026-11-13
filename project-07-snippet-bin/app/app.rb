# Project 07 — Snippet bin: Sinatra + Upstash Redis.
# Every request is written as ONE plain-text line to ACCESS_LOG so we can practise
# grep/awk/sed/cut/sort/uniq pipelines on realistic data (see scripts/log_analyzer.sh).
require "sinatra/base"
require "redis"
require "json"
require "securerandom"
require "time"
require "logger"

# Rack middleware: "ts ip method path status duration_ms bytes "user-agent""
class PlainAccessLog
  def initialize(app, path)
    @app = app
    @file = File.open(path, "a")
    @file.sync = true
    @mutex = Mutex.new
  rescue Errno::EACCES, Errno::ENOENT => e
    warn "WARN cannot open access log #{path}: #{e.message} — logging to stderr"
    @file = $stderr
    @mutex = Mutex.new
  end

  def call(env)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status, headers, body = @app.call(env)
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
    ip = (env["HTTP_X_FORWARDED_FOR"] || env["REMOTE_ADDR"] || "-").split(",").first.strip
    bytes = headers["content-length"] || headers["Content-Length"] || "-"
    ua = (env["HTTP_USER_AGENT"] || "-").tr('"', "'")[0, 200]
    line = format(%(%s %s %s %s %d %.1f %s "%s"\n),
                  Time.now.utc.iso8601, ip, env["REQUEST_METHOD"], env["PATH_INFO"], status, ms, bytes, ua)
    @mutex.synchronize { @file.write(line) }
    [status, headers, body]
  end
end

class SnippetBin < Sinatra::Base
  LANGS = %w[text bash python ruby javascript go sql yaml json dockerfile nginx].freeze
  MAX_SIZE = 64 * 1024
  RECENT_KEY = "snips:recent"
  STARTED = Time.now

  configure do
    set :public_folder, File.expand_path("../public", __dir__)
    set :show_exceptions, false
    set :raise_errors, false
    set :host_authorization, { permitted_hosts: [] } # Caddy already filters hosts
    $stdout.sync = true
  end

  use PlainAccessLog, ENV.fetch("ACCESS_LOG", "/var/log/snippetbin/access.log")

  def self.redis
    @redis ||= Redis.new(url: ENV.fetch("REDIS_URL"), timeout: 3, reconnect_attempts: 2)
  end

  helpers do
    def redis = SnippetBin.redis

    def json(data, code = 200)
      content_type :json
      halt code, JSON.generate(data)
    end

    def body_json
      JSON.parse(request.body.read)
    rescue JSON::ParserError
      json({ error: "invalid JSON" }, 400)
    end

    def snippet_payload(id, h)
      ttl = redis.ttl("snip:#{id}")
      { id: id, title: h["title"], lang: h["lang"], content: h["content"],
        created_at: h["created_at"], views: h["views"].to_i, expires_in_s: ttl.positive? ? ttl : nil }
    end
  end

  get "/api/health" do
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    pong = redis.ping
    json({ status: "ok", database: "upstash-redis", db_ok: pong == "PONG",
           redis_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1),
           pid: Process.pid, ruby: RUBY_VERSION, uptime_s: (Time.now - STARTED).round })
  rescue Redis::BaseError => e
    json({ status: "degraded", db_ok: false, error: e.message }, 503)
  end

  post "/api/snippets" do
    data = body_json
    content = data["content"].to_s
    title = data["title"].to_s.strip[0, 100]
    lang = LANGS.include?(data["lang"]) ? data["lang"] : "text"
    ttl_h = data["ttl_hours"].to_i
    ttl_h = ENV.fetch("DEFAULT_TTL_HOURS", "72").to_i unless ttl_h.between?(1, 24 * 30)
    json({ error: "content is required" }, 422) if content.strip.empty?
    json({ error: "content larger than 64 KB" }, 413) if content.bytesize > MAX_SIZE

    id = SecureRandom.alphanumeric(8)
    key = "snip:#{id}"
    redis.multi do |tx|
      tx.hset(key, "title", title.empty? ? "untitled" : title, "lang", lang, "content", content,
              "created_at", Time.now.utc.iso8601, "views", 0)
      tx.expire(key, ttl_h * 3600)
      tx.lpush(RECENT_KEY, id)
      tx.ltrim(RECENT_KEY, 0, 49)
      tx.incr("stats:created")
    end
    json({ id: id, url: "/#/s/#{id}", expires_in_s: ttl_h * 3600 }, 201)
  end

  get "/api/snippets" do
    ids = redis.lrange(RECENT_KEY, 0, 49)
    rows = ids.filter_map do |id|
      h = redis.hgetall("snip:#{id}")
      next if h.empty? # expired
      { id: id, title: h["title"], lang: h["lang"], created_at: h["created_at"], views: h["views"].to_i }
    end
    json(rows)
  end

  get "/api/snippets/:id" do
    id = params[:id]
    json({ error: "bad id" }, 400) unless id.match?(/\A[A-Za-z0-9]{8}\z/)
    h = redis.hgetall("snip:#{id}")
    json({ error: "not found or expired" }, 404) if h.empty?
    redis.hincrby("snip:#{id}", "views", 1)
    redis.incr("stats:views")
    json(snippet_payload(id, h))
  end

  delete "/api/snippets/:id" do
    removed = redis.del("snip:#{params[:id]}")
    redis.lrem(RECENT_KEY, 0, params[:id])
    removed.positive? ? halt(204) : json({ error: "not found" }, 404)
  end

  get "/api/stats" do
    created, views = redis.mget("stats:created", "stats:views")
    json({ created: created.to_i, views: views.to_i, keys_in_db: redis.dbsize })
  end

  # Deliberately slow / failing endpoints so the log analyzer has something to find
  get "/api/lab/slow" do
    sleep(rand(0.5..1.5))
    json({ slow: true })
  end

  get "/api/lab/error" do
    raise "simulated failure for log analysis practice"
  end

  not_found do
    json({ error: "no such endpoint" }, 404) if request.path_info.start_with?("/api/")
    send_file File.join(settings.public_folder, "index.html")
  end

  error do
    e = env["sinatra.error"]
    warn "ERROR #{e.class}: #{e.message}"
    json({ error: e.is_a?(Redis::BaseError) ? "redis unavailable" : "internal error" }, e.is_a?(Redis::BaseError) ? 503 : 500)
  end
end
