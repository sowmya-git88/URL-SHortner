# syntax=docker/dockerfile:1.7
# ---------- stage 1: install ALL deps (incl. TypeScript) ----------
FROM node:22-alpine AS deps
WORKDIR /app
COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm npm install --no-audit --no-fund

# ---------- stage 2: compile TypeScript ----------
FROM deps AS build
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# ---------- stage 3: production deps only ----------
FROM node:22-alpine AS prod-deps
WORKDIR /app
COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm npm install --omit=dev --no-audit --no-fund

# ---------- stage 4: tiny runtime image ----------
FROM node:22-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app
# the official image ships an unprivileged 'node' user (uid 1000)
COPY --from=prod-deps --chown=node:node /app/node_modules ./node_modules
COPY --from=build     --chown=node:node /app/dist ./dist
COPY --chown=node:node package.json ./
USER node
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
  CMD wget -qO- http://127.0.0.1:3000/api/health || exit 1
# exec form → node is PID 1 and receives SIGTERM directly from `docker stop`
CMD ["node", "dist/main.js"]
