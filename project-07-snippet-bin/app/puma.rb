# Puma config — single mode (no forked workers) keeps RAM ≈ 60–80 MB on the 1 GB box.
bind "tcp://#{ENV.fetch('BIND', '127.0.0.1')}:#{ENV.fetch('PORT', '5007')}"
environment ENV.fetch("RACK_ENV", "production")
threads 2, 4
workers 0
# stdout/stderr go to journald via systemd
log_requests false
# Graceful shutdown window on SIGTERM
worker_shutdown_timeout 10
