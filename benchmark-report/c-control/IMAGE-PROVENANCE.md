# iouring-control:latest, as built for the replication

Cell C of [REPLICATION.md](../REPLICATION.md) is netty's server driven by this image's C client, so
what is in the image is part of the measurement. Rebuilt 2026-11-17 on thor from
`c-control/Dockerfile` with `docker build --network=host`, to be saved onto the replication USB key
and run unchanged on both machines.

| | |
|---|---|
| image id | `sha256:bfab28e5e4d895ced29618eb4b672ff7543678e5112abdb8e98df3c65c0d64b7` |
| size | 1.29GB |
| base | `ubuntu:24.04` |

Pinned upstream commits, read out of `/opt/bin/COMMITS.txt` in the built image rather than from the
Dockerfile, so this records what was actually compiled:

| component | commit or version |
|---|---|
| `frevib/io_uring-echo-server` | `dc00940baeec2ac577410dfa4d881d0852b01a08` |
| `frevib/epoll-echo-server` | `22f325165c3e9749aca85a777cbb8f9b66ea7a27` |
| `haraldh/rust_echo_bench` | `920f8a5a2ab4d99ebb71bdc1b9fe9e62e303ecdf` |
| liburing | 2.5-1build1 |
| gcc | gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0 |

Binaries in `/opt/bin`: `echo_bench_stock` (the client cell C uses), `echo_bench_loop`,
`io_uring_echo_server_stock`, `epoll_echo_server_stock`, and the `_big` variants whose
`MAX_MESSAGE_LEN` is raised to 65536 for the large-payload sweep.

**Two run-time requirements**, both of which otherwise fail quietly rather than loudly:
`--security-opt seccomp=unconfined`, because docker's default profile blocks `io_uring_setup` and
io_uring then looks unavailable rather than slow; and `--network=host` at build time, because this
host's docker bridge is not reliable for outbound TCP.
