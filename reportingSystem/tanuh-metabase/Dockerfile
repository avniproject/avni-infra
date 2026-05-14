###########################################################################
# Tanuh-branded Metabase — multi-stage source build.
#
# Stage 1 clones Metabase at the pinned tag, applies our branding overlays
# (LogoIcon component, two clj setting defaults, logo + favicon assets) and
# runs the upstream build script to produce metabase.jar.
#
# Stage 2 is the runtime image, mirroring the upstream Dockerfile's runner
# stage (eclipse-temurin:21-jre-alpine + fonts + AWS RDS CA bundle).
#
# Build time: ~30–60 min on a fast machine. Use BuildKit + cache mounts in
# CI to speed up incremental builds.
###########################################################################

# Tag for the upstream Metabase release we're branding (e.g. v0.60.4.1).
ARG METABASE_VERSION=v0.60.4.1

###########################################################################
# STAGE 1: builder
###########################################################################
FROM node:22-bullseye AS builder

ARG METABASE_VERSION
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /build

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        wget gpg curl git ca-certificates apt-transport-https \
    && wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
        | gpg --dearmor | tee /etc/apt/trusted.gpg.d/adoptium.gpg > /dev/null \
    && echo "deb https://packages.adoptium.net/artifactory/deb $(awk -F= '/^VERSION_CODENAME/{print$2}' /etc/os-release) main" \
        | tee /etc/apt/sources.list.d/adoptium.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends temurin-21-jdk \
    && curl -fsSLO https://download.clojure.org/install/linux-install-1.12.0.1488.sh \
    && chmod +x linux-install-1.12.0.1488.sh \
    && ./linux-install-1.12.0.1488.sh \
    && rm -f linux-install-1.12.0.1488.sh \
    && curl -LsSf https://astral.sh/uv/install.sh | sh \
    && npm install -g bun \
    && rm -rf /var/lib/apt/lists/*

# Clone Metabase at the pinned tag. Shallow clone keeps the layer small.
RUN git clone --depth 1 --branch "${METABASE_VERSION}" \
        https://github.com/metabase/metabase.git . \
    && git config --global --add safe.directory /build

# Sanity-check upstream paths before applying overlays. If Metabase upstream
# moves any of these, the build fails LOUDLY at this step rather than at the
# silent point where our overlay no longer takes effect.
RUN set -e; \
    for f in \
        frontend/src/metabase/common/components/LogoIcon/LogoIcon.tsx \
        src/metabase/appearance/settings.clj \
        resources/frontend_client/app/assets/img/favicon.ico \
        resources/frontend_client/app/assets/img/logo.svg \
    ; do \
        test -f "$f" || { echo "ERROR: upstream path missing: $f"; exit 1; }; \
    done

# Apply patches first (small targeted clj defaults), then overlay the
# replacement files (LogoIcon component + branding assets).
COPY patches/ /tanuh-patches/
RUN for p in /tanuh-patches/*.patch; do \
        echo "Applying patch: $p"; \
        git apply --verbose "$p"; \
    done

COPY files/LogoIcon.tsx \
    frontend/src/metabase/common/components/LogoIcon/LogoIcon.tsx
COPY assets/logo.png \
    resources/frontend_client/app/assets/img/logo.png

# The favicon is the same Tanuh PNG. Patch 0001 redirects the
# application-favicon-url setting default to app/assets/img/logo.png so the
# HTML <link rel="icon"> resolves to our logo. No separate .ico needed.

# Install JS deps and build the uberjar. INTERACTIVE=false CI=true matches
# upstream's own Dockerfile.
RUN bun install --frozen-lockfile
RUN INTERACTIVE=false CI=true MB_EDITION=oss \
    bin/build.sh :version "${METABASE_VERSION}"

###########################################################################
# STAGE 2: runner — mirrors upstream Dockerfile's runner stage.
###########################################################################
FROM eclipse-temurin:21-jre-alpine AS runner

ENV FC_LANG=en-US LC_CTYPE=en_US.UTF-8

# Copy CA cert from builder before keytool import.
COPY --from=builder /build/bin/docker/DigiCertGlobalRootG2.crt.pem \
    /app/certs/DigiCertGlobalRootG2.crt.pem

RUN apk add -U bash fontconfig curl \
        font-noto font-noto-arabic font-noto-hebrew font-noto-cjk \
        java-cacerts \
    && apk upgrade \
    && rm -rf /var/cache/apk/* \
    && curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
        -o /app/certs/rds-combined-ca-bundle.pem \
    && /opt/java/openjdk/bin/keytool -noprompt -import -trustcacerts \
        -alias aws-rds -file /app/certs/rds-combined-ca-bundle.pem \
        -keystore /etc/ssl/certs/java/cacerts -keypass changeit -storepass changeit \
    && /opt/java/openjdk/bin/keytool -noprompt -import -trustcacerts \
        -alias azure-cert -file /app/certs/DigiCertGlobalRootG2.crt.pem \
        -keystore /etc/ssl/certs/java/cacerts -keypass changeit -storepass changeit \
    && mkdir -p /plugins && chmod a+rwx /plugins

COPY --from=builder /build/target/uberjar/metabase.jar /app/metabase.jar
COPY --from=builder /build/bin/docker/run_metabase.sh /app/run_metabase.sh

EXPOSE 3000
ENTRYPOINT ["/app/run_metabase.sh"]
