# Build stage
FROM alpine:3.21 AS build

RUN apk add --no-cache curl tar xz

ARG ZIG_VERSION=0.15.2
ARG TARGETARCH=amd64
RUN ZIG_ARCH=$(case "${TARGETARCH}" in amd64) echo x86_64;; arm64) echo aarch64;; *) echo "${TARGETARCH}";; esac) && \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /usr/local --strip-components=1

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src/ src/

ARG TARGETARCH=amd64
RUN --mount=type=cache,target=/root/.cache/zig \
    ZIG_TARGET=$(case "${TARGETARCH}" in amd64) echo x86_64-linux-musl;; arm64) echo aarch64-linux-musl;; *) echo "${TARGETARCH}-linux-musl";; esac) && \
    /usr/local/zig build -Doptimize=ReleaseFast -Dtarget="${ZIG_TARGET}"

# Runtime stage
FROM scratch

LABEL org.opencontainers.image.title="cyberdan-chess-solver" \
      org.opencontainers.image.description="Bitboard-based chess engine with HTTP API, UCI, and Lichess bot support" \
      org.opencontainers.image.source="https://github.com/cyberdan/cyberdan-chess-solver"

ENV CORS_PERMISSIVE=""

COPY --from=build /src/zig-out/bin/cyberdan-chess-solver /cyberdan-chess-solver

USER 65534:65534

EXPOSE 8080

ENTRYPOINT ["/cyberdan-chess-solver"]
CMD ["serve"]
