# SPDX-License-Identifier: MIT
#
# The Amplestocks keeper.
#
# Two stages so the image carries no build toolchain, and a non-root user because nothing here needs a key: in
# the production configuration (`AMPS_SUBMITTER=relayer`) the container holds no private key at all — it POSTs
# transaction requests to the self-hosted OpenZeppelin Relayer, which owns the signer and the nonce.
#
# Build from the repository root, not from this directory:
#
#     docker build -f apps/keeper/Dockerfile -t amplestocks/keeper:dev .

FROM node:22.22-bookworm-slim AS build
WORKDIR /app
ENV PNPM_HOME=/pnpm
ENV PATH=$PNPM_HOME:$PATH
RUN corepack enable

# The workspace manifests first, so a source-only change reuses the install layer.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json .npmrc .nvmrc ./
COPY packages/config/package.json packages/config/
COPY packages/abis/package.json packages/abis/
COPY packages/quant/package.json packages/quant/
COPY apps/keeper/package.json apps/keeper/
COPY apps/indexer/package.json apps/indexer/
COPY apps/web/package.json apps/web/

RUN pnpm install --frozen-lockfile --filter @amplestocks/keeper...

COPY packages/config packages/config
COPY packages/abis packages/abis
COPY apps/keeper apps/keeper

# `@amplestocks/config` compiles to `dist`; `@amplestocks/abis` is committed TypeScript with no build step, and
# the keeper runs from source under `tsx` (see apps/keeper/README.md).
RUN pnpm --filter @amplestocks/config build \
 && pnpm --filter @amplestocks/keeper typecheck

FROM node:22.22-bookworm-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production
ENV PNPM_HOME=/pnpm
ENV PATH=$PNPM_HOME:$PATH
RUN corepack enable && useradd --create-home --uid 10001 keeper

COPY --from=build --chown=keeper:keeper /app /app

USER keeper
EXPOSE 9464

# The scrape endpoint doubles as the liveness probe: `/readyz` fails once a scan is four intervals overdue.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.AMPS_METRICS_PORT||9464)+'/readyz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

WORKDIR /app/apps/keeper
CMD ["pnpm", "start"]
