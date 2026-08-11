# Solar2D Linux Build Environment
# Single image with both Solar2DBuilder and Solar2DSimulator.
#
# Usage:
#   docker build --build-arg SOLAR2D_VERSION=2026.3728 -t solar2d mobile/docker/
#
#   # HTML5 build (CI/CD or local)
#   docker run -v $(pwd)/mobile/corona:/project -v $(pwd)/mobile/html5-build:/output \
#     solar2d build --app-name MyApp
#
#   # Android build (APK + AAB)
#   docker run -v $(pwd)/mobile/corona:/project -v $(pwd)/mobile/android-build:/output \
#     solar2d build-android --app-name MyApp --package com.example.myapp
#
#   # Simulator with hot-reload
#   docker run -v $(pwd)/mobile/corona:/project solar2d simulate
#
#   # Show available commands
#   docker run solar2d

# ============================================================
# Stage 1: Build both targets from source
# ============================================================
FROM debian:bookworm-slim AS compile

# Single version arg, e.g. "2026.3728" — tag is derived as everything after the dot
ARG SOLAR2D_VERSION
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    ca-certificates \
    libgl1-mesa-dev \
    libfreetype-dev \
    libcurl4-gnutls-dev \
    libpcap-dev \
    libssl-dev \
    libsdl2-dev \
    libjpeg-dev \
    libpng-dev \
    zlib1g-dev \
    libboost-all-dev \
    libopenal-dev \
    lua5.3 \
    liblua5.3-dev \
    wget \
    msitools \
    libgtk-3-dev \
    libwebkit2gtk-4.0-dev \
    && rm -rf /var/lib/apt/lists/*

# Solar2D comes from our fork, on a branch cut from the release tag and carrying the
# Linux fixes the upstream tree lacks: the HTML5 builder, the Android builder, and
# the display.save() channel order that made every simulator screenshot blue.
# A new release needs a matching linux-<tag> branch pushed first; the clone fails
# loudly if it is missing, which is the intended signal.
# Point SOLAR2D_REPO/SOLAR2D_REF elsewhere to build any other tree or branch.
ARG SOLAR2D_REPO=https://github.com/chkuendig/corona.git
ARG SOLAR2D_REF=""
# The ref is a branch, so its content changes without its name changing — and a
# cached clone layer would then silently keep building the old tree. Pass the
# resolved commit here (CI does) so moving the branch busts the cache.
#   gh api repos/chkuendig/corona/commits/linux-3728 --jq .sha
ARG SOLAR2D_REF_SHA=""

WORKDIR /opt
RUN REF="${SOLAR2D_REF:-linux-${SOLAR2D_VERSION#*.}}" && \
    echo "Cloning $SOLAR2D_REPO @ $REF (sha ${SOLAR2D_REF_SHA:-unpinned})" && \
    git clone --recursive --depth=1 --branch "$REF" "$SOLAR2D_REPO" solar2d && \
    if [ -n "$SOLAR2D_REF_SHA" ]; then \
      GOT=$(git -C solar2d rev-parse HEAD); \
      [ "$GOT" = "$SOLAR2D_REF_SHA" ] || { echo "ref sha mismatch: wanted $SOLAR2D_REF_SHA, got $GOT" >&2; exit 1; }; \
    fi

# Replace the 0-byte webtemplate.zip placeholder with the real one from the official
# Windows release. The source tree only ships a 0-byte placeholder — the real WASM engine
# (coronaHtml5App.wasm + JS glue) is built by Solar2D's CI using Emscripten on macOS and
# only shipped inside the Windows MSI and macOS DMG installers. The Linux cmake build has
# no Emscripten build step, so it would just copy the 0-byte placeholder into
# build/Resources/ and fail at runtime. By placing the real file here before cmake runs,
# the build picks it up automatically and no patching of the Lua sanity check is needed.
# See also: https://github.com/coronalabs/corona/pull/835
# The same MSI also carries the Android half of the toolchain, which the source tree
# does not build on Linux either: Native/Corona/android holds android-template.zip
# (the Gradle project every Android build is generated from) and Corona.aar (the
# engine). Ant's setup-gradle-builds target looks for them under <Resources>/Native,
# so they are staged here and copied next to the built Resources below.
RUN wget -q "https://github.com/coronalabs/corona/releases/download/${SOLAR2D_VERSION#*.}/Solar2D-Windows-${SOLAR2D_VERSION}.msi" \
        -O /tmp/solar2d.msi && \
    mkdir /tmp/msi-extract && \
    cd /tmp/msi-extract && \
    msiextract /tmp/solar2d.msi && \
    WEBTEMPLATE=$(find /tmp/msi-extract -name "webtemplate.zip" -print -quit) && \
    test -n "$WEBTEMPLATE" && \
    cp "$WEBTEMPLATE" /opt/solar2d/platform/resources/webtemplate.zip && \
    NATIVE=$(find /tmp/msi-extract -type d -path "*/Native/Corona" -print -quit) && \
    test -n "$NATIVE" && \
    mkdir -p /opt/native-staging && \
    cp -r "$NATIVE/android" "$NATIVE/shared" /opt/native-staging/ && \
    test -f /opt/native-staging/android/resource/android-template.zip && \
    test -f /opt/native-staging/android/lib/gradle/Corona.aar && \
    rm -rf /tmp/msi-extract /tmp/solar2d.msi

# Optional: build with upstream pull requests applied, e.g. SOLAR2D_PRS="891 935".
# Fetched as diffs rather than merged because the clone is shallow — there is no
# common history to merge against.
ARG SOLAR2D_PRS=""
RUN if [ -n "$SOLAR2D_PRS" ]; then \
      cd /opt/solar2d && \
      for pr in $SOLAR2D_PRS; do \
        echo "Applying coronalabs/corona PR #$pr" && \
        wget -q "https://github.com/coronalabs/corona/pull/${pr}.diff" -O /tmp/pr.diff && \
        git apply --check /tmp/pr.diff && git apply /tmp/pr.diff && rm /tmp/pr.diff; \
      done; \
    fi

WORKDIR /opt/solar2d/build
RUN cmake .. && make -j$(nproc) Solar2DBuilder Solar2DSimulator

# cmake copies neither of these into build/Resources: the Native tree because it is
# not built on Linux at all, AndroidValidation.lua because it is read from disk at
# build time rather than compiled into the binary like the other Lua resources.
RUN mkdir -p /opt/solar2d/build/Resources/Native/Corona && \
    cp -r /opt/native-staging/android /opt/native-staging/shared \
          /opt/solar2d/build/Resources/Native/Corona/ && \
    cp /opt/solar2d/platform/resources/AndroidValidation.lua /opt/solar2d/build/Resources/

RUN /opt/solar2d/build/Solar2DBuilder build --help 2>&1 | head -5
RUN ls -la /opt/solar2d/build/Solar2DSimulator

# ============================================================
# Stage 2: Runtime (single image with both tools)
# ============================================================
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    # Shared runtime libs
    libgl1-mesa-dri \
    libfreetype6 \
    libcurl3-gnutls \
    libpcap0.8 \
    libssl3 \
    libsdl2-2.0-0 \
    libjpeg62-turbo \
    libpng16-16 \
    zlib1g \
    libopenal1 \
    lua5.3 \
    liblua5.3-0 \
    # Builder: zip/unzip for HTML5 packaging
    unzip \
    zip \
    # Android: Ant and Gradle both run on the JDK, and Rtt_AndroidAppPackager
    # hardcodes /usr/bin/java on Linux — which is what this package provides.
    # 17 is the version the packager probes for before invoking the wrapper.
    openjdk-17-jdk-headless \
    # Gradle downloads its own distribution and the Android SDK packages
    ca-certificates \
    curl \
    # Simulator: X11/OpenGL for headless rendering
    libgl1-mesa-glx \
    mesa-utils \
    xvfb \
    x11-utils \
    libgtk-3-0 \
    libwebkit2gtk-4.0-37 \
    # MCP: stitches recorded frames into an MP4
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Copy both binaries and shared resources
COPY --from=compile /opt/solar2d/build/Solar2DBuilder /usr/local/bin/Solar2DBuilder
COPY --from=compile /opt/solar2d/build/Solar2DSimulator /usr/local/bin/Solar2DSimulator
COPY --from=compile /opt/solar2d/build/Resources/ /usr/local/share/solar2d/Resources/
RUN mkdir -p /usr/local/bin/Resources
COPY --from=compile /opt/solar2d/build/Resources/ /usr/local/bin/Resources/

# Android SDK. compileSdk/targetSdk are 35 in Solar2D's Gradle template; build-tools
# must match. Only the three packages a Solar2D build actually reaches for are
# installed — the full SDK is several GB. The licences directory is made writable
# because the template's setup.sh re-appends the SDK licence on every build: a no-op
# as root, but the dev container runs as an ordinary user and would fail there.
ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PATH=$PATH:/opt/android-sdk/platform-tools:/opt/android-sdk/cmdline-tools/latest/bin

ARG ANDROID_CMDLINE_TOOLS=11076708
ARG ANDROID_API=35
ARG ANDROID_BUILD_TOOLS=35.0.0
RUN mkdir -p "$ANDROID_HOME/cmdline-tools" && \
    curl -fsSL -o /tmp/cmdline-tools.zip \
      "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip" && \
    unzip -q /tmp/cmdline-tools.zip -d "$ANDROID_HOME/cmdline-tools" && \
    mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest" && \
    rm /tmp/cmdline-tools.zip && \
    yes | sdkmanager --licenses > /dev/null && \
    sdkmanager --install "platform-tools" "platforms;android-${ANDROID_API}" \
      "build-tools;${ANDROID_BUILD_TOOLS}" > /dev/null && \
    chmod -R a+rwX "$ANDROID_HOME/licenses"

# Gradle's own distribution, pre-fetched so a build does not spend its first two
# minutes downloading it. The version is pinned by the wrapper inside
# android-template.zip; reading it from there keeps the two from drifting apart.
# The dependency cache is deliberately left cold — it is large, changes with the
# project, and belongs in a mounted GRADLE_USER_HOME instead.
ENV GRADLE_USER_HOME=/gradle-cache
RUN mkdir -p /gradle-cache /tmp/gradle-warm && \
    unzip -qo /usr/local/bin/Resources/Native/Corona/android/resource/android-template.zip \
      "template/*" -d /tmp/gradle-warm && \
    chmod +x /tmp/gradle-warm/template/gradlew && \
    (cd /tmp/gradle-warm/template && ./gradlew --version > /dev/null) && \
    rm -rf /tmp/gradle-warm && \
    chmod -R 0777 /gradle-cache

COPY build-html5.sh build-android.sh /usr/local/bin/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/build-html5.sh /usr/local/bin/build-android.sh /usr/local/bin/entrypoint.sh

# solar2d-mcp: Python MCP server for simulator control (screenshots, taps, logs).
# Our Linux work lives on the `linux-fixes` branch of the fork, pinned by commit:
# the simulator argument format, and waiting a frame for display.save() to write.
# Both sit on top of upstream main — the stdout→DEVNULL fix we used to carry is
# upstream's own now.
#   fork:     https://github.com/chkuendig/solar2d-mcp/tree/linux-fixes
#   upstream: https://github.com/sensiblecoder/solar2d-mcp
ARG SOLAR2D_MCP_REF=842c893f18e62913bc12ec52fa4d5ded0854b6ea
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-pip && \
    pip3 install --break-system-packages \
      "solar2d-mcp-server @ https://github.com/chkuendig/solar2d-mcp/archive/${SOLAR2D_MCP_REF}.tar.gz" && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /root/.config/solar2d-mcp && \
    echo '{"simulator_path":"/usr/local/bin/Solar2DSimulator"}' > /root/.config/solar2d-mcp/config.json

LABEL org.opencontainers.image.source=https://github.com/chkuendig/docker-solar2d

VOLUME ["/project", "/output"]
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
