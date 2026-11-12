# Part 8: Optional local tooling

Produces `scripts/70-headlamp.sh`, `tools/headlamp/`, `scripts/80-network-test.sh`, `scripts/90-stop.sh` and `scripts/99-cleanup.sh`. None of these are in `run-all.sh`, because they are for working with the cluster and would only make the reviewer's run longer.

## Build prompt: Headlamp

```text
Add Headlamp so I can inspect the cluster in a browser. Pin the chart version.
Serve it through the existing Traefik ingress at headlamp.localhost:8080, because
*.localhost resolves to 127.0.0.1 in browsers, so no new port and no hosts-file edit.
Do not give the Headlamp pod any cluster role; the UI acts with the token you log in
with. Create a separate read-only account (get/list/watch only) and print a 24-hour
token, because inspecting needs no write access. Check with `kubectl auth can-i` that
delete, create, patch and exec are denied.
```

## Build prompt: in-cluster network test

```text
The toolbox is a Docker container, not a pod, so it cannot resolve *.svc.cluster.local
or reach Service IPs. Write 80-network-test.sh that starts a curl pod and checks each
layer: cluster DNS names, Service load balancing across pods, direct pod IPs, Traefik
inside the cluster, the host path, and the NetworkPolicy in `troubleshoot`.

For the NetworkPolicy, a failed connection alone proves nothing (the service could be
down). So: first confirm web-svc has endpoints, then expect an unlabeled pod to be
refused or time out, and expect a pod labeled app=smoke-client to get HTTP 200.
Retry the allowed check for a few seconds, because k3s applies policy rules to a new
pod shortly after it starts.
```

## Review prompt: the test passed for the wrong reason

```text
The first version ran each check in `sh -c`, where the script's functions do not
exist. The "must be denied" check passed only because the command failed. Run checks
directly in the script, and accept only the specific curl exit codes for refused (7)
or timed out (28).
```

## Build prompt: stop and cleanup

```text
90-stop.sh: stop the k3d containers and the toolbox, keep all state. Resume is
`docker compose up -d`, which works because 00-bootstrap starts a stopped cluster.

99-cleanup.sh: return the workspace to a fresh clone: delete the k3d cluster
(containers, network, volume), the toolbox (container, network, volume, image), the
built quote-api images, and .terraform/.kube in the repo. Select only this project's
resources by exact name and k3d's labels, because the user's Docker has other things
in it. Keep pulled base images unless --images is given (faster next start). List
everything first, support --dry-run, and require typing "yes" or passing --yes.
Without a terminal and without --yes, refuse.

Both run on the host and refuse to run inside the toolbox, because a container
cannot remove itself.
```
