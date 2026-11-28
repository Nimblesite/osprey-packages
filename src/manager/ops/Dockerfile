FROM docker.io/library/debian:trixie-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0 AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates clang curl libdigest-sha-perl libssl-dev make \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY . .
RUN make _registry-hosted-api REGISTRY_HOSTED_BINARY=/out/osprey-registry-hosted

FROM docker.io/library/debian:trixie-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates openssl postgresql-client-17 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/osprey-registry-hosted /usr/local/bin/osprey-registry-hosted
WORKDIR /tmp
USER 65532:65532
EXPOSE 8080 8081
ENTRYPOINT ["/usr/local/bin/osprey-registry-hosted"]
