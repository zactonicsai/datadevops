# Jenkins build agent for C++ projects.
FROM jenkins/inbound-agent:latest-jdk21

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential g++ gcc clang clang-tidy cmake ninja-build \
      ccache gdb git make pkg-config lcov cppcheck \
      libgtest-dev \
    && rm -rf /var/lib/apt/lists/*

# Debian ships GoogleTest as source only, so compile and install it once here.
RUN cmake -S /usr/src/googletest -B /tmp/gtest-build -DCMAKE_BUILD_TYPE=Release \
 && cmake --build /tmp/gtest-build -j"$(nproc)" \
 && cmake --install /tmp/gtest-build \
 && rm -rf /tmp/gtest-build

USER jenkins
ENV CCACHE_DIR=/home/jenkins/.ccache
