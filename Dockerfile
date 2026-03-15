# Build stage
FROM alpine:3.21 AS build

RUN apk add --no-cache curl tar xz

ARG ZIG_VERSION=0.15.2
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /usr/local --strip-components=1

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src/ src/

RUN /usr/local/zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl

# Runtime stage
FROM scratch

COPY --from=build /src/zig-out/bin/cyberdan-chess-solver /cyberdan-chess-solver

EXPOSE 8080

ENTRYPOINT ["/cyberdan-chess-solver", "serve"]
