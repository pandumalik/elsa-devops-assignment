# Part 3 — Troubleshooting Challenge (`TROUBLESHOOTING.md`)

After running `./troubleshoot/prepare.sh` and applying `kubectl apply -f troubleshoot/broken-app.yaml`, we diagnosed and remediated **8 independent failure modes** across scheduling, volume mounting, image pulling, health probing, service routing, and CNI network policy enforcement.

---

## Initial Triage

```bash
kubectl get pods,svc,ep,networkpolicy -n troubleshoot -o wide
kubectl get events -n troubleshoot --sort-by='.lastTimestamp'
```

Both `web` and `ai-inference` pods were stuck in `Pending`, and `service/web-svc` had `<none>` endpoints.

---

## Issue 1 — `web` Pods Stuck in `Pending` (Excessive Memory Request)

- **Symptom:** Both replicas of `deployment/web` remained in `Pending` state immediately after applying `broken-app.yaml`.
- **Diagnostic Commands:**
  ```bash
  kubectl describe pod -n troubleshoot -l app=web
  kubectl describe nodes | grep -A 5 "Allocatable:"
  ```
- **Observed Event:**
  ```text
  Warning  FailedScheduling  default-scheduler  0/5 nodes are available: 1 node(s) had untolerated taint {nvidia.com/gpu: true}, 4 Insufficient memory.
  ```
- **Root Cause:** `deployment/web` requested `memory: 16Gi` (`limits.memory: 16Gi`) per replica, exceeding the allocatable memory of the local k3d worker nodes.
- **Fix:** Right-sized `resources.requests.memory` to `64Mi` and `resources.limits.memory` to `128Mi` (`cpu: 100m` request / `500m` limit).

---

## Issue 2 — `web` Pods Stuck in `CreateContainerConfigError` (Missing ConfigMap `web-conf`)

- **Symptom:** Once memory requests were lowered and the `web` pods were scheduled onto worker nodes, they entered `ContainerCreating` and then `CreateContainerConfigError`.
- **Diagnostic Commands:**
  ```bash
  kubectl describe pod -n troubleshoot -l app=web
  kubectl get configmap -n troubleshoot
  ```
- **Observed Event:**
  ```text
  Warning  Failed  kubelet  Error: configmap "web-conf" not found
  ```
- **Root Cause:** The volume `html` in `deployment/web` referenced `configMap.name: web-conf`, whereas the ConfigMap defined in the manifest is named `web-config`.
- **Fix:** Updated `spec.template.spec.volumes[0].configMap.name` from `web-conf` to `web-config`.

---

## Issue 3 — `web` Pods Stuck in `ErrImagePull` / `ImagePullBackOff` (`nginx:1.25.99`)

- **Symptom:** After the ConfigMap mount succeeded, the container failed to start with `ErrImagePull` / `ImagePullBackOff`.
- **Diagnostic Commands:**
  ```bash
  kubectl describe pod -n troubleshoot -l app=web | grep -A 6 "Events:"
  ```
- **Observed Event:**
  ```text
  Warning  Failed  kubelet  Failed to pull image "nginx:1.25.99": rpc error: code = NotFound desc = failed to pull and unpack image "docker.io/library/nginx:1.25.99": not found
  ```
- **Root Cause:** Tag `nginx:1.25.99` does not exist on Docker Hub (Nginx 1.25 releases only went up to `1.25.5`).
- **Fix:** Updated container image to `nginx:1.25-alpine`.

---

## Issue 4 — `web` Pods Unready & Restarting (`CrashLoopBackOff` on Port `8080` Probes)

- **Symptom:** Once `nginx:1.25-alpine` started, pods stayed `0/1 Running` and began restarting after ~15 seconds.
- **Diagnostic Commands:**
  ```bash
  kubectl describe pod -n troubleshoot -l app=web
  kubectl logs -n troubleshoot -l app=web
  ```
- **Observed Event:**
  ```text
  Warning  Unhealthy  kubelet  Readiness probe failed: Get "http://10.42.1.14:8080/": dial tcp 10.42.1.14:8080: connect: connection refused
  Warning  Unhealthy  kubelet  Liveness probe failed: Get "http://10.42.1.14:8080/": dial tcp 10.42.1.14:8080: connect: connection refused
  ```
- **Root Cause:** Default `nginx:1.25-alpine` listens on TCP port `80` (`containerPort: 80`), but both `livenessProbe` and `readinessProbe` targeted port `8080`.
- **Fix:** Changed `livenessProbe.httpGet.port` and `readinessProbe.httpGet.port` from `8080` to `80`.

---

## Issue 5 — `ai-inference` Pod Stuck in `Pending` (Mismatched `nodeSelector` Label Key)

- **Symptom:** `deployment/ai-inference` remained `0/1 Pending`.
- **Diagnostic Commands:**
  ```bash
  kubectl describe pod -n troubleshoot -l app=ai-inference
  kubectl get nodes --show-labels | grep gpu
  ```
- **Observed Event:**
  ```text
  Warning  FailedScheduling  default-scheduler  0/5 nodes are available: 5 node(s) didn't match Pod's node affinity/selector.
  ```
- **Root Cause:** `deployment/ai-inference` used `nodeSelector: { node-type: gpu }`, but `troubleshoot/prepare.sh` labeled the GPU node with the prefixed key `acme.io/node-type=gpu`.
- **Fix:** Updated `spec.template.spec.nodeSelector` to `acme.io/node-type: gpu`.

---

## Issue 6 — `ai-inference` Pod Still `Pending` (Untolerated GPU Taint)

- **Symptom:** After fixing `nodeSelector`, `ai-inference` still remained `Pending`.
- **Diagnostic Commands:**
  ```bash
  kubectl describe pod -n troubleshoot -l app=ai-inference
  kubectl get node -l acme.io/node-type=gpu -o jsonpath='{.items[0].spec.taints}'
  ```
- **Observed Event:**
  ```text
  Warning  FailedScheduling  default-scheduler  0/5 nodes are available: 1 node(s) had untolerated taint {nvidia.com/gpu: true}, 4 node(s) didn't match Pod's node affinity/selector.
  ```
- **Root Cause:** The GPU node has taint `nvidia.com/gpu=true:NoSchedule`, and `deployment/ai-inference` had no corresponding toleration.
- **Fix:** Added a matching toleration to `deployment/ai-inference`:
  ```yaml
  tolerations:
    - key: nvidia.com/gpu
      operator: Equal
      value: "true"
      effect: NoSchedule
  ```

---

## Issue 7 — `Service/web-svc` Has No Endpoints & Wrong `targetPort`

- **Symptom:** `deployment/web` was `2/2 Ready`, but `verify.sh` failed at step `[6/7] Service must have ready endpoints...`.
- **Diagnostic Commands:**
  ```bash
  kubectl describe svc web-svc -n troubleshoot
  kubectl get endpoints web-svc -n troubleshoot
  kubectl get pods -n troubleshoot --show-labels
  ```
- **Root Cause:**
  1. `service/web-svc` had `selector: { app: webapp }`, whereas the `web` pods had label `app: web`, resulting in `Endpoints: <none>`.
  2. `service/web-svc` had `targetPort: 8080`, whereas the `nginx` container listens on port `80`.
- **Fix:** Updated `service/web-svc` selector to `app: web` and `ports[0].targetPort` to `80`.

---

## Issue 8 — `smoke-test` Job Fails due to `default-deny` NetworkPolicy Blocking DNS & HTTP

- **Symptom:** `verify.sh` reached step `[7/7] In-cluster smoke test through the Service...`, and `job/smoke-test` timed out / failed with `curl: (6) Could not resolve host: web-svc.troubleshoot.svc.cluster.local` (and subsequently connection timeout on port 80).
- **Diagnostic Commands:**
  ```bash
  kubectl get networkpolicy -n troubleshoot -o yaml
  kubectl logs job/smoke-test -n troubleshoot
  ```
- **Root Cause:** The `default-deny` NetworkPolicy applies to all pods (`podSelector: {}`) in `troubleshoot` for both `Ingress` and `Egress`. Consequently:
  1. `smoke-test` (`app: smoke-client`) could not send DNS egress packets (UDP/TCP 53) to CoreDNS in `kube-system`.
  2. `smoke-test` could not send HTTP egress packets (TCP 80) to `app: web`.
  3. `web` (`app: web`) could not accept HTTP ingress packets (TCP 80) from `app: smoke-client`.
- **Fix:** Kept `default-deny` intact and added two least-privilege NetworkPolicies in `troubleshoot/fixed-app.yaml`:
  - `allow-web-ingress`: allows TCP port `80` ingress to `app: web` strictly from `podSelector: { matchLabels: { app: smoke-client } }`.
  - `allow-smoke-egress`: allows `app: smoke-client` egress to `kube-system` (`k8s-app: kube-dns`) on UDP/TCP `53` and to `app: web` on TCP `80`.

