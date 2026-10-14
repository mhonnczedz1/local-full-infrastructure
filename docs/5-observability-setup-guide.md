# Observability for the Platform: A Build Guide

**Goal:** See the platform. Metrics, dashboards, traces and logs for both clusters, built as add-ons on the pluggable structure from guide 4, with a canary that can abort itself when its error rate is worse than stable's. Either cluster can run the stack alone, and removing it from a cluster is deleting directories.

**Status:** DRAFT. Nothing in this guide has been executed against a cluster. Progress is ticked in `tracker_5_observability.md`, not here. What was checked while writing, and what was not:

| Checked locally | Not checked (verify as you go) |
|---|---|
| The Python in Sections 23 and 24 (metrics middleware, OpenTelemetry setup, fault injection) passes `ruff` and `pytest` against the pinned versions, and one trace id really does cross two in-process services | Helm chart versions and value keys for Prometheus, Grafana, Loki, Tempo and Alloy (Task 22.1.1 checks the keys you depend on) |
| The Kustomize changes build from the service config repos (eight service builds and four Postgres builds, with components fetched by remote reference), and the analysis block is injected into prod only | The Alloy configuration syntax, and whether Grafana's provisioning accepts the datasource blocks exactly as written |
| The source patches (metrics, then tracing, then fault injection) apply in that order to the current service repos, and the resulting code passes its tests | Label names the Prometheus chart's scrape jobs attach (`service`, `namespace`, `pod`), which every query here relies on |
| The dashboard JSON parses, `observe.sh` passes a `bash -n` syntax check under macOS bash 3.2, and the Makefile edit lists correctly in `gmake help` | How Argo Rollouts and ArgoCD behave together on the stable and canary Services (Task 23.1.3) |
| The edit to `scripts/gen-appsets.sh` for Service selector drift applies once, refuses a second run, regenerates both clusters' services ApplicationSet, keeps `check-contract.sh` green, and passes a server-side dry run | That Argo Rollouts resolves `valueFrom.fieldRef` on `metadata.namespace` in the analysis arguments (Task 25.1.1; Appendix K has a tested fallback) |
| The Section 22 to 25 edits to manifests, the new `canary-analysis` component and the fault patch were applied, in order, to a scratch rehearsal of guide 4's end state (config repos, templates repo and GitOps repo, with local Git remotes standing in for GitHub) | Every memory figure, which is an estimate to be replaced by measurement (Task 25.2.1) |

**Relationship to the earlier guides:** This continues `docs/1-local-full-infra-guide.md` (Sections 1 to 9), `docs/2-multi-env-infra-guide.md` (Sections 10 to 13), `docs/3-eks-counterpart-guide.md` (Sections 14 to 18) and `docs/4-pluggable-structure-guide.md` (Sections 19 to 21). Numbering resumes at Section 22 and appendix lettering at K. Every task assumes you finished Section 21: both clusters can run from the pluggable layout, the ApplicationSets for services, data and add-ons work, and EKS allows about 110 pods per node.

This guide **replaces guide 2's Section 13**, which was scoped but deliberately unbuilt. Its two phases live on here: metrics and dashboards (Sections 22 and 23) and automated analysis (Section 25). What it does not finish is Task 13.2.3, proving the metrics catch a canary that returns **wrong answers**. Task 25.1.3 shows that error-rate analysis cannot, which is a finding, and the marketplace project is where that gap gets closed with business metrics.

**Tech stack added:** Prometheus (the `prometheus` chart from prometheus-community), Grafana, Loki and Tempo in single-binary mode, Grafana Alloy as the one agent for logs and OTLP, `prometheus-client` and OpenTelemetry in the Python services, a Postgres exporter sidecar, and Argo Rollouts analysis. Everything is installed through the add-on layer from guide 4, apart from the sidecar and the service changes.

**Cost:** nothing on the local cluster. On EKS the stack adds no node (the pod limit was raised in guide 4) but it adds a few gp3 volumes and more memory on the one `t3.large`. The cluster still bills about 0.23 USD an hour while it exists. Every EKS confirmation in this guide is batched into the last phase of its section so the cluster is up for as little time as possible, and each one ends with the choice to destroy it.

---

## How to use this guide

Work top to bottom. Every task has a **Goal**, a **Why** where a choice could have gone another way, and a **Validate** block with the command and the output you should see. Do not move on until Validate passes.

Sections are separate parts of the system. Phases are milestones inside a section. Tasks are single actions, numbered `Task <section>.<phase>.<n>`.

**Local first, EKS last.** Sections 22, 23 and 24 each build and validate on the local cluster, then finish with one phase that repeats the result on EKS. Section 25 does both.

**This guide touches the repositories guide 4 created.** The GitOps repo for add-ons, dashboards, scripts and the ApplicationSet generator. Each service's config repo for its manifests (the stable and canary Services, the Postgres exporter, the tracing variables, the analysis template). The templates repo for one new component, `canary-analysis`. And both service repos for application code. Application changes reach a cluster the way every other change does: merge to `main`, CI builds an image, dev picks it up, and a release moves it to prod. Manifest changes reach it when the config repo's `main` moves.

**Pull requests use `gh`.** If `gh auth status` lists more than one host, the GitHub account that holds these repos may not be the default. Prefix the `gh` commands with `GH_HOST=github.com` (or your host) rather than discovering it halfway through a merge.

### Where commands run

| Name | Resolves to | Notes |
|------|-------------|-------|
| `$PLATFORM_HOME` | the project root | Set in guide 1, Task 1.2.1. Holds `docs/`, the trackers and `.tmp/`, which is gitignored here. |
| `$PLATFORM_HOME/lfi-infrastructure-gitops` | the GitOps repo | Add-ons, dashboards, scripts, the generator for the ApplicationSets and the `Makefile`, so `gmake` runs here. |
| `$CFG1`, `$CFG2` | the service config repos | `lfi-service-1-config` and `lfi-service-2-config`, from guide 4. Each service's manifests. |
| `$TPL` | the templates repo | `lfi-service-templates`, from guide 4. Components, pinned by tag. |
| `$PLATFORM_HOME/lfi-service-1-app`, `lfi-service-2-app` | the service repos | Their own Git repos. Sections 23 and 24 change `src/`, `tests/` and `requirements.txt`. |

Every command block that depends on location **starts with an explicit `cd`**. A block with no `cd` only talks to a cluster, so it runs from any directory.

### Pin the context on every command

Your kubeconfig almost certainly holds clusters that have nothing to do with this project. A bare `kubectl` or `helm` command acts on whichever one is current, and a stray `kubectl config use-context` in another terminal changes that silently. **Every cluster command in this guide names its context explicitly.** Never rely on, or change, the current context.

Set these names once per terminal. The cluster contexts and the project name come from the registry that guide 4 created, so a renamed cluster or project needs no edit here. The three directories are the repos guide 4 made, beside the GitOps repo:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
export LOCAL_CTX="$(yq '.clusters[] | select(.name == "local") | .context' platform/registry.yaml)"
export EKS_CTX="$(yq '.clusters[] | select(.name == "eks") | .context' platform/registry.yaml)"
PROJECT="$(yq '.project' platform/registry.yaml)"
export CFG1="$PLATFORM_HOME/$PROJECT-service-1-config"
export CFG2="$PLATFORM_HOME/$PROJECT-service-2-config"
export TPL="$PLATFORM_HOME/$PROJECT-service-templates"
echo "$LOCAL_CTX $EKS_CTX"
ls -d "$CFG1" "$CFG2" "$TPL"
```
Expected: `k3d-platform lfi-eks`, then the three directories listed. A missing one means guide 4's Phase 20.1 is not finished.

### Four helpers used throughout

Paste these into each terminal you work in. They save repeating long commands, and both pin the context you pass in.

```bash
# prom <context> <promql>: one instant query, through the API server's proxy, so
# no port-forward is needed. Prints "labels<TAB>value" per series.
prom() {
  kubectl --context "$1" get --raw \
    "/api/v1/namespaces/observability/services/prometheus-server:80/proxy/api/v1/query?query=$(jq -rn --arg q "$2" '$q|@uri')" \
    | jq -r '.data.result[] | [(.metric | tostring), .value[1]] | @tsv'
}

# targets <context>: how many scrape targets are up or down, per job.
targets() {
  kubectl --context "$1" get --raw \
    "/api/v1/namespaces/observability/services/prometheus-server:80/proxy/api/v1/targets?state=active" \
    | jq -r '.data.activeTargets[] | [.labels.job, .health] | @tsv' | sort | uniq -c
}

# merge_to_main <branch>: merge a validated GitOps branch to main and push. The
# ApplicationSets track the default branch, so nothing deploys until this runs.
merge_to_main() {
  ( cd "$PLATFORM_HOME/lfi-infrastructure-gitops" \
    && git switch main && git pull --ff-only \
    && git merge --no-ff "$1" -m "Merge $1" && git push origin main \
    && git switch "$1" )
}

# merge_config <repo dir> <branch>: the same step for a config or templates
# repository, which are siblings of the GitOps repo. Pass $CFG1, $CFG2 or $TPL.
merge_config() {
  ( cd "$1" \
    && git switch main && git pull --ff-only \
    && git merge --no-ff "$2" -m "Merge $2" && git push origin main \
    && git switch "$2" )
}
```
**Stop if `git merge` reports a conflict or `git push` is rejected.** Your work is safe on the branch. A rejection by branch protection means `main` does not take direct pushes, which is a repository setting to change deliberately, not to work around.

**Why `merge_to_main` exists at all.** The Applications that ArgoCD creates track `HEAD` of the default branch. Committing on a feature branch deploys nothing, which is the point of working on a branch, and merging is the deploy. A config repo works the same way: its Applications track the default branch, so `merge_config` is the deploy for a manifest change. Use it for changes you are content to merge directly. For anything the team has protected, a prod path above all, open a pull request in that repo instead, as the release process does.

---

## Decisions already made

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| 1 | Packaging | **The lean `prometheus` and `grafana` charts, each as its own add-on. Not kube-prometheus-stack.** | The stack brings an operator, a dozen CRDs and several extra pods. On a node with a pod limit and 8 GiB, each pod is a cost. The lean chart is one server pod. |
| 2 | Mimir | **Not used** | Prometheus with short retention covers a two-cluster lab. Mimir would roughly double the memory bill for no visible gain. |
| 3 | How things get scraped | **Annotations.** A Service with `prometheus.io/scrape: "true"` is scraped through its endpoints. A pod with the same annotation is scraped directly. | The chart ships jobs for both (verified in Task 22.1.1), so no custom scrape configuration exists to maintain. Adding a target is adding an annotation. |
| 4 | Telling canary from stable | **Two extra Services per service, `<svc>-stable` and `<svc>-canary`, named in the Rollout's `stableService` and `canaryService`.** Only those two are scraped. | Rollouts points each at the right pods and keeps them pointed as hashes rotate, so a query names a Service rather than a hash. This is the first of the two routes Section 13 described. The `service` label then carries the answer. |
| 5 | Instrumentation | **A small hand-written middleware over `prometheus-client`** | About sixty lines you can read in one sitting, with exactly the labels the dashboard needs. A convenience library hides the one decision that matters here, the route template. |
| 6 | Postgres metrics | **An exporter sidecar in the existing Postgres pod, not a separate deployment** | A sidecar is a container, not a pod, so it costs memory but no pod-limit slot. It also reads the credentials from the Secret already in that namespace. |
| 7 | One agent | **Grafana Alloy for both logs and OTLP** | One pod instead of a log shipper plus a collector. It receives traces from the services, forwards them to Tempo, and tails pod logs into Loki. |
| 8 | Tempo and Loki | **Single-binary mode, filesystem storage, small volumes** | The distributed modes are built for scale this project does not have. |
| 9 | Traces and logs reach Grafana | **Traces over OTLP to Alloy, logs over stdout tailed by Alloy** | Services never talk to Loki. A log line carries the trace id as text, which is the join key. |
| 10 | Analysis | **Background analysis from the pause step, comparing canary to stable error rate, with `pause: {}` kept** | Analysis catches what you told it to look for. The pause is what catches the rest. |
| 11 | Namespace | **`observability`** | Created by the add-on layer's `CreateNamespace=true`. |
| 12 | Access | **`kubectl port-forward` only**, through `gmake grafana` and `gmake prometheus` | No new Ingress, no new public surface, no new load balancer. |
| 13 | Dashboards | **JSON files in `dashboards/`, loaded by Grafana from the repo's raw URL at startup** | Reviewable in a diff, and the add-on layer needs no plain-manifest support. The trade-off is that the repo must be public and the URL names the owner. See the primer. |
| 14 | Data | **Volumes survive pod restarts, not cluster destruction** | `gmake destroy` wipes them, which is fine for a lab. Section 25 adds them to the "nothing left billing" check. |
| 15 | Business metrics | **Deferred to the marketplace project** | The stubs have no business logic worth measuring. |
| 16 | Load testing | **Prometheus accepts remote write now** | k6 will write its own metrics into the same Grafana later. The flag costs nothing today. |

### Primer: what the three signals answer

Metrics say **how much and how fast**: requests per second, the share that failed, how slow the slowest five percent are. They are cheap, so you keep weeks of them, and they cannot say why.

Logs say **what happened** in one place: a line a service chose to write. They are precise and expensive, so you keep days.

Traces say **where the time went** for one request across services: an ordered list of spans, each with a duration. They explain a slow or failed request that a metric only flagged.

The habit the stack is built to support is the drill down: a metric panel shows a p95 rising, a trace shows the time is in the call from service-1 to service-2, and the log lines for that trace id show service-2 returned 503. Each tool answers the question the previous one raised.

### Primer: the RED method

For every service, three numbers: **R**ate (requests per second), **E**rrors (the share that failed) and **D**uration (how long requests took, as a percentile). They are the smallest set that tells you whether users are being served, and they need no knowledge of what the service does. That last property is why they come first here, and why they cannot tell you a service is answering **wrongly**. A worker that returns 200 with the wrong number has perfect RED.

Two details decide whether RED stays useful:

- **Label by route template, not by path.** `/items/17` and `/items/18` are the same route. A label per raw path makes one time series per id, which is how Prometheus runs out of memory. The middleware in Task 23.1.1 reads the template from the router.
- **Leave probes out.** Kubernetes probes hit `/healthz` and `/readyz` every few seconds. Counted, they dominate the request rate and dilute the error ratio.

### Primer: why canary and stable are Services

A Rollout runs the old and new versions side by side during a canary. To compare them you need two things that stay true for the whole rollout: a way to say "the old pods" and a way to say "the new pods".

The pods carry a `rollouts-pod-template-hash` label, but the hash is opaque and changes with every release. A dashboard that names a hash works for one week. Setting `stableService` and `canaryService` on the Rollout avoids that. Rollouts keeps each named Service's selector pointed at the right ReplicaSet, so **the Service name is the stable identifier** and the hash never appears in a query.

Prometheus scrapes the endpoints behind those two Services, and the chart's service job copies the Service name into a `service` label. A query for `service="service-1-canary"` is now a query for the canary pods, this week and every week.

Outside a rollout both Services select the same pods, because there is nothing to tell apart. The canary and stable series are then identical, and summing across both would count every request twice. The dashboards and the analysis always keep them apart.

### Primer: the pod and memory budget

Two limits bind. On the local cluster the limit is the VM's memory (about 7.9 GiB), of which the platform already requests about 1.9 GiB (guide 2's Resource Budget). On EKS it was the pod limit, which guide 4 raised with prefix delegation, leaving memory on one `t3.large` (8 GiB) as the next ceiling.

What this guide adds, as **estimates to be replaced by measurement in Task 25.2.1**:

| Component | Pods | Memory request (estimate) |
|---|---|---|
| Prometheus server | 1 | 300 Mi |
| Grafana | 1 | 150 Mi |
| Loki (single binary) | 1 | 250 Mi |
| Tempo (single binary) | 1 | 200 Mi |
| Alloy | 1 | 150 Mi |
| Postgres exporter sidecars | 0 | 2 x 32 Mi |
| **Total** | **5** | **about 1.1 Gi** |

That is roughly 3 GiB of requests against 7.9 GiB locally. Limits are higher than requests and real use sits between them, so treat the total as a floor. The existing `docs/resource_check.md` commands measure the local side; `kubectl top` measures both.

The subcharts the Prometheus chart bundles (Alertmanager, Pushgateway, node-exporter, kube-state-metrics) are turned off, which is what keeps Prometheus to one pod. Task 22.3.3 explains what that costs you.

### Primer: how dashboards reach Grafana

Grafana can load dashboards three ways. The chart can embed the JSON in the Helm values, which puts hundreds of lines of JSON in a YAML file. A sidecar can watch for ConfigMaps, which needs the dashboards delivered as plain manifests, and the add-on layer from guide 4 deliberately only installs charts. Or the chart can download a dashboard from a URL when Grafana starts, which is what this guide does.

So `dashboards/red.json` is an ordinary file in the GitOps repo, reviewed like any other, and the Grafana values point at its raw GitHub URL. Two consequences to know about: the repo must be public (it is, as guide 1 chose), and the URL contains the owner and repo name, so a repo stamped from this template must change it. The stamp checklist from guide 4 gains one line for that in Task 25.3.2.

---

## Section 22: Metrics platform

**Objective:** Prometheus and Grafana running as add-ons on the local cluster, scraping the platform, with Postgres and Traefik metrics flowing. EKS repeats it in the last phase.

### Phase 22.1: Preflight and Prometheus

#### Task 22.1.1: Verify chart versions, value keys and the scrape model

**Goal:** Chart versions you have confirmed exist, and confirmation that the value keys and scrape jobs this guide relies on are really in those versions. Same discipline as Task 15.1.2, applied harder here: the value keys in Helm charts are the part most likely to have moved since this guide was written, and a wrong key is ignored **silently**.

```bash
cd "$PLATFORM_HOME"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update prometheus-community grafana
for c in prometheus-community/prometheus grafana/grafana grafana/loki grafana/tempo grafana/alloy; do
  printf '%-36s' "$c"
  helm search repo "$c" --output json | jq -r --arg c "$c" '.[] | select(.name == $c) | .version + "  (app " + .app_version + ")"'
done
```
Expected: one line per chart with a version. **If `grafana/grafana` (or any other `grafana/` chart) returns nothing or warns it is deprecated,** the chart has moved to a community repository. Find where with the chart's page on artifacthub.io, add that repo instead, and change the `chart.repo` field in each affected `addon.yaml` (Tasks 22.2.1, 24.1.1, 24.1.2 and 24.1.3) to match.

Record the versions where every later task can read them:
```bash
cd "$PLATFORM_HOME"
ver() { helm search repo "$1" --output json | jq -r --arg c "$1" '.[] | select(.name == $c) | .version'; }
cat > .tmp/obs-versions.env <<EOF
export PROMETHEUS_CHART_VERSION="$(ver prometheus-community/prometheus)"
export GRAFANA_CHART_VERSION="$(ver grafana/grafana)"
export LOKI_CHART_VERSION="$(ver grafana/loki)"
export TEMPO_CHART_VERSION="$(ver grafana/tempo)"
export ALLOY_CHART_VERSION="$(ver grafana/alloy)"
EOF
cat .tmp/obs-versions.env
```

**Why pin.** The pin is the `chart.version` field in each `addon.yaml`. A chart has no lock file, so an unpinned add-on silently upgrades the next time it is reinstalled and may rename the keys below.

Now check the keys. Each command prints the keys the guide uses, so a missing one shows as a missing line:
```bash
cd "$PLATFORM_HOME"; source .tmp/obs-versions.env
PV() { helm show values prometheus-community/prometheus --version "$PROMETHEUS_CHART_VERSION"; }
echo "--- prometheus: top-level toggles"; PV | yq 'keys | .[]' | grep -E '^(alertmanager|prometheus-pushgateway|prometheus-node-exporter|kube-state-metrics|server)$'
echo "--- prometheus: server keys";       PV | yq '.server | keys | .[]' | grep -E '^(retention|retentionSize|extraFlags|persistentVolume|global|resources)$'
echo "--- prometheus: default scrape jobs"
helm template prometheus prometheus-community/prometheus --version "$PROMETHEUS_CHART_VERSION" \
  | yq 'select(.kind == "ConfigMap" and .metadata.name == "prometheus-server") | .data["prometheus.yml"]' \
  | yq '.scrape_configs[].job_name'
```
Expected: the five toggle and server names, six server keys, and a job list that includes `kubernetes-service-endpoints`, `kubernetes-pods` and `kubernetes-nodes-cadvisor`.

The next check matters most, because every query in this guide filters on the `service` label. It must be produced by the service-endpoints job:
```bash
cd "$PLATFORM_HOME"; source .tmp/obs-versions.env
helm template prometheus prometheus-community/prometheus --version "$PROMETHEUS_CHART_VERSION" \
  | yq 'select(.kind == "ConfigMap" and .metadata.name == "prometheus-server") | .data["prometheus.yml"]' \
  | yq '.scrape_configs[] | select(.job_name == "kubernetes-service-endpoints") | .relabel_configs[] | select(.target_label == "service" or .target_label == "namespace" or .target_label == "pod")'
```
Expected: entries setting `namespace` and `service` from the Service's metadata (and `pod` from the endpoint's target). If `service` is absent, the chart version you have changed the job: read its `relabel_configs` and either add a relabel through `serverFiles` or adjust every `service=` selector in Sections 23 and 25 to the label it does produce. Note the difference in Task 25's deviations log.

Finally, the other charts' keys:
```bash
cd "$PLATFORM_HOME"; source .tmp/obs-versions.env
echo "--- loki";    helm show values grafana/loki    --version "$LOKI_CHART_VERSION"    | yq 'keys | .[]' | grep -E '^(deploymentMode|singleBinary|gateway|chunksCache|resultsCache|lokiCanary|test)$'
echo "--- tempo";   helm show values grafana/tempo   --version "$TEMPO_CHART_VERSION"   | yq 'keys | .[]' | grep -E '^(tempo|persistence|resources)$'
echo "--- alloy";   helm show values grafana/alloy   --version "$ALLOY_CHART_VERSION"   | yq 'keys | .[]' | grep -E '^(alloy|controller)$'
echo "--- grafana"; helm show values grafana/grafana --version "$GRAFANA_CHART_VERSION" | yq 'keys | .[]' | grep -E '^(datasources|dashboardProviders|dashboards|persistence|resources|grafana.ini)$'
echo "--- alloy service name"
helm template alloy grafana/alloy --version "$ALLOY_CHART_VERSION" | yq 'select(.kind == "Service") | .metadata.name'
```
Expected: every name present, and the Alloy Service named `alloy`. The guide assumes that name in `alloy.observability.svc.cluster.local`.

**If a key is missing,** do not guess. Read `helm show values <chart> --version <v>` for its replacement and record the change in the Notes and Deviations table of the tracker. A values file with a wrong key installs cleanly and does nothing, which is the hardest failure in this guide to see.

**Validate:** `cat "$PLATFORM_HOME/.tmp/obs-versions.env"` shows five exported versions, and every `grep` above printed the names it looks for.

#### Task 22.1.2: Confirm the starting point and branch

**Goal:** A healthy local cluster from guide 4, and a branch to work on.

If the cluster is not running, bring it up first:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake up CLUSTER=local
```

**Validate:**
```bash
kubectl --context "$LOCAL_CTX" -n argocd get applicationsets
kubectl --context "$LOCAL_CTX" -n argocd get applications
kubectl --context "$LOCAL_CTX" top nodes
```
Expected: three ApplicationSets (`services-local`, `data-local`, `addons-local`), every Application `Synced` and `Healthy`, and `top nodes` printing CPU and memory. If `top` errors, the local metrics-server is not answering yet; wait a minute.

Then:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch main && git pull --ff-only
git switch -c feat/observability
git branch --show-current
```
Expected: `feat/observability`.

#### Task 22.1.3: The Prometheus add-on

**Goal:** `addons/local/prometheus/` holding the two files the add-on layer reads, planned but not yet merged.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"; source "$PLATFORM_HOME/.tmp/obs-versions.env"
mkdir -p addons/local/prometheus
cat > addons/local/prometheus/addon.yaml <<EOF
name: prometheus
namespace: observability
chart:
  repo: https://prometheus-community.github.io/helm-charts
  name: prometheus
  version: "$PROMETHEUS_CHART_VERSION"
EOF
cat > addons/local/prometheus/values.yaml <<'EOF'
# Four subcharts the chart installs by default, all off. Each is a real feature
# you are choosing not to run (see Task 22.3.3), and each one is a pod.
alertmanager:
  enabled: false
prometheus-pushgateway:
  enabled: false
prometheus-node-exporter:
  enabled: false
kube-state-metrics:
  enabled: false

server:
  # Three days is long enough to compare this release with last week's only in
  # your dreams; it is here to keep the volume small. Raise it if you want
  # history. The size cap is the backstop: Prometheus deletes the oldest blocks
  # before it would fill the volume, which is better than the volume filling.
  retention: 3d
  retentionSize: 1500MB
  global:
    # 15 seconds is the default, written down. Rates over a one minute window
    # need at least two samples, and the canary analysis uses two minutes.
    scrape_interval: 15s
    evaluation_interval: 15s
  # This list REPLACES the chart's default list, so the lifecycle flag that the
  # chart normally sets is repeated here. The second flag lets a load generator
  # (k6, in the marketplace project) push its metrics in.
  extraFlags:
    - web.enable-lifecycle
    - web.enable-remote-write-receiver
  persistentVolume:
    enabled: true
    size: 2Gi
  resources:
    requests:
      cpu: 50m
      memory: 300Mi
    limits:
      memory: 600Mi
EOF
```

**Why the annotation scrape model.** The chart ships jobs that scrape any Service, or any pod, carrying `prometheus.io/scrape: "true"`, with `prometheus.io/port` and `prometheus.io/path` choosing the port and path. That is the whole contract for adding a target later, and it is why there is no custom scrape configuration in this file.

**Why memory limits only.** Same discipline as the ArgoCD values: say what you reserve, cap what you can tolerate. Prometheus memory grows with the number of series, so the limit is the one to watch.

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
yq '.chart.version' addons/local/prometheus/addon.yaml
yq '.server.extraFlags' addons/local/prometheus/values.yaml
```
Expected: the chart version from Task 22.1.1 (not empty), and the two flags.

#### Task 22.1.4: Merge and watch it converge

**Goal:** Prometheus running, with its own targets up.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git add addons/local/prometheus
git commit -m "feat(observability): Prometheus add-on on local"
merge_to_main feat/observability
kubectl --context "$LOCAL_CTX" -n argocd annotate applicationset addons-local argocd.argoproj.io/application-set-refresh=true --overwrite 2>/dev/null || true
kubectl --context "$LOCAL_CTX" -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
```
The ApplicationSet polls Git on its own interval; the refresh above skips the wait where it can.

**Validate:**
```bash
kubectl --context "$LOCAL_CTX" -n argocd get applications | grep prometheus
kubectl --context "$LOCAL_CTX" -n observability get pods,pvc
targets "$LOCAL_CTX"
```
Expected: an Application named for the add-on, `Synced` and `Healthy`; one `prometheus-server` pod `Running` with all containers ready, and a `Bound` PVC; and a target list with at least the `prometheus` job `up`. Image pulls take a minute or two on a fresh node, so repeat until the pod is running.

Check the remote-write receiver is on. The request body is empty on purpose: a receiver that is enabled rejects it as malformed, while one that is disabled does not know the path:
```bash
kubectl --context "$LOCAL_CTX" -n observability port-forward svc/prometheus-server 9090:80 >/dev/null 2>&1 &
PF=$!; sleep 3
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:9090/api/v1/write
kill $PF
```
Expected: `400`. A `404` means the flag did not take; check `server.extraFlags` against the chart (Task 22.1.1).

**If the Application stays `OutOfSync` or `Degraded`,** read why:
```bash
kubectl --context "$LOCAL_CTX" -n argocd get applications -o name | grep prometheus
kubectl --context "$LOCAL_CTX" -n argocd get application <name from the line above> -o jsonpath='{.status.conditions[*].message}{"\n"}'
```
The usual causes are a multi-source misconfiguration from guide 4 (the message names the source) or a chart version that does not exist (recheck Task 22.1.1).

### Phase 22.2: Grafana

#### Task 22.2.1: The Grafana add-on with Prometheus as a datasource

**Goal:** Grafana running, with Prometheus provisioned as its default datasource, so no one clicks through a setup screen.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"; source "$PLATFORM_HOME/.tmp/obs-versions.env"
mkdir -p addons/local/grafana
cat > addons/local/grafana/addon.yaml <<EOF
name: grafana
namespace: observability
chart:
  repo: https://grafana.github.io/helm-charts
  name: grafana
  version: "$GRAFANA_CHART_VERSION"
EOF
cat > addons/local/grafana/values.yaml <<'EOF'
# The chart generates a random admin password into a Secret named "grafana".
# `gmake grafana` reads it from there, so no password is ever committed.
adminUser: admin

# Dashboards and datasources are provisioned from Git, so there is nothing to
# persist. A restart rebuilds the same state.
persistence:
  enabled: false

# Grafana phones home by default. On a lab cluster that is only noise.
grafana.ini:
  analytics:
    check_for_updates: false
    check_for_plugin_updates: false
    reporting_enabled: false

datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Prometheus
        # A fixed uid is what lets dashboard JSON refer to this datasource by a
        # name that does not change. Without it Grafana invents one per install.
        uid: prometheus
        type: prometheus
        access: proxy
        url: http://prometheus-server.observability.svc.cluster.local
        isDefault: true

resources:
  requests:
    cpu: 25m
    memory: 150Mi
  limits:
    memory: 300Mi
EOF
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
yq '.datasources."datasources.yaml".datasources[0].uid' addons/local/grafana/values.yaml
```
Expected: `prometheus`. The pod check comes after Task 22.2.2 adds the command that opens it.

#### Task 22.2.2: Commands that ask: `gmake grafana`, `gmake prometheus`, `gmake traffic`

**Goal:** Three commands that follow the pattern from guide 3's Section 18: they ask which cluster, offer a default, and print the form that skips the questions.

**Why ports are offset.** Both clusters may be open at once. Local uses port 3000 for Grafana and EKS 3001, so one terminal does not need closing to open the other.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
cat > scripts/observe.sh <<'OBSERVE_EOF'
#!/usr/bin/env bash
# Opens the observability UIs on a cluster, or sends it steady traffic.
#
# Usage: scripts/observe.sh <grafana|prometheus|traffic>
#   Asks which cluster. Name it up front and nothing is asked:
#     gmake grafana CLUSTER=eks
#   traffic also asks which environment, and reads DURATION (seconds, default 120):
#     DURATION=300 gmake traffic CLUSTER=local ENVIRONMENT=prod
#
# Ports are offset by the cluster's position in the registry (local 3000, eks
# 3001 for Grafana), so both can be open at once without a clash.
set -euo pipefail

WHAT="${1:-}"
case "$WHAT" in
  grafana|prometheus|traffic) ;;
  *) echo "ERROR: action must be grafana, prometheus or traffic (got '${WHAT}')." >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"

case "$WHAT" in
  grafana)    pick_cluster "open Grafana on" no "running" ;;
  prometheus) pick_cluster "open Prometheus on" no "running" ;;
  traffic)    pick_cluster "send traffic to" no "running"; pick_stage "send traffic to" no ;;
esac
show_equivalent "gmake ${WHAT}"

CLUSTER_NAME="${PICKED_CLUSTERS[0]}"
CONTEXT="$(cluster_context "$CLUSTER_NAME")"

# Position of the cluster in LFI_CLUSTERS, used to offset the local port.
OFFSET=0
for i in "${!LFI_CLUSTERS[@]}"; do
  [[ "${LFI_CLUSTERS[$i]}" == "$CLUSTER_NAME" ]] && OFFSET="$i"
done

case "$WHAT" in
  grafana)
    PORT=$((3000 + OFFSET))
    PASSWORD="$(kubectl --context "$CONTEXT" -n observability get secret grafana \
      -o jsonpath='{.data.admin-password}' | base64 -d)"
    echo
    echo "Grafana for ${CLUSTER_NAME} at http://localhost:${PORT}   user: admin   password: ${PASSWORD}"
    echo "Ctrl-C closes the tunnel."
    exec kubectl --context "$CONTEXT" -n observability port-forward svc/grafana "${PORT}:80"
    ;;
  prometheus)
    PORT=$((9090 + OFFSET))
    echo
    echo "Prometheus for ${CLUSTER_NAME} at http://localhost:${PORT}   Ctrl-C closes the tunnel."
    exec kubectl --context "$CONTEXT" -n observability port-forward svc/prometheus-server "${PORT}:80"
    ;;
  traffic)
    STAGE="${PICKED_STAGES[0]}"
    DURATION="${DURATION:-120}"
    # The Host headers mirror the ones in each config repo's environment kustomization.
    if [[ "$CLUSTER_NAME" == "local" ]]; then
      BASE="http://127.0.0.1:8080"
      HOST="${STAGE}.localhost"
    else
      LB="$(kubectl --context "$CONTEXT" -n traefik get svc traefik \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
      [[ -n "$LB" ]] || usage_error "The load balancer has no address yet. Try again in a minute."
      BASE="http://${LB}"
      HOST="${STAGE}.eks.test"
    fi
    echo
    echo "Sending about 5 requests a second to ${CLUSTER_NAME}/${STAGE} for ${DURATION}s. Ctrl-C stops early."
    END=$((SECONDS + DURATION))
    N=0
    while (( SECONDS < END )); do
      N=$((N + 1))
      curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 \
        -H "Host: ${HOST}" -H 'Content-Type: application/json' \
        -d "{\"value\": $((N % 100))}" "${BASE}/compute" || echo "fail"
      sleep 0.2
    done | sort | uniq -c
    ;;
esac
OBSERVE_EOF
chmod +x scripts/observe.sh
```

Add the commands to the `Makefile`, in their own help group just above the internals banner. This edit is scripted because a Makefile recipe needs a real tab, which does not survive being pasted from a document:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
python3 - <<'PY'
s = open("Makefile").read()
add = (
    "##@ Observe\n\n"
    "grafana: ## Open Grafana for a cluster. Asks which\n\t$(PASS) ./scripts/observe.sh grafana\n\n"
    "prometheus: ## Open Prometheus for a cluster. Asks which\n\t$(PASS) ./scripts/observe.sh prometheus\n\n"
    "traffic: ## Send steady traffic to a cluster and environment. Asks which. DURATION=120\n\t$(PASS) ./scripts/observe.sh traffic\n\n"
)
marker = "# ---------------------------------------------------------------------------\n# Internals, called by the commands above."
assert marker in s, "banner not found: add the three targets by hand under a ##@ Observe header"
s = s.replace(marker, add + marker, 1)
s = s.replace("_eks-up _eks-down _eks-destroy", "_eks-up _eks-down _eks-destroy grafana prometheus traffic", 1)
open("Makefile", "w").write(s)
PY
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
/bin/bash -n scripts/observe.sh && echo "syntax ok"
gmake help | sed -n '/Observe/,/^$/p'
```
Expected: `syntax ok` (`/bin/bash` is macOS's bash 3.2, the oldest the scripts must run on), then a group with the three commands.

Merge and open Grafana:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git add addons/local/grafana scripts/observe.sh Makefile
git commit -m "feat(observability): Grafana add-on and the gmake commands that open it"
merge_to_main feat/observability
kubectl --context "$LOCAL_CTX" -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
sleep 90
kubectl --context "$LOCAL_CTX" -n observability get pods
```
When `grafana` is `Running` and ready, open it in a second terminal:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake grafana CLUSTER=local
```
It prints the URL, the user and the password, then holds the tunnel open until Ctrl-C.

**Validate** (from the first terminal, while the tunnel is open):
```bash
curl -s http://localhost:3000/api/health | jq -r '.database'
PASS="$(kubectl --context "$LOCAL_CTX" -n observability get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d)"
curl -s -u "admin:$PASS" http://localhost:3000/api/datasources | jq -r '.[] | .name + " " + .uid'
```
Expected: `ok`, then `Prometheus prometheus`. In the browser, Explore with the Prometheus datasource and the query `up` should list the targets Prometheus knows.

### Phase 22.3: Postgres, Traefik and the cluster itself

#### Task 22.3.1: The Postgres exporter sidecar

**Goal:** Postgres metrics (connections, transactions, locks, database size) in both environment namespaces, from a container that shares the Postgres pod.

**Why a sidecar.** It costs memory and no pod-limit slot, and it reads the credentials from the Secret that already sits in each environment's namespace. A separate exporter deployment in `observability` could not read either namespace's Secret, and would need one copy per environment.

**The cost is a restart.** Adding a container changes the StatefulSet's pod template, so each Postgres pod restarts once. The data is on a PVC and survives, and the Postgres Application has `prune: false`. Expect a short window where the services' `/readyz` fails and comes back on its own.

**Where the change lives.** Postgres belongs to service-1's team (guide 4, Task 20.1.2), so the sidecar is added to **service-1's config repo**, in `base/postgres`, where all four Postgres environments share it. It reaches the cluster when that repo's `main` moves, which Task 22.3.3 does together with the Traefik change.

```bash
cd "$CFG1"
git switch main && git pull --ff-only
git switch -c feat/observability
cat > base/postgres/exporter-patch.yaml <<'EXPORTER_EOF'
# Adds a metrics sidecar to the Postgres pod. A sidecar is a container, not a
# pod, so it costs memory but no entry against the node's pod limit.
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  template:
    metadata:
      annotations:
        # Prometheus' pod job scrapes any pod with these three annotations.
        prometheus.io/scrape: "true"
        prometheus.io/port: "9187"
        prometheus.io/path: /metrics
    spec:
      containers:
        - name: exporter
          image: quay.io/prometheuscommunity/postgres-exporter:v0.17.1
          ports:
            - name: metrics
              containerPort: 9187
          env:
            # Each value comes from the Secret by reference, never by copy.
            # POSTGRES_DB is listed first because $(POSTGRES_DB) below can only
            # expand variables defined earlier in this same env list.
            - name: POSTGRES_DB
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_DB
            - name: DATA_SOURCE_USER
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_USER
            - name: DATA_SOURCE_PASS
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: POSTGRES_PASSWORD
            # Same pod, so Postgres is on localhost.
            - name: DATA_SOURCE_URI
              value: localhost:5432/$(POSTGRES_DB)?sslmode=disable
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 96Mi
EXPORTER_EOF
yq -i '.patches += [{"path": "exporter-patch.yaml"}]' base/postgres/kustomization.yaml
```

The image tag above is the version this guide was written against. Check it exists before relying on it:
```bash
docker manifest inspect quay.io/prometheuscommunity/postgres-exporter:v0.17.1 >/dev/null && echo "tag exists"
```
If it reports `no such manifest`, pick a current tag from the project's releases page and edit the patch.

**Validate:**
```bash
for c in local eks; do for e in dev prod; do
  printf '%s %s: ' "$c" "$e"
  kustomize build "$CFG1/$c/$e/postgres" \
    | yq 'select(.kind == "StatefulSet") | [.spec.template.spec.containers[].name] | join(",")'
done; done
kustomize build "$CFG1/local/dev/postgres" \
  | yq 'select(.kind == "StatefulSet") | .spec.template.metadata.annotations'
```
Expected: `exporter,postgres` for all four, then the three `prometheus.io/*` annotations. The volume claim must be untouched, because changing it would be refused by Kubernetes:
```bash
kustomize build "$CFG1/local/dev/postgres" | yq 'select(.kind == "StatefulSet") | .spec.volumeClaimTemplates[0].spec.resources.requests.storage'
```
Expected: the same size as before (`2Gi` unless you changed it). Commit it on the branch; it is merged in Task 22.3.3:
```bash
cd "$CFG1"
git add base/postgres
git commit -m "feat(observability): Postgres exporter sidecar"
```

#### Task 22.3.2: Traefik metrics

**Goal:** Request counts at the edge, per route and status, before any service code is involved. If a service's own metrics say nothing is wrong and Traefik says half of requests failed, the fault is between them.

Traefik is installed differently on each cluster, so the change is too.

**Local.** k3s installs Traefik itself and lets you adjust it with a `HelmChartConfig` in `kube-system`. It is applied at platform bring-up so a rebuilt cluster keeps it:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
cat > terraform/local/02-platform/bootstrap/traefik-metrics.yaml <<'EOF'
# Adjusts the Traefik that k3s installs. k3s watches for this object and
# re-renders its bundled chart with these values merged in.
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    deployment:
      podAnnotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9100"
        prometheus.io/path: /metrics
    metrics:
      prometheus:
        entryPoint: metrics
EOF
python3 - <<'PY'
s = open("Makefile").read()
start = s.index("_local-platform: check-env")
needle = "\tterraform apply -auto-approve -input=false\n"
i = s.index(needle, start) + len(needle)
line = "\tkubectl --context $(CONTEXT) apply -f ../../../terraform/local/02-platform/bootstrap/traefik-metrics.yaml\n"
assert line not in s
s = s[:i] + line + s[i:]
open("Makefile", "w").write(s)
PY
sed -n '/^_local-platform/,/^$/p' Makefile
```
The recipe runs from inside `terraform/local/02-platform` (its `cd` persists under `.ONESHELL`), which is why the path climbs back out. Confirm the printed recipe ends with the new `kubectl` line directly after `terraform apply`.

Apply it to the running cluster now rather than waiting for a rebuild:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
kubectl --context "$LOCAL_CTX" apply -f terraform/local/02-platform/bootstrap/traefik-metrics.yaml
kubectl --context "$LOCAL_CTX" -n kube-system rollout status deployment/traefik --timeout=120s
```

**EKS.** Traefik is a Helm release that Terraform owns, so the same intent goes into its values file. It takes effect on the next `gmake up CLUSTER=eks`, which is Task 22.4.1:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
cat >> terraform/eks/02-platform/values/traefik.yaml <<'EOF'

# Scraped by Prometheus' pod job. 9100 is the chart's metrics entrypoint.
deployment:
  podAnnotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9100"
    prometheus.io/path: /metrics
metrics:
  prometheus:
    entryPoint: metrics
EOF
yq '.deployment.podAnnotations' terraform/eks/02-platform/values/traefik.yaml
```
Expected: the three annotations. Guide 3's values file already has `ingressClass`, `service`, `providers` and `resources` keys at the top level, so the appended block adds new top-level keys and collides with none of them.

**Why the local chart's keys may differ.** k3s bundles a specific Traefik chart version, chosen by the k3s release, not by you. If the pod does not gain the annotations, read the bundled chart's values rather than guessing:
```bash
kubectl --context "$LOCAL_CTX" -n kube-system get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.annotations}{"\n"}'
```

**Validate** (after merging, in Task 22.3.3's validation, which checks all the infrastructure targets together).

#### Task 22.3.3: Decide on kube-state-metrics, and prove the cluster's own metrics are there

**Goal:** A deliberate decision about what the cluster reports about itself, and proof that container CPU and memory arrive without the subcharts.

**The decision: leave kube-state-metrics, node-exporter, Alertmanager and the Pushgateway off.**

| Subchart | What you lose by leaving it off | Why that is acceptable |
|---|---|---|
| kube-state-metrics | Pod restart counts, replica counts and rollout status as metrics | `kubectl get pods` and `gmake status` show these, and Argo Rollouts' own state is on the Rollout. It is one more pod. |
| node-exporter | Node-level disk, network and CPU | Container CPU and memory come from the kubelet's cAdvisor endpoint, scraped by a job the chart already has. The node is one machine you can inspect directly. |
| Alertmanager | Notifications | Nothing pages anyone on a lab cluster. Section 25's analysis is the one automated reaction. |
| Pushgateway | A place for short batch jobs to push | There are no batch jobs. |

Turn one back on by setting its `enabled: true` in the values file. kube-state-metrics is the one most likely to be wanted, the first time you ask "how many restarts has this had" of a graph rather than of `kubectl`.

Merge the Traefik change in the GitOps repo and the exporter in service-1's config repo:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git add terraform/local/02-platform/bootstrap/traefik-metrics.yaml terraform/eks/02-platform/values/traefik.yaml Makefile
git commit -m "feat(observability): Traefik metrics"
merge_to_main feat/observability
merge_config "$CFG1" feat/observability
kubectl --context "$LOCAL_CTX" -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
sleep 120
```

**Validate:**
```bash
targets "$LOCAL_CTX"
prom "$LOCAL_CTX" 'pg_up'
prom "$LOCAL_CTX" 'sum by (namespace) (container_memory_working_set_bytes{namespace=~"platform-.*",container!=""})'
prom "$LOCAL_CTX" 'traefik_entrypoint_requests_total' | head -3
```
Expected: `kubernetes-pods` targets `up` (Postgres in both namespaces, and Traefik), `pg_up` returning `1` for two series (one per environment), a memory figure for each of `platform-dev` and `platform-prod`, and at least one Traefik request series. If the Traefik query returns nothing, send one request first (`curl -s http://127.0.0.1:8080/ -H 'Host: dev.localhost' >/dev/null`) and retry, because a counter with no traffic has no series.

### Phase 22.4: Prove it on EKS

This phase is the one place Section 22 spends money. Do it in one sitting.

#### Task 22.4.1: Enable the same add-ons on EKS

**Goal:** The two add-on directories on EKS, with the changes storage and the `gp3` default class imply.

The EKS directories are copies of the local ones. Only values that are truly cluster-specific differ, and today none do (the default `gp3` class is already the default, so `persistentVolume` needs no `storageClass`):
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
mkdir -p addons/eks
cp -R addons/local/prometheus addons/local/grafana addons/eks/
git switch -c feat/observability-eks
git add addons/eks
git commit -m "feat(observability): Prometheus and Grafana on EKS"
```
Do not merge yet. Merging deploys to a cluster that must exist first.

Bring the cluster up (15 to 25 minutes, billing starts). This also applies the Traefik annotations from Task 22.3.2:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake up CLUSTER=eks
```
Then merge:
```bash
merge_to_main feat/observability-eks
kubectl --context "$EKS_CTX" -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
sleep 180
```

**Validate:**
```bash
kubectl --context "$EKS_CTX" -n argocd get applications
kubectl --context "$EKS_CTX" -n observability get pods,pvc
targets "$EKS_CTX"
prom "$EKS_CTX" 'pg_up'
```
Expected: `prometheus` and `grafana` Applications `Synced` and `Healthy`, both pods `Running` with `Bound` PVCs on `gp3`, the same job list as local, and `pg_up` returning `1` for two series.

#### Task 22.4.2: Measure, then decide whether to leave it up

**Goal:** Real numbers against the budget primer's estimates, and a conscious decision about the billing cluster.

```bash
kubectl --context "$EKS_CTX" top pods -n observability
kubectl --context "$EKS_CTX" top nodes
kubectl --context "$EKS_CTX" get pods -A --no-headers | wc -l
kubectl --context "$EKS_CTX" get node -o jsonpath='{.items[0].status.allocatable.pods}{"\n"}'
```
Write the figures into the tracker's Notes table. They feed Task 25.2.1, and are the first real check on the estimates in the budget primer.

Leaving the cluster up for Sections 23 and 24 costs about 5 to 6 USD a day. Section 23 needs it only in its last phase, so destroying now is usually right:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake destroy CLUSTER=eks
```

**Validate:** if you destroyed it, the check from Task 18.3.1 (using the registry's cluster name) shows nothing left:
```bash
aws eks list-clusters --region ap-southeast-2 --query clusters
aws ec2 describe-volumes --region ap-southeast-2 --filters Name=tag-key,Values="kubernetes.io/cluster/$EKS_CTX" --query 'Volumes[].VolumeId'
```
Expected: `[]` for both. The two new volumes from Prometheus are the ones most likely to be left behind.

Commit Section 22 when its tracker rows are ticked.


---

## Section 23: Instrumenting the stubs

**Objective:** Both services report rate, errors and duration per route, service-1 also reports how long its calls to service-2 and to Postgres take, and a dashboard shows canary beside stable. Then a real canary is watched on it.

This section changes application code, so it works in the two service repos as well as the GitOps repo and the two config repos. Work service-2 first: it is the simpler service, and it is also the one you release first, because service-1 calls it.

### Phase 23.1: Metrics in the services

#### Task 23.1.1: service-2 exposes RED metrics

**Goal:** `GET /metrics` on service-2 returns Prometheus text, and `/process` shows up in `http_requests_total` by route template.

```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
git switch main && git pull --ff-only
git switch -c feat/metrics
source .venv/bin/activate 2>/dev/null || true
```
Add the one new dependency, pinned exactly (version checked installable together with the rest in October 2026):
```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
printf 'prometheus-client==0.26.0\n' >> requirements.txt
pip install -r requirements-dev.txt
```

Create the metrics module. The same file goes into both services, which is a deliberate copy: two services sharing a library would need a package registry, and this one file is small enough to read in full.
```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
cat > src/metrics.py <<'METRICS_EOF'
import time
from contextlib import contextmanager

from fastapi import FastAPI, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

# Paths that are not traffic worth measuring. Probes fire every few seconds
# and would drown the real request rate; /metrics measuring itself is noise.
SKIP_PATHS = {"/metrics", "/healthz", "/readyz"}

REQUESTS = Counter(
    "http_requests_total",
    "HTTP requests handled, by method, route template and status code.",
    ["method", "route", "status"],
)
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds, by method and route template.",
    ["method", "route"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)
OUTBOUND_REQUESTS = Counter(
    "outbound_requests_total",
    "Calls this service made to another service, by target and status.",
    ["target", "status"],
)
OUTBOUND_LATENCY = Histogram(
    "outbound_request_duration_seconds",
    "Latency of calls this service made to another service.",
    ["target"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)
DB_LATENCY = Histogram(
    "db_query_duration_seconds",
    "Latency of Postgres queries, by a short fixed query name.",
    ["query"],
    buckets=(0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0),
)


def install(app: FastAPI) -> None:
    """Add the RED middleware and the /metrics endpoint to an app."""

    @app.middleware("http")
    async def record_red(request: Request, call_next):
        if request.url.path in SKIP_PATHS:
            return await call_next(request)
        start = time.perf_counter()
        status = "500"
        try:
            response = await call_next(request)
            status = str(response.status_code)
            return response
        finally:
            # The route TEMPLATE (/items/{id}), never the raw path. A raw path
            # would create one time series per id, which is how Prometheus
            # runs out of memory. Unmatched requests share one label value.
            route = request.scope.get("route")
            path = getattr(route, "path", "unmatched")
            REQUESTS.labels(request.method, path, status).inc()
            LATENCY.labels(request.method, path).observe(time.perf_counter() - start)

    @app.get("/metrics", include_in_schema=False)
    def metrics() -> Response:
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@contextmanager
def outbound_call(target: str):
    """Time a call to another service. Set call["status"] to the HTTP status
    once a response arrives; if the call raises, the status stays "error"."""
    call = {"status": "error"}
    start = time.perf_counter()
    try:
        yield call
    finally:
        OUTBOUND_REQUESTS.labels(target, call["status"]).inc()
        OUTBOUND_LATENCY.labels(target).observe(time.perf_counter() - start)


@contextmanager
def db_query(name: str):
    """Time one Postgres query. `name` is a short fixed label, never SQL."""
    start = time.perf_counter()
    try:
        yield
    finally:
        DB_LATENCY.labels(name).observe(time.perf_counter() - start)
METRICS_EOF
```

**What to notice.**
- `route = getattr(request.scope.get("route"), "path", "unmatched")`: the router stores the matched route in the request scope, and `path` is the template (`/process`). A request that matches nothing (a scanner probing `/wp-admin`) shares the single value `unmatched` instead of minting a series per URL.
- The middleware reads the route **after** `call_next`, in `finally`. The router fills it in while handling the request, so reading it before would always see `unmatched`.
- `status` defaults to `"500"` and is overwritten on success. An exception that escapes the handler is counted as the 500 it becomes.
- `/metrics` is a plain route, not a mounted sub-application. A mount redirects `/metrics` to `/metrics/`, and a redirect from a scraper is a surprise worth avoiding.
- `outbound_call` and `db_query` are context managers that the next task uses in service-1. They are defined here so both services carry the identical file.

Wire it in with a patch. It adds two lines to `src/main.py`:
```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
git apply <<'PATCH_EOF'
diff --git a/src/main.py b/src/main.py
index e1fdd11..d0d4ee3 100644
--- a/src/main.py
+++ b/src/main.py
@@ -1,9 +1,12 @@
 from fastapi import FastAPI
 from pydantic import BaseModel
 
+from src import metrics
+
 # No lifespan handler, unlike service-1. This service opens no connections to
 # anything, so there is nothing to set up or tear down.
 app = FastAPI(title="service-2-worker", version="1.2.0")
+metrics.install(app)
 
 
 # ---------------------------------------------------------------------------
PATCH_EOF
```

Add tests. They live in the existing test file and compare before and after, because the counters are process-wide:
```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
cat >> tests/test_main.py <<'TEST_EOF'


# ---------------------------------------------------------------------------
# Metrics.
# ---------------------------------------------------------------------------
async def test_process_is_counted_by_route_template(client):
    await client.post("/process", json={"value": 1})
    body = (await client.get("/metrics")).text
    assert 'http_requests_total{method="POST",route="/process",status="200"}' in body


async def test_probes_are_not_counted(client):
    await client.get("/healthz")
    body = (await client.get("/metrics")).text
    assert 'route="/healthz"' not in body
TEST_EOF
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
ruff check src tests
pytest -q
```
Expected: `All checks passed!` and all tests passing (the existing ones plus the two new).

Then run it for real and look at the output:
```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
uvicorn src.main:app --port 8012 >/dev/null 2>&1 &
UV=$!; sleep 2
curl -s -X POST localhost:8012/process -H 'content-type: application/json' -d '{"value": 21}'
echo
curl -s localhost:8012/metrics | grep -E '^http_requests_total|^http_request_duration_seconds_count'
kill $UV
```
Expected: `{"service":"service-2","input":21,"result":42}`, then a `http_requests_total{method="POST",route="/process",status="200"} 1.0` line and a matching duration count. There is no line for `/metrics` or `/healthz`.

Commit, but do not merge yet:
```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
git add requirements.txt src/metrics.py src/main.py tests/test_main.py
git commit -m "feat: expose RED metrics on /metrics"
```

#### Task 23.1.2: service-1 exposes RED metrics, plus outbound and database timings

**Goal:** The same, plus `outbound_requests_total` and a latency histogram for the call to service-2, and a latency histogram for each of service-1's two Postgres queries.

**Why these two extra sets.** When `/compute` gets slow, the first question is which hop. Service-1's total time is its own work plus the call to service-2 plus the insert. Separate timings turn "it's slow" into "the insert is slow" without opening a trace, and they still work on the cheap, long-retention side of the stack.

```bash
cd "$PLATFORM_HOME/lfi-service-1-app"
git switch main && git pull --ff-only
git switch -c feat/metrics
source .venv/bin/activate 2>/dev/null || true
printf 'prometheus-client==0.26.0\n' >> requirements.txt
pip install -r requirements-dev.txt
```
Create the same `src/metrics.py` (identical to service-2's; copying it is the point):
```bash
cp "$PLATFORM_HOME/lfi-service-2-app/src/metrics.py" "$PLATFORM_HOME/lfi-service-1-app/src/metrics.py"
cd "$PLATFORM_HOME/lfi-service-1-app"
git apply <<'PATCH_EOF'
diff --git a/src/main.py b/src/main.py
index ba086b4..05ba6fe 100644
--- a/src/main.py
+++ b/src/main.py
@@ -7,6 +7,7 @@ import httpx
 from fastapi import Depends, FastAPI, HTTPException, Request
 from pydantic import BaseModel
 
+from src import metrics
 from src.config import database_url, service_2_url
 
 # Log to stdout at INFO. In Kubernetes stdout IS the log: kubectl logs reads
@@ -84,6 +85,7 @@ async def lifespan(app: FastAPI):
 
 
 app = FastAPI(title="service-1-gateway", version="1.3.0", lifespan=lifespan)
+metrics.install(app)
 
 
 # These two exist as dependencies rather than direct app.state reads so
@@ -150,7 +152,9 @@ async def compute(
     # Call the worker FIRST, persist second. The ordering is the contract:
     # a failed worker call must leave no row behind. The 502 test pins it.
     try:
-        response = await worker.post("/process", json={"value": body.value})
+        with metrics.outbound_call("service-2") as call:
+            response = await worker.post("/process", json={"value": body.value})
+            call["status"] = str(response.status_code)
         # httpx does not raise on 4xx/5xx by default, so this line is what
         # turns the broken_worker fixture's 503 into an exception.
         response.raise_for_status()
@@ -166,11 +170,12 @@ async def compute(
     # $1/$2 are asyncpg's placeholders. Values are passed separately, so the
     # driver parameterises the query and string formatting never touches SQL.
     # RETURNING id hands back the new primary key in the same round trip.
-    persisted_id = await pool.fetchval(
-        "INSERT INTO computations (input_value, result) VALUES ($1, $2) RETURNING id",
-        body.value,
-        payload["result"],
-    )
+    with metrics.db_query("insert_computation"):
+        persisted_id = await pool.fetchval(
+            "INSERT INTO computations (input_value, result) VALUES ($1, $2) RETURNING id",
+            body.value,
+            payload["result"],
+        )
 
     return ComputeResponse(
         gateway="service-1",
@@ -187,9 +192,10 @@ async def compute(
 async def history(pool: asyncpg.Pool = Depends(get_pool)) -> list[HistoryEntry]:
     # DESC + LIMIT 10: newest first, bounded. An unbounded SELECT would be a
     # slow surprise the first time the table is large.
-    rows = await pool.fetch(
-        "SELECT id, input_value, result FROM computations ORDER BY id DESC LIMIT 10"
-    )
+    with metrics.db_query("select_history"):
+        rows = await pool.fetch(
+            "SELECT id, input_value, result FROM computations ORDER BY id DESC LIMIT 10"
+        )
     # asyncpg returns Record objects, not dicts. dict(row) converts, then **
     # unpacks into the model, which validates the shape on the way out.
     return [HistoryEntry(**dict(row)) for row in rows]
PATCH_EOF
```
The patch wraps the call to service-2 and the two queries, and installs the middleware. Read it once: the only logic change is that `call["status"]` is recorded **inside** the `with`, so a non-2xx answer from service-2 is counted with its status before `raise_for_status` turns it into the 502.

Add tests:
```bash
cd "$PLATFORM_HOME/lfi-service-1-app"
cat >> tests/test_main.py <<'TEST_EOF'


# ---------------------------------------------------------------------------
# Metrics. The counters are process-global, so each assertion compares a
# before and an after instead of expecting an absolute number.
# ---------------------------------------------------------------------------
async def sample(client, name: str, labels: str) -> float:
    text = (await client.get("/metrics")).text
    for line in text.splitlines():
        if line.startswith(name + "{") and labels in line:
            return float(line.rsplit(" ", 1)[1])
    return 0.0


async def test_compute_is_counted_by_route_template():
    client, _ = build_client(healthy_worker)
    async with client:
        before = await sample(client, "http_requests_total", 'route="/compute"')
        await client.post("/compute", json={"value": 21})
        after = await sample(client, "http_requests_total", 'route="/compute"')
    assert after == before + 1


async def test_probes_and_metrics_are_not_counted():
    client, _ = build_client(healthy_worker)
    async with client:
        await client.get("/healthz")
        body = (await client.get("/metrics")).text
    assert 'route="/healthz"' not in body
    assert 'route="/metrics"' not in body


async def test_outbound_failure_is_counted_with_the_status():
    client, _ = build_client(broken_worker)
    async with client:
        before = await sample(client, "outbound_requests_total", 'status="503"')
        await client.post("/compute", json={"value": 1})
        after = await sample(client, "outbound_requests_total", 'status="503"')
    assert after == before + 1
TEST_EOF
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-service-1-app"
ruff check src tests
pytest -q
```
Expected: `All checks passed!` and all tests passing (the existing ones plus three new). The three new ones pin the behaviours that matter: a request is counted under its route template, probes and `/metrics` are not counted, and a failing worker is counted as an outbound 503.

```bash
cd "$PLATFORM_HOME/lfi-service-1-app"
git add requirements.txt src/metrics.py src/main.py tests/test_main.py
git commit -m "feat: expose RED, outbound and database metrics on /metrics"
```

#### Task 23.1.3: Scrapeable canary and stable Services

**Goal:** Each service has `<svc>-stable` and `<svc>-canary` Services, named in its Rollout, annotated for scraping. ArgoCD is told that Rollouts owns their selectors.

Read the primer "why canary and stable are Services" first if you skipped it. The short version: Rollouts keeps each of these Services pointed at the right pods, so a query can name a Service instead of a hash.

The Services and the two Rollout fields are the service's own manifests, so they go in each service's **config repo**, in `base/app`, which dev and prod share. The ArgoCD side is a platform policy that applies to every service, so it goes in the **GitOps repo**, in the generator that writes the services ApplicationSet.

First the manifests, one branch in each config repo:
```bash
for pair in "service-1:$CFG1" "service-2:$CFG2"; do
  s="${pair%%:*}"; cfg="${pair#*:}"
  cd "$cfg"
  git switch main && git pull --ff-only
  git switch -c feat/instrument
  b=base/app
  for role in stable canary; do
    SVC=$s ROLE=$role yq '
      .metadata.name = strenv(SVC) + "-" + strenv(ROLE)
      | .metadata.annotations."prometheus.io/scrape" = "true"
      | .metadata.annotations."prometheus.io/port" = "8000"
      | .metadata.annotations."prometheus.io/path" = "/metrics"
    ' "$b/service.yaml" > "$b/service-$role.yaml"
  done
  yq -i '.resources += ["service-stable.yaml", "service-canary.yaml"]' "$b/kustomization.yaml"
  SVC=$s yq -i '
    .spec.strategy.canary.canaryService = strenv(SVC) + "-canary"
    | .spec.strategy.canary.stableService = strenv(SVC) + "-stable"
  ' "$b/rollout.yaml"
done
```
The original `service-1` and `service-2` Services are untouched and **not** annotated. They are what Ingress and other services use, and scraping them as well would count every pod twice.

Now the ArgoCD side. Rollouts rewrites the selectors of the two new Services at runtime, adding the pod-template hash. Git says `app: service-1` and the live object says `app: service-1, rollouts-pod-template-hash: ...`. ArgoCD reads that difference as drift, and with `selfHeal: true` it may revert it, which Rollouts then re-applies. The result is a fight that shows as `OutOfSync` and can disturb a canary. Tell ArgoCD to leave `.spec.selector` on Services alone.

The services ApplicationSets are **generated** by `scripts/gen-appsets.sh` (guide 4, Task 20.2.2), and the contract check fails if a committed file differs from what the generator writes. So the edit goes in the generator, and the files are regenerated. The edit refuses to run if the generator is not shaped as expected, and refuses a second run:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch main && git pull --ff-only
git switch -c feat/instrument
python3 - <<'PYEOF'
import sys
path = "scripts/gen-appsets.sh"
s = open(path).read()
old = """            maxDuration: 2m
EOF

  cat > "$(out data "$c")" <<EOF"""
new = """            maxDuration: 2m
        syncOptions:
          # Without this, ignoreDifferences below only hides a difference in the UI
          # and a sync still overwrites the field.
          - RespectIgnoreDifferences=true
      ignoreDifferences:
        # Argo Rollouts rewrites the selector of the stable and canary Services at
        # runtime, adding the pod-template hash. Git says one thing and the live
        # object another; without this, selfHeal would fight the Rollout over it.
        - group: ""
          kind: Service
          jsonPointers:
            - /spec/selector
EOF

  cat > "$(out data "$c")" <<EOF"""
if s.count(old) != 1:
    sys.exit(f"ERROR: {path}: expected one match for the end of the services template, found {s.count(old)}.")
open(path, "w").write(s.replace(old, new))
print("Edited scripts/gen-appsets.sh.")
PYEOF
scripts/gen-appsets.sh
yq '.spec.template.spec | pick(["ignoreDifferences", "syncPolicy"])' argocd/apps-local/appsets/services.yaml
scripts/check-contract.sh
```
`RespectIgnoreDifferences=true` matters: without it the ignore only hides the diff in the UI and a sync still overwrites the field.

**The trade-off, honestly.** This ignores selector drift on **every** Service in those apps, including the plain `service-1` and `service-2`, because `ignoreDifferences` cannot select by name pattern here. A hand-edited selector on those two would go uncorrected. On a lab cluster that is a fair price; a production one would list the four Service names explicitly.

**If the edit reports no match,** your generator differs from guide 4's. Make the same change by hand: the two fields belong under the services template's `spec` (`ignoreDifferences` beside `syncPolicy`, `syncOptions` inside it). The validation below prints where they landed, and `scripts/check-contract.sh` must still print `OK`.

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
for pair in "service-1:$CFG1" "service-2:$CFG2"; do
  s="${pair%%:*}"; cfg="${pair#*:}"
  for c in local eks; do for e in dev prod; do
    printf '%s %s %s: ' "$c" "$e" "$s"
    kustomize build "$cfg/$c/$e/app" | yq -N 'select(.kind == "Service") | .metadata.name' | tr '\n' ' '
    echo
  done; done
done
kustomize build "$CFG1/local/prod/app" | yq 'select(.kind == "Rollout") | .spec.strategy.canary | pick(["canaryService", "stableService"])'
yq '.images[].newTag' "$CFG1/local/dev/app/kustomization.yaml"
```
Expected: eight lines, each listing three Services (`service-1 service-1-canary service-1-stable`, and the service-2 equivalent), the two names on the Rollout, and a build tag, which proves the field CI writes is still where CI looks. Then the ApplicationSet fields printed above, and `OK` from the contract check.

```bash
for cfg in "$CFG1" "$CFG2"; do
  git -C "$cfg" add base/app
  git -C "$cfg" commit -m "feat(observability): stable and canary Services, scraped"
done
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git add scripts argocd
git commit -m "feat(observability): ignore Service selector drift in the services ApplicationSets"
```

#### Task 23.1.4: Ship it to dev

**Goal:** Both new builds running in dev, and Prometheus scraping them.

Order matters only mildly. Service-2 first because service-1 depends on it, and the manifests before the first scrape so the Services exist:
```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
git push -u origin feat/metrics
gh pr create --fill --base main && gh pr merge --merge --delete-branch
```
Wait for its CI to build and promote to dev (a few minutes; watch the repo's Actions tab, or `gh run watch`), then the same for service-1:
```bash
cd "$PLATFORM_HOME/lfi-service-1-app"
git push -u origin feat/metrics
gh pr create --fill --base main && gh pr merge --merge --delete-branch
```
Then merge the manifests. The ApplicationSet change goes first, so the selector rule is already in place when the new Services appear, and then the two config repos:
```bash
merge_to_main feat/instrument
merge_config "$CFG2" feat/instrument
merge_config "$CFG1" feat/instrument
kubectl --context "$LOCAL_CTX" -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
```
The config repos' `base/app` is shared, so prod gets the two new Services too. Nothing in a pod template changed, so prod does not start a rollout.
`gh pr merge` may need `--admin` or a review step if you turned on branch protection in guide 1. Follow whichever path you set up there; the point is that `main` moves and CI runs.

**Validate:**
```bash
kubectl --context "$LOCAL_CTX" -n platform-dev get svc
kubectl --context "$LOCAL_CTX" -n platform-dev get endpoints service-1-canary service-1-stable
kubectl --context "$LOCAL_CTX" -n argocd get applications | grep -E 'service-[12]-dev'
targets "$LOCAL_CTX"
```
Expected: six Services in `platform-dev` (the plain, stable and canary for each), endpoints behind both stable and canary (the same pod, because nothing is rolling out), both dev Applications `Synced`, and `kubernetes-service-endpoints` targets. **In `platform-prod` the same targets exist but are `down`**: the prod pods still run the old build with no `/metrics`. That is expected until Task 23.2.3.

Send some traffic and ask Prometheus about it:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
DURATION=60 gmake traffic CLUSTER=local ENVIRONMENT=dev
prom "$LOCAL_CTX" 'sum by (route) (rate(http_requests_total{namespace="platform-dev",service=~"service-[12]-stable"}[1m]))'
prom "$LOCAL_CTX" 'histogram_quantile(0.95, sum by (le, target) (rate(outbound_request_duration_seconds_bucket{namespace="platform-dev"}[1m])))'
```
Expected: the traffic command ends with a count of `200` responses (a few hundred, for example `  280 200`), then a rate for `/compute` and for `/process` (around 5 per second each, since one `/compute` triggers one `/process`), and a p95 for the `service-2` target. Run the `prom` lines within a minute of the traffic ending or the rate window will be empty.

**If `targets` shows `kubernetes-service-endpoints` but the series are missing a `service` label,** Task 22.1.1's label check should have caught it; return there.

### Phase 23.2: A dashboard, and a canary to watch on it

#### Task 23.2.1: The RED dashboard

**Goal:** A dashboard, kept in Git, with request rate, error ratio and p95 latency by route, outbound and database timings, and canary against stable.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
mkdir -p dashboards
cat > dashboards/red.json <<'DASH_EOF'
{
 "uid": "red-overview", "title": "RED overview", "tags": ["platform"], "timezone": "browser",
 "schemaVersion": 39, "version": 1, "refresh": "10s", "time": {"from": "now-30m", "to": "now"},
 "templating": {"list": [
  {"name": "namespace", "type": "custom", "query": "platform-dev,platform-prod", "current": {"text": "platform-prod", "value": "platform-prod"}, "options": [{"text": "platform-dev", "value": "platform-dev", "selected": false}, {"text": "platform-prod", "value": "platform-prod", "selected": true}]},
  {"name": "service", "type": "custom", "query": "service-1,service-2", "current": {"text": "service-1", "value": "service-1"}, "options": [{"text": "service-1", "value": "service-1", "selected": true}, {"text": "service-2", "value": "service-2", "selected": false}]}
 ]},
 "panels": [
  {"id": 1, "type": "timeseries", "title": "Request rate by route", "datasource": {"type": "prometheus", "uid": "prometheus"}, "gridPos": {"x": 0, "y": 0, "w": 12, "h": 8}, "fieldConfig": {"defaults": {"unit": "reqps"}}, "targets": [{"refId": "A", "expr": "sum by (route) (rate(http_requests_total{namespace=\"$namespace\",service=~\"${service}-stable\"}[1m]))", "legendFormat": "{{route}}"}]},
  {"id": 2, "type": "timeseries", "title": "Error ratio by route", "datasource": {"type": "prometheus", "uid": "prometheus"}, "gridPos": {"x": 12, "y": 0, "w": 12, "h": 8}, "fieldConfig": {"defaults": {"unit": "percentunit"}}, "targets": [{"refId": "A", "expr": "sum by (route) (rate(http_requests_total{namespace=\"$namespace\",service=~\"${service}-stable\",status=~\"5..\"}[1m])) / clamp_min(sum by (route) (rate(http_requests_total{namespace=\"$namespace\",service=~\"${service}-stable\"}[1m])), 0.001)", "legendFormat": "{{route}}"}]},
  {"id": 3, "type": "timeseries", "title": "p95 latency by route", "datasource": {"type": "prometheus", "uid": "prometheus"}, "gridPos": {"x": 0, "y": 8, "w": 12, "h": 8}, "fieldConfig": {"defaults": {"unit": "s"}}, "targets": [{"refId": "A", "expr": "histogram_quantile(0.95, sum by (le, route) (rate(http_request_duration_seconds_bucket{namespace=\"$namespace\",service=~\"${service}-stable\"}[5m])))", "legendFormat": "{{route}}"}]},
  {"id": 4, "type": "timeseries", "title": "Canary vs stable: request rate", "datasource": {"type": "prometheus", "uid": "prometheus"}, "gridPos": {"x": 12, "y": 8, "w": 12, "h": 8}, "fieldConfig": {"defaults": {"unit": "reqps"}}, "targets": [{"refId": "A", "expr": "sum by (service) (rate(http_requests_total{namespace=\"$namespace\",service=~\"${service}-(stable|canary)\"}[1m]))", "legendFormat": "{{service}}"}]},
  {"id": 5, "type": "timeseries", "title": "Canary vs stable: error ratio", "datasource": {"type": "prometheus", "uid": "prometheus"}, "gridPos": {"x": 0, "y": 16, "w": 12, "h": 8}, "fieldConfig": {"defaults": {"unit": "percentunit"}}, "targets": [{"refId": "A", "expr": "sum by (service) (rate(http_requests_total{namespace=\"$namespace\",service=~\"${service}-(stable|canary)\",status=~\"5..\"}[1m])) / clamp_min(sum by (service) (rate(http_requests_total{namespace=\"$namespace\",service=~\"${service}-(stable|canary)\"}[1m])), 0.001)", "legendFormat": "{{service}}"}]},
  {"id": 6, "type": "timeseries", "title": "Outbound p95 by target", "datasource": {"type": "prometheus", "uid": "prometheus"}, "gridPos": {"x": 12, "y": 16, "w": 12, "h": 8}, "fieldConfig": {"defaults": {"unit": "s"}}, "targets": [{"refId": "A", "expr": "histogram_quantile(0.95, sum by (le, target) (rate(outbound_request_duration_seconds_bucket{namespace=\"$namespace\"}[5m])))", "legendFormat": "{{target}}"}]},
  {"id": 7, "type": "timeseries", "title": "Postgres query p95", "datasource": {"type": "prometheus", "uid": "prometheus"}, "gridPos": {"x": 0, "y": 24, "w": 12, "h": 8}, "fieldConfig": {"defaults": {"unit": "s"}}, "targets": [{"refId": "A", "expr": "histogram_quantile(0.95, sum by (le, query) (rate(db_query_duration_seconds_bucket{namespace=\"$namespace\"}[5m])))", "legendFormat": "{{query}}"}]}
 ]
}
DASH_EOF
jq -e '.panels | length' dashboards/red.json
```
Expected: `7`.

**Reading the queries.** Three details are worth understanding before you trust the graphs:
- Panels 1 to 3 query only `-stable`. Outside a rollout the stable and canary Services both select the same pods, so including both would double every number. During a rollout the stable line is the old version alone, which is what you want as the baseline.
- Panel 5 divides error rate by a `clamp_min(..., 0.001)` of total rate. A service with no traffic has a total of zero, and dividing by zero produces `NaN`, which draws as a gap and poisons any comparison. The clamp turns "no traffic" into "zero errors", which is honest for a graph and **not** safe as a health check. Section 25's analysis therefore has a second check that insists on traffic.
- The `namespace` and `service` variables are custom lists, not queries, so they work even when a namespace has no data yet.

Point Grafana at it. The values gain two keys. The owner is read from your remote, so nothing is typed by hand:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
OWNER="$(git remote get-url origin | sed -E 's#.*github\.com[:/]([^/]+)/.*#\1#')"
REPO="$(basename "$(git remote get-url origin)" .git)"
cat >> addons/local/grafana/values.yaml <<EOF

# Where Grafana looks for dashboard files on disk, and which to download into
# that folder when it starts. The URL is the repo's raw file on the default
# branch, so merging a change to dashboards/red.json is the whole deploy.
dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
      - name: platform
        folder: Platform
        type: file
        disableDeletion: true
        options:
          path: /var/lib/grafana/dashboards/platform
dashboards:
  platform:
    red:
      url: https://raw.githubusercontent.com/${OWNER}/${REPO}/main/dashboards/red.json
EOF
yq '.dashboards.platform.red.url' addons/local/grafana/values.yaml
curl -sfI "$(yq '.dashboards.platform.red.url' addons/local/grafana/values.yaml)" | head -1
```
The last line asks GitHub for the file. It returns `404` until the dashboard is merged, which is the expected order of events here: merge first, and the URL exists.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch -c feat/dashboard
git add dashboards addons/local/grafana
git commit -m "feat(observability): RED dashboard"
merge_to_main feat/dashboard
```
Changing Grafana's values restarts its pod. Wait for it, then confirm the dashboard arrived:
```bash
kubectl --context "$LOCAL_CTX" -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
sleep 120
kubectl --context "$LOCAL_CTX" -n observability rollout status deployment/grafana --timeout=180s
```

**Validate:** open Grafana (`gmake grafana CLUSTER=local`) and run, from a second terminal:
```bash
PASS="$(kubectl --context "$LOCAL_CTX" -n observability get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d)"
curl -s -u "admin:$PASS" 'http://localhost:3000/api/search?query=RED' | jq -r '.[] | .folderTitle + " / " + .title'
```
Expected: `Platform / RED overview`. If it is empty, the init container that downloads dashboards could not reach GitHub or got a `404`; read its log with `kubectl --context "$LOCAL_CTX" -n observability logs deploy/grafana -c download-dashboards`.

#### Task 23.2.2: Watch traffic on the dashboard

**Goal:** Every panel populated, and a feel for what normal looks like before anything is broken.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
DURATION=180 gmake traffic CLUSTER=local ENVIRONMENT=dev
```
In Grafana, open Platform, RED overview, set `namespace` to `platform-dev` and `service` to `service-1`. Then switch `service` to `service-2`.

**Validate:** with traffic running, the request rate panel shows `/compute` at roughly 5 per second for service-1 and `/process` at the same rate for service-2; error ratio is flat at zero; p95 is in single-digit milliseconds for service-2 and a little higher for service-1; "Outbound p95 by target" shows `service-2`, and "Postgres query p95" shows `insert_computation`. The two canary panels show one line each, both labelled stable and canary with the same values, because nothing is rolling out.

Write down what normal looks like: the request rate you sent and the p95 you got. Section 25's thresholds are easier to judge against a baseline you saw yourself.

#### Task 23.2.3: Release to prod, then watch a canary on the dashboard

**Goal:** The metrics build in prod, and one real canary observed as two lines diverging.

**Release 1 brings the metrics code to prod.** Nothing is being compared yet, because the stable pods have no `/metrics` at all.
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake release CLUSTER=local SVC=both
```
It opens one PR per service, each in that service's config repo. Review and merge both, then promote service-2 first and service-1 second, as every release in guide 2:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake status CLUSTER=local ENVIRONMENT=prod
gmake canary ACTION=promote CLUSTER=local SVC=service-2
gmake canary ACTION=promote CLUSTER=local SVC=service-1
```
Confirm the prod targets are now up:
```bash
targets "$LOCAL_CTX"
```
Expected: no `down` targets left under `kubernetes-service-endpoints`.

**Release 2 is the one you watch.** It needs a build that differs from the running one, so make the smallest honest change, a version string:
```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
git switch main && git pull --ff-only
sed -i '' 's/version="1.2.0"/version="1.2.1"/' src/main.py
git switch -c chore/bump-version
git commit -am "chore: bump worker version to 1.2.1"
git push -u origin chore/bump-version
gh pr create --fill --base main && gh pr merge --merge --delete-branch
```
When CI has promoted it to dev, open the release:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake release CLUSTER=local SVC=service-2
```
Merge the PR, then start traffic against prod **before** the canary pauses, and leave it running (it needs the five minutes):
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
DURATION=400 gmake traffic CLUSTER=local ENVIRONMENT=prod
```
In another terminal, watch the rollout, and open the dashboard with `namespace` set to `platform-prod` and `service` set to `service-2`:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake canary ACTION=watch CLUSTER=local SVC=service-2
```

**Validate, while the rollout is paused at 50 percent:**
```bash
kubectl --context "$LOCAL_CTX" -n platform-prod get endpoints service-2-canary service-2-stable -o custom-columns=NAME:.metadata.name,ENDPOINTS:.subsets[*].addresses[*].ip
kubectl --context "$LOCAL_CTX" -n argocd get application service-2-prod -o jsonpath='{.status.sync.status}{"\n"}'
prom "$LOCAL_CTX" 'sum by (service) (rate(http_requests_total{namespace="platform-prod",service=~"service-2-(stable|canary)"}[1m]))'
```
Expected: the two Services list **different** pod IPs (one canary pod against the stable pods), the Application stays `Synced` through the whole pause, and two series come back with roughly comparable rates, since traffic splits by pod count. On the dashboard, "Canary vs stable: request rate" shows two lines and "Canary vs stable: error ratio" shows two flat lines at zero.

**If the Application flaps between `Synced` and `OutOfSync`,** the `ignoreDifferences` from Task 23.1.3 did not take effect: check that it sits under the Application template's `spec` and that `RespectIgnoreDifferences=true` is in `syncOptions`.

Now finish it:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake canary ACTION=promote CLUSTER=local SVC=service-2
```
After the promotion the two lines merge into one, because both Services select the same pods again.

Commit Section 23's tracker rows when they are ticked.

### Phase 23.3: Confirm on EKS

The service builds reached EKS dev automatically (each service's CI writes the dev tag for both clusters into its config repo, guide 4 Task 20.3.7), so only the dashboard and the cluster need attention.

#### Task 23.3.1: Dashboard and a canary on EKS

**Goal:** The same dashboard working on EKS, with one canary watched through the load balancer.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch -c feat/dashboard-eks
cp addons/local/grafana/values.yaml addons/eks/grafana/values.yaml
git add addons/eks/grafana
git commit -m "feat(observability): RED dashboard on EKS"
gmake up CLUSTER=eks
merge_to_main feat/dashboard-eks
kubectl --context "$EKS_CTX" -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
sleep 240
```

**Validate:**
```bash
targets "$EKS_CTX"
DURATION=90 gmake traffic CLUSTER=eks ENVIRONMENT=dev
prom "$EKS_CTX" 'sum by (route) (rate(http_requests_total{namespace="platform-dev",service=~"service-[12]-stable"}[1m]))'
```
Expected: the same target jobs as local, the traffic summary ending in `200`s, and a rate for `/compute` and `/process`. Then open `gmake grafana CLUSTER=eks` (port 3001) and confirm `Platform / RED overview` shows the EKS data.

To see a canary on EKS, repeat Task 23.2.3's release step with `CLUSTER=eks` and the traffic command against prod. It is optional here: the mechanism is the same, and the EKS result that matters is that the dashboard and the two Services work behind a different ingress.

Measure, and then decide whether to leave the cluster up for Section 24 (it is usually cheaper to destroy and rebuild):
```bash
kubectl --context "$EKS_CTX" top pods -n observability
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake destroy CLUSTER=eks
```


---

## Section 24: Traces and logs

**Objective:** One request from the ingress through service-1, service-2 and Postgres appears as a single trace, the log lines it caused are findable by the trace's id, and Grafana jumps between them.

The pipeline, so the pieces below have somewhere to sit:

```
service pods --OTLP over HTTP--> Alloy --OTLP over gRPC--> Tempo ---+
service pods --stdout--> (kubelet) <--API tail-- Alloy --push--> Loki ---+--> Grafana
service pods <--scrape-- Prometheus (Section 22, unchanged)        ---+
```

### Phase 24.1: The stores and the agent

Each of these is an add-on directory of the kind Task 22.1.3 created. All four tasks edit the GitOps repo on one branch and merge once, at the end of the phase, because the pieces only make sense together.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch main && git pull --ff-only
git switch -c feat/traces-and-logs
source "$PLATFORM_HOME/.tmp/obs-versions.env"
```

#### Task 24.1.1: Tempo

**Goal:** A single-binary Tempo that accepts OTLP and keeps a day of traces.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"; source "$PLATFORM_HOME/.tmp/obs-versions.env"
mkdir -p addons/local/tempo
cat > addons/local/tempo/addon.yaml <<EOF
name: tempo
namespace: observability
chart:
  repo: https://grafana.github.io/helm-charts
  name: tempo
  version: "$TEMPO_CHART_VERSION"
EOF
cat > addons/local/tempo/values.yaml <<'EOF'
tempo:
  # One day. Traces are the most expensive signal to keep, and the use case
  # here is "what just happened", not history.
  retention: 24h
  receivers:
    otlp:
      protocols:
        # Alloy forwards to the gRPC port. HTTP stays on so a trace can be
        # posted directly while debugging.
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
persistence:
  enabled: true
  size: 2Gi
resources:
  requests:
    cpu: 50m
    memory: 200Mi
  limits:
    memory: 400Mi
EOF
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
yq '.tempo.retention' addons/local/tempo/values.yaml
yq '.chart.version' addons/local/tempo/addon.yaml
```
Expected: `24h` and a chart version. The running checks come once the phase is merged.

#### Task 24.1.2: Loki

**Goal:** A single-binary Loki on a filesystem volume, with three days of retention and none of the scale-out components.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"; source "$PLATFORM_HOME/.tmp/obs-versions.env"
mkdir -p addons/local/loki
cat > addons/local/loki/addon.yaml <<EOF
name: loki
namespace: observability
chart:
  repo: https://grafana.github.io/helm-charts
  name: loki
  version: "$LOKI_CHART_VERSION"
EOF
cat > addons/local/loki/values.yaml <<'EOF'
# One process does everything. The chart's other modes split reads, writes and
# a backend into separate pods, which is scale this project does not have.
deploymentMode: SingleBinary

loki:
  # No tenant header required. There is one tenant: you.
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  limits_config:
    retention_period: 72h
  compactor:
    # Retention is enforced by the compactor, so it has to be on for the
    # retention_period above to delete anything.
    retention_enabled: true
    delete_request_store: filesystem

singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: 2Gi
  resources:
    requests:
      cpu: 50m
      memory: 250Mi
    limits:
      memory: 500Mi

# Scale-out components, all off. Leaving one at its default would start pods.
read:
  replicas: 0
write:
  replicas: 0
backend:
  replicas: 0

# A gateway (nginx) in front of Loki adds a pod and nothing a single binary
# needs. Grafana and Alloy talk to the Loki Service directly.
gateway:
  enabled: false
# Caches are for query speed at a scale this does not reach, and each is a pod.
chunksCache:
  enabled: false
resultsCache:
  enabled: false
# The chart's own smoke test and canary would be extra pods and extra traffic.
lokiCanary:
  enabled: false
test:
  enabled: false
EOF
```

**Why this file is the one to distrust.** The Loki chart has changed its required keys more than once and several old keys are silently ignored. This values file is the right shape for a single binary, but if the pod will not start or `read`, `write` or `backend` pods appear, read the chart's `values.yaml` for the version you pinned, and record what you changed in the tracker's deviations table.

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"; source "$PLATFORM_HOME/.tmp/obs-versions.env"
helm template loki grafana/loki --version "$LOKI_CHART_VERSION" -f addons/local/loki/values.yaml \
  | yq 'select(.kind == "StatefulSet" or .kind == "Deployment") | .kind + "/" + .metadata.name' | sort
```
Expected: exactly one workload, named `loki` (a `StatefulSet` in single-binary mode). Any `loki-read`, `loki-write`, `loki-backend`, `loki-gateway` or cache entry means a toggle above did not take.

#### Task 24.1.3: Alloy

**Goal:** One pod that receives OTLP from the services and forwards it to Tempo, and that tails the platform namespaces' pod logs into Loki.

**Why Alloy for both jobs.** The usual arrangement is an OpenTelemetry Collector for traces and a separate log shipper for logs: two pods, two configurations. Alloy does both. It tails logs through the Kubernetes API (`loki.source.kubernetes`), not by reading files on the node, so it needs no host mounts and runs as a single Deployment rather than one pod per node.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"; source "$PLATFORM_HOME/.tmp/obs-versions.env"
mkdir -p addons/local/alloy
cat > addons/local/alloy/addon.yaml <<EOF
name: alloy
namespace: observability
chart:
  repo: https://grafana.github.io/helm-charts
  name: alloy
  version: "$ALLOY_CHART_VERSION"
EOF
cat > addons/local/alloy/values.yaml <<'EOF'
controller:
  # One Deployment. Log tailing goes through the API server, so it does not
  # need a pod on every node, and on a multi-node cluster a DaemonSet would
  # tail every pod once per node.
  type: deployment
  replicas: 1

alloy:
  # The OTLP ports. Nothing is reachable at them until they are listed here,
  # because the chart only opens the ports it knows about.
  extraPorts:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      protocol: TCP
    - name: otlp-http
      port: 4318
      targetPort: 4318
      protocol: TCP
  resources:
    requests:
      cpu: 50m
      memory: 150Mi
    limits:
      memory: 300Mi
  configMap:
    content: |
      // ---- Traces: receive from the services, batch, forward to Tempo. ----
      otelcol.receiver.otlp "default" {
        grpc { endpoint = "0.0.0.0:4317" }
        http { endpoint = "0.0.0.0:4318" }
        output { traces = [otelcol.processor.batch.default.input] }
      }

      otelcol.processor.batch "default" {
        output { traces = [otelcol.exporter.otlp.tempo.input] }
      }

      otelcol.exporter.otlp "tempo" {
        client {
          endpoint = "tempo.observability.svc.cluster.local:4317"
          tls { insecure = true }
        }
      }

      // ---- Logs: tail the platform namespaces' pods into Loki. ------------
      discovery.kubernetes "pods" {
        role = "pod"
      }

      discovery.relabel "platform_pods" {
        targets = discovery.kubernetes.pods.targets

        // Only the environments this project runs. Everything else in the
        // cluster (ArgoCD, Traefik, this stack) would multiply the volume for
        // logs nobody is looking for here.
        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          regex         = "platform-.*"
          action        = "keep"
        }
        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_label_app"]
          target_label  = "app"
        }
      }

      loki.source.kubernetes "platform_pods" {
        targets    = discovery.relabel.platform_pods.output
        forward_to = [loki.write.default.receiver]
      }

      loki.write "default" {
        endpoint {
          url = "http://loki.observability.svc.cluster.local:3100/loki/api/v1/push"
        }
      }
EOF
```

**Labels are the index.** Loki indexes only the labels, not the log text, which is why the four labels above are few and low-cardinality (namespace, pod, container, app). The trace id lives in the text, where it is searched with a filter. Putting it in a label would create a series per request.

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
yq '.alloy.extraPorts[].port' addons/local/alloy/values.yaml
yq '.alloy.configMap.content' addons/local/alloy/values.yaml | grep -cE '^(otelcol|discovery|loki)\.'
```
Expected: `4317` and `4318`, then `7` (the seven top-level blocks). The config language is checked by Alloy itself at startup; a syntax error shows in the pod's log in Task 24.1.4.

#### Task 24.1.4: Grafana learns about Tempo and Loki, and links them

**Goal:** Two more datasources, with the two links that make the stack more than three separate tools: a trace id in a log line becomes a link to the trace, and a span links to the logs for its pod.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
cat > "$PLATFORM_HOME/.tmp/datasources-extra.yaml" <<'EOF'
- name: Loki
  uid: loki
  type: loki
  access: proxy
  url: http://loki.observability.svc.cluster.local:3100
  jsonData:
    derivedFields:
      # Turns "trace_id=4bf9..." anywhere in a log line into a link.
      # The $$ is Grafana's escape for a literal $ in provisioning files.
      - name: trace_id
        matcherRegex: "trace_id=(\\w+)"
        url: "$${__value.raw}"
        datasourceUid: tempo
        urlDisplayLabel: Open trace
- name: Tempo
  uid: tempo
  type: tempo
  access: proxy
  url: http://tempo.observability.svc.cluster.local:3200
  jsonData:
    tracesToLogsV2:
      datasourceUid: loki
      # The span's pod name (set from OTEL_RESOURCE_ATTRIBUTES in Task 24.2.3)
      # becomes Loki's pod label, and the trace id filters the lines.
      tags:
        - key: k8s.pod.name
          value: pod
      filterByTraceID: true
      spanStartTimeShift: "-2m"
      spanEndTimeShift: "2m"
EOF
yq -i '.datasources."datasources.yaml".datasources += load("'"$PLATFORM_HOME"'/.tmp/datasources-extra.yaml")' addons/local/grafana/values.yaml
yq '.datasources."datasources.yaml".datasources[].name' addons/local/grafana/values.yaml
```
Expected: `Prometheus`, `Loki`, `Tempo`.

**Validate the whole phase, then merge it:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git add addons/local
git commit -m "feat(observability): Tempo, Loki and Alloy, with Grafana correlation"
merge_to_main feat/traces-and-logs
kubectl --context "$LOCAL_CTX" -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
sleep 180
kubectl --context "$LOCAL_CTX" -n observability get pods
```
Expected: `prometheus-server`, `grafana`, `tempo`, `loki` and `alloy` pods, each `Running` and ready (Loki can take another minute). Then ask each one if it is ready:
```bash
for spec in tempo:3200/ready loki:3100/ready alloy:12345/-/ready; do
  svc="${spec%%/*}"; path="/${spec#*/}"
  printf '%-10s ' "${svc%%:*}"
  kubectl --context "$LOCAL_CTX" get --raw "/api/v1/namespaces/observability/services/${svc}/proxy${path}"
  echo
done
```
Expected: `ready` from Tempo and Loki, and Alloy's readiness text. If a pod is in `CrashLoopBackOff`, read its log first (`kubectl --context "$LOCAL_CTX" -n observability logs <pod>`): Alloy prints a precise line and column for a config error, and Loki names the key it rejected.

### Phase 24.2: OpenTelemetry in the services

The code is a small module that turns tracing on **only when a collector is configured**. With `OTEL_EXPORTER_OTLP_ENDPOINT` unset it does nothing, so the tests, a bare `docker run` and any cluster without the stack behave exactly as before.

#### Task 24.2.1: service-2 traces and logs with trace ids

**Goal:** service-2 continues the trace it receives, and its log lines carry the trace id.

```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
git switch main && git pull --ff-only
git switch -c feat/tracing
source .venv/bin/activate 2>/dev/null || true
cat >> requirements.txt <<'EOF'
opentelemetry-sdk==1.45.0
opentelemetry-exporter-otlp-proto-http==1.45.0
opentelemetry-instrumentation-fastapi==0.66b0
opentelemetry-instrumentation-httpx==0.66b0
opentelemetry-instrumentation-logging==0.66b0
EOF
pip install -r requirements-dev.txt
```
The OpenTelemetry instrumentation packages are beta (`0.x b0`) and change their options between releases, so they are pinned **exactly**, as a set that was installed together and tested. Do not loosen a pin without running the tests and the proof script below.

Service-2 has no database, so it leaves out the asyncpg instrumentation. The module is the same file in both services:
```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
cat > src/telemetry.py <<'TELEMETRY_EOF'
import logging
import os

from fastapi import FastAPI

# trace_id and span_id are filled in by the logging instrumentation. A log line
# written inside a request carries the id of that request's trace, which is the
# join key between logs and traces in Grafana.
LOG_FORMAT = (
    "%(asctime)s %(levelname)s [%(name)s] "
    "trace_id=%(otelTraceID)s span_id=%(otelSpanID)s %(message)s"
)


def setup(app: FastAPI, database: bool = False) -> bool:
    """Turn on tracing when a collector is configured. Returns whether it did.

    With OTEL_EXPORTER_OTLP_ENDPOINT unset this does nothing at all, which is
    what keeps the test suite and a bare `docker run` free of any collector.
    The imports sit inside the function for the same reason.
    """
    if not os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT"):
        return False

    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
    from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
    from opentelemetry.instrumentation.logging import LoggingInstrumentor
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    # Resource.create() and OTLPSpanExporter() both read the standard OTEL_*
    # environment variables (service name, endpoint, resource attributes), and
    # TracerProvider() reads OTEL_TRACES_SAMPLER. The manifest sets them.
    provider = TracerProvider(resource=Resource.create())
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)

    # Probes and scrapes would otherwise produce a trace every few seconds.
    FastAPIInstrumentor.instrument_app(app, excluded_urls="healthz,readyz,metrics")
    HTTPXClientInstrumentor().instrument()
    if database:
        from opentelemetry.instrumentation.asyncpg import AsyncPGInstrumentor

        AsyncPGInstrumentor().instrument()

    # inject_trace_context adds otelTraceID and otelSpanID to every record.
    # enable_log_auto_instrumentation=False stops the package from also
    # shipping logs over OTLP: logs leave through stdout and the log shipper,
    # so a second path would duplicate every line.
    LoggingInstrumentor().instrument(
        inject_trace_context=True, enable_log_auto_instrumentation=False
    )
    # service-1 configures logging at import; service-2 never did, and without a
    # handler on the root logger there is nothing to give the trace format to.
    logging.basicConfig(level=logging.INFO)
    for handler in logging.getLogger().handlers:
        handler.setFormatter(logging.Formatter(LOG_FORMAT))
    return True
TELEMETRY_EOF
git apply <<'PATCH_EOF'
diff --git a/src/main.py b/src/main.py
index d0d4ee3..0fc8a4a 100644
--- a/src/main.py
+++ b/src/main.py
@@ -1,12 +1,17 @@
+import logging
+
 from fastapi import FastAPI
 from pydantic import BaseModel
 
-from src import metrics
+from src import metrics, telemetry
+
+logger = logging.getLogger("service-2")
 
 # No lifespan handler, unlike service-1. This service opens no connections to
 # anything, so there is nothing to set up or tear down.
 app = FastAPI(title="service-2-worker", version="1.2.0")
 metrics.install(app)
+telemetry.setup(app)
 
 
 # ---------------------------------------------------------------------------
@@ -47,10 +52,12 @@ def healthz() -> dict[str, str]:
 # in a threadpool and nothing blocks the event loop either way.
 @app.post("/process", response_model=ProcessResponse)
 def process(request: ProcessRequest) -> ProcessResponse:
+    result = transform(request.value)
+    logger.info("processed value=%s result=%s", request.value, result)
     return ProcessResponse(
         # Echoing the service name is what lets service-1's response prove the
         # internal DNS hop actually happened rather than being faked locally.
         service="service-2",
         input=request.value,
-        result=transform(request.value),
+        result=result,
     )
PATCH_EOF
cat > tests/test_telemetry.py <<'TEST_EOF'
from fastapi import FastAPI

from src import telemetry


def test_setup_is_a_noop_without_a_collector(monkeypatch):
    monkeypatch.delenv("OTEL_EXPORTER_OTLP_ENDPOINT", raising=False)
    assert telemetry.setup(FastAPI()) is False
TEST_EOF
```

**What to notice.**
- `Resource.create()`, `OTLPSpanExporter()` and `TracerProvider()` read the standard `OTEL_*` variables themselves (service name, endpoint, resource attributes, sampler), so the module hardcodes none of them. The manifest in Task 24.2.3 supplies them.
- `excluded_urls="healthz,readyz,metrics"` stops probes and scrapes from creating a trace every few seconds.
- `inject_trace_context=True, enable_log_auto_instrumentation=False`: the first puts `otelTraceID` into every log record. The second is needed because, by default in this package version, the logging instrumentation also installs a handler that ships logs over OTLP. Logs here leave through stdout and Alloy, and a second path would duplicate every line.
- The formatter is set on the root handlers after instrumenting, and `logging.basicConfig` runs first, because service-2 never configured logging at all. Without a handler there is nothing to format, and INFO lines would be dropped.

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
ruff check src tests
pytest -q
```
Expected: `All checks passed!` and all tests passing. Now the proof that matters: that one trace id really crosses a service boundary. Save the script and run it:
```bash
cat > "$PLATFORM_HOME/.tmp/propagation_proof.py" <<'PROOF_EOF'
"""Proves one trace id crosses two in-process services. Needs no cluster.

Run from a service repo's root, so that `src.telemetry` imports:
    PYTHONPATH=. python "$PLATFORM_HOME/.tmp/propagation_proof.py"
"""
import asyncio
import logging
import os
import sys

# Point at a collector that is not there: this script only reads spans back
# from memory, so the export failures at exit are expected and silenced below.
os.environ.setdefault("OTEL_EXPORTER_OTLP_ENDPOINT", "http://127.0.0.1:4318")
os.environ.setdefault("OTEL_SERVICE_NAME", "proof")

import httpx  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from opentelemetry import trace  # noqa: E402
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor  # noqa: E402
from opentelemetry.sdk.trace.export import SimpleSpanProcessor  # noqa: E402
from opentelemetry.sdk.trace.export.in_memory_span_exporter import (  # noqa: E402
    InMemorySpanExporter,
)

from src import telemetry  # noqa: E402

gateway, worker = FastAPI(), FastAPI()


@worker.get("/process")
def process():
    logging.getLogger("worker").info("inside the worker")
    return {"ok": True}


client = httpx.AsyncClient(transport=httpx.ASGITransport(app=worker), base_url="http://worker")


@gateway.get("/compute")
async def compute():
    logging.getLogger("gateway").info("inside the gateway")
    return (await client.get("/process")).json()


assert telemetry.setup(gateway), "telemetry.setup returned False: is the endpoint set?"
FastAPIInstrumentor.instrument_app(worker)
memory = InMemorySpanExporter()
trace.get_tracer_provider().add_span_processor(SimpleSpanProcessor(memory))


async def main():
    transport = httpx.ASGITransport(app=gateway)
    async with httpx.AsyncClient(transport=transport, base_url="http://gateway") as c:
        await c.get("/compute")


asyncio.run(main())
ids = {format(s.context.trace_id, "032x") for s in memory.get_finished_spans()}
logging.getLogger("opentelemetry.exporter").setLevel(logging.CRITICAL)
print(f"{len(memory.get_finished_spans())} spans, {len(ids)} distinct trace id(s)")
sys.exit(0 if len(ids) == 1 else 1)
PROOF_EOF
cd "$PLATFORM_HOME/lfi-service-2-app"
PYTHONPATH=. python "$PLATFORM_HOME/.tmp/propagation_proof.py" 2>&1 | grep -vE 'WARNING|Transient'
```
Expected: log lines from `gateway` and `worker` carrying the **same** `trace_id=...`, and a last line `6 spans, 1 distinct trace id(s)`. The `httpx` line that follows the gateway's own request shows `trace_id=0`: that is the test client calling the gateway from outside any span, not a fault.

```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
git add requirements.txt src tests
git commit -m "feat: continue traces and stamp logs with the trace id"
```

#### Task 24.2.2: service-1 traces its outbound call and its queries

**Goal:** service-1 starts the trace, passes it to service-2 in a `traceparent` header, and records its Postgres queries as spans.

```bash
cd "$PLATFORM_HOME/lfi-service-1-app"
git switch main && git pull --ff-only
git switch -c feat/tracing
source .venv/bin/activate 2>/dev/null || true
cat >> requirements.txt <<'EOF'
opentelemetry-sdk==1.45.0
opentelemetry-exporter-otlp-proto-http==1.45.0
opentelemetry-instrumentation-fastapi==0.66b0
opentelemetry-instrumentation-httpx==0.66b0
opentelemetry-instrumentation-asyncpg==0.66b0
opentelemetry-instrumentation-logging==0.66b0
EOF
pip install -r requirements-dev.txt
cp "$PLATFORM_HOME/lfi-service-2-app/src/telemetry.py" src/telemetry.py
git apply <<'PATCH_EOF'
diff --git a/src/main.py b/src/main.py
index 05ba6fe..12ab40e 100644
--- a/src/main.py
+++ b/src/main.py
@@ -7,7 +7,7 @@ import httpx
 from fastapi import Depends, FastAPI, HTTPException, Request
 from pydantic import BaseModel
 
-from src import metrics
+from src import metrics, telemetry
 from src.config import database_url, service_2_url
 
 # Log to stdout at INFO. In Kubernetes stdout IS the log: kubectl logs reads
@@ -86,6 +86,9 @@ async def lifespan(app: FastAPI):
 
 app = FastAPI(title="service-1-gateway", version="1.3.0", lifespan=lifespan)
 metrics.install(app)
+# A no-op unless OTEL_EXPORTER_OTLP_ENDPOINT is set, so tests and bare runs
+# need no collector. database=True also traces asyncpg queries.
+telemetry.setup(app, database=True)
 
 
 # These two exist as dependencies rather than direct app.state reads so
PATCH_EOF
cp "$PLATFORM_HOME/lfi-service-2-app/tests/test_telemetry.py" tests/test_telemetry.py
```
The patch calls `telemetry.setup(app, database=True)`, which also instruments asyncpg. The httpx instrumentation is what injects the `traceparent` header on the call to service-2, and service-2's FastAPI instrumentation is what reads it.

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-service-1-app"
ruff check src tests
pytest -q
PYTHONPATH=. python "$PLATFORM_HOME/.tmp/propagation_proof.py" 2>&1 | tail -1
git add requirements.txt src tests
git commit -m "feat: start traces, propagate them to service-2, trace Postgres queries"
```
Expected: `All checks passed!`, all tests passing, and `6 spans, 1 distinct trace id(s)`.

#### Task 24.2.3: Point the pods at Alloy

**Goal:** The environment variables that switch tracing on and tell it where to send and who the service is.

**Why in the manifest and not the code.** Which collector to talk to is a property of the cluster, not of the service. The code reads standard variables, and the manifest says what they are here.

The variables go in each service's config repo, in `base/app/rollout.yaml`, on a branch of their own:
```bash
for pair in "service-1:$CFG1" "service-2:$CFG2"; do
  s="${pair%%:*}"; cfg="${pair#*:}"
  cd "$cfg"
  git switch main && git pull --ff-only
  git switch -c feat/tracing-env
  SVC="$s" yq -i '
    .spec.template.spec.containers[0].env += [
      {"name": "POD_NAME", "valueFrom": {"fieldRef": {"fieldPath": "metadata.name"}}},
      {"name": "POD_NAMESPACE", "valueFrom": {"fieldRef": {"fieldPath": "metadata.namespace"}}},
      {"name": "OTEL_SERVICE_NAME", "value": strenv(SVC)},
      {"name": "OTEL_RESOURCE_ATTRIBUTES", "value": "k8s.pod.name=$(POD_NAME),k8s.namespace.name=$(POD_NAMESPACE)"},
      {"name": "OTEL_EXPORTER_OTLP_ENDPOINT", "value": "http://alloy.observability.svc.cluster.local:4318"},
      {"name": "OTEL_EXPORTER_OTLP_PROTOCOL", "value": "http/protobuf"},
      {"name": "OTEL_TRACES_SAMPLER", "value": "parentbased_traceidratio"},
      {"name": "OTEL_TRACES_SAMPLER_ARG", "value": "1.0"}
    ]' base/app/rollout.yaml
done
```
`parentbased_traceidratio` with `1.0` records every trace and, more importantly, follows the parent's sampling decision: a trace service-1 chose to record is recorded by service-2 as well, so a trace is never half-kept. Lowering the volume is done in Alloy, in one place (Task 24.4.2), not here.

`$(POD_NAME)` expands inside `OTEL_RESOURCE_ATTRIBUTES` because Kubernetes substitutes variables defined **earlier in the same env list**, which is why the two downward-API variables are added first. The Tempo-to-Loki link in Task 24.1.4 relies on the resulting `k8s.pod.name` attribute.

**A cluster without the stack.** These variables live in the service base, so they apply everywhere. On a cluster where Alloy is not installed the services log a failed-export warning every few seconds and otherwise carry on; tracing is best-effort by design and never fails a request. A team that does not want the warnings there can patch the variables out of that cluster's environments.

**Validate:**
```bash
for pair in "service-1:$CFG1" "service-2:$CFG2"; do
  s="${pair%%:*}"; cfg="${pair#*:}"
  kustomize build "$cfg/local/dev/app" \
    | yq 'select(.kind == "Rollout") | .spec.template.spec.containers[0].env[] | select(.name == "OTEL_SERVICE_NAME" or .name == "OTEL_RESOURCE_ATTRIBUTES") | .name + "=" + .value'
  git -C "$cfg" add base/app
  git -C "$cfg" commit -m "feat(observability): point the service at Alloy"
done
```
Expected: for each service, `OTEL_SERVICE_NAME=<service>` and the resource attributes line with the two `$(...)` references intact (Kubernetes expands them, not Kustomize).

#### Task 24.2.4: Ship it

**Goal:** The traced builds running in dev.

Same order as Task 23.1.4: service-2 first, then service-1, then the manifests.
```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
git push -u origin feat/tracing
gh pr create --fill --base main && gh pr merge --merge --delete-branch
```
When its CI has promoted to dev:
```bash
cd "$PLATFORM_HOME/lfi-service-1-app"
git push -u origin feat/tracing
gh pr create --fill --base main && gh pr merge --merge --delete-branch
```
Then merge the two config repos:
```bash
merge_config "$CFG2" feat/tracing-env
merge_config "$CFG1" feat/tracing-env
kubectl --context "$LOCAL_CTX" -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
```
These variables change the pod template in the shared base, so **prod starts a canary on both services as well**, on the image prod already runs. They pause at 50 percent like any release. Check with `gmake status CLUSTER=local ENVIRONMENT=prod` and promote service-2 first, then service-1, as in Task 23.2.3.

**Validate:**
```bash
kubectl --context "$LOCAL_CTX" -n platform-dev get pods
kubectl --context "$LOCAL_CTX" -n platform-dev logs -l app=service-2 --tail=3
```
Expected: the dev pods `Running` on their new builds, and no export errors in the log (an error naming `alloy` means the Alloy Service or its port 4318 is not reachable; recheck Task 24.1.3). A Rollout has no Deployment to address, so logs are read by label.

### Phase 24.3: Follow one request

#### Task 24.3.1: One trace, three spans and a query

**Goal:** A single trace in Tempo that includes service-1 and service-2.

Send traffic for a minute, so there is something to find:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
DURATION=60 gmake traffic CLUSTER=local ENVIRONMENT=dev
```
Ask Tempo for a recent trace from service-1, then for the services inside it:
```bash
TEMPO="/api/v1/namespaces/observability/services/tempo:3200/proxy"
TRACE="$(kubectl --context "$LOCAL_CTX" get --raw "$TEMPO/api/search?tags=service.name%3Dservice-1&limit=1" | jq -r '.traces[0].traceID')"
echo "trace: $TRACE"
kubectl --context "$LOCAL_CTX" get --raw "$TEMPO/api/traces/$TRACE" \
  | jq -r '[.batches[] | .resource.attributes[] | select(.key == "service.name") | .value.stringValue] | unique | join(" ")'
```
Expected: a 32-character trace id, then `service-1 service-2`. **If the second command prints an error,** the API shape differs in your Tempo version (newer ones return `resourceSpans` under a `trace` key from a `/api/v2/traces/...` path). The thing to confirm is unchanged: one trace containing both services.

In Grafana, Explore, choose Tempo, Search, Service Name `service-1`, Run. Open a result. The waterfall should show, nested: `POST /compute` (service-1), an HTTP client span for the call to service-2, `POST /process` (service-2), and an asyncpg span for the insert.

**Validate:** the waterfall contains spans from both services and a database span, and the client span's duration is slightly longer than service-2's server span (the difference is the network hop).

#### Task 24.3.2: The log lines of that trace

**Goal:** The log lines written while handling one request, found by trace id, from both services.

```bash
LOKI="/api/v1/namespaces/observability/services/loki:3100/proxy"
Q='{namespace="platform-dev"} |= "trace_id='"$TRACE"'"'
kubectl --context "$LOCAL_CTX" get --raw "$LOKI/loki/api/v1/query_range?limit=20&query=$(jq -rn --arg q "$Q" '$q|@uri')" \
  | jq -r '.data.result[] | .stream.app + "  " + .values[0][1]'
```
Expected: at least two lines sharing that trace id, one with `app` `service-1` (the httpx client line) and one with `app` `service-2` (`processed value=... result=...`). Run it within a few minutes of the traffic, since the default query window is an hour but the trace was found above moments ago.

If nothing comes back, the usual cause is on the Alloy side, not Loki. Check:
```bash
kubectl --context "$LOCAL_CTX" -n observability logs deploy/alloy --tail=30 | grep -iE 'error|forbidden|denied'
```
A `forbidden` on `pods/log` means Alloy's service account lacks permission to read logs, and the chart's RBAC needs the rule added.

#### Task 24.3.3: Jump between them

**Goal:** Click from a log line to its trace, and from a span to its logs. This is the point of the whole section.

In Grafana, Explore, choose Loki, and run `{namespace="platform-dev", app="service-2"} |= "processed"`. Each line has an **Open trace** link beside the detected `trace_id`. Click it: the Tempo waterfall opens on that trace. In the waterfall, select the service-2 span and use **Logs for this span**: Explore opens Loki filtered to that pod and that trace id.

**Validate** (the provisioning the clicks depend on):
```bash
PASS="$(kubectl --context "$LOCAL_CTX" -n observability get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d)"
# with `gmake grafana CLUSTER=local` running in another terminal
curl -s -u "admin:$PASS" http://localhost:3000/api/datasources/uid/loki  | jq -r '.jsonData.derivedFields[0].datasourceUid'
curl -s -u "admin:$PASS" http://localhost:3000/api/datasources/uid/tempo | jq -r '.jsonData.tracesToLogsV2.datasourceUid'
```
Expected: `tempo`, then `loki`. The clicks working end to end is the real check.

**You now have the full drill down.** Panel 5 of the RED dashboard shows an error ratio rising, Explore finds a failing trace, and the trace's logs say why. Task 25.1.2 uses exactly that path.

### Phase 24.4: Confirm on EKS, and the knobs

#### Task 24.4.1: The same stack on EKS

**Goal:** Tempo, Loki and Alloy on EKS, and one trace across both services there.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch main && git pull --ff-only
git switch -c feat/traces-and-logs-eks
cp -R addons/local/tempo addons/local/loki addons/local/alloy addons/eks/
cp addons/local/grafana/values.yaml addons/eks/grafana/values.yaml
git add addons/eks
git commit -m "feat(observability): Tempo, Loki and Alloy on EKS"
gmake up CLUSTER=eks
merge_to_main feat/traces-and-logs-eks
kubectl --context "$EKS_CTX" -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
sleep 300
```

**Validate:**
```bash
kubectl --context "$EKS_CTX" -n observability get pods
DURATION=90 gmake traffic CLUSTER=eks ENVIRONMENT=dev
TEMPO="/api/v1/namespaces/observability/services/tempo:3200/proxy"
TRACE="$(kubectl --context "$EKS_CTX" get --raw "$TEMPO/api/search?tags=service.name%3Dservice-1&limit=1" | jq -r '.traces[0].traceID')"
kubectl --context "$EKS_CTX" get --raw "$TEMPO/api/traces/$TRACE" \
  | jq -r '[.batches[] | .resource.attributes[] | select(.key == "service.name") | .value.stringValue] | unique | join(" ")'
```
Expected: five observability pods `Running` (prometheus-server, grafana, tempo, loki, alloy), then `service-1 service-2`.

Measure now, while all five are running. These are the figures Task 25.2.1 compares to the estimates:
```bash
kubectl --context "$EKS_CTX" top pods -n observability
kubectl --context "$EKS_CTX" top nodes
kubectl --context "$EKS_CTX" get pods -A --no-headers | wc -l
```

#### Task 24.4.2: Sampling and retention

**Goal:** Know where the volume knobs are, before load testing makes them matter.

At demo traffic, recording every trace is free. Under a load test it is not: a few hundred requests a second is a few hundred traces a second into a 2 GiB volume holding 24 hours. There are three knobs, in order of how often you will want them:

| To reduce | Change | Where |
|---|---|---|
| Trace volume, keeping whole traces | Keep a percentage of traces | Alloy: add a probabilistic sampler (below) |
| How long traces are kept | `tempo.retention` | `addons/<cluster>/tempo/values.yaml` |
| How long logs are kept | `loki.limits_config.retention_period` | `addons/<cluster>/loki/values.yaml` |
| Metrics history | `server.retention` and `retentionSize` | `addons/<cluster>/prometheus/values.yaml` |

Sampling in Alloy, not in the services, means one change in one place with no application release. Put a sampler between the receiver and the batch processor. It keeps or drops by trace id, so all spans of a trace share one fate:
```
otelcol.receiver.otlp "default" {
  grpc { endpoint = "0.0.0.0:4317" }
  http { endpoint = "0.0.0.0:4318" }
  output { traces = [otelcol.processor.probabilistic_sampler.default.input] }
}

otelcol.processor.probabilistic_sampler "default" {
  sampling_percentage = 10
  output { traces = [otelcol.processor.batch.default.input] }
}
```
That replaces the receiver block in `alloy.configMap.content`, and adds the sampler block. **Leave it out until you load-test:** at ten percent a single request you want to inspect has a nine in ten chance of having no trace, which is confusing at a demo.

Metrics are not sampled: counters are cheap at any traffic. Only traces and logs need this discipline.

**Validate:** this task changes nothing until you choose to. Confirm you know where each of the four lines in the table lives:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
yq '.tempo.retention' addons/eks/tempo/values.yaml
yq '.loki.limits_config.retention_period' addons/eks/loki/values.yaml
yq '.server.retention + " / " + .server.retentionSize' addons/eks/prometheus/values.yaml
```
Expected: `24h`, `72h`, `3d / 1500MB`.

Leave EKS up for Section 25's phases that need it, or destroy and rebuild later:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake destroy CLUSTER=eks
```


---

## Section 25: Analysis, budget and operation

**Objective:** A canary that aborts itself when its error rate is worse than stable's, an honest account of what that does and does not catch, measured memory and pod numbers for both clusters, and the commands and checklists to run it all.

### Phase 25.1: Automated analysis

Section 12 ended with a human pausing the rollout at 50 percent and judging by eye. This phase gives that judgment a second opinion that never looks away. The pause stays, because the analysis only catches what it was told to look for.

#### Task 25.1.1: An AnalysisTemplate per service, wired into prod only

**Goal:** Every prod rollout runs a background analysis from the pause step onwards, comparing the canary's error ratio with stable's. Dev is untouched.

**Design, briefly.**
- **Background analysis starting at step 1.** The canary steps are `setWeight: 50`, `pause: {}`, `setWeight: 100`. Step 0 is the weight change, step 1 is the pause. Starting the analysis at step 1 means it runs during the pause, which is exactly when a human is also looking. If it fails it aborts the rollout; if it succeeds the rollout still waits for you.
- **One template per service, named after the service.** It compares that service's `-canary` and `-stable` Services. The query names them directly, so the template needs only one argument, the namespace. The template is the service's own manifest, so it lives in the service's config repo.
- **A component wires it in generically.** The analysis block is added by a new `canary-analysis` component in the templates repo, which knows nothing about individual services. A Kustomize `replacement` copies each Rollout's own name into `templateName`, and the namespace argument is read from the Rollout itself (`valueFrom.fieldRef` on `metadata.namespace`), so the same component works for service-1, service-2 and any service added later, as long as its base has an AnalysisTemplate named like its Rollout.
- **Dev is unaffected.** Only environments that name the component get the block, and only the prod environments will.

**Step 1: the component, released as a tag.** This is the platform's piece, in the templates repo:
```bash
cd "$TPL"
git switch main && git pull --ff-only
git switch -c feat/canary-analysis
mkdir -p components/canary-analysis
cat > components/canary-analysis/kustomization.yaml <<'COMPONENT_EOF'
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
patches:
  # Adds a background analysis from the pause step onwards. The template name
  # and the namespace are filled in below and by Argo Rollouts, so this works for
  # any Rollout in any namespace.
  - target:
      group: argoproj.io
      version: v1alpha1
      kind: Rollout
    patch: |-
      - op: add
        path: /spec/strategy/canary/analysis
        value:
          startingStep: 1
          templates:
            - templateName: placeholder
          args:
            # Argo Rollouts reads the Rollout's own namespace, so one component
            # serves every environment. Kustomize cannot do this here: a
            # component's replacements run before the environment sets its
            # namespace, so the field would not exist yet.
            - name: namespace
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
replacements:
  # The analysis template is named after the Rollout.
  - source:
      kind: Rollout
      fieldPath: metadata.name
    targets:
      - select:
          kind: Rollout
        fieldPaths:
          - spec.strategy.canary.analysis.templates.0.templateName
COMPONENT_EOF
git add components/canary-analysis
git commit -m "add the canary-analysis component"
merge_config "$TPL" feat/canary-analysis
git switch main
git tag -a v1.1.0 -m "Adds the canary-analysis component"
git push origin v1.1.0
```
Releasing a tag changes nothing for anyone: no environment references `v1.1.0` yet. A component change reaches an environment only when its team moves the `?ref=`, which is the next step.

**Step 2: the template, in each service's config repo.** Create it for both services from one source:
```bash
cat > "$PLATFORM_HOME/.tmp/analysis.yaml.in" <<'ANALYSIS_EOF'
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  # Named after the service, so the canary-analysis component can derive the
  # template a Rollout uses from the Rollout's own name (see Task 25.1.1).
  name: SERVICE_NAME
spec:
  args:
    # Which environment's series to compare. The Rollout supplies it.
    - name: namespace
  metrics:
    # 1. Is the canary failing more than stable?
    - name: error-rate-delta
      # Rates over two minutes need data from the new pods, which starts at
      # zero when the canary appears. Do not judge before there is some.
      initialDelay: 90s
      interval: 30s
      # Ten checks, thirty seconds apart: five minutes of judging.
      count: 10
      # One bad reading is tolerated (a single slow scrape), two abort.
      failureLimit: 1
      # The canary's error ratio may exceed stable's by at most two points.
      successCondition: result[0] <= 0.02
      provider:
        prometheus:
          address: http://prometheus-server.observability.svc.cluster.local
          query: |
            (
              sum(rate(http_requests_total{namespace="{{args.namespace}}",service="SERVICE_NAME-canary",status=~"5.."}[2m]))
              / clamp_min(sum(rate(http_requests_total{namespace="{{args.namespace}}",service="SERVICE_NAME-canary"}[2m])), 0.001)
            )
            -
            (
              sum(rate(http_requests_total{namespace="{{args.namespace}}",service="SERVICE_NAME-stable",status=~"5.."}[2m]))
              / clamp_min(sum(rate(http_requests_total{namespace="{{args.namespace}}",service="SERVICE_NAME-stable"}[2m])), 0.001)
            )
    # 2. Did the canary get any traffic at all? Metric 1 reads "no traffic" as
    # "no errors", because the clamp turns 0/0 into 0. A canary nobody called
    # must not pass as healthy, so this one insists on a request rate.
    #
    # It can only succeed or be inconclusive, never fail: failureCondition is
    # a value a rate cannot take. Inconclusive leaves the rollout paused,
    # which is where it already is, waiting for you.
    - name: canary-receives-traffic
      initialDelay: 90s
      interval: 30s
      count: 10
      inconclusiveLimit: 10
      successCondition: result[0] >= 0.05
      failureCondition: result[0] < 0
      provider:
        prometheus:
          address: http://prometheus-server.observability.svc.cluster.local
          query: |
            sum(rate(http_requests_total{namespace="{{args.namespace}}",service="SERVICE_NAME-canary"}[2m]))
ANALYSIS_EOF
for pair in "service-1:$CFG1" "service-2:$CFG2"; do
  s="${pair%%:*}"; cfg="${pair#*:}"
  cd "$cfg"
  git switch main && git pull --ff-only
  git switch -c feat/analysis
  sed "s/SERVICE_NAME/$s/g" "$PLATFORM_HOME/.tmp/analysis.yaml.in" > base/app/analysis.yaml
  yq -i '.resources += ["analysis.yaml"]' base/app/kustomization.yaml
done
```

**What to notice in the template.**
- `clamp_min(..., 0.001)` on the denominator avoids a divide by zero, at the price of reading "no traffic" as "no errors". That is why the second metric exists.
- The two metrics answer different questions. Metric 1 can fail the rollout. Metric 2 can only succeed or be inconclusive, and an inconclusive result leaves the rollout paused, which is the safe direction.
- `initialDelay: 90s` matters. The canary pods are new, so a two-minute rate over them has almost nothing in it for the first minute, and judging early would compare noise.
- The Prometheus address is the Service the `prometheus` add-on creates. Task 22.1.1 confirmed its name (`prometheus-server`) and port (80) from the chart.

**Step 3: prod environments opt in.** Each service's prod environment, on each cluster, names the new component at the new tag, beside the `canary-manual-gate` it already uses. It copies that component's URL, so the owner and repository are never typed twice:
```bash
for cfg in "$CFG1" "$CFG2"; do
  cd "$cfg"
  for c in local eks; do
    f="$c/prod/app/kustomization.yaml"
    url="$(yq '.components[] | select(test("canary-manual-gate"))' "$f")"
    NEW="$(echo "$url" | sed 's#canary-manual-gate?ref=[^ ]*#canary-analysis?ref=v1.1.0#')" \
      yq -i '.components += [strenv(NEW)]' "$f"
  done
  git add base/app local/prod eks/prod
  git commit -m "feat(observability): error-rate analysis on prod canaries"
done
```
Each reference carries its own tag, so `canary-manual-gate` stays on `v1.0.0` while `canary-analysis` is on `v1.1.0`. Move them together when it suits the team.

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
for pair in "service-1:$CFG1" "service-2:$CFG2"; do
  s="${pair%%:*}"; cfg="${pair#*:}"
  for c in local eks; do for e in dev prod; do
    printf '%s %s %s: ' "$c" "$e" "$s"
    kustomize build "$cfg/$c/$e/app" \
      | yq 'select(.kind == "Rollout") | (.spec.strategy.canary.analysis.templates[0].templateName // "none")'
  done; done
done
kustomize build "$CFG2/local/prod/app" | yq 'select(.kind == "Rollout") | .spec.strategy.canary.analysis'
kustomize build "$CFG2/local/prod/app" | yq 'select(.kind == "AnalysisTemplate") | .metadata.namespace + " " + .metadata.name'
```
Expected: `none` for every dev build, and for prod the Rollout's own name (`service-1` or `service-2`) as `templateName`, derived by the replacement. The analysis block prints with `startingStep: 1` and the namespace argument as a `fieldRef`, and the AnalysisTemplate lands in `platform-prod`, named `service-2`. A `templateName: placeholder` in the output means the replacement did not run; it needs Kustomize 5 or later (`kustomize version`).

The ordering trap: the replacement runs on the Rollout **after** the patch has added the field. If a future Kustomize applies them the other way round, the build fails with a path-not-found error on `templates.0.templateName`, not a silent wrong value.

The `fieldRef` is the one thing here that only the cluster can check: whether your Argo Rollouts version fills the namespace argument from the Rollout. Task 25.1.2's first AnalysisRun shows it, and Appendix K has a tested fallback if it does not.

**Not merged yet.** The templates repo change is merged and tagged above because nothing references the tag. The config repo commits touch prod environments, and prod changes only through a release PR in the team's repo, so they are merged together with the first release that uses them, in Task 25.1.2, rather than on their own.

#### Task 25.1.2: A way to make service-2 misbehave on purpose

**Goal:** Two environment switches on service-2, both off by default: one makes a share of `/process` calls answer 503, the other makes a share answer 200 with a **wrong** number.

**Why.** An analysis you have only watched succeed is untested. You need a build that fails on request, and a second one that fails in the way error-rate analysis cannot see. They default to zero, so a normal deployment never misbehaves, and they are read on every request so a test can change them without a restart.

```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
git switch main && git pull --ff-only
git switch -c feat/fault-injection
source .venv/bin/activate 2>/dev/null || true
git apply <<'PATCH_EOF'
diff --git a/src/main.py b/src/main.py
index 0fc8a4a..f1a95fc 100644
--- a/src/main.py
+++ b/src/main.py
@@ -1,6 +1,8 @@
 import logging
+import os
+import random
 
-from fastapi import FastAPI
+from fastapi import FastAPI, HTTPException
 from pydantic import BaseModel
 
 from src import metrics, telemetry
@@ -13,6 +15,14 @@ app = FastAPI(title="service-2-worker", version="1.2.0")
 metrics.install(app)
 telemetry.setup(app)
 
+# Fault injection, for rehearsing canary analysis. Both default to 0, so a
+# normal deployment never misbehaves. They are read on every request, so a test
+# can change them without restarting the app.
+#   FAULT_ERROR_PERCENT  share of /process calls that answer 503
+#   FAULT_WRONG_PERCENT  share that answer 200 with a wrong result
+def fault_percent(name: str) -> float:
+    return float(os.environ.get(name, "0"))
+
 
 # ---------------------------------------------------------------------------
 # Request and response schemas. Declaring these buys three things at once:
@@ -52,7 +62,11 @@ def healthz() -> dict[str, str]:
 # in a threadpool and nothing blocks the event loop either way.
 @app.post("/process", response_model=ProcessResponse)
 def process(request: ProcessRequest) -> ProcessResponse:
+    if random.uniform(0, 100) < fault_percent("FAULT_ERROR_PERCENT"):
+        raise HTTPException(status_code=503, detail="injected fault")
     result = transform(request.value)
+    if random.uniform(0, 100) < fault_percent("FAULT_WRONG_PERCENT"):
+        result += 1
     logger.info("processed value=%s result=%s", request.value, result)
     return ProcessResponse(
         # Echoing the service name is what lets service-1's response prove the
PATCH_EOF
cat >> tests/test_main.py <<'TEST_EOF'


# ---------------------------------------------------------------------------
# Fault injection.
# ---------------------------------------------------------------------------
async def test_injected_errors_answer_503(client, monkeypatch):
    monkeypatch.setenv("FAULT_ERROR_PERCENT", "100")
    response = await client.post("/process", json={"value": 21})
    assert response.status_code == 503


async def test_injected_wrong_answers_still_answer_200(client, monkeypatch):
    monkeypatch.setenv("FAULT_WRONG_PERCENT", "100")
    response = await client.post("/process", json={"value": 21})
    assert response.status_code == 200
    assert response.json()["result"] == 43
TEST_EOF
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
ruff check src tests
pytest -q
```
Expected: `All checks passed!` and all tests passing. The second new test is the important one to read: a wrong answer is a **200**. Nothing about the request looks unusual to an HTTP-level metric.

Ship it to dev, then to prod (it changes nothing there, since both switches are off):
```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
git add src tests
git commit -m "feat: fault injection switches for rehearsing canary analysis"
git push -u origin feat/fault-injection
gh pr create --fill --base main && gh pr merge --merge --delete-branch
```
When CI has promoted it to dev, merge the analysis into both config repos and release to prod. The release PR carries the new service-2 build, and it is opened in the same repository the analysis was just merged into, so review it with the analysis change in view:
```bash
merge_config "$CFG2" feat/analysis
merge_config "$CFG1" feat/analysis
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake release CLUSTER=local SVC=service-2
```
`merge_config` of a branch that touches prod paths may be refused by that repo's branch protection or CODEOWNERS rules; if so, open it as a pull request and merge that, the way the release process in guide 2 does.

Merge the release PR. This rollout **runs the new analysis for the first time**, against a healthy canary. Start traffic first:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
DURATION=600 gmake traffic CLUSTER=local ENVIRONMENT=prod
```
In another terminal:
```bash
kubectl --context "$LOCAL_CTX" -n platform-prod get analysisrun -w
```

**Validate:** once the rollout pauses, an AnalysisRun named for the Rollout appears and reads `Running`. After about five minutes of healthy traffic it reads `Successful`, and the rollout is **still paused**, waiting for you. Promote it:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake canary ACTION=promote CLUSTER=local SVC=service-2
```
Service-1 has no new build in this release, so there is nothing else to promote.

**If the AnalysisRun shows `Error` rather than `Running` or `Successful`,** read why:
```bash
kubectl --context "$LOCAL_CTX" -n platform-prod get analysisrun -o jsonpath='{.items[-1:].status.metricResults[*].message}{"\n"}'
```
The usual causes: the Prometheus address is wrong (a connection error names it), the query returned no series because the `service` label is missing (Task 22.1.1), or the result is a vector the condition cannot index (an empty result).

#### Task 25.1.3: Rehearse a bad canary, and a wrong one

**Goal:** Watch the analysis abort a canary that returns errors, then watch it wave through one that returns wrong answers. Both are findings.

Each rehearsal is a small change to service-2's **prod environment only**, in its config repo, which creates a new ReplicaSet, which is a canary. Save the patch once:
```bash
cat > "$PLATFORM_HOME/.tmp/fault-patch.yaml.in" <<'EOF'
- target:
    group: argoproj.io
    version: v1alpha1
    kind: Rollout
    name: service-2
  patch: |-
    - op: add
      path: /spec/template/spec/containers/0/env/-
      value:
        name: FAULT_VAR
        value: "FAULT_VALUE"
EOF
```
The patch appends to the container's `env` list, which exists because Task 24.2.3 added the OpenTelemetry variables.

**Rehearsal A: errors. The analysis aborts it.**
```bash
cd "$CFG2"
git switch main && git pull --ff-only
git switch -c rehearse/errors
sed 's/FAULT_VAR/FAULT_ERROR_PERCENT/; s/FAULT_VALUE/50/' "$PLATFORM_HOME/.tmp/fault-patch.yaml.in" > "$PLATFORM_HOME/.tmp/fault-patch.yaml"
yq -i '.patches += load("'"$PLATFORM_HOME"'/.tmp/fault-patch.yaml")' local/prod/app/kustomization.yaml
git commit -am "rehearsal: service-2 answers 503 to half of /process"
git push -u origin rehearse/errors
gh pr create --fill --base main
```
Merge the PR in the config repo (it touches prod, so it goes through review as any release does). Start traffic the moment the canary pauses, and leave it:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
DURATION=600 gmake traffic CLUSTER=local ENVIRONMENT=prod
```
Watch in three places: the dashboard (namespace `platform-prod`, service `service-2`), the AnalysisRun, and the rollout.
```bash
kubectl --context "$LOCAL_CTX" -n platform-prod get analysisrun -w
kubectl --context "$LOCAL_CTX" argo rollouts get rollout service-2 -n platform-prod --watch
```

**Validate:** on the dashboard, "Canary vs stable: error ratio" shows the canary line climbing towards half of its share of calls while stable stays at zero. Within a few minutes the AnalysisRun becomes `Failed`, and the rollout reads `Degraded` and scales the canary away by itself. **Nobody ran `abort`.** Stable kept serving the whole time:
```bash
kubectl --context "$LOCAL_CTX" -n platform-prod get rollout service-2
curl -s -X POST -H 'Host: prod.localhost' -H 'content-type: application/json' -d '{"value": 21}' http://127.0.0.1:8080/compute
```
Expected: the Rollout `Degraded` and all replicas available on the stable version, and `/compute` answering with `"result":42`.

Then look for the failure with the tools from Section 24, the way you would for a real one: in Explore, Tempo, search for service `service-2` with status `error`. The failing traces are there, and each opens to the span that raised the 503.

**Undo it.** The abort scaled the canary away, but Git still points at the bad configuration, exactly as after a manual abort in guide 2. Revert the rehearsal through a pull request in the config repo, since it touches a prod path:
```bash
cd "$CFG2"
git switch main && git pull --ff-only
git log --oneline -3
```
Find the merge commit of the rehearsal PR in that list and put its hash in `MERGE_SHA`, then:
```bash
cd "$CFG2"
MERGE_SHA=<hash of the rehearsal's merge commit>
git switch -c revert/rehearsal-errors
git revert -m 1 --no-edit "$MERGE_SHA"
git push -u origin revert/rehearsal-errors
gh pr create --fill --base main
```
(`-m 1` is for a merge commit. If you squash-merged, drop it.) Merge the PR, then confirm the environment no longer carries the switch:
```bash
cd "$CFG2"
git switch main && git pull --ff-only
kustomize build local/prod/app | yq 'select(.kind == "Rollout") | .spec.template.spec.containers[0].env[].name' | grep -c FAULT || true
```
Expected: `0`. The revert itself starts a rollout to the healthy configuration, which runs the analysis again and passes; promote it when it pauses.

**Rehearsal B: wrong answers. The analysis waves it through.** Repeat exactly as above with the other switch, so the only differences are the branch name, the variable and the commit message:
```bash
cd "$CFG2"
git switch main && git pull --ff-only
git switch -c rehearse/wrong
sed 's/FAULT_VAR/FAULT_WRONG_PERCENT/; s/FAULT_VALUE/50/' "$PLATFORM_HOME/.tmp/fault-patch.yaml.in" > "$PLATFORM_HOME/.tmp/fault-patch.yaml"
yq -i '.patches += load("'"$PLATFORM_HOME"'/.tmp/fault-patch.yaml")' local/prod/app/kustomization.yaml
git commit -am "rehearsal: service-2 answers wrongly to half of /process"
git push -u origin rehearse/wrong
gh pr create --fill --base main
```
Merge, start traffic, and watch the AnalysisRun. It ends `Successful`. On the dashboard every panel looks healthy: the canary's error ratio sits at zero beside stable's.

But the canary is wrong, and you can see it by asking directly, several times, since half the canary's answers are wrong and half the calls reach the canary:
```bash
for i in 1 2 3 4 5 6 7 8; do
  curl -s -X POST -H 'Host: prod.localhost' -H 'content-type: application/json' -d '{"value": 21}' http://127.0.0.1:8080/compute | jq -r .result
done | sort | uniq -c
```
Expected: a mix of `42` and `43`. A client who got `43` was told something false by a system whose every metric was green.

Abort the canary, and revert the same way as before (`gmake canary ACTION=abort CLUSTER=local SVC=service-2`, then a revert PR for the `rehearse/wrong` merge commit).

**Validate:** you can state, in your own words, why rehearsal A was caught and rehearsal B was not. If you cannot, read the two dashboards again side by side.

#### Task 25.1.4: Write down the finding

**Goal:** The answer to Task 13.2.3, recorded, because it is the specification for the next project.

Add to the tracker's Notes and Deviations table (or to a short note of your own) a sentence for each:

- What error-rate analysis **does** catch: a canary that fails requests, including partial failure, within about five minutes of judging, without anyone watching.
- What it **cannot** catch: a canary that answers 200 with the wrong content. HTTP status is not correctness. The service-2 stub is the most likely place this fails in real life, because its whole job is to return a computed number.
- What would catch it: a check on **business meaning**. For the stubs that could be a metric comparing service-1's expected result with what service-2 returned. For the marketplace it is things like "orders whose total matches the sum of their items", "stock never negative", "wallet balance after checkout equals balance before minus total". Those are measured by the service that knows them, exposed as counters, and compared canary to stable exactly like the error rate here.
- The manual pause stays, for the same reason. The analysis is the floor, and your judgment is still the ceiling.

**Validate:** the note exists and names at least one concrete business metric for the marketplace. That list is the first thing the marketplace guide builds.

Commit and merge nothing further for this phase except the tracker.

### Phase 25.2: The budget, measured

#### Task 25.2.1: Replace the estimates with measurements

**Goal:** A table of what the stack actually costs on both clusters, filled from commands, not from this guide.

Local, with everything from Sections 22 to 24 running and a minute of traffic:
```bash
cd "$PLATFORM_HOME"
bash docs/resource_check.sh
kubectl --context "$LOCAL_CTX" top pods -n observability
kubectl --context "$LOCAL_CTX" describe node | sed -n '/Allocated resources/,/Events/p'
kubectl --context "$LOCAL_CTX" get pods -A --no-headers | wc -l
```
EKS, which needs the cluster up with the same stack (Task 24.4.1 measured it; repeat here only if you destroyed it since):
```bash
kubectl --context "$EKS_CTX" top pods -n observability
kubectl --context "$EKS_CTX" top nodes
kubectl --context "$EKS_CTX" describe node | sed -n '/Allocated resources/,/Events/p'
kubectl --context "$EKS_CTX" get pods -A --no-headers | wc -l
kubectl --context "$EKS_CTX" get node -o jsonpath='{.items[0].status.allocatable.pods}{"\n"}'
```
Fill in this table in the tracker's Notes section:

| Component | Estimate | Local measured | EKS measured |
|---|---|---|---|
| Prometheus server | 300 Mi | | |
| Grafana | 150 Mi | | |
| Loki | 250 Mi | | |
| Tempo | 200 Mi | | |
| Alloy | 150 Mi | | |
| Stack total | 1.1 Gi | | |
| Pods on the cluster (all namespaces) | | | |
| Node memory requested, percent of allocatable | | | |
| Node pod limit (EKS) | 110 | n/a | |

**Reading the describe output.** "Requests" is what the scheduler has reserved and what would block a new pod; "Limits" can exceed 100 percent legitimately. `top` shows actual use. Requests well under use mean the scheduler is being lied to and the node can be overcommitted in practice. Requests well over use waste room.

**Validate:** every cell of the table is filled, and the stack total is the sum of the five rows (within rounding).

#### Task 25.2.2: Set the requests to what you measured

**Goal:** Requests that match reality, so the scheduler and this guide's budget agree.

For each component where measured use is clearly above the estimate (say by a quarter or more), raise `resources.requests.memory` in that add-on's `values.yaml` on **both** clusters, and raise the limit so it stays about twice the request. Where use is well below, lower it. Leave CPU alone unless `top` shows a component pinned.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch main && git pull --ff-only
git switch -c chore/observability-sizing
# Example: Loki measured at 320Mi on both clusters.
# yq -i '.singleBinary.resources.requests.memory = "320Mi" | .singleBinary.resources.limits.memory = "640Mi"' addons/local/loki/values.yaml addons/eks/loki/values.yaml
```
The key path differs per chart (`server.resources` for Prometheus, `singleBinary.resources` for Loki, `resources` for Grafana and Tempo, `alloy.resources` for Alloy). The commented example shows the shape; the files above show the paths.

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
for n in prometheus grafana loki tempo alloy; do
  printf '%-11s' "$n"
  diff <(yq '.. | select(tag == "!!map" and has("requests")) | .requests.memory' "addons/local/$n/values.yaml") \
       <(yq '.. | select(tag == "!!map" and has("requests")) | .requests.memory' "addons/eks/$n/values.yaml") >/dev/null && echo "local and eks agree" || echo "DIFFER"
done
```
Expected: `local and eks agree` for all five, unless you deliberately gave one cluster a different size (then note why). Merge:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git commit -am "chore(observability): size requests from measurements"
merge_to_main chore/observability-sizing
```

#### Task 25.2.3: Headroom on the one EKS node

**Goal:** A clear answer to "is there room for the marketplace?", which will add three services.

From the figures above:
- **Memory.** The node has about 7 GiB allocatable on a `t3.large`. The platform plus this stack should request well under 80 percent of that. If it is over, the marketplace will not fit without trimming, and the cheapest trims are a smaller Prometheus retention and dropping Tempo's volume size, not a second node.
- **Pods.** With about 110 allowed, pods are no longer the constraint. Confirm the figure the node reports, since it depends on prefix delegation having taken effect for the current node.
- **CPU.** A `t3.large` is burstable (2 vCPU, credits). During a load test the generator is off-cluster, but Prometheus, Alloy and Tempo all work harder. Note the credit balance before and after a load test in the marketplace project.

Write the conclusion in one line in the tracker, for example "EKS: 62 percent of memory requested, 41 of 110 pods, room for three services and a canary surge".

**Validate:** that line exists and quotes the two measured percentages.

### Phase 25.3: Operating it

#### Task 25.3.1: The commands, and how to read a canary

**Goal:** A short reference to what you now have, which is also the check that it all hangs together.

| Command | Does |
|---|---|
| `gmake grafana` | Opens Grafana on a cluster you choose, on port 3000 (local) or 3001 (EKS) |
| `gmake prometheus` | Opens Prometheus likewise, on 9090 or 9091 |
| `gmake traffic` | Sends about five requests a second to a cluster and environment, for `DURATION` seconds |
| `gmake status` | Builds in Git against builds running (unchanged from guide 3) |
| `gmake canary` | Watch, promote or abort (unchanged from guide 3) |

**Reading a canary, in order.** This is the runbook the stack exists to support:
1. `gmake release`, merge the PR, start `gmake traffic` against prod. Without traffic there is nothing to judge.
2. When the rollout pauses, open the RED dashboard: namespace `platform-prod`, the service you are releasing.
3. "Canary vs stable: request rate" should show both lines carrying traffic. If the canary line is empty, nothing reaches it and no judgment is possible.
4. "Canary vs stable: error ratio": the canary must not be above stable. The AnalysisRun says the same in words: `kubectl --context "$LOCAL_CTX" -n platform-prod get analysisrun`.
5. "p95 latency" and "Outbound p95": a canary that is slower is a finding even when it is not failing.
6. Then the check the analysis **cannot** make: call the endpoint yourself a few times and read the answers (Task 25.1.3, rehearsal B).
7. Promote or abort.

**Validate:** without looking back, you can name what step 6 is for. If not, reread Task 25.1.4.

#### Task 25.3.2: Teardown, the stamp checklist, and the docs

**Goal:** Nothing from this guide left billing or unmentioned.

**Teardown.** The observability stack adds persistent volumes (Prometheus, Loki and Tempo each have one). The existing check in Task 18.3.1 looks for volumes tagged with the cluster name, which covers them. After a destroy, confirm:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake destroy CLUSTER=eks
aws ec2 describe-volumes --region ap-southeast-2 --filters Name=tag-key,Values="kubernetes.io/cluster/$EKS_CTX" --query 'Volumes[].VolumeId'
aws elbv2 describe-load-balancers --region ap-southeast-2 --query 'LoadBalancers[].LoadBalancerName'
aws eks list-clusters --region ap-southeast-2 --query clusters
```
Expected: `[]` three times. An orphaned volume shows as `available` in the console and bills about a tenth of a cent per GiB-hour; delete it there.

**The stamp checklist.** A project created from this template (the marketplace) must change these, on top of guide 4's list. Find them all with one search:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
grep -rn --include='*.yaml' --include='*.json' --include='*.sh' -E 'raw\.githubusercontent\.com|platform-prod|platform-dev|lfi-infrastructure-gitops' addons dashboards scripts/observe.sh
```
Each hit is one of: the dashboard URL in each cluster's Grafana values (owner and repo), and the namespace variable options in `dashboards/red.json`. The analysis names no namespace any more: it reads the Rollout's own. In the other repositories, a stamped project's config repos carry its namespace prefix in the `namespace:` line of every environment kustomization, which guide 4's README section covers.

**The docs.**
1. In `lfi-infrastructure-gitops/README.md`, add `addons/<cluster>/{prometheus,grafana,loki,tempo,alloy}`, `dashboards/`, `scripts/observe.sh`, and a sentence on the three new `gmake` commands.
2. In the project root `README.md`, add guide 5 to the guide list and sections 22 to 25 to the sections table.
3. To publish guide 5 and its tracker, add `!docs/5-observability-setup-guide.md` and `!tracker_5_observability.md` to the allowlists in the project root `.gitignore`.
4. Guide 2's Section 13 still says "scoped, not scheduled". Changing it to point here is a one-paragraph edit you may want to make now, so a reader of guide 2 does not think the section is still open.

**Validate:**
```bash
cd "$PLATFORM_HOME"
grep -c 'observe.sh' lfi-infrastructure-gitops/README.md
grep -c '5-observability-setup-guide' README.md
git -C "$PLATFORM_HOME" status --short
```
Expected: non-zero counts for the two greps, and the status showing the README, `.gitignore` and the new guide and tracker.

**Where this leaves you.** A platform you can see into, on two clusters, with a canary that watches itself and an honest list of what it cannot see. The marketplace project starts from exactly here: its first metrics are the business ones that Task 25.1.4 named.

---

## Appendix K: Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `kubectl` acts on the wrong cluster | Current context is a different cluster | Every command in this guide passes `--context`. Use `"$LOCAL_CTX"` and `"$EKS_CTX"` and never change the current context. |
| Add-on Application `Unknown` or `ComparisonError` | Chart version does not exist, or the multi-source values reference is wrong | `kubectl --context "$LOCAL_CTX" -n argocd get application <name> -o jsonpath='{.status.conditions[*].message}'`, then recheck Task 22.1.1. |
| Values file installs but a setting has no effect | The key is wrong for this chart version; Helm ignores unknown keys silently | `helm show values <chart> --version <v>` and compare. Task 22.1.1 checks the keys that matter. |
| `targets` shows no `kubernetes-service-endpoints` targets | Services are not annotated, or the annotation names are not the chart's | Check `prometheus.io/scrape: "true"` is a **string** on the Service, and the names in Task 22.1.1's job dump. |
| Queries return nothing although targets are up | A label name differs from what the query expects (`service`, `namespace`) | `prom "$LOCAL_CTX" 'http_requests_total'` and read the label names on the real series. |
| Canary and stable panels show one line | Expected outside a rollout | Both Services select the same pods until a rollout starts. |
| Application flaps `Synced`/`OutOfSync` during a canary | ArgoCD is reverting the selectors Rollouts set | Task 23.1.3's `ignoreDifferences`, and `RespectIgnoreDifferences=true`. |
| Grafana has no dashboard | The download at startup got a `404` or no network | Merge `dashboards/red.json` first, then check `logs deploy/grafana -c download-dashboards`. |
| Traefik series missing | Pod lacks the scrape annotations | Task 22.3.2: inspect the pod's annotations; on local, re-apply the `HelmChartConfig`. |
| `pg_up` missing or 0 | Exporter cannot log in | `kubectl logs postgres-0 -c exporter`; the Secret keys must be `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`. |
| Postgres restarted when the exporter was added | Expected: the pod template changed | The data is on a PVC. Services recover on their own when `/readyz` passes. |
| Loki shows `read`, `write` or `backend` pods | Scale-out toggles not honoured by this chart version | Task 24.1.2's render check; read the chart's values. |
| Alloy pod `CrashLoopBackOff` | Config syntax error | `logs deploy/alloy`; it names the line and column. |
| No traces in Tempo | Services cannot reach Alloy, or `OTEL_EXPORTER_OTLP_ENDPOINT` is unset | Pod log for export errors; `kubectl exec` is not needed, the warning names the address. |
| Trace has spans from only one service | `traceparent` not propagated | Run the proof script (Task 24.2.1); check httpx is instrumented in service-1 and FastAPI in service-2. |
| Log lines have no `trace_id` | Line was written outside a span, or by uvicorn's own logger | Only application logs inside a request carry it. Uvicorn access lines never do. |
| Logs missing from Loki | Alloy cannot read pod logs | `logs deploy/alloy`; a `forbidden` on `pods/log` needs an RBAC rule. |
| AnalysisRun `Error` | Prometheus address or query wrong | `kubectl get analysisrun -o jsonpath='{.items[-1:].status.metricResults[*].message}'` |
| AnalysisRun never starts | Rollout has no step 1, or no analysis block in this environment (its kustomization does not name `canary-analysis`) | Task 25.1.1's validation; dev has none by design. |
| Canary passes with no traffic | Metric 1 reads zero traffic as zero errors | Metric 2 exists for this; make sure traffic runs (`gmake traffic`). |
| Replacement leaves `templateName: placeholder` | Kustomize older than 5 | `kustomize version`. |
| `top` shows nothing on EKS | metrics-server add-on not running | Guide 4's proof add-on; `kubectl get pods -n kube-system`. |
| Orphan EBS volumes after destroy | PVCs were not deleted before the cluster | Delete the `available` volumes tagged with the cluster name. |

**Fallback for the namespace argument.** If an AnalysisRun reports an error about the `namespace` argument, your Argo Rollouts does not resolve `valueFrom.fieldRef` there. Give the component a plain placeholder and let each prod environment fill it in. In the templates repo, change the `args` entry in `components/canary-analysis/kustomization.yaml` to `value: placeholder`, commit, and release it as `v1.1.1`. Then in each prod `app/kustomization.yaml` of both config repos, move the reference to `?ref=v1.1.1` and add the replacement below, which works because the environment's own `namespace:` is already applied when it runs:
```yaml
replacements:
  - source:
      kind: Rollout
      fieldPath: metadata.namespace
    targets:
      - select:
          kind: Rollout
        fieldPaths:
          - spec.strategy.canary.analysis.args.0.value
```

## Appendix L: Glossary

**RED.** Rate, Errors, Duration: the three numbers that say whether a service is serving users.
**Time series.** One metric name plus one specific set of label values. Each distinct combination is a separate series and costs memory.
**Cardinality.** How many distinct label combinations a metric has. High-cardinality labels (user ids, raw URLs) are what exhaust Prometheus.
**Scrape.** Prometheus fetching `/metrics` from a target on a schedule.
**Exporter.** A process that turns a system's own statistics into Prometheus format when the system cannot do it itself. Here, the Postgres sidecar.
**Sidecar.** A second container in a pod. It shares the pod's network and costs memory, not a pod slot.
**Histogram.** A metric that counts observations into buckets so percentiles can be computed later with `histogram_quantile`.
**Span.** One timed operation inside a trace, such as a request handler, an HTTP call or a query.
**Trace.** All the spans caused by one request, across services, sharing a trace id.
**Trace context.** The `traceparent` header that carries the trace id from one service to the next.
**OTLP.** The OpenTelemetry wire protocol services use to send traces.
**Sampling.** Keeping only some traces. Head sampling decides at the start; the sampler here decides by trace id so a trace is kept or dropped whole.
**Alloy.** Grafana's agent. Here it receives OTLP, forwards traces to Tempo, and tails pod logs into Loki.
**LogQL.** Loki's query language: a label selector in braces, then filters.
**Derived field.** A rule in the Loki datasource that turns a piece of a log line into a link, here the trace id into a Tempo trace.
**AnalysisTemplate.** An Argo Rollouts resource describing a metric query and the condition that counts as success or failure.
**AnalysisRun.** One execution of an AnalysisTemplate against a live rollout.
**Inconclusive.** An analysis result that is neither success nor failure. It leaves the rollout paused rather than aborting it.
**Kustomize component.** A reusable bundle of patches that an environment opts into, here by URL and pinned to a tag of the templates repo. `canary-manual-gate` and `canary-analysis` give a prod environment its pause and its analysis.

## Where to Go Next

**The marketplace project.** The first thing to build on this is the business metrics named in Task 25.1.4, exposed by checkout, inventory and accounts, and compared canary to stable the way the error rate is here.
**k6 load testing.** Prometheus already accepts remote write (Task 22.1.3). A load test that writes its own metrics into this Grafana puts the client's view and the service's view on the same screen. Set the Alloy sampler (Task 24.4.2) before running one.
**Alerting.** Alertmanager is off. Turning it on and routing one alert to a channel you read is the usual next step once something is worth waking for.
**Exemplars.** Prometheus can store a trace id alongside a histogram sample, so a latency spike on a panel links straight to a slow trace. It needs the OpenMetrics exposition format in the services and Prometheus' exemplar storage feature flag.
**A separate metrics port.** `/metrics` is reachable through the public Ingress today. Serving it on a second port that only Prometheus can reach closes that.
**kube-state-metrics.** The subchart left off in Task 22.3.3, for restart counts and rollout status as metrics.
**Recording rules.** Precomputing the error ratio as a named series makes dashboards cheaper and the AnalysisTemplate query shorter.
