# UTXOpia Sui indexer — Bun service (events → sqlite → HTTP API).
FROM oven/bun:1-slim AS base
WORKDIR /app

# Dependency install (cached unless package.json / lockfile change).
COPY package.json bun.lock* ./
RUN bun install --frozen-lockfile || bun install

# App source.
COPY src ./src
COPY README.md PLAN.md ./

# HTTP API port (overridable via PORT).
EXPOSE 8787

# Persisted sqlite lives on a mounted volume; set UTXOPIA_SUI_INDEXER_DB to a path there.
CMD ["bun", "run", "src/server.ts"]
