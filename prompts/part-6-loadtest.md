# Part 6: Load test and observability

Produces `part-6-loadtest/` (k6 script, monitoring manifests, dashboard JSON and screenshot), `scripts/60-loadtest.sh` and `LOADTEST.md`.

## Build prompt: monitoring

```text
Install kube-prometheus-stack (Prometheus and Grafana in one chart) with small
resource settings for a laptop. Pin the chart version, because an unpinned chart
installs whatever is newest on the reviewer's machine.

- Set the *SelectorNilUsesHelmValues options to false, so Prometheus picks up our
  ServiceMonitor and PrometheusRule without a release label.
- ServiceMonitor for quote-api on the `http` port every 10 s. No prometheus.io
  annotations, because this stack does not use them.
- PrometheusRule with two alerts: P95 latency of /api/quote above 0.45 s for 2 minutes,
  and 5xx ratio above 1% for 1 minute. Justify 0.45 s from measurements, not a
  generic number.
- Dashboard with request rate, P50/P95/P99 latency, HPA current/desired/min replicas
  and CPU per pod. Keep grafana-dashboard.json as the only copy and create the
  ConfigMap from it in the script, because two copies drift.
- Grafana admin password from a generated Secret, never in values, because the
  assignment fails any committed secret.
- Give Grafana enough CPU to start: the first start runs database migrations, which
  took minutes at 250m.
```

## Build prompt: k6 and the script

```text
k6 script against /api/quote through the ingress: 20 s to 4 VUs, 45 s to 16, 35 s
to 20, 15 s down to 0, with 150 ms sleep per iteration. This ramps past what 3 pods
can serve (each pod has 0.5 CPU and each request uses 0.1 CPU, so about 5 RPS per pod),
which forces the HPA to scale.

Thresholds, with the measurement each is based on in a comment:
http_req_failed < 1%, p(95) < 450 ms (same as the alert), p(99) < 850 ms,
checks > 99%. Use the built-in metrics; with one endpoint, custom metrics would only
duplicate them.

scripts/60-loadtest.sh: install the stack, apply the monitoring resources, record
HPA state every 5 s in the background but only log changes, run k6 with --quiet (the
progress bar floods logs), then print the HPA log and pod placement.
```

## Review prompt: is the evidence real?

```text
The first dashboard "screenshot" was a hand-drawn SVG, and LOADTEST.md had numbers
that were not from a run. Replace both with measurements:
- Measure a 1-VU baseline (P50 105 ms, P95 139 ms, P99 145 ms).
- Run the full test three times and record requests, error rate and P95/P99.
- Take a real Grafana screenshot during a run with a headless browser. The first
  attempt showed "Could not load plugin": Playwright 1.49's Chromium was too old for
  Grafana 13, so use a current Playwright.
- Note what the numbers showed: at 10 pods each used about 0.4 CPU, under its limit,
  so on a 4-CPU machine the next bottleneck is node capacity, not the pod limit.
```

## Build prompt: LOADTEST.md

```text
Half a page: the machine it ran on, baseline latency, per-pod and 3-pod ceilings,
the measured peak and percentiles at 10 replicas, the HPA log, the placement table at
peak, the bottleneck, and what to scale first in production (pod CPU and worker
threads, then nodes through Karpenter, then caching) with the reason for that order.
```
