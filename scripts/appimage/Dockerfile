# Builder image for the yacwu AppImage.
#
# Ubuntu 20.04 (glibc 2.31) keeps the produced binaries compatible with old
# distros: an AppImage carries everything except glibc, so the glibc the
# Erlang runtime was built against sets the compatibility floor.
FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates git unzip file imagemagick xz-utils \
    libssl1.1 libncurses6 zlib1g \
    && rm -rf /var/lib/apt/lists/*

# Prebuilt Erlang/OTP for this exact distro and CPU architecture from hex.pm's
# build service (the same builds erlef/setup-beam uses), so nothing is compiled
# here. Its crypto NIF links the distro's libssl 1.1 dynamically; the AppImage
# bundles that library alongside the runtime.
ARG OTP_VERSION=27.3
RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in amd64|arm64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1;; esac \
    && curl -fsSL "https://builds.hex.pm/builds/otp/${arch}/ubuntu-20.04/OTP-${OTP_VERSION}.tar.gz" \
      -o /tmp/otp.tar.gz \
    && mkdir /opt/erlang \
    && tar -xzf /tmp/otp.tar.gz -C /opt/erlang --strip-components=1 \
    && /opt/erlang/Install -minimal /opt/erlang \
    && rm /tmp/otp.tar.gz
ENV PATH="/opt/erlang/bin:${PATH}"

# Gleam (statically linked musl build, runs anywhere) + rebar3 (escript).
ARG GLEAM_VERSION=1.18.1
RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in amd64) gleam_arch=x86_64;; arm64) gleam_arch=aarch64;; *) echo "Unsupported architecture: $arch" >&2; exit 1;; esac \
    && curl -fsSL "https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/gleam-v${GLEAM_VERSION}-${gleam_arch}-unknown-linux-musl.tar.gz" \
      | tar -xz -C /usr/local/bin gleam \
    && curl -fsSL https://s3.amazonaws.com/rebar3/rebar3 -o /usr/local/bin/rebar3 \
    && chmod +x /usr/local/bin/rebar3

# Bun, for building the web UI.
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# appimagetool; APPIMAGE_EXTRACT_AND_RUN lets it run without FUSE in Docker.
RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in amd64) appimage_arch=x86_64;; arm64) appimage_arch=aarch64;; *) echo "Unsupported architecture: $arch" >&2; exit 1;; esac \
    && curl -fsSL "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${appimage_arch}.AppImage" \
      -o /usr/local/bin/appimagetool \
    && chmod +x /usr/local/bin/appimagetool
ENV APPIMAGE_EXTRACT_AND_RUN=1

COPY build-inside.sh /usr/local/bin/build-inside.sh
COPY AppRun /opt/appimage/AppRun
RUN chmod +x /usr/local/bin/build-inside.sh /opt/appimage/AppRun

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/build-inside.sh"]
