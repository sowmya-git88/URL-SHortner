// /opt/kanban/ecosystem.config.js — PM2 process file (CommonJS on purpose: PM2 loads it with require())
module.exports = {
  apps: [
    {
      name: "kanban-api",
      // PM2 is a Node tool, but it can supervise ANY binary: interpreter "none" = exec directly
      script: "/usr/local/bin/deno",
      args: "run --allow-net --allow-env --allow-read --allow-sys --env-file=/etc/kanban/kanban.env main.ts",
      interpreter: "none",
      cwd: "/opt/kanban/api",
      exec_mode: "fork",
      instances: 1,
      autorestart: true,
      max_restarts: 10,
      min_uptime: "10s",          // a start that dies within 10 s counts as unstable
      restart_delay: 2000,
      exp_backoff_restart_delay: 200,
      max_memory_restart: "150M", // PM2 restarts the process when RSS exceeds this
      kill_timeout: 8000,         // ms between SIGINT and SIGKILL on stop/restart
      watch: false,
      time: true,                 // prefix log lines with timestamps
      merge_logs: true,
      out_file: "/var/log/kanban/out.log",
      error_file: "/var/log/kanban/error.log",
      pid_file: "/var/lib/kanban/kanban-api.pid",
      env: {
        DENO_DIR: "/var/lib/kanban/deno-cache",
        NO_COLOR: "1",
      },
    },
  ],
};
