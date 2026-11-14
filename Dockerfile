# syntax=docker/dockerfile:1
#
# Step 5 - Secure Docker image for the MedSecure patient API.
#
# Hardening compared with the handout's 3-line example:
#   * Node 24 LTS instead of Node 18: Node 18 is end-of-life (April 2025) and
#     node:18-alpine ships an end-of-life Alpine 3.21 - the pipeline's Trivy
#     stage blocks both (scripts/ci/trivy-image.sh).
#   * Base image pinned by digest (reproducible; nobody can swap the tag under us).
#   * Multi-stage build: only production dependencies reach the final image.
#   * npm, npx, corepack and yarn are deleted from the runtime image: the app
#     does not need them, and they are the main source of CVEs in node images.
#   * apk upgrade pulls in the latest Alpine security patches.
#   * Runs as a dedicated non-root user (uid 10001) with no shell or home.
#   * App files are owned by root and read-only for appuser, so a compromised
#     process cannot modify its own code.
ARG NODE_IMAGE=node:24-alpine@sha256:116b800c3754b440ee0aa3ed2f20f5bf3d99a554bfd9adeea09ea8017f6e85f5

# ---- Stage 1: install production dependencies --------------------------------
FROM ${NODE_IMAGE} AS deps
WORKDIR /build
COPY app/package.json app/package-lock.json ./
# --ignore-scripts: never run install scripts from third-party packages.
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
 && npm cache clean --force

# ---- Stage 2: minimal runtime --------------------------------------------------
FROM ${NODE_IMAGE} AS runtime

LABEL org.opencontainers.image.title="medsecure-patient-api" \
      org.opencontainers.image.description="VLE-9 Healthcare DevSecOps lab - patient records API" \
      org.opencontainers.image.licenses="MIT"

ENV NODE_ENV=production \
    PORT=3000 \
    METRICS_PORT=9464

RUN apk upgrade --no-cache \
 && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
           /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
           /usr/local/bin/yarn /usr/local/bin/yarnpkg /opt/yarn-* \
 && deluser --remove-home node \
 && addgroup -S -g 10001 appgroup \
 && adduser -S -D -H -u 10001 -G appgroup -s /sbin/nologin appuser

WORKDIR /app
COPY --from=deps --chown=root:root /build/node_modules ./node_modules
COPY --chown=root:root app/package.json ./
COPY --chown=root:root app/src ./src
COPY --chown=root:root app/public ./public

# Numeric uid:gid so Kubernetes can verify runAsNonRoot.
USER 10001:10001

EXPOSE 3000 9464

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["node", "src/healthcheck.js"]

ENTRYPOINT ["node"]
CMD ["src/server.js"]
