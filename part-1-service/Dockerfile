# syntax=docker/dockerfile:1

# Stage 1: install production dependencies only (lockfile-exact, no scripts)
FROM node:24-trixie-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

# Stage 2: distroless runtime: node binary + app only, no shell, non-root
FROM gcr.io/distroless/nodejs24-debian13:nonroot
WORKDIR /app
ENV NODE_ENV=production \
    PORT=3000
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
USER 65532:65532
EXPOSE 3000
# The distroless entrypoint is already `node`
CMD ["src/index.js"]
