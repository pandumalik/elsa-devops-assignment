# Part 0: Harness (compose, toolbox, bootstrap)

Builds `docker-compose.yml`, `toolbox/Dockerfile`, `scripts/lib.sh`, `scripts/00-bootstrap-cluster.sh`, `scripts/run-all.sh`, `README.md` and `AI-USAGE.md`.

## Build prompt: compose + toolbox + cluster

```text
The reviewer will only run:
  git clone <repo> && cd <repo>
  docker compose up -d
  ./scripts/run-all.sh
so everything has to work from that, without reading docs.

1. toolbox/Dockerfile on debian:bookworm-slim with kubectl, helm, terraform, k3d, k6,
   docker CLI, git, jq, curl. Pin every tool version, because an unpinned install
   gives the reviewer a different toolset than the one I tested. Pick the binary by
   TARGETARCH, because reviewers on Apple Silicon need arm64.

2. docker-compose.yml with one service, elsa-toolbox. Mount the Docker socket
   (k3d creates the cluster as sibling containers) and the repo at /workspace
   (the assignment wants the scripts bind-mounted; mounting the whole repo covers that
   and lets scripts read the manifests).

3. scripts/00-bootstrap-cluster.sh: k3d cluster "elsa" with 1 server and 4 agents,
   host port ${INGRESS_PORT:-8080} -> 80 on the load balancer. Make it idempotent:
   create the cluster if missing, start it if it exists but is stopped. Then join the
   toolbox to the k3d network, write a kubeconfig that points at the server container,
   wait for nodes, and run troubleshoot/prepare.sh (the assignment requires it during
   bootstrap). The toolbox CMD runs this script, so `docker compose up -d` alone
   produces a ready cluster.
```

## Review prompt: running scripts from the host

```text
Two problems with the Golden Rule as written:

1. The reviewer runs ./scripts/run-all.sh on their host, which may not have kubectl,
   helm or k6. Put the shared logic in scripts/lib.sh: if a script runs on the host
   and elsa-toolbox is up, re-run it inside the toolbox with `docker exec ... sh`.
   Use `sh <script>` rather than executing it directly, so a lost executable bit in
   git does not break it.

2. compose starts 00-bootstrap in the background and run-all.sh starts it again a
   second later. Add a lock directory that stores the owner PID: the second run waits,
   and a lock left behind by a killed run (PID gone) is removed instead of blocking
   forever.

Also: when a script runs on the host, do not touch ~/.kube/config, because it may
point at a real cluster. Use a git-ignored kubeconfig inside the repo instead.
```

## Review prompt: output and failure handling

```text
The scripts print a lot of noise (helm, terraform init, docker build) and stop with
little context when something fails. In lib.sh add:
- step/log/warn/die helpers with one short prefix per script,
- run_logged <logfile> <cmd>: send noisy output to /tmp/elsa-logs/, print only the
  last lines on failure, so the normal run stays readable and failures stay debuggable,
- show_placement: one table of pod -> node -> pool (spot / on-demand), because that
  is the question every Part 2 and Part 6 step needs to answer.
run-all.sh should stop at the first failure (later steps depend on earlier ones) and
print a per-step time summary.
```

## Build prompt: README and AI-USAGE

```text
Write README.md with: quick start (the three Golden Rule commands), a Mermaid diagram
of compose -> toolbox -> k3d nodepools -> ArgoCD -> quote-api -> ingress (the
assignment says reviewers read this first), a second diagram for a production AWS
setup, one line per script, design decisions with what was cut and why, and three
likely problems on a reviewer's machine (port 8080 taken, too little Docker RAM,
arm64 vs amd64).

Write AI-USAGE.md with the tools used, three prompts that helped, and real cases
where the AI was wrong and how it was caught. Only include cases that actually
happened, because the reviewer will ask about them live.
```
