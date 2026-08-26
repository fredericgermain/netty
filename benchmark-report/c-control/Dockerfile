# Build image for the C io_uring-vs-epoll control experiment.
#
# Everything is built inside the container because we have no root on the test host and
# cannot install liburing-dev there.
#
# Build with --network=host: the test host's docker bridge is not reliable for outbound TCP.
# Run with --security-opt seccomp=unconfined: docker's default seccomp profile blocks
# io_uring_setup, which would make io_uring look unavailable rather than slow.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        build-essential \
        liburing-dev \
        pkg-config \
        ca-certificates \
        git \
        cargo \
        rustc \
    && rm -rf /var/lib/apt/lists/*

# Pinned to the exact commits whose numbers we are reproducing against.
ARG IOURING_SRV_SHA=dc00940baeec2ac577410dfa4d881d0852b01a08
ARG EPOLL_SRV_SHA=22f325165c3e9749aca85a777cbb8f9b66ea7a27
ARG BENCH_SHA=920f8a5a2ab4d99ebb71bdc1b9fe9e62e303ecdf

WORKDIR /src

RUN git clone https://github.com/frevib/io_uring-echo-server.git iouring \
    && git -C iouring checkout -q ${IOURING_SRV_SHA} \
    && git clone https://github.com/frevib/epoll-echo-server.git epoll \
    && git -C epoll checkout -q ${EPOLL_SRV_SHA} \
    && git clone https://github.com/haraldh/rust_echo_bench.git bench \
    && git -C bench checkout -q ${BENCH_SHA}

RUN mkdir -p /opt/bin \
    && git -C iouring rev-parse HEAD > /opt/bin/COMMITS.txt \
    && git -C epoll rev-parse HEAD >> /opt/bin/COMMITS.txt \
    && git -C bench rev-parse HEAD >> /opt/bin/COMMITS.txt \
    && dpkg -s liburing-dev | grep ^Version >> /opt/bin/COMMITS.txt \
    && gcc --version | head -1 >> /opt/bin/COMMITS.txt

# --- Stock binaries: byte-for-byte upstream, used for the reproduction runs. ---

RUN gcc -Wall -O2 -o /opt/bin/io_uring_echo_server_stock \
        /src/iouring/io_uring_echo_server.c -luring \
    && gcc -Wall -O2 -o /opt/bin/epoll_echo_server_stock \
        /src/epoll/epoll_echo_server.c

RUN cd /src/bench && cargo build --release --offline 2>/dev/null || cargo build --release
RUN cp /src/bench/target/release/echo_bench /opt/bin/echo_bench_stock

# --- Patched binaries: large-payload sweep only. ---
#
# Upstream caps a single echo at MAX_MESSAGE_LEN 2048. Above that the epoll server
# deadlocks outright: it is edge-triggered and does exactly one recv() per event, so a
# message split across segments is never fully drained and epoll never re-arms while the
# lockstep client waits. Both servers get the identical cap raise so the comparison stays
# symmetric. BUFFERS_COUNT drops to 1024 to keep the io_uring server's static buffer pool
# at 64 MB instead of 256 MB; ping-pong holds at most one buffer per connection, so 1024
# covers every connection count we sweep.

RUN sed -e 's/#define MAX_MESSAGE_LEN     2048/#define MAX_MESSAGE_LEN     65536/' \
        -e 's/#define BUFFERS_COUNT       MAX_CONNECTIONS/#define BUFFERS_COUNT       1024/' \
        /src/iouring/io_uring_echo_server.c > /src/io_uring_echo_server_big.c \
    && grep -q 'MAX_MESSAGE_LEN     65536' /src/io_uring_echo_server_big.c \
    && grep -q 'BUFFERS_COUNT       1024' /src/io_uring_echo_server_big.c \
    && gcc -Wall -O2 -o /opt/bin/io_uring_echo_server_big /src/io_uring_echo_server_big.c -luring

RUN sed -e 's/#define MAX_MESSAGE_LEN 2048/#define MAX_MESSAGE_LEN 65536/' \
        /src/epoll/epoll_echo_server.c > /src/epoll_echo_server_big.c \
    && grep -q 'MAX_MESSAGE_LEN 65536' /src/epoll_echo_server_big.c \
    && gcc -Wall -O2 -o /opt/bin/epoll_echo_server_big /src/epoll_echo_server_big.c

# The stock client issues one read() and declares a read error unless it returns the whole
# message, which kills that connection's thread and silently shrinks the load. Harmless at
# 128-1000 bytes, fatal above the point where a reply spans segments. Reading to completion
# is what makes the large-payload cells measurable at all, and it applies to both servers.
COPY patch-bench.pl /src/patch-bench.pl
RUN cd /src/bench && perl /src/patch-bench.pl src/main.rs \
    && cargo build --release \
    && cp target/release/echo_bench /opt/bin/echo_bench_loop \
    && git checkout -- src/main.rs

ENV PATH=/opt/bin:$PATH
WORKDIR /opt/bin
