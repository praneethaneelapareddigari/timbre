# One image, one origin: Phoenix serves the API, the WebSocket and the built
# React app. Three stages:
#   web  — Rust → WASM (wasm-pack), then the Vite production build
#   api  — Elixir release with the web build copied into priv/static
#   run  — just the release
#
# Build & run locally:
#   docker build -t timbre .
#   docker run -p 8080:8080 -e SECRET_KEY_BASE=$(openssl rand -base64 48) \
#     -e PHX_HOST=localhost -v timbre-data:/data timbre

ARG ELIXIR_IMAGE=elixir:1.18-otp-27-slim

# ---- web ---------------------------------------------------------------------
FROM node:22-bookworm AS web

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --target wasm32-unknown-unknown
ENV PATH=/root/.cargo/bin:$PATH
RUN npm install -g wasm-pack

WORKDIR /app/web
# The brief is imported by the app (Brief tab), from the repo root.
COPY ASSIGNMENT.md /app/ASSIGNMENT.md
COPY web/crates ./crates
COPY web/package.json web/package-lock.json ./
# package.json depends on the wasm-pack output, so build WASM before npm ci.
RUN npm run build:wasm && npm ci
COPY web/ ./
RUN npx tsc -b && npx vite build

# ---- api ---------------------------------------------------------------------
FROM ${ELIXIR_IMAGE} AS api

RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod
WORKDIR /app/api
RUN mix local.hex --force && mix local.rebar --force

COPY api/mix.exs api/mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY api/config ./config
COPY api/lib ./lib
COPY api/priv ./priv
COPY --from=web /app/web/dist ./priv/static

RUN mix compile && mix release

# ---- run ---------------------------------------------------------------------
# Same base as the builder so the release's ERTS and the SQLite NIF find
# exactly the system libraries they were built against.
FROM ${ELIXIR_IMAGE}

WORKDIR /app
RUN mkdir -p /data
ENV MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=8080 \
    DATABASE_PATH=/data/timbre.db \
    LANG=C.UTF-8

COPY --from=api /app/api/_build/prod/rel/timbre ./

EXPOSE 8080
CMD ["/bin/sh", "-c", "bin/timbre eval 'Timbre.Release.migrate()' && exec bin/timbre start"]
