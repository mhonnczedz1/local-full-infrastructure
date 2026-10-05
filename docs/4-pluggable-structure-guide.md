# A Pluggable Platform Template: A Build Guide

**Goal:** Turn the GitOps repo from "two clusters with hand-written Applications" into a template where adding a service, removing a service or enabling an add-on is a directory change, where cluster identity is written once, and where a new project can be stamped from it.

**Status:** DRAFT. Nothing in this guide has been executed against a live cluster. What was checked offline, on a scratch copy of the repo: the Kustomize restructure renders byte for byte the same manifests for all 12 cluster, environment and service combinations; the registry readers, the scaffolder, the contract check and the stamp script run under macOS bash 3.2 and behave as described, including on deliberately broken input; the edited scripts parse; the Makefile edit expands to the Terraform commands shown, with the state keys you already use (checked by printing them, never by running Terraform); and the branch-conflict recipe in Appendix I resolves a staged conflict correctly. What was **not** checked, because it needs a running ArgoCD: how the ApplicationSet controller treats the cutover, the behavior of the `applicationsSync` and `preserveResourcesOnDeletion` policies, the add-on chart version, and EKS prefix delegation. Each of those has a Validate block that will tell you, and a fallback in Appendix I. Progress is ticked in `tracker_4_pluggable.md`, not here.

**Relationship to the earlier guides:** This continues `docs/1-local-full-infra-guide.md` (Sections 1 to 9), `docs/2-multi-env-infra-guide.md` (Sections 10 to 13) and `docs/3-eks-counterpart-guide.md` (Sections 14 to 18). Numbering resumes at Section 19 and appendix lettering at I. It assumes you finished Section 18: both clusters can be brought up with `gmake up`, each runs `root` plus six child Applications, and Terraform state lives in S3.

**Tech stack added:** ArgoCD ApplicationSets (already installed by the ArgoCD chart, never used until now), Kustomize Components, a small YAML registry read with `yq`, and an EKS VPC CNI setting (prefix delegation). No new cluster software is installed except one proof add-on, metrics-server, on EKS.

**Cost:** nothing new for the local cluster. EKS bills about 0.23 USD an hour while it exists. This guide makes every change blind to EKS first and brings the cluster up **once**, in Phase 21.5, to validate all of it together, so you pay for a few hours and not for the whole guide.

---

## How to use this guide

Work top to bottom. Every task has a **Goal**, a **Why** where a choice could have gone another way, and a **Validate** block with the command and the output you should see. Do not move on until Validate passes.

Sections are separate parts of the system. Phases are milestones inside a section. Tasks are single actions, numbered `Task <section>.<phase>.<n>`.

Section 20 changes a live cluster, so it is written to be zero downtime, and it proves that with pod identifiers rather than with a glance at `kubectl get pods`. Read its primer before touching anything.

### Where commands run

Same rules as guide 3: every command block that depends on location **starts with an explicit `cd`**, and a block with no `cd` only talks to a cluster or to AWS.

| Name | Resolves to | Notes |
|------|-------------|-------|
| `$PLATFORM_HOME` | the workspace root | Set in guide 1, Task 1.2.1. Holds `docs/`, the trackers and `.tmp/`. |
| `$PLATFORM_HOME/lfi-infrastructure-gitops` | the GitOps repo | Its own Git repo. `gmake` runs here. This guide changes it heavily. |
| `$PLATFORM_HOME/lfi-service-1-app`, `lfi-service-2-app` | the service repos | Only tagged in this guide. Their CI is not edited. |
| `$PLATFORM_HOME/.tmp/g4/` | scratch for this guide | Snapshots and staged files. Disposable. |

### Two safety rules for this machine

**Always pass `--context`.** A workstation's kubeconfig often holds many unrelated clusters, and this one does. A bare `kubectl` acts on whatever context is current, which may be a work cluster. Every cluster command in this guide names its context: `k3d-platform` for the local cluster and `lfi-eks` for EKS. Keep doing that in your own commands.

**`gmake -n` is not a dry run here.** GNU make runs any recipe that mentions `$(MAKE)` even under `-n`, and because the Makefile uses `.ONESHELL`, the **whole recipe** runs for real, including the Terraform lines in it. That covers `_local-destroy`, `_eks-destroy`, `up` and `destroy` paths that call sub-makes. To preview what a Terraform target would do, use the `_local-plan` and `_eks-plan` targets added in Task 21.2.1, which only plan.

---

## Decisions already made

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| 1 | Template, not fork | **Refactor `lfi-infrastructure-gitops` in place, tag the old state, and mark the repo as a GitHub template** | Guides 1 to 3 point at the repo. The tag `guide-3-complete` keeps them accurate. A new project is created from the template, not forked. GitHub does not let you fork your own repo into your own account anyway. |
| 2 | How a service is discovered | **An ApplicationSet with a Git directory generator over `kubernetes/overlays/<cluster>/*/*`** | A directory is the unit of deployment already. Adding or deleting one is the whole operation. |
| 3 | Datastores | **A second ApplicationSet, with no prune, no cascading delete and `preserveResourcesOnDeletion`** | One policy cannot be both "a removed service should disappear" and "a removed database must never disappear". Two sets keep each policy honest. |
| 4 | Shared environment behavior | **Kustomize Components per cluster and environment** (`kubernetes/components/<cluster>-<env>/`) | Replica counts, the canary steps and the Ingress host were copy-pasted into every service overlay. A new service would copy them again. The component holds them once. |
| 5 | What CI and `release.sh` write | **Unchanged.** `kubernetes/overlays/<cluster>/<env>/<svc>/kustomization.yaml`, field `images[0].newTag` | Every writer in both service repos depends on this path and field. The refactor changes who creates the Application, not where the tag lives. |
| 6 | Application names | **Unchanged.** `service-1-dev`, `service-1-dev-eks` and so on | A generated Application with the same name as the old one adopts the running resources instead of recreating them. |
| 7 | One source of truth | **`platform/registry.yaml`** holds clusters, environments, namespace prefix and services. Scripts, the Makefile and the stamp script read it; a contract check compares everything else to it | ArgoCD cannot read it, so the few values ApplicationSets need are repeated there, and the check catches the copy that drifts. |
| 8 | Add-ons | **`addons/<cluster>/<name>/addon.yaml` plus `values.yaml`, one ApplicationSet per cluster** | Enabled on a cluster by the presence of its directory, like a service. Multi-source Applications keep values in Git and the chart in its own repository. |
| 9 | EKS pod limit | **VPC CNI prefix delegation** | The `t3.large` caps at 35 pods by interface arithmetic. Prefix delegation moves the limit toward the kubelet ceiling of 110, with no second node. |
| 10 | Stamping | **A script, dry run by default, that relabels a copy of the repo** | Creating a goal project should be a few minutes and a checklist, not an afternoon of `grep`. |

### Primer: why an ApplicationSet and not more Applications

Guide 1 built an app-of-apps: a `root` Application watches a directory of Application manifests, and each manifest deploys one thing. It works, and it means that for every service, cluster and environment you write another nearly identical manifest. Guide 3 made that twelve files, two of which differ from the rest only by a `prune: false`.

An ApplicationSet is a template plus a generator. The generator here looks at the Git repository's directory tree and emits one set of values per matching directory. The controller stamps one Application out of the template for each. Delete a directory and its Application is removed. The `root` Application still exists, but what it now syncs is a handful of ApplicationSet manifests, not a pile of Applications.

The controller is not new. The ArgoCD chart has installed `argocd-applicationset-controller` since Section 6. A comment in `values/argocd.yaml` said it was disabled, but the chart has no such switch, so it has been running, unused, the whole time. Task 20.2.1 fixes that comment.

### Primer: why finalizers decide whether the cutover is safe

Every hand-written Application carries `resources-finalizer.argocd.argoproj.io`. That finalizer means: **when this Application is deleted, delete everything it deployed first.** It is why deleting `root` cleans up a whole cluster, and it is a feature.

It is also the one way this guide could destroy the database. If you simply delete the six Application files from Git, `root` prunes six Applications, each cascades, and Postgres and its volume claim go with them. So the cutover removes the finalizers **first**, proves they are gone, and only then deletes the files. An Application without the finalizer can be deleted while the workload keeps running, and a new Application of the same name picks the workload back up. Phase 20.3 is built around that order.

### Primer: adoption by name

ArgoCD remembers which Application owns a resource by a tracking identifier that includes the Application's name. A new Application with the same name claims resources with that identifier as its own, finds they already match the Git state, and changes nothing. This is why Decision 6 matters and why the cutover is validated by comparing pod identifiers before and after: identical identifiers mean nothing was recreated.

---

## What changes and what does not

| Changes | Does not change |
|---------|-----------------|
| Who creates the Applications: ApplicationSets instead of twelve hand-written files | Where image tags live and which field holds them |
| Overlays shrink to namespace, base, component, image | Base manifests under `kubernetes/base/` |
| Scripts read services and clusters from the registry | The commands you type: `gmake up`, `status`, `release`, `canary`, `rollback` |
| Terraform state keys come from the registry on the command line | The state bucket and the key values themselves, so nothing migrates |
| EKS gets prefix delegation | Node count and instance type |
| New: `platform/`, `kubernetes/components/`, `kubernetes/templates/`, `addons/`, scaffold and stamp scripts | Both service repos, their CI and their images |

---

## Directory layout after this guide

```
lfi-infrastructure-gitops/
├── platform/
│   └── registry.yaml                      clusters, environments, services, identity
├── kubernetes/
│   ├── base/<service>/                    unchanged
│   ├── components/<cluster>-<env>/        new: replicas or canary steps, and the host
│   ├── overlays/<cluster>/<env>/<service>/kustomization.yaml   slimmer
│   └── templates/service/                 new: what `gmake add-service` copies
├── addons/
│   ├── local/README.md
│   └── eks/metrics-server/{addon.yaml,values.yaml}
├── argocd/
│   ├── apps-local/appsets/{services,data,addons}.yaml
│   └── apps-eks/appsets/{services,data,addons}.yaml
├── scripts/
│   ├── reg.sh  check-contract.sh  new-service.sh  stamp.sh     new
│   └── lib.sh  canary.sh  release.sh  status.sh                read the registry
└── terraform/                             backends lose their hard-coded key
```

## Resource budget

The ApplicationSet controller already runs; budget roughly 50 to 100 MB for it. The only workload this guide adds is metrics-server on EKS, requesting 25m CPU and 48Mi. Prefix delegation adds no pods. The throwaway `demo` service in the drills requests 25m and 64Mi per replica and is gone at the end of each drill.

---

## Table of Contents

- [Section 19: Baseline and contract](#section-19-baseline-and-contract)
- [Section 20: Pluggable services](#section-20-pluggable-services)
- [Section 21: Add-ons and multi-cluster](#section-21-add-ons-and-multi-cluster)
- [Appendix I: Troubleshooting](#appendix-i-troubleshooting)
- [Appendix J: Glossary](#appendix-j-glossary)

---

## Section 19: Baseline and contract

**Objective:** A known-good starting point you can return to, and a written statement of what must not change.

### Phase 19.1: Preflight

#### Task 19.1.1: Bring up the local cluster and prove it healthy

**Goal:** A known-good baseline, so any later breakage is attributable. EKS stays down until Phase 21.5.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake up CLUSTER=local
```

**Validate:**
```bash
kubectl --context k3d-platform -n argocd get applications
kubectl --context k3d-platform -n argocd get deploy argocd-applicationset-controller
```
Expected: `root` plus six children, all `Synced` and `Healthy`, and the ApplicationSet controller Deployment `1/1`. If the controller is missing, your ArgoCD chart predates ApplicationSets being bundled; stop and see Appendix I.

#### Task 19.1.2: Sync main and tag the end of guide 3

**Goal:** A named point in each repo that the earlier guides can refer to, whatever this guide does next.

**Why all three repos:** The guides' companion repos are these three. Only the GitOps repo changes here, but tagging the other two now costs nothing and means a later reader can reproduce the exact set.

The GitOps repo is usually a few commits behind `origin` because CI commits image tags to it, so pull first.
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch main
git pull --ff-only
git status -sb | head -1

for repo in lfi-infrastructure-gitops lfi-service-1-app lfi-service-2-app; do
  cd "$PLATFORM_HOME/$repo"
  git switch main >/dev/null
  git pull --ff-only
  git tag -a guide-3-complete -m "State at the end of guide 3"
  git push origin guide-3-complete
done
```

**Validate:**
```bash
for repo in lfi-infrastructure-gitops lfi-service-1-app lfi-service-2-app; do
  cd "$PLATFORM_HOME/$repo"
  printf '%s: ' "$repo"; git ls-remote --tags origin guide-3-complete | wc -l
done
```
Expected: `1` for each repo. The first command block should have printed `## main...origin/main` with no `ahead` or `behind`.

#### Task 19.1.3: Snapshot what exists today

**Goal:** Three records to compare against later: the rendered manifests for every overlay in both clusters, the names of the Applications, and the identity of every running pod and claim in the local cluster.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
mkdir -p "$S/render-before"

for cluster in local eks; do for env in dev prod; do for svc in service-1 service-2 postgres; do
  kustomize build "kubernetes/overlays/$cluster/$env/$svc" > "$S/render-before/$cluster-$env-$svc.yaml"
done; done; done

kubectl --context k3d-platform -n argocd get applications -o name | sort > "$S/apps-before.txt"

for ns in platform-dev platform-prod; do
  kubectl --context k3d-platform -n "$ns" get pods,pvc \
    -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.metadata.uid}{"\n"}{end}'
done | sort > "$S/uids-before.txt"
```

**Validate:**
```bash
S="$PLATFORM_HOME/.tmp/g4"
ls "$S/render-before" | wc -l
find "$S/render-before" -empty | wc -l
wc -l < "$S/apps-before.txt"
wc -l < "$S/uids-before.txt"
```
Expected: `12`, `0`, `7` (six children plus `root`), and a count of pods plus claims (about ten: one pod per service in dev, two per service in prod, and a Postgres pod and claim in each environment). None of the four may be zero.

#### Task 19.1.4: Work on a branch

**Goal:** Nothing lands on `main` until it is validated. This guide merges to `main` several times, deliberately, in Phase 20.3, because ArgoCD reads `main`. Everything else merges once.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch -c feat/pluggable-structure
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git branch --show-current
```
Expected: `feat/pluggable-structure`.

### Phase 19.2: The contract

#### Task 19.2.1: Write the registry

**Goal:** `platform/registry.yaml` exists and says, in one place, what this repo deploys and to where. Nothing reads it yet.

**Why `stateKeyPrefix` is here:** the Terraform state keys already exist in S3 under `local-platform/` and `lfi-eks/`. Recording those exact strings is what lets Task 21.2.2 move the keys out of the backend blocks without migrating any state.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
mkdir -p platform
cat > platform/registry.yaml <<'EOF'
# The one place that says what exists. Scripts, the Makefile and the stamp
# script read it. ArgoCD cannot, so the ApplicationSets repeat the few values
# they need, and scripts/check-contract.sh fails if the two drift.
project: lfi
owner: YOUR_GITHUB_USER
repo: lfi-infrastructure-gitops
stateBucket: YOUR_STATE_BUCKET
namespacePrefix: platform
environments: [dev, prod]
clusters:
  - name: local
    kind: k3d
    context: k3d-platform
    clusterName: platform
    stateKeyPrefix: local-platform
  - name: eks
    kind: eks
    context: lfi-eks
    clusterName: lfi-eks
    region: ap-southeast-2
    stateKeyPrefix: lfi-eks
# Order is the order the menus show. dependsOn means "calls": the dependency is
# released and promoted first.
services:
  - name: service-1
    role: the gateway. Calls service-2.
    dependsOn: [service-2]
  - name: service-2
    role: the worker. Release and promote it first.
EOF
```
Replace `YOUR_GITHUB_USER` with your GitHub owner and `YOUR_STATE_BUCKET` with the bucket named in your `backend.tf` files:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
BUCKET="$(sed -n 's/.*bucket *= *"\(.*\)".*/\1/p' terraform/local/01-cluster/backend.tf)"
OWNER="$(sed -n 's#.*github.com/\([^/]*\)/.*#\1#p' argocd/apps-local/dev/service-1.yaml | head -1)"
O="$OWNER" B="$BUCKET" yq -i '.owner = strenv(O) | .stateBucket = strenv(B)' platform/registry.yaml
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
yq '.owner, .stateBucket' platform/registry.yaml
yq '.clusters[].name, .services[].name' platform/registry.yaml | tr '\n' ' '; echo
```
Expected: your owner and bucket (neither may contain `YOUR_`), then `local eks service-1 service-2`. Also confirm the state key prefixes match what Terraform uses today, because Task 21.2.2 depends on it:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
grep -h 'key ' terraform/*/*/backend.tf
```
Expected: four keys beginning `local-platform/` (two) and `lfi-eks/` (two), matching `stateKeyPrefix`.

#### Task 19.2.2: A contract check that fails loudly

**Goal:** `scripts/check-contract.sh`, a read-only script that compares the repo to the registry and exits non-zero when they disagree. You run it after every structural change in this guide.

**Why:** Pluggable means many places must agree: every service needs a base, four overlays, two components and a registry entry. One missing overlay otherwise shows up weeks later as a release that silently skips a cluster. The check turns that into an error at the moment you cause it.

First the small reader the script and later scripts share. It is written for macOS bash 3.2: no `mapfile`, no associative arrays.
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
cat > scripts/reg.sh <<'EOF'
# Reads platform/registry.yaml. Sourced by other scripts, never run directly.
# Written for bash 3.2 (macOS): no mapfile and no associative arrays.
REGISTRY="${REGISTRY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/platform/registry.yaml}"

# registry_list '<yq expression>' fills REGISTRY_LIST, one array element per line.
registry_list() {
  REGISTRY_LIST=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && REGISTRY_LIST+=("$line")
  done < <(yq "$1" "$REGISTRY")
}

registry_list '.clusters[].name';  LFI_CLUSTERS=("${REGISTRY_LIST[@]}")
registry_list '.services[].name';  LFI_SERVICES=("${REGISTRY_LIST[@]}")
registry_list '.environments[]';   LFI_STAGES=("${REGISTRY_LIST[@]}")
NAMESPACE_PREFIX="$(yq '.namespacePrefix' "$REGISTRY")"

# cluster_field <cluster> <field>: prints the value, or fails if there is none.
cluster_field() {
  local v
  v="$(C="$1" yq '.clusters[] | select(.name == strenv(C)) | .'"$2" "$REGISTRY")"
  [[ -n "$v" && "$v" != null ]] || return 1
  echo "$v"
}
cluster_context() { cluster_field "$1" context; }

service_role() { S="$1" yq '.services[] | select(.name == strenv(S)) | .role' "$REGISTRY"; }
# Services that <service> calls.
service_deps() { S="$1" yq '.services[] | select(.name == strenv(S)) | .dependsOn[]?' "$REGISTRY"; }
# Services that call <service>.
service_dependents() { S="$1" yq '.services[] | select(.dependsOn[]? == strenv(S)) | .name' "$REGISTRY"; }
EOF

cat > scripts/check-contract.sh <<'XEOF'
#!/usr/bin/env bash
# Fails loudly when the repo stops matching platform/registry.yaml.
# Read-only. Run it after any structural change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/reg.sh"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }

# Every service has a base, and an overlay in every cluster and environment,
# and each overlay carries the image entry that CI and release.sh write to.
for svc in "${LFI_SERVICES[@]}"; do
  [[ -f "kubernetes/base/$svc/kustomization.yaml" ]] || fail "missing kubernetes/base/$svc/kustomization.yaml"
  for cluster in "${LFI_CLUSTERS[@]}"; do
    for env in "${LFI_STAGES[@]}"; do
      f="kubernetes/overlays/$cluster/$env/$svc/kustomization.yaml"
      if [[ ! -f "$f" ]]; then fail "missing $f"; continue; fi
      tag="$(S="$svc" yq '.images[] | select(.name == strenv(S)) | .newTag' "$f")"
      [[ -n "$tag" && "$tag" != null ]] || fail "$f has no images entry named $svc with a newTag"
    done
  done
done

# Components only matter once Phase 20.1 creates them, so this part waits for them.
if [[ -d kubernetes/components ]]; then
  for cluster in "${LFI_CLUSTERS[@]}"; do
    for env in "${LFI_STAGES[@]}"; do
      [[ -f "kubernetes/components/$cluster-$env/kustomization.yaml" ]] || fail "missing component kubernetes/components/$cluster-$env"
    done
  done
fi

# The other direction: no overlay directory exists that the registry does not know.
for cluster in "${LFI_CLUSTERS[@]}"; do
  for dir in kubernetes/overlays/"$cluster"/*/*/; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    [[ "$name" == postgres ]] && continue
    [[ " ${LFI_SERVICES[*]} " == *" $name "* ]] || fail "$dir exists but $name is not in the registry"
  done
done

# Cluster identity agrees with the files that hard-code it.
for cluster in "${LFI_CLUSTERS[@]}"; do
  [[ -d "argocd/apps-$cluster" ]] || fail "missing argocd/apps-$cluster"
  [[ -d "terraform/$cluster" ]] || fail "missing terraform/$cluster"
done
k3d_name="$(yq '.clusters[] | select(.kind == "k3d") | .clusterName' "$REGISTRY")"
cfg_name="$(yq '.metadata.name' terraform/local/01-cluster/k3d-config.yaml)"
[[ "$k3d_name" == "$cfg_name" ]] || fail "registry says the k3d cluster is '$k3d_name' but k3d-config.yaml says '$cfg_name'"

# Manifests under argocd/ repeat the repo URL because ArgoCD cannot read the
# registry. Any Git URL (one ending in .git) must match it. Helm chart
# repositories do not end in .git, so they are ignored. Catch the copy that was missed.
want_url="https://github.com/$(yq '.owner' "$REGISTRY")/$(yq '.repo' "$REGISTRY").git"
for f in $(find argocd -name '*.yaml' 2>/dev/null); do
  while IFS= read -r url; do
    [[ "$url" == "$want_url" ]] || fail "$f names repoURL $url, registry says $want_url"
  done < <(yq '.. | select(has("repoURL")) | .repoURL' "$f" 2>/dev/null | grep '\.git$' || true)
done

if [[ "$FAILS" -gt 0 ]]; then
  echo "$FAILS problem(s). The repo and platform/registry.yaml disagree." >&2
  exit 1
fi
echo "OK: ${#LFI_SERVICES[@]} services x ${#LFI_CLUSTERS[@]} clusters x ${#LFI_STAGES[@]} environments match the registry."
XEOF
chmod +x scripts/check-contract.sh
```

**Validate:** it passes on the repo as it is, and it fails when you break something.
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
scripts/check-contract.sh

mv kubernetes/overlays/eks/prod/service-2 "$PLATFORM_HOME/.tmp/g4/service-2.bak"
scripts/check-contract.sh; echo "exit code: $?"
mv "$PLATFORM_HOME/.tmp/g4/service-2.bak" kubernetes/overlays/eks/prod/service-2

mkdir kubernetes/overlays/local/dev/ghost
scripts/check-contract.sh; echo "exit code: $?"
rmdir kubernetes/overlays/local/dev/ghost

scripts/check-contract.sh
```
Expected: `OK: 2 services x 2 clusters x 2 environments match the registry.`, then `FAIL: missing kubernetes/overlays/eks/prod/service-2/kustomization.yaml` with exit code `1`, then `FAIL: kubernetes/overlays/local/dev/ghost/ exists but ghost is not in the registry` with exit code `1`, then `OK` again. The last run proves you put everything back.

---
## Section 20: Pluggable services

**Objective:** Adding a service is a scaffold command and a merge. Removing one is deleting directories. The six Applications on the local cluster are generated instead of hand-written, and you can prove nothing was recreated while that happened.

**Order of work:** Phase 20.1 restructures manifests and changes nothing a cluster can see. Phase 20.2 stages the ApplicationSets without applying them. Phase 20.3 is the only phase that touches the live cluster. Phase 20.4 and 20.5 are tooling. Phase 20.6 proves the result.

A note on merging. ArgoCD reads `main`, so several tasks here end with the same **ship** step. Create it once:
```bash
S="$PLATFORM_HOME/.tmp/g4"
cat > "$S/ship.sh" <<'EOF'
#!/usr/bin/env bash
# usage: ship.sh "<commit message>"   Stage the files first with git add.
# Commits on the feature branch, merges it into main with a merge commit, pushes,
# then brings the merge commit back so the next ship merges cleanly.
set -euo pipefail
: "${PLATFORM_HOME:?PLATFORM_HOME is not set. Export it (guide 1, Task 1.2.1).}"
BRANCH=feat/pluggable-structure
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
[[ "$(git branch --show-current)" == "$BRANCH" ]] || { echo "ERROR: not on $BRANCH." >&2; exit 1; }
git commit -m "$1"
git switch main
git pull --ff-only
git merge --no-ff "$BRANCH" -m "Merge: $1"
git push origin main
git switch "$BRANCH"
git merge --ff-only main
echo "Shipped: $1"
EOF
chmod +x "$S/ship.sh"
```
Run it as `bash "$S/ship.sh" "message"`. **Stop if `git merge` reports a conflict or `git push` is rejected.** Your work is safe on the branch and nothing has been deleted. A conflict in a `kustomization.yaml` `newTag` line means a service repo's CI pushed a new tag to `main` while you were working; Appendix I has the four-line fix.

### Primer: what a Component is

A Kustomize **Component** is a bundle of patches that an overlay opts into with `components:`. Unlike a base, it does not hold resources; it holds changes. Three things were copy-pasted into every service's overlay in guides 2 and 3: the dev replica count, the prod canary steps and the Ingress host. All three are properties of the *environment and cluster*, not of the service, so they belong in one place per cluster and environment.

The patches target a *kind* and omit a name, so they apply to every Rollout or Ingress in the overlay that uses the component. A patch whose target matches nothing (service-2 has no Ingress) is simply skipped by Kustomize 5. That is what lets one component serve both services, and every future one.

### Phase 20.1: Components and slimmer overlays

#### Task 20.1.1: Create the four components

**Goal:** `kubernetes/components/{local,eks}-{dev,prod}/kustomization.yaml`, each holding that environment's rollout behavior and Ingress host.

**Why these four values:** they are the ones in today's overlays. The hosts are `dev.localhost`, `prod.localhost`, `dev.eks.test` and `prod.eks.test`.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
for cluster in local eks; do
  for env in dev prod; do
    case "$cluster-$env" in
      local-dev)  host=dev.localhost ;;
      local-prod) host=prod.localhost ;;
      eks-dev)    host=dev.eks.test ;;
      eks-prod)   host=prod.eks.test ;;
    esac
    dir="kubernetes/components/$cluster-$env"
    mkdir -p "$dir"
    {
      echo "apiVersion: kustomize.config.k8s.io/v1alpha1"
      echo "kind: Component"
      echo "patches:"
      if [[ "$env" == dev ]]; then
        cat <<'EOF'
  # DO NOT use kustomize's `replicas:` field. Its built-in transformer only
  # knows Deployment, ReplicaSet, StatefulSet and ReplicationController. A
  # Rollout is a custom resource, so `replicas:` matches nothing and reports
  # nothing: you get prod's replica count in dev and no sign anything is wrong.
  # A JSON6902 patch names the group and kind, so a mismatch is an error.
  #
  # No `name:` in the target, so this applies to every Rollout in the overlay.
  - target:
      group: argoproj.io
      version: v1alpha1
      kind: Rollout
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 1
EOF
      else
        cat <<'EOF'
  # Replaces the base's single-step strategy with a real canary.
  #
  # setWeight is a proportion of pods, not a traffic rule. With replicas: 2,
  # 50 means one canary pod beside one stable pod, and the existing ClusterIP
  # splits requests across them by endpoint count.
  #
  # `pause: {}` with no duration waits INDEFINITELY. That is the manual gate:
  # no timer is racing your judgment.
  - target:
      group: argoproj.io
      version: v1alpha1
      kind: Rollout
    patch: |-
      - op: replace
        path: /spec/strategy/canary/steps
        value:
          - setWeight: 50
          - pause: {}
          - setWeight: 100
EOF
      fi
      cat <<EOF
  # The base Ingress deliberately has no host, so it matches any Host header.
  # Two of those would collide in one cluster, so each environment adds its own.
  # A JSON6902 patch, because Ingress \`rules\` is a list with no merge key and a
  # strategic merge would replace the whole list. Services without an Ingress
  # are skipped: a patch that matches nothing is not an error.
  - target:
      kind: Ingress
    patch: |-
      - op: add
        path: /spec/rules/0/host
        value: $host
EOF
    } > "$dir/kustomization.yaml"
  done
done
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
ls -d kubernetes/components/*
for f in kubernetes/components/*/kustomization.yaml; do yq '.kind' "$f"; done | sort -u
yq '.patches[1].patch' kubernetes/components/eks-prod/kustomization.yaml | grep value
```
Expected: four directories, a single line `Component`, and `value: prod.eks.test`.

#### Task 20.1.2: Slim the service overlays

**Goal:** Each of the eight service overlays holds only its namespace, its base, its component, and its image. The Postgres overlays are not touched.

**Why a script and not by hand:** eight files, and the one thing that must survive exactly is `images[0].newTag`, because that is what CI and `release.sh` write. The script reads each file's own name and tag before overwriting it, and it is safe to run twice.

```bash
S="$PLATFORM_HOME/.tmp/g4"
cat > "$S/slim-overlays.sh" <<'EOF'
set -euo pipefail
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
for cluster in local eks; do for env in dev prod; do for svc in service-1 service-2; do
  f="kubernetes/overlays/$cluster/$env/$svc/kustomization.yaml"
  name="$(yq '.images[0].newName' "$f")"
  tag="$(yq '.images[0].newTag' "$f")"
  cat > "$f" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# Injected into every resource the base produces.
namespace: platform-$env
resources:
  - ../../../../base/$svc
# Replicas or canary steps, and the Ingress host, for this cluster and environment.
components:
  - ../../../../components/$cluster-$env
# The FULL image reference lives here, newName and newTag together. Splitting
# newName into the base does not work: the overlay's transformer runs against
# already-rewritten output, where the image is no longer the bare name it is
# trying to match.
#
# This newTag field is the only thing this service's CI ever writes.
images:
  - name: $svc
    newName: $name
    newTag: $tag
YAML
done; done; done
EOF
bash "$S/slim-overlays.sh"
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
wc -l kubernetes/overlays/eks/prod/service-1/kustomization.yaml
for f in kubernetes/overlays/*/*/service-*/kustomization.yaml; do yq '.images | length' "$f"; done | sort | uniq -c
git diff --stat -- kubernetes/overlays | tail -1
```
Expected: about 20 lines (it was about 55), `8 1` (eight overlays, each with exactly one image entry), and a diff summary touching eight files.

#### Task 20.1.3: Prove the render did not change

**Goal:** Every overlay in both clusters renders exactly the same manifests as before. This is the whole safety argument for Phase 20.1.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
rm -rf "$S/render-after"; mkdir -p "$S/render-after"
for cluster in local eks; do for env in dev prod; do for svc in service-1 service-2 postgres; do
  kustomize build "kubernetes/overlays/$cluster/$env/$svc" > "$S/render-after/$cluster-$env-$svc.yaml"
done; done; done
diff -r "$S/render-before" "$S/render-after" && echo IDENTICAL
```

**Validate:** the last line is `IDENTICAL` and `diff` printed nothing above it. If it prints differences, read them: a difference in an `image:` line means CI moved a tag between your snapshot and now (take a fresh snapshot of `main` to compare against); anything else is a bug in a component, so fix the component rather than the expectation.

Also run the contract check, which now also looks for the components:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
scripts/check-contract.sh
```
Expected: `OK: 2 services x 2 clusters x 2 environments match the registry.`

#### Task 20.1.4: Widen the code owners

**Goal:** The prod review gate covers the new places that can change prod, and no longer names a cluster, so a new cluster needs no edit.

**Why:** Components now carry the prod canary steps. Before this change, weakening the canary meant editing a file under `overlays/*/prod/`, which was gated. After it, the same change lives in `kubernetes/components/`, which is not. Without this edit the refactor would have quietly opened a hole in the release gate. `argocd/` is included because ApplicationSets now decide what is deployed, and `platform/` because it decides what exists.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
OWNER="$(yq '.owner' platform/registry.yaml)"
cat > .github/CODEOWNERS <<EOF
# Changes under these paths require review from the listed owner. This is the
# prod release gate, and it is why environment branches are unnecessary: a
# directory can be protected just as effectively as a branch.
#
# * matches one path segment, so these cover every cluster, including ones
# added later.
/kubernetes/overlays/*/prod/     @$OWNER

# Components carry each environment's rollout behavior, prod's canary gate
# included. Weakening the gate here would bypass the overlay rule above.
/kubernetes/components/          @$OWNER

# ApplicationSets decide what gets deployed where. The registry decides what exists.
/argocd/                         @$OWNER
/platform/                       @$OWNER
/addons/                         @$OWNER

# Terraform provisions both environments, so it gets the same treatment.
/terraform/                      @$OWNER

# Deliberately unowned: dev is meant to be continuous, and requiring review
# here would defeat the purpose of automated promotion.
# /kubernetes/overlays/*/dev/
EOF
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
grep -c '^/' .github/CODEOWNERS
grep -c 'YOUR_\|@$' .github/CODEOWNERS
```
Expected: `6` and `0`.

### Phase 20.2: Stage the ApplicationSets

#### Task 20.2.1: Correct the ArgoCD values and confirm the controller

**Goal:** `values/argocd.yaml` stops claiming the ApplicationSet controller is disabled, and the controller is confirmed running on the local cluster.

**Why now:** the file is applied by Terraform. Changing it triggers a Helm upgrade with no effective change on the next apply, so do it here, apply it once on local, and the later plan-based checks (Task 21.2.3) come back clean.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
python3 - <<'EOF'
import re, sys
new = """# Templated generation of Applications from Git. This platform uses it: the
# ApplicationSets under argocd/apps-<cluster>/appsets/ create every service,
# datastore and add-on Application from the directory tree.
#
# The argo-cd chart has no `applicationSet.enabled` value (in 7.x or 10.x), so
# the key that used to sit here did nothing and the controller ran regardless.
# It is removed rather than left to mislead. Budget roughly 50-100 MB for the
# controller, which the resource figures below already assume.
"""
for p in ["terraform/local/02-platform/values/argocd.yaml", "terraform/eks/02-platform/values/argocd.yaml"]:
    s = open(p).read()
    m = re.search(r"# Templated generation of Applications across many clusters\..*?applicationSet:\n  enabled: false\n", s, re.S)
    if not m:
        sys.exit(f"ERROR: {p}: the applicationSet block was not found. Edit it by hand.")
    open(p, "w").write(s[:m.start()] + new + s[m.end():])
    print("edited", p)
EOF
gmake up CLUSTER=local
```
`gmake up` runs Terraform for both stages. Stage 1 is a no-op; stage 2 upgrades the ArgoCD Helm release.

**Validate:**
```bash
kubectl --context k3d-platform -n argocd get deploy argocd-applicationset-controller
kubectl --context k3d-platform -n argocd get applications
grep -c 'applicationSet:' "$PLATFORM_HOME/lfi-infrastructure-gitops/terraform/local/02-platform/values/argocd.yaml"
```
Expected: the controller `1/1`, `root` plus six children still `Synced` and `Healthy`, and `0`.

#### Task 20.2.2: Write the ApplicationSets outside the watched directory

**Goal:** Four ApplicationSet manifests (services and data, for each cluster) staged in `$PLATFORM_HOME/.tmp/g4/appsets/`, **not** in the repo, where `root` would apply them before you are ready.

**Why staged:** The `root` Application syncs everything under `argocd/apps-local`, recursively, as soon as it lands on `main`. An ApplicationSet whose generator matches the directories that today's Applications already manage would start creating duplicates. Staging keeps them inert until Phase 20.3 moves them in at the right moment.

**What the services set says.** The generator finds every directory two levels under `kubernetes/overlays/<cluster>/`, which is `<environment>/<service>`, and excludes `postgres`. The template builds the Application's name from the service and the environment, exactly as today's files do, and points `source.path` at the directory. `path.segments` is the list `[kubernetes, overlays, <cluster>, <environment>, <service>]`, so index 3 is the environment.

**What the data set says.** Same discovery, but only `postgres`, and with every protection the hand-written Postgres Applications had: no prune, so a file removed from Git cannot delete the StatefulSet; `ignoreDifferences` for `volumeClaimTemplates`; no finalizer, so deleting the Application cannot delete the database; and `preserveResourcesOnDeletion`, so even deleting the *ApplicationSet* leaves the Postgres resources alone.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
URL="https://github.com/$(yq '.owner' platform/registry.yaml)/$(yq '.repo' platform/registry.yaml).git"
PREFIX="$(yq '.namespacePrefix' platform/registry.yaml)"
mkdir -p "$S/appsets"

for c in local eks; do
  sfx=""; [[ "$c" == eks ]] && sfx="-eks"

  cat > "$S/appsets/services-$c.yaml" <<EOF
# One Application per service per environment, discovered from the directory
# tree kubernetes/overlays/$c/<environment>/<service>. Adding a directory adds
# an Application. Deleting one removes it, and prune takes the workload with it.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: services-$c
  namespace: argocd
spec:
  # Go templates, with an error on any missing key instead of a silent blank.
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: $URL
        revision: HEAD
        directories:
          - path: kubernetes/overlays/$c/*/*
          # Datastores have their own ApplicationSet with a safer policy.
          - path: kubernetes/overlays/$c/*/postgres
            exclude: true
  template:
    metadata:
      # path.segments is [kubernetes, overlays, $c, <environment>, <service>],
      # so index 3 is the environment and basename is the service.
      name: '{{ .path.basename }}-{{ index .path.segments 3 }}$sfx'
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: default
      source:
        repoURL: $URL
        targetRevision: HEAD
        path: '{{ .path.path }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '$PREFIX-{{ index .path.segments 3 }}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        retry:
          limit: 3
          backoff:
            duration: 10s
            factor: 2
            maxDuration: 2m
EOF

  cat > "$S/appsets/data-$c.yaml" <<EOF
# Datastores. Same discovery as the services, but with every protection the
# hand-written postgres Applications had: no prune, no cascading delete, and
# the Application itself survives the directory being removed.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: data-$c
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  # If the postgres directory disappears from Git, leave the Application and
  # everything it deployed alone. Losing a database to a bad merge is not a
  # mistake Git history can undo.
  syncPolicy:
    preserveResourcesOnDeletion: true
    applicationsSync: create-update
  generators:
    - git:
        repoURL: $URL
        revision: HEAD
        directories:
          # To add another datastore, add a line here. Each one needs this policy.
          - path: kubernetes/overlays/$c/*/postgres
  template:
    metadata:
      name: '{{ .path.basename }}-{{ index .path.segments 3 }}$sfx'
      # No finalizer: deleting this Application must not delete the database.
    spec:
      project: default
      source:
        repoURL: $URL
        targetRevision: HEAD
        path: '{{ .path.path }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '$PREFIX-{{ index .path.segments 3 }}'
      syncPolicy:
        automated:
          # false: a file removed from Git must not delete the StatefulSet.
          prune: false
          selfHeal: true
        retry:
          limit: 3
          backoff:
            duration: 10s
            factor: 2
            maxDuration: 2m
      ignoreDifferences:
        # volumeClaimTemplates are immutable after creation and the API server
        # returns them with defaulted fields, which ArgoCD reads as permanent
        # drift. Without this the app sits OutOfSync forever.
        - group: apps
          kind: StatefulSet
          jsonPointers:
            - /spec/volumeClaimTemplates
EOF
done
ls "$S/appsets"
```

**Validate.** Three checks, none of which touch the cluster's state.

First, the cluster's API server accepts the manifests' shape (this catches a misspelled field or a policy value the installed CRD does not know):
```bash
S="$PLATFORM_HOME/.tmp/g4"
for f in services-local data-local; do
  kubectl --context k3d-platform apply --dry-run=server -f "$S/appsets/$f.yaml"
done
```
Expected: `applicationset.argoproj.io/services-local created (server dry run)` and the same for `data-local`. An `unknown field` error names the exact field; see Appendix I.

Second, the names the generators would produce are exactly the names that exist today. This reproduces the generator's naming rule in shell, for both clusters:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
for c in local eks; do
  sfx=""; [[ "$c" == eks ]] && sfx="-eks"
  generated="$(for d in kubernetes/overlays/$c/*/*; do echo "$(basename "$d")-$(basename "$(dirname "$d")")$sfx"; done | sort)"
  existing="$(yq -N '.metadata.name' argocd/apps-$c/*/*.yaml | sort)"
  if [[ "$generated" == "$existing" ]]; then echo "$c: names match ($(echo "$generated" | wc -l | tr -d ' ') Applications)"
  else echo "$c: MISMATCH"; diff <(echo "$generated") <(echo "$existing"); fi
done
```
Expected: `local: names match (6 Applications)` and `eks: names match (6 Applications)`. This is the adoption guarantee from the primer.

Third, the templates carry the same `spec` as the files they replace, apart from the path and namespace they fill in:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
cmp_spec() { # <template file> <existing application>; comment lines are ignored
  diff <(yq '.spec.template.spec | del(.source.path) | del(.destination.namespace)' "$1" | grep -v '^ *#') \
       <(yq '.spec | del(.source.path) | del(.destination.namespace)' "$2" | grep -v '^ *#') \
    && echo "same spec: $(basename "$1")"
}
cmp_spec "$S/appsets/services-local.yaml" argocd/apps-local/dev/service-1.yaml
cmp_spec "$S/appsets/data-local.yaml"     argocd/apps-local/dev/postgres.yaml
```
Expected: `same spec: services-local.yaml` and `same spec: data-local.yaml`. Any output from `diff` instead is a real difference in behavior. (Comment lines are filtered out, so wording differences never show here.)

---
### Phase 20.3: Cutover on the local cluster

**Objective:** Replace six hand-written Applications with two ApplicationSets on the running local cluster, and prove with pod identifiers that nothing was recreated.

**The plan, in four moves, each merged and verified before the next:**

| Move | Change in Git | What the cluster does | Danger if skipped |
|------|---------------|------------------------|-------------------|
| 1 | Overlays, components, registry (Phase 20.1) | Nothing. The render is identical. | None, but it proves the refactor is inert. |
| 2 | Remove the finalizer from the six Applications | Children lose their delete-cascade | Move 3 would delete the workloads, database included. |
| 3 | Delete the six Application files | `root` prunes six Applications. The workloads keep running, unmanaged, for a few minutes. | Deleting with finalizers still present deletes everything. |
| 4 | Add the ApplicationSets | They generate six Applications with the same names, which re-adopt the running workloads | Adding them at the same time as move 3 risks the controller and `root` fighting over the same names. |

**Only run this phase with EKS down.** The EKS cluster, if it existed, would hold its own six hand-written Applications and need the same four moves. With it down, `argocd/apps-eks` can change in one step (Task 20.3.5) because a cluster that gets created later simply reads the new layout. If you left EKS up, destroy it (`gmake destroy CLUSTER=eks`) before continuing. That costs nothing you built: everything on it is reproduced from Git.

#### Task 20.3.1: Confirm the preconditions and record pod identity

**Goal:** Three facts true before you start, and the identifiers to compare against at every later step.

```bash
S="$PLATFORM_HOME/.tmp/g4"
cat > "$S/uids.sh" <<'EOF'
#!/usr/bin/env bash
# Prints "<kind>/<name> <uid>" for every pod and claim in both environments of
# the local cluster. The same output before and after a change means nothing
# was recreated: a recreated pod has a new name and a new uid.
PREFIX="$(yq '.namespacePrefix' "$PLATFORM_HOME/lfi-infrastructure-gitops/platform/registry.yaml")"
for env in dev prod; do
  kubectl --context k3d-platform -n "$PREFIX-$env" get pods,pvc \
    -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.metadata.uid}{"\n"}{end}'
done | sort
EOF
cat > "$S/refresh.sh" <<'EOF'
#!/usr/bin/env bash
# Asks ArgoCD to re-read Git for every Application now, instead of waiting up to
# three minutes for the next poll.
for a in $(kubectl --context k3d-platform -n argocd get applications -o name); do
  kubectl --context k3d-platform -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
done
EOF
chmod +x "$S/uids.sh" "$S/refresh.sh"

kubectl config get-contexts -o name | grep -c '^lfi-eks$' || true
kubectl --context k3d-platform -n argocd get applications
kubectl --context k3d-platform get rollouts -A
"$S/uids.sh" | tee "$S/uids-cutover-before.txt" | wc -l
```

**Validate:** the context count is `0` (EKS is not registered; if it is `1`, stop as described above), all seven Applications are `Synced` and `Healthy`, every Rollout is `Healthy` with none mid-canary (a rollout in flight makes pod identity a moving target), and the last number matches the count from Task 19.1.3.

#### Task 20.3.2: Move 1: ship the restructure

**Goal:** Phase 20.1's work on `main`, with the cluster unaffected.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
git add platform scripts/reg.sh scripts/check-contract.sh kubernetes/components kubernetes/overlays \
        .github/CODEOWNERS terraform/local/02-platform/values/argocd.yaml terraform/eks/02-platform/values/argocd.yaml
git status --short | head -30
bash "$S/ship.sh" "refactor: registry, components and slimmer overlays"
"$S/refresh.sh"
```

**Validate:** wait a minute, then:
```bash
S="$PLATFORM_HOME/.tmp/g4"
kubectl --context k3d-platform -n argocd get applications
diff "$S/uids-cutover-before.txt" <("$S/uids.sh") && echo NOTHING RECREATED
```
Expected: seven Applications `Synced` and `Healthy`, and `NOTHING RECREATED` with no `diff` output above it. The `git status` listing before the ship should show only the paths you staged.

#### Task 20.3.3: Move 2: remove the finalizers

**Goal:** None of the six child Applications carries `resources-finalizer.argocd.argoproj.io` any more.

**Why:** see the primer. This is the step that makes Move 3 safe, so the Validate is a guard, not a formality.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
sed -i '' '/^  finalizers:$/,/^    - resources-finalizer.argocd.argoproj.io$/d' argocd/apps-local/*/*.yaml
git diff --stat -- argocd | tail -1
git add argocd/apps-local
bash "$S/ship.sh" "cutover 1/3: drop finalizers from the local child Applications"
"$S/refresh.sh"
```

**Validate (the guard):**
```bash
LEFT="$(kubectl --context k3d-platform -n argocd get applications \
  -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.finalizers}{"\n"}{end}' \
  | grep -v '^root=' | grep -v '=$' || true)"
if [[ -z "$LEFT" ]]; then echo "SAFE: no child Application has a finalizer"; else echo "STOP: $LEFT"; fi
```
Expected: `git diff --stat` reports six files changed with 2 deletions each, and the guard prints `SAFE: no child Application has a finalizer`. The guard reads the **live** Applications, not Git. If it prints `STOP`, wait another minute and run it again; if it still prints `STOP`, remove the finalizer directly (Appendix I) and do **not** continue until it prints `SAFE`.

#### Task 20.3.4: Move 3: delete the six Application files

**Goal:** `root` prunes the six child Applications. The workloads stay.

**Why a placeholder file:** `root` watches `argocd/apps-local`. Git does not store empty directories, so deleting the last files would remove the path, and `root` would report that the path does not exist and stop syncing, which is a worse state than the one you are trying to reach. A `README.md` keeps the directory. ArgoCD reads only YAML and JSON from a directory source, so the file is inert.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
git rm -q -r argocd/apps-local/dev argocd/apps-local/prod
cat > argocd/apps-local/README.md <<'EOF'
# apps-local

The local cluster's `root` Application watches this directory. It holds
ApplicationSets under `appsets/`, which generate every other Application from
the directory tree. There are no hand-written service Applications here.
EOF
git add argocd/apps-local/README.md
git status --short
bash "$S/ship.sh" "cutover 2/3: remove the local child Applications (ApplicationSets follow)"
"$S/refresh.sh"
```

**Validate:** give it a minute or two.
```bash
S="$PLATFORM_HOME/.tmp/g4"
kubectl --context k3d-platform -n argocd get applications
kubectl --context k3d-platform -n platform-dev get pods
kubectl --context k3d-platform -n platform-prod get pods
diff "$S/uids-cutover-before.txt" <("$S/uids.sh") && echo NOTHING RECREATED
```
Expected: only `root` is left, all pods in both environments are still `Running` and `Ready`, and `NOTHING RECREATED`. This is the state where the services exist but no Application owns them. It is safe to pause here for as long as you like, but do not leave it for days: nothing is watching them for drift.

#### Task 20.3.5: Move 4: add the ApplicationSets

**Goal:** `services-local` and `data-local` exist, generate the six Applications under their old names, and those Applications re-adopt the running workloads. The EKS tree receives its ApplicationSets at the same time.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
mkdir -p argocd/apps-local/appsets argocd/apps-eks/appsets
cp "$S/appsets/services-local.yaml" argocd/apps-local/appsets/services.yaml
cp "$S/appsets/data-local.yaml"     argocd/apps-local/appsets/data.yaml
cp "$S/appsets/services-eks.yaml"   argocd/apps-eks/appsets/services.yaml
cp "$S/appsets/data-eks.yaml"       argocd/apps-eks/appsets/data.yaml

# EKS is down, so its hand-written Applications can go in the same step.
git rm -q -r argocd/apps-eks/dev argocd/apps-eks/prod
sed 's/apps-local/apps-eks/; s/local cluster/EKS cluster/' argocd/apps-local/README.md > argocd/apps-eks/README.md

scripts/check-contract.sh
git add argocd
bash "$S/ship.sh" "cutover 3/3: ApplicationSets generate the service and data Applications"
"$S/refresh.sh"
```

**Validate:** wait up to three minutes. The ApplicationSet controller polls Git on its own interval, so the refresh above speeds `root` but not necessarily the set.
```bash
S="$PLATFORM_HOME/.tmp/g4"
kubectl --context k3d-platform -n argocd get applicationsets
kubectl --context k3d-platform -n argocd get applications
diff "$S/apps-before.txt" <(kubectl --context k3d-platform -n argocd get applications -o name | sort) && echo SAME NAMES
diff "$S/uids-cutover-before.txt" <("$S/uids.sh") && echo NOTHING RECREATED
kubectl --context k3d-platform -n argocd get application service-1-dev -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
kubectl --context k3d-platform -n argocd get application postgres-prod -o jsonpath='prune={.spec.syncPolicy.automated.prune} finalizers={.metadata.finalizers}{"\n"}'
```
Expected: `services-local` and `data-local` listed; `root` plus six children all `Synced` and `Healthy`; `SAME NAMES`; `NOTHING RECREATED`; `ApplicationSet`; and `prune=false finalizers=`.

If the set produces no Applications after five minutes, or they appear `OutOfSync` or `Missing`, read the controller log before touching anything:
```bash
kubectl --context k3d-platform -n argocd logs deploy/argocd-applicationset-controller --tail=50
```
The usual causes, and how to roll back, are in Appendix I.

### Phase 20.4: Scripts read the registry

#### Task 20.4.1: Replace the hard-coded service and cluster lists

**Goal:** Adding a service or a cluster to the registry is enough for `gmake status`, `release`, `canary` and `rollback` to offer it. Nothing in `scripts/` names `service-1`, `service-2`, `platform-prod` or a cluster context any more, except in comments.

**Why:** before this, a new service was in Git and ArgoCD and invisible to every command, so the first time you tried `gmake release` for it, it would not be on the menu. The three hard-coded "service-2 goes first" hints become a question the registry answers (`dependsOn`).

Snapshot what `gmake status` says today, so you can prove the output did not change:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
gmake status CLUSTER=local ENVIRONMENT=both > "$S/status-before.txt" 2>&1
wc -l < "$S/status-before.txt"
```

Now the edit. It refuses to run if any script differs from what it expects, rather than half-editing it:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
python3 - <<'PYEOF'
import sys

def edit(path, pairs):
    s = open(path).read()
    for old, new in pairs:
        # Exactly one match or stop. A script that has drifted from what this
        # edit expects must fail here, not get half-edited.
        if s.count(old) != 1:
            sys.exit(f"ERROR: {path}: expected one match, found {s.count(old)} for:\n{old[:120]}")
        s = s.replace(old, new)
    open(path, "w").write(s)

edit("scripts/lib.sh", [
("""LFI_CLUSTERS=(local eks)
LFI_SERVICES=(service-1 service-2)
LFI_STAGES=(dev prod)
""", """# LFI_CLUSTERS, LFI_SERVICES, LFI_STAGES, NAMESPACE_PREFIX and the cluster_* and
# service_* readers all come from platform/registry.yaml, so adding a service or
# a cluster never means editing this file.
source "$(dirname "${BASH_SOURCE[0]}")/reg.sh"
"""),
("""cluster_context() {
  case "$1" in
    local) echo "k3d-platform" ;;
    eks)   echo "lfi-eks" ;;
    *)     return 1 ;;
  esac
}

""", ""),
("""  menu_note() {
    case "$1" in
      service-1) echo "the gateway. Calls service-2." ;;
      service-2) echo "the worker. Release and promote it first." ;;
      both)      echo "service-1 and service-2" ;;
    esac
  }
  pick_generic "service\"""", """  menu_note() {
    case "$1" in
      both) echo "${LFI_SERVICES[*]}" ;;
      *)    service_role "$1" ;;
    esac
  }
  pick_generic "service\""""),
("""# show_equivalent <command>: only when a question was actually asked.""",
"""# first_to_promote <service...>: of the services given, the first that another of
# them depends on, or the first one given if none does. Dependencies go first so
# each canary judgment is about one change.
first_to_promote() {
  local s d
  for s in "$@"; do
    for d in "$@"; do
      [[ "$d" == "$s" ]] && continue
      [[ " $(service_deps "$d" | tr '\\n' ' ') " == *" $s "* ]] && { echo "$s"; return 0; }
    done
  done
  echo "$1"
}

# called_by_note <service>: ": it is called by service-1", or nothing.
called_by_note() {
  local d
  d="$(service_dependents "$1" | tr '\\n' ' ')"
  [[ -n "$d" ]] && echo ": it is called by ${d% }"
  return 0
}

# show_equivalent <command>: only when a question was actually asked."""),
])

edit("scripts/canary.sh", [
("""NAMESPACE="${NAMESPACE:-platform-prod}\"""", """NAMESPACE="${NAMESPACE:-${NAMESPACE_PREFIX}-prod}\""""),
("""    "gmake canary ACTION=promote CLUSTER=local SVC=service-2\"""", """    "gmake canary ACTION=promote CLUSTER=local SVC=${LFI_SERVICES[0]}\""""),
("""  is_tty || usage_error "SVC is required (service-1 or service-2)." \\
    "gmake canary ACTION=${ACTION} CLUSTER=${CLUSTER_NAME} SVC=service-2\"""", """  is_tty || usage_error "SVC is required (one of: ${LFI_SERVICES[*]})." \\
    "gmake canary ACTION=${ACTION} CLUSTER=${CLUSTER_NAME} SVC=${LFI_SERVICES[0]}\""""),
("""    DEFAULT="service-2"
    echo
    echo "  Both are rolling out. service-2 goes first: service-1 calls it.\"""", """    DEFAULT="$(first_to_promote "${IN_FLIGHT[@]}")"
    echo
    echo "  Several are rolling out. ${DEFAULT} goes first$(called_by_note "$DEFAULT").\""""),
("""usage_error "SVC must be service-1 or service-2 (got '${SVC}').\"""", """usage_error "SVC must be one of: ${LFI_SERVICES[*]} (got '${SVC}').\""""),
("""    [[ "$SVC" == "service-2" ]] && STEPS=("gmake canary          now promote service-1 if it is in this release" "${STEPS[@]}")""", """    DEPENDENTS="$(service_dependents "$SVC" | tr '\\n' ' ')"
    [[ -n "$DEPENDENTS" ]] && STEPS=("gmake canary          now promote ${DEPENDENTS}if it is in this release" "${STEPS[@]}")"""),
])

edit("scripts/status.sh", [
("""    ns="platform-${stage}\"""", """    ns="${NAMESPACE_PREFIX}-${stage}\""""),
("Promote service-2 first.", "Promote dependencies first."),
])

edit("scripts/release.sh", [
("""BODY+=$'\\n'"Promote **service-2 before service-1**: service-1 calls service-2, so"
BODY+=" promoting the dependency first keeps each canary judgment about one change.\"""", """for svc in "${LFI_SERVICES[@]}"; do
  for dep in $(service_deps "$svc"); do
    BODY+=$'\\n'"Promote **${dep} before ${svc}**: ${svc} calls ${dep}, so promoting the dependency"
    BODY+=" first keeps each canary judgment about one change."
  done
done"""),
("""git add kubernetes/overlays/local/prod kubernetes/overlays/eks/prod""", """for c in "${LFI_CLUSTERS[@]}"; do git add "kubernetes/overlays/$c/prod"; done"""),
("""promote it. service-2 first: service-1 calls it.\"""", """promote it. Dependencies first, as the PR says.\""""),
])
print("Edited lib.sh, canary.sh, status.sh and release.sh.")
PYEOF
```

**Validate:** the scripts parse, the readers return what the registry says, and `gmake status` prints exactly what it did before.
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
for f in scripts/*.sh; do bash -n "$f" || echo "SYNTAX ERROR in $f"; done
bash -c 'source scripts/lib.sh; echo "clusters: ${LFI_CLUSTERS[*]}"; echo "services: ${LFI_SERVICES[*]}"; echo "first to promote: $(first_to_promote service-1 service-2)"; echo "note: $(called_by_note service-2)"'
grep -n 'platform-\|k3d-platform\|lfi-eks\|service-[12]' scripts/*.sh | grep -v '^\S*:[0-9]*:\s*#' | grep -v 'reg.sh'
gmake status CLUSTER=local ENVIRONMENT=both > "$S/status-after.txt" 2>&1
diff "$S/status-before.txt" "$S/status-after.txt" && echo STATUS UNCHANGED
```
Expected: no `SYNTAX ERROR`; `clusters: local eks`, `services: service-1 service-2`, `first to promote: service-2`, `note: : it is called by service-1`; the `grep` prints only lines that mention a service inside an example string or usage message (none should name `platform-`, `k3d-platform` or `lfi-eks`); and `STATUS UNCHANGED`. The `grep` is informational: review what it prints rather than expecting silence.

Ship it:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git add scripts
bash "$PLATFORM_HOME/.tmp/g4/ship.sh" "scripts: read services, clusters and namespaces from the registry"
```

### Phase 20.5: The scaffolder

#### Task 20.5.1: The service template

**Goal:** `kubernetes/templates/service/` holds a minimal, correct base for a new service, with three placeholders.

**Why minimal:** a template that carries Postgres wiring, a sidecar and an Ingress makes every service inherit things it may not want, and deleting lines is easier to get wrong than adding them. The template is a Rollout and a Service. A service that needs a database adds the `postgres-credentials` env as service-1's base shows. One that needs public HTTP adds an Ingress; the environment components already patch any Ingress they find.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
mkdir -p kubernetes/templates/service
cat > kubernetes/templates/service/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - rollout.yaml
  - service.yaml
labels:
  - pairs:
      app.kubernetes.io/part-of: local-platform
    includeTemplates: true
EOF
cat > kubernetes/templates/service/rollout.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: __NAME__
  labels:
    app: __NAME__
spec:
  # The prod default. The dev component patches this down to 1.
  replicas: 2
  progressDeadlineSeconds: 600
  selector:
    matchLabels:
      app: __NAME__
  strategy:
    canary:
      # One step, straight to 100%. The prod component replaces these steps
      # with the 50 percent pause.
      steps:
        - setWeight: 100
  template:
    metadata:
      labels:
        app: __NAME__
    spec:
      containers:
        - name: __NAME__
          # Bare name, rewritten by the overlay's images: block.
          image: __NAME__
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: __PORT__
          livenessProbe:
            httpGet:
              path: __HEALTH__
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: __HEALTH__
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              memory: 128Mi
EOF
cat > kubernetes/templates/service/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: __NAME__
  labels:
    app: __NAME__
spec:
  type: ClusterIP
  selector:
    app: __NAME__
  ports:
    - name: http
      port: __PORT__
      targetPort: http
EOF
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
grep -c '__NAME__' kubernetes/templates/service/*.yaml
yq -N '.kind' kubernetes/templates/service/rollout.yaml kubernetes/templates/service/service.yaml | tr '\n' ' '; echo
```
Expected: `kustomization.yaml:0`, `rollout.yaml:6`, `service.yaml:3`, then `Rollout Service`. The placeholders make the template invalid for Kubernetes until the scaffolder fills them, which is intended: nothing can apply it by accident, and no generator matches `kubernetes/templates/`.

#### Task 20.5.2: The scaffold script

**Goal:** `scripts/new-service.sh <name> --image ... --tag ...` creates a service's base, every overlay the registry calls for, and the registry entry, then prints what to do in the service's own repo.

**Why it writes overlays for every cluster and environment:** that is the contract Task 19.2.2 checks and the one CI's `MANIFESTS` list depends on. A scaffolder that produced only `local/dev` would create exactly the drift the check exists to catch.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
cat > scripts/new-service.sh <<'XEOF'
#!/usr/bin/env bash
# Scaffolds a service: a base from kubernetes/templates/service, one overlay for
# every cluster and environment in platform/registry.yaml, and a registry entry.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/reg.sh"

usage() {
  cat >&2 <<EOF
Usage: scripts/new-service.sh <name> --image <repo> --tag <tag> [options]
  --image <repo>    image repository without a tag, e.g. ghcr.io/you/orders
  --tag <tag>       first image tag to deploy, e.g. 1.0.0
  --port <n>        container port (default 8000)
  --health <path>   liveness and readiness path (default /healthz)
  --role <text>     one line for the menus (default: a service)
  --depends-on <s>  a service this one calls (repeatable)
EOF
  exit 1
}

NAME="${1:-}"; [[ -n "$NAME" ]] || usage; shift
PORT=8000; HEALTH=/healthz; IMAGE=""; TAG=""; ROLE="a service"; DEPS=()
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || usage
  case "$1" in
    --image) IMAGE="$2" ;;
    --tag) TAG="$2" ;;
    --port) PORT="$2" ;;
    --health) HEALTH="$2" ;;
    --role) ROLE="$2" ;;
    --depends-on) DEPS+=("$2") ;;
    *) usage ;;
  esac
  shift 2
done
[[ -n "$IMAGE" && -n "$TAG" ]] || usage

[[ "$NAME" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "ERROR: name must be lowercase letters, digits and dashes." >&2; exit 1; }
[[ "$NAME" != postgres ]] || { echo "ERROR: postgres is handled by the data ApplicationSet." >&2; exit 1; }
[[ " ${LFI_SERVICES[*]} " != *" $NAME "* ]] || { echo "ERROR: $NAME is already in the registry." >&2; exit 1; }
[[ ! -e "kubernetes/base/$NAME" ]] || { echo "ERROR: kubernetes/base/$NAME already exists." >&2; exit 1; }
# `${DEPS[@]+...}` because bash 3.2 treats an empty array as unset under set -u.
for d in ${DEPS[@]+"${DEPS[@]}"}; do
  [[ " ${LFI_SERVICES[*]} " == *" $d "* ]] || { echo "ERROR: --depends-on $d is not in the registry." >&2; exit 1; }
done

mkdir -p "kubernetes/base/$NAME"
for f in kustomization.yaml rollout.yaml service.yaml; do
  sed -e "s#__NAME__#$NAME#g" -e "s#__PORT__#$PORT#g" -e "s#__HEALTH__#$HEALTH#g" \
    "kubernetes/templates/service/$f" > "kubernetes/base/$NAME/$f"
done

for cluster in "${LFI_CLUSTERS[@]}"; do
  for env in "${LFI_STAGES[@]}"; do
    dir="kubernetes/overlays/$cluster/$env/$NAME"
    mkdir -p "$dir"
    cat > "$dir/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${NAMESPACE_PREFIX}-${env}
resources:
  - ../../../../base/${NAME}
components:
  - ../../../../components/${cluster}-${env}
images:
  - name: ${NAME}
    newName: ${IMAGE}
    newTag: ${TAG}
EOF
  done
done

N="$NAME" R="$ROLE" yq -i '.services += [{"name": strenv(N), "role": strenv(R)}]' "$REGISTRY"
for d in ${DEPS[@]+"${DEPS[@]}"}; do
  N="$NAME" D="$d" yq -i '(.services[] | select(.name == strenv(N)) | .dependsOn) += [strenv(D)]' "$REGISTRY"
done

echo "Created kubernetes/base/$NAME, ${#LFI_CLUSTERS[@]} x ${#LFI_STAGES[@]} overlays, and a registry entry for $NAME."
echo
echo "Next, in the service's own repository, .github/workflows/ci.yaml:"
echo "  env.IMAGE_NAME: $NAME        promote job: SERVICE: $NAME"
echo "  MANIFESTS=("
for cluster in "${LFI_CLUSTERS[@]}"; do
  echo "    \"kubernetes/overlays/$cluster/dev/\${SERVICE}/kustomization.yaml\""
done
echo "  )"
echo
echo "Then: scripts/check-contract.sh, commit, merge. ArgoCD creates ${NAME}-<env> on its own."
XEOF
chmod +x scripts/new-service.sh
```

**Validate.** Prove it works on a disposable copy, so the repo is untouched:
```bash
S="$PLATFORM_HOME/.tmp/g4"
rm -rf "$S/scaffold-test"; mkdir -p "$S/scaffold-test"
rsync -a --exclude .git --exclude .terraform --exclude .generated "$PLATFORM_HOME/lfi-infrastructure-gitops/" "$S/scaffold-test/"
cd "$S/scaffold-test"
scripts/new-service.sh demo --image ghcr.io/example/demo --tag 1.0.0 --port 9898 --role "a throwaway demo"
for c in local eks; do for e in dev prod; do
  kustomize build kubernetes/overlays/$c/$e/demo | yq -N 'select(.kind == "Rollout") | "'"$c $e"' replicas=" + (.spec.replicas | tostring) + " ns=" + .metadata.namespace'
done; done
scripts/check-contract.sh
scripts/new-service.sh demo --image x --tag 1 2>&1 | tail -1
scripts/new-service.sh other --image x --tag 1 --depends-on nope 2>&1 | tail -1
```
Expected: four lines, `local dev replicas=1 ns=platform-dev`, `local prod replicas=2 ns=platform-prod`, then the same two for `eks`; then `OK: 3 services x 2 clusters x 2 environments match the registry.`; then `ERROR: demo is already in the registry.`; then `ERROR: --depends-on nope is not in the registry.` The last two show the script refuses bad input **before** writing anything. Delete the copy afterwards with `rm -rf "$S/scaffold-test"`.

Ship it:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git add kubernetes/templates scripts/new-service.sh
bash "$PLATFORM_HOME/.tmp/g4/ship.sh" "add the service template and scaffold script"
```

### Phase 20.6: Plug-in drill (local)

**Objective:** Add a real service by adding directories, see it appear, remove it by removing directories, see it vanish, and prove the existing services never noticed.

The service is **podinfo**, a small public demo application. It needs no database, listens on 9898 and serves `/healthz`. It is a stand-in for whatever you build next.

#### Task 20.6.1: Plug a service in

**Goal:** `demo-dev` and `demo-prod` Applications appear on the local cluster, healthy, from one scaffold command and one merge.

First confirm the image tag exists; pick any published tag from the project's release page if this one does not:
```bash
docker manifest inspect ghcr.io/stefanprodan/podinfo:6.7.1 >/dev/null && echo "tag exists"
```
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
"$S/uids.sh" > "$S/uids-drill-before.txt"
scripts/new-service.sh demo --image ghcr.io/stefanprodan/podinfo --tag 6.7.1 \
  --port 9898 --health /healthz --role "a throwaway demo"
scripts/check-contract.sh
git add kubernetes platform
bash "$S/ship.sh" "drill: plug in the demo service"
"$S/refresh.sh"
kubectl --context k3d-platform -n argocd annotate applicationset services-local \
  argocd.argoproj.io/application-set-refresh=true --overwrite
```
The last line asks the controller to re-read Git now; if your version ignores it, the set notices within three minutes anyway.

**Validate:**
```bash
S="$PLATFORM_HOME/.tmp/g4"
kubectl --context k3d-platform -n argocd get applications | grep -E 'NAME|demo'
kubectl --context k3d-platform -n platform-dev get pods -l app=demo
kubectl --context k3d-platform -n platform-prod get pods -l app=demo
kubectl --context k3d-platform -n platform-dev port-forward svc/demo 19898:9898 >/dev/null 2>&1 &
PF=$!; sleep 3; curl -s http://localhost:19898/healthz; echo; kill $PF
diff "$S/uids-drill-before.txt" <("$S/uids.sh" | grep -v 'demo') && echo EXISTING SERVICES UNTOUCHED
```
Expected: `demo-dev` and `demo-prod` `Synced` and `Healthy`; one `demo` pod in dev and two in prod, all `Running`; `{"status":"OK"}` from the health check; and `EXISTING SERVICES UNTOUCHED`. Image pulls on a cold node take a minute or two, so repeat the first commands until the pods are `Running`.

#### Task 20.6.2: Plug it out

**Goal:** Deleting the directories removes the Applications and the pods, and leaves everything else alone.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
git rm -q -r kubernetes/base/demo kubernetes/overlays/local/dev/demo kubernetes/overlays/local/prod/demo \
             kubernetes/overlays/eks/dev/demo kubernetes/overlays/eks/prod/demo
yq -i 'del(.services[] | select(.name == "demo"))' platform/registry.yaml
scripts/check-contract.sh
git add platform
bash "$S/ship.sh" "drill: plug out the demo service"
"$S/refresh.sh"
kubectl --context k3d-platform -n argocd annotate applicationset services-local \
  argocd.argoproj.io/application-set-refresh=true --overwrite
```

**Validate:** within a few minutes:
```bash
S="$PLATFORM_HOME/.tmp/g4"
kubectl --context k3d-platform -n argocd get applications
kubectl --context k3d-platform get pods -A -l app=demo
diff "$S/uids-drill-before.txt" <("$S/uids.sh") && echo BACK TO THE START
```
Expected: `root` plus the six original children, `No resources found` for the demo pods, and `BACK TO THE START`. The namespaces remain because Terraform owns them, and the registry is back to two services.

**Checkpoint.** Section 20 is a complete outcome on its own: a local platform whose services are plugged in and out by directory. Everything after this is making the same true across clusters and for add-ons.

---
## Section 21: Add-ons and multi-cluster

**Objective:** Platform software (metrics-server now, Prometheus and Grafana in guide 5) is enabled on a cluster by adding a directory, cluster identity is written once, EKS can hold the extra pods, and a new project can be stamped from this repo. EKS is brought up once, in Phase 21.5, to prove all of it.

### Primer: why add-ons are not services

A service is your code, released weekly through a canary, with an image tag that CI writes. An add-on is someone else's software, installed from a Helm chart at a pinned version, upgraded when you choose. They need different policies (no canary, no CI-written tag, a chart repository instead of a base), and mixing them into `kubernetes/overlays/` would make `gmake release` offer to release Prometheus.

So add-ons get their own tree and their own ApplicationSet, built the same way: a directory per add-on per cluster, `addons/<cluster>/<name>/`, holding two files.

- `addon.yaml` says *what*: the add-on's name, the namespace it lives in, and the chart (repository, name, version).
- `values.yaml` says *how*: the chart's values, kept in Git next to everything else.

The ApplicationSet uses the **Git files generator**, which reads the contents of each `addon.yaml` and hands those fields to the template. Each Application has two sources: the Helm chart from its own repository, and this Git repo as a `ref` named `values`, so `values.yaml` is read from Git. Enabling an add-on on a cluster is the presence of its directory. Removing the directory removes it.

### Phase 21.1: The add-on layer

#### Task 21.1.1: The add-ons ApplicationSets

**Goal:** `addons-local` and `addons-eks` exist. Neither creates anything yet, because no `addon.yaml` exists.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
URL="https://github.com/$(yq '.owner' platform/registry.yaml)/$(yq '.repo' platform/registry.yaml).git"

for c in local eks; do
  cat > "argocd/apps-$c/appsets/addons.yaml" <<EOF
# One Application per directory addons/$c/<name>/ that holds an addon.yaml.
# The Git files generator reads each addon.yaml and passes its fields to the
# template, so the add-on's name, namespace and chart come from the file, not
# from here. Values come from values.yaml beside it.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: addons-$c
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: $URL
        revision: HEAD
        files:
          - path: addons/$c/*/addon.yaml
  template:
    metadata:
      name: 'addon-{{ .name }}-$c'
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: default
      # Two sources: the chart, and this repo under the name "values" so the
      # chart's valueFiles can point into it with \$values.
      sources:
        - repoURL: '{{ .chart.repo }}'
          chart: '{{ .chart.name }}'
          targetRevision: '{{ .chart.version }}'
          helm:
            releaseName: '{{ .name }}'
            # An add-on with no values.yaml runs on the chart's defaults.
            ignoreMissingValueFiles: true
            valueFiles:
              - '\$values/{{ .path.path }}/values.yaml'
        - repoURL: $URL
          targetRevision: HEAD
          ref: values
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{ .namespace }}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          # Add-ons create their own namespaces. Services never do: Terraform
          # owns those.
          - CreateNamespace=true
        retry:
          limit: 3
          backoff:
            duration: 10s
            factor: 2
            maxDuration: 2m
EOF
done

mkdir -p addons/local addons/eks
cat > addons/local/README.md <<'EOF'
# Local add-ons

One directory per add-on: `addons/local/<name>/addon.yaml` and `values.yaml`.
k3s already ships metrics-server, so this cluster starts with none. See
`addons/eks/metrics-server/` for the shape.
EOF
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
grep -c '\$values' argocd/apps-local/appsets/addons.yaml argocd/apps-eks/appsets/addons.yaml
kubectl --context k3d-platform apply --dry-run=server -f argocd/apps-local/appsets/addons.yaml
scripts/check-contract.sh
```
Expected: `2` for each file (one in a comment and one in the `valueFiles` line; the reference reached the file literally instead of being expanded by the shell), `applicationset.argoproj.io/addons-local created (server dry run)`, and `OK`. A `0` means the backslash was lost and the file has an empty expansion where `$values` belongs.

#### Task 21.1.2: The proof add-on: metrics-server on EKS

**Goal:** `addons/eks/metrics-server/` holds a real add-on, so the layer is exercised and `kubectl top` works on EKS.

**Why metrics-server:** it is small (requests of 25m and 48Mi here), useful on its own, and missing from EKS by default, while k3s ships it. `docs/resource_check.md` depends on `kubectl top`, so this closes a real gap between the two clusters. It is also the smallest thing that proves chart repository, version, values and namespace all flow through the generator.

The chart version is a fact to look up, not to trust from this guide. The command below asks the chart repository for the newest release and writes it into the file:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
helm repo update metrics-server
VER="$(helm search repo metrics-server/metrics-server -o json | yq -p=json '.[0].version')"
echo "chart version: $VER"

mkdir -p addons/eks/metrics-server
cat > addons/eks/metrics-server/addon.yaml <<EOF
name: metrics-server
namespace: kube-system
chart:
  repo: https://kubernetes-sigs.github.io/metrics-server/
  name: metrics-server
  version: "$VER"
EOF
cat > addons/eks/metrics-server/values.yaml <<'EOF'
# Requests only what the controller needs on a one-node cluster, and a memory
# limit so a leak cannot take the node. No CPU limit: throttling is recoverable.
resources:
  requests:
    cpu: 25m
    memory: 48Mi
  limits:
    memory: 128Mi
EOF
```

**Validate:** render the chart with your values, offline from any cluster:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
VER="$(yq '.chart.version' addons/eks/metrics-server/addon.yaml)"
helm template metrics-server metrics-server/metrics-server --version "$VER" \
  --namespace kube-system -f addons/eks/metrics-server/values.yaml > "$PLATFORM_HOME/.tmp/g4/metrics-server.yaml"
grep -c '^kind:' "$PLATFORM_HOME/.tmp/g4/metrics-server.yaml"
grep -A3 'requests:' "$PLATFORM_HOME/.tmp/g4/metrics-server.yaml" | head -5
```
Expected: a count of at least `8` resources, and `cpu: 25m` and `memory: 48Mi` under `requests`. The second line proves the `resources` key in your values file is a real key in this chart version. If it prints the chart's default (`cpu: 100m`), the key name differs in this version: read `helm show values metrics-server/metrics-server --version "$VER"` and fix `values.yaml`.

Ship Phase 21.1:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git add argocd addons
bash "$PLATFORM_HOME/.tmp/g4/ship.sh" "add the add-on layer and metrics-server for EKS"
```
```bash
kubectl --context k3d-platform -n argocd get applicationsets
kubectl --context k3d-platform -n argocd get applications | wc -l
```
Expected after a minute or two: `services-local`, `data-local` and `addons-local` listed, and `7` lines from the second command (a header plus `root` plus six children). The local cluster gained an ApplicationSet that generates nothing, and lost nothing.

### Phase 21.2: One source of truth for cluster identity

**Objective:** The cluster's name, context, region, namespace prefix and Terraform state keys are each written once, in the registry, and the Makefile and Terraform read them.

#### Task 21.2.1: The Makefile reads the registry

**Goal:** Nothing in the Makefile spells a cluster name. The Terraform state key is passed on the command line. `gmake add-service` exists.

**Why the state key moves:** Terraform cannot read variables inside a `backend` block, so `lfi-eks/01-cluster/...` sat there as a literal, and a second project would have to edit four files to avoid writing into the first one's state. Passing it with `-backend-config` from the registry fixes that. The *values* are exactly the ones already in S3, so no state moves.

The edit refuses to run if the Makefile is not what it expects:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
python3 - <<'PYEOF'
import sys

def edit(path, pairs):
    s = open(path).read()
    for old, new in pairs:
        if s.count(old) != 1:
            sys.exit(f"ERROR: {path}: expected one match, found {s.count(old)} for:\n{old[:120]}")
        s = s.replace(old, new)
    open(path, "w").write(s)

edit("Makefile", [
# 1. Identity comes from the registry.
("""# The k3d cluster's name. Not CLUSTER: that word is reserved for the question every
# command asks, local or eks, so CLUSTER=eks on the command line cannot clobber it.
K3D_CLUSTER := platform

# Used by resume. Also here because ad-hoc kubectl commands want it.
CONTEXT  := k3d-$(K3D_CLUSTER)

EKS_CLUSTER := lfi-eks
EKS_REGION  := ap-southeast-2
EKS_CONTEXT := $(EKS_CLUSTER)
""", """# Cluster identity comes from platform/registry.yaml, the one place it is written.
# Not CLUSTER: that word is reserved for the question every command asks, local
# or eks, so CLUSTER=eks on the command line cannot clobber these.
REGISTRY := platform/registry.yaml
reg = $(shell yq '$(1)' $(REGISTRY))

K3D_CLUSTER      := $(call reg,.clusters[] | select(.kind == "k3d") | .clusterName)
EKS_CLUSTER      := $(call reg,.clusters[] | select(.kind == "eks") | .clusterName)
EKS_REGION       := $(call reg,.clusters[] | select(.kind == "eks") | .region)
STATE_LOCAL      := $(call reg,.clusters[] | select(.kind == "k3d") | .stateKeyPrefix)
STATE_EKS        := $(call reg,.clusters[] | select(.kind == "eks") | .stateKeyPrefix)
NAMESPACE_PREFIX := $(call reg,.namespacePrefix)

# An empty value means yq is missing or the registry is unreadable. Stop here
# rather than let Terraform run with a blank cluster name.
$(if $(and $(K3D_CLUSTER),$(EKS_CLUSTER),$(EKS_REGION),$(STATE_LOCAL),$(STATE_EKS),$(NAMESPACE_PREFIX)),,$(error Could not read $(REGISTRY). Is yq installed?))

# Used by resume. Also here because ad-hoc kubectl commands want it.
CONTEXT     := k3d-$(K3D_CLUSTER)
EKS_CONTEXT := $(EKS_CLUSTER)
"""),
# 2. The .env bridge gains the namespace prefix; new bridges for the registry.
("""export TF_VAR_gitops_repo_url="$$GITOPS_REPO_URL"
endef
""", """export TF_VAR_gitops_repo_url="$$GITOPS_REPO_URL"
export TF_VAR_namespace_prefix="$(NAMESPACE_PREFIX)"
endef

# The same bridge for what the registry owns. These are variables without
# defaults in Terraform, so a run that forgets them fails instead of guessing
# a cluster.
define local_env
export TF_VAR_cluster_name="$(K3D_CLUSTER)"
export TF_VAR_kube_context="$(CONTEXT)"
endef

define eks_env
export TF_VAR_cluster_name="$(EKS_CLUSTER)"
export TF_VAR_region="$(EKS_REGION)"
export TF_VAR_kube_context="$(EKS_CONTEXT)"
endef

# terraform init with the state key taken from the registry, so the backend
# blocks carry no cluster name. Call it as $(call tf_init,<state prefix>,<stage>).
# Same bucket and same keys as before the registry existed: nothing migrates.
define tf_init
terraform init -input=false -backend-config="key=$(1)/$(2)/terraform.tfstate"
endef
"""),
("""$(PASS) NAMESPACE=platform-prod ./scripts/canary.sh""", """$(PASS) NAMESPACE=$(NAMESPACE_PREFIX)-prod ./scripts/canary.sh"""),
("""        _local-cluster _local-platform _local-up _local-down _local-destroy \\
        _eks-cluster _eks-platform _eks-up _eks-down _eks-destroy""", """        _local-cluster _local-platform _local-up _local-down _local-destroy _local-plan \\
        _eks-cluster _eks-platform _eks-up _eks-down _eks-destroy _eks-plan add-service"""),
# 3. A new command.
("""##@ Ship
""", """##@ Extend

# Scaffolds a service: base, one overlay per cluster and environment, and a
# registry entry. Extra flags go in ARGS, e.g. ARGS="--port 9898 --health /healthz".
add-service: ## Scaffold a service. NAME=orders IMAGE=ghcr.io/you/orders TAG=1.0.0
	./scripts/new-service.sh "$(NAME)" --image "$(IMAGE)" --tag "$(TAG)" $(ARGS)

##@ Ship
"""),
# 4. Every Terraform call: registry variables and the state key on the command line.
("""_local-cluster: check-env
	cd terraform/local/01-cluster
# -input=false makes Terraform fail rather than prompt, which is what you want
# in a scripted path. A prompt here would mean a variable is missing.
	terraform init -input=false
	terraform apply -auto-approve -input=false

_local-platform: check-env
	$(tf_env)
	cd terraform/local/02-platform
	terraform init -input=false
	terraform apply -auto-approve -input=false
""", """_local-cluster: check-env
	$(local_env)
	cd terraform/local/01-cluster
# -input=false makes Terraform fail rather than prompt, which is what you want
# in a scripted path. A prompt here would mean a variable is missing.
	$(call tf_init,$(STATE_LOCAL),01-cluster)
	terraform apply -auto-approve -input=false

_local-platform: check-env
	$(tf_env)
	$(local_env)
	cd terraform/local/02-platform
	$(call tf_init,$(STATE_LOCAL),02-platform)
	terraform apply -auto-approve -input=false

# Plan only, both stages. Exit code 2 means there are changes. Used to prove a
# refactor changed nothing: it should exit 0 for both.
_local-plan: check-env
	$(tf_env)
	$(local_env)
	cd terraform/local/01-cluster
	$(call tf_init,$(STATE_LOCAL),01-cluster)
	terraform plan -input=false -detailed-exitcode
	cd ../02-platform
	$(call tf_init,$(STATE_LOCAL),02-platform)
	terraform plan -input=false -detailed-exitcode
"""),
("""_local-down: check-env
	$(tf_env)
	cd terraform/local/02-platform
	terraform destroy -auto-approve -input=false
""", """_local-down: check-env
	$(tf_env)
	$(local_env)
	cd terraform/local/02-platform
	$(call tf_init,$(STATE_LOCAL),02-platform)
	terraform destroy -auto-approve -input=false
"""),
("""	$(MAKE) _local-down || echo "WARNING: stage 2 destroy failed. Continuing to delete the cluster." >&2
	cd terraform/local/01-cluster
	terraform destroy -auto-approve -input=false
""", """	$(MAKE) _local-down || echo "WARNING: stage 2 destroy failed. Continuing to delete the cluster." >&2
	$(local_env)
	cd terraform/local/01-cluster
	$(call tf_init,$(STATE_LOCAL),01-cluster)
	terraform destroy -auto-approve -input=false
"""),
("""_eks-cluster:
	cd terraform/eks/01-cluster
	terraform init -input=false
	terraform apply -auto-approve -input=false
	aws eks update-kubeconfig --region $(EKS_REGION) --name $(EKS_CLUSTER) --alias $(EKS_CONTEXT)

_eks-platform: check-env
	$(tf_env)
	cd terraform/eks/02-platform
	terraform init -input=false
	terraform apply -auto-approve -input=false
""", """_eks-cluster:
	$(eks_env)
	cd terraform/eks/01-cluster
	$(call tf_init,$(STATE_EKS),01-cluster)
	terraform apply -auto-approve -input=false
	aws eks update-kubeconfig --region $(EKS_REGION) --name $(EKS_CLUSTER) --alias $(EKS_CONTEXT)

_eks-platform: check-env
	$(tf_env)
	$(eks_env)
	cd terraform/eks/02-platform
	$(call tf_init,$(STATE_EKS),02-platform)
	terraform apply -auto-approve -input=false

# Plan only, both stages. Exit code 2 means there are changes.
_eks-plan: check-env
	$(tf_env)
	$(eks_env)
	cd terraform/eks/01-cluster
	$(call tf_init,$(STATE_EKS),01-cluster)
	terraform plan -input=false -detailed-exitcode
	cd ../02-platform
	$(call tf_init,$(STATE_EKS),02-platform)
	terraform plan -input=false -detailed-exitcode
"""),
("""	kubectl --context $(EKS_CONTEXT) -n argocd delete application root --wait=true --timeout=180s || true
	$(tf_env)
	cd terraform/eks/02-platform
	terraform destroy -auto-approve -input=false
""", """	kubectl --context $(EKS_CONTEXT) -n argocd delete application root --wait=true --timeout=180s || true
	$(tf_env)
	$(eks_env)
	cd terraform/eks/02-platform
	$(call tf_init,$(STATE_EKS),02-platform)
	terraform destroy -auto-approve -input=false
"""),
("""	sleep 90
	cd terraform/eks/01-cluster
	terraform destroy -auto-approve -input=false
""", """	sleep 90
	$(eks_env)
	cd terraform/eks/01-cluster
	$(call tf_init,$(STATE_EKS),01-cluster)
	terraform destroy -auto-approve -input=false
"""),
])
print("Edited the Makefile.")
PYEOF
```

**Validate.** Do **not** use `gmake -n` on the destroy targets (see the safety rules at the top). The plan targets contain no `$(MAKE)`, so printing one is safe:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake help | grep -A1 Extend
gmake -n _eks-plan 2>&1 | grep -E 'TF_VAR_(cluster_name|region|kube_context)|terraform init'
gmake help REGISTRY=/nonexistent 2>&1 | tail -1
```
Expected: the `Extend` section listing `add-service`; `TF_VAR_cluster_name="lfi-eks"`, `TF_VAR_region="ap-southeast-2"`, `TF_VAR_kube_context="lfi-eks"`, and two `terraform init` lines carrying `-backend-config="key=lfi-eks/01-cluster/terraform.tfstate"` and `.../02-platform/...`; and `Makefile:...: *** Could not read /nonexistent. Is yq installed?.  Stop.` The last line is the guard: a wrong registry stops `gmake` before Terraform.

#### Task 21.2.2: Terraform stops naming the cluster

**Goal:** No `backend.tf` holds a state key, and the variables the registry owns have no defaults.

**Why remove the defaults:** a default is a second place the name lives. With `cluster_name = "lfi-eks"` still as a default, a stamped project that forgot to set the variable would quietly build a cluster called `lfi-eks` beside the original. With no default, Terraform stops and says which variable is missing. The kube-context guard that used to compare against the literal `lfi-eks` now compares against the cluster name, so it still refuses a stray context.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
python3 - <<'PYEOF'
import sys

def edit(path, pairs):
    s = open(path).read()
    for old, new in pairs:
        if s.count(old) != 1:
            sys.exit(f"ERROR: {path}: expected one match, found {s.count(old)} for:\n{old[:120]}")
        s = s.replace(old, new)
    open(path, "w").write(s)

# 1. The backend blocks stop naming a state key. The Makefile supplies it.
for stage, prefix in [("local/01-cluster", "local-platform"), ("local/02-platform", "local-platform"),
                      ("eks/01-cluster", "lfi-eks"), ("eks/02-platform", "lfi-eks")]:
    stage_dir = stage.split("/")[1]
    edit(f"terraform/{stage}/backend.tf", [(
        f'    key          = "{prefix}/{stage_dir}/terraform.tfstate"\n',
        '    # key is supplied by the Makefile from platform/registry.yaml:\n'
        '    #   terraform init -backend-config="key=<stateKeyPrefix>/<stage>/terraform.tfstate"\n'
        '    # so this file names no cluster.\n')])

# 2. Variables the registry owns lose their defaults.
edit("terraform/eks/01-cluster/variables.tf", [(
"""variable "region" {
  type        = string
  description = "Region the cluster runs in."
  default     = "ap-southeast-2"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name. The kube context alias is set to the same value."
  default     = "lfi-eks"
}""",
"""# No defaults for region and cluster_name: platform/registry.yaml owns them and
# the Makefile passes them as TF_VAR_region and TF_VAR_cluster_name. A run that
# forgets fails with "No value for required variable" instead of guessing.
variable "region" {
  type        = string
  description = "Region the cluster runs in. From the registry."
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name. The kube context alias is set to the same value. From the registry."
}""")])

edit("terraform/eks/02-platform/variables.tf", [(
"""variable "kube_context" {
  type        = string
  description = "kubectl context to target. Pinned to the EKS cluster."
  default     = "lfi-eks"

  validation {
    condition     = var.kube_context == "lfi-eks"
    error_message = "This module only targets the lfi-eks context. Refusing to plan against another cluster."
  }
}
""",
"""variable "cluster_name" {
  type        = string
  description = "EKS cluster name, from the registry via TF_VAR_cluster_name."
}

variable "kube_context" {
  type        = string
  description = "kubectl context to target. Must equal the cluster name, from the registry."

  # The guard that stops a stray context from receiving this apply. It now
  # compares against the registry's cluster name instead of a literal, so it
  # survives the cluster being renamed. Referencing another variable inside a
  # validation needs Terraform 1.9, which required_version already demands.
  validation {
    condition     = var.kube_context == var.cluster_name
    error_message = "kube_context must equal cluster_name. Refusing to plan against another cluster."
  }
}
""")])

edit("terraform/local/01-cluster/main.tf", [(
"""  description = "Name of the k3d cluster. Kube context becomes k3d-<name>."
  default     = "platform"
}""",
"""  description = "Name of the k3d cluster. Kube context becomes k3d-<name>. From the registry."
}""")])

edit("terraform/local/02-platform/variables.tf", [(
"""variable "kube_context" {
  type        = string
  # Must match `kube_context` output by 01-cluster. Nothing enforces that
  # automatically, so a mismatch here is silently applying to another cluster.
  description = "kubectl context to target. Must match the 01-cluster output."
  default     = "k3d-platform"
}""",
"""variable "cluster_name" {
  type        = string
  description = "k3d cluster name, from the registry via TF_VAR_cluster_name."
}

variable "kube_context" {
  type        = string
  description = "kubectl context to target. From the registry, and checked against cluster_name."

  # Was an unchecked default. k3d names the context k3d-<cluster>, so a context
  # that does not fit the cluster name is a stray one. Refuse it.
  validation {
    condition     = var.kube_context == "k3d-${var.cluster_name}"
    error_message = "kube_context must be k3d-<cluster_name>. Refusing to plan against another cluster."
  }
}""")])
print("Edited the Terraform files.")
PYEOF
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
grep -c 'terraform.tfstate"$' terraform/*/*/backend.tf
grep -n 'default' terraform/eks/01-cluster/variables.tf terraform/eks/02-platform/variables.tf terraform/local/02-platform/variables.tf | grep -E 'cluster_name|region|kube_context' || echo "no defaults left for the registry's variables"
scripts/check-contract.sh
```
Expected: `0` for every `backend.tf` (no state key left in the files), `no defaults left for the registry's variables`, and `OK`.

#### Task 21.2.3: Prove no state moved (local)

**Goal:** With the state key now coming from the registry, Terraform's view of the local cluster is unchanged: both stages plan to zero changes.

**Why this is the test that matters:** a wrong key would make Terraform look at an empty state and plan to create everything again. `plan` is read-only, so you find out before anything applies.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake _local-plan; echo "exit code: $?"
```
This needs AWS credentials for the state bucket (`aws sts get-caller-identity` must work) and the local cluster up.

**Validate:** two `No changes. Your infrastructure matches the configuration.` messages, one per stage, and `exit code: 0`. Exit code `2` means Terraform wants to change something; read the plan before doing anything. Exit code `1` with `Backend configuration changed` is Appendix I.

Ship Phase 21.2:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git add Makefile terraform
bash "$PLATFORM_HOME/.tmp/g4/ship.sh" "cluster identity from the registry; Terraform state keys by flag"
```

### Phase 21.3: EKS prefix delegation

**Objective:** Raise the pod limit on the single EKS node from 35 so that guide 5's monitoring fits without a second node.

### Primer: why 35, and what prefix delegation changes

On EKS each pod takes its own IP address from the VPC. A node has a fixed number of network interfaces, and each interface holds a fixed number of addresses, so the instance type caps the pods: `t3.large` gets 35. The pod count on this cluster is already about 25, and guide 5 adds Prometheus, Grafana, exporters and a log and trace stack.

**Prefix delegation** changes what an interface holds. Instead of individual addresses, each slot carries a `/28` prefix of 16 addresses, so the same interfaces supply far more pods. The ceiling then becomes the kubelet's own limit, 110 for an instance this size. It is a setting on the VPC CNI add-on and costs nothing. The catches: it only applies to nodes created **after** the setting, and the VPC subnets need room for the prefixes (`/24` subnets are enough here).

#### Task 21.3.1: Verify the setting exists for your add-on version

**Goal:** Evidence that the installed VPC CNI accepts `ENABLE_PREFIX_DELEGATION` and `WARM_PREFIX_TARGET`, from AWS, before you edit anything.

**Why verify:** the configuration schema differs by add-on version, and this guide could not check yours.

```bash
K8S="$(sed -n 's/.*default *= *"\(1\.[0-9]*\)".*/\1/p' "$PLATFORM_HOME/lfi-infrastructure-gitops/terraform/eks/01-cluster/variables.tf" | head -1)"
REGION="$(yq '.clusters[] | select(.kind == "eks") | .region' "$PLATFORM_HOME/lfi-infrastructure-gitops/platform/registry.yaml")"
echo "Kubernetes $K8S in $REGION"
V="$(aws eks describe-addon-versions --region "$REGION" --addon-name vpc-cni --kubernetes-version "$K8S" \
  --query 'addons[0].addonVersions[0].addonVersion' --output text)"
echo "newest vpc-cni for this Kubernetes version: $V"
aws eks describe-addon-configuration --region "$REGION" --addon-name vpc-cni --addon-version "$V" \
  --query configurationSchema --output text | jq -r '.properties.env.properties | keys[]' | grep -E 'ENABLE_PREFIX_DELEGATION|WARM_PREFIX_TARGET'
```

**Validate:** the last command prints both `ENABLE_PREFIX_DELEGATION` and `WARM_PREFIX_TARGET`. If either is missing, stop and read the schema (`... | jq '.properties.env.properties | keys'`) before continuing.

#### Task 21.3.2: Turn it on

**Goal:** The `vpc-cni` add-on in `eks.tf` carries the two settings, so a newly created node starts with the higher limit.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
python3 - <<'PYEOF'
import sys
p = "terraform/eks/01-cluster/eks.tf"
s = open(p).read()
old = """    vpc-cni = {
      before_compute = true
    }"""
new = """    vpc-cni = {
      before_compute = true
      # Prefix delegation: each network interface hands out /28 prefixes
      # instead of single IPs, which lifts the pod limit from the interface
      # arithmetic (35 on a t3.large) toward the kubelet ceiling (110).
      # WARM_PREFIX_TARGET = 1 keeps one spare prefix ready, not more.
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }"""
if s.count(old) != 1:
    sys.exit(f"ERROR: expected one vpc-cni block, found {s.count(old)}.")
open(p, "w").write(s.replace(old, new))
print("Edited eks.tf.")
PYEOF
terraform fmt -check terraform/eks/01-cluster/eks.tf && echo "eks.tf is formatted"
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
grep -A8 'vpc-cni = {' terraform/eks/01-cluster/eks.tf | grep -E 'ENABLE_PREFIX|WARM_PREFIX'
```
Expected: both settings printed. The real test is on a running cluster in Task 21.5.3. **If you ever enable this on an existing cluster,** the node must be replaced for the new limit to apply; the EKS cluster here is rebuilt from scratch in Phase 21.5, so it starts with the setting.

Ship Phase 21.3:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git add terraform
bash "$PLATFORM_HOME/.tmp/g4/ship.sh" "EKS: enable VPC CNI prefix delegation"
```

### Phase 21.4: A template others can stamp

**Objective:** Creating the next project from this repo is a short checklist, not an afternoon.

#### Task 21.4.1: The stamp script

**Goal:** `scripts/stamp.sh` relabels a fresh copy of the repo as a new project: owner, repository name, cluster names, namespaces, Terraform state keys and bucket, code owner. It is a dry run unless you pass `--apply`.

**What it deliberately leaves alone:** the two example services and their images. They keep deploying from the original project's public images, so a stamped repo is a working platform on the first `gmake up`, and the next project's guide replaces them by plugging services in and out, which is the point of this whole guide. It also does not touch service repositories: their CI names the GitOps repository and the cluster list (Appendix I).

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
cat > scripts/stamp.sh <<'XEOF'
#!/usr/bin/env bash
# Re-labels a copy of this repo as a new project: new GitHub owner and repo,
# new cluster names, new namespaces, new state bucket. Run it once, in a fresh
# copy made from the GitHub template, before anything is applied.
#
# Dry run by default. Add --apply to change files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/reg.sh"

usage() {
  cat >&2 <<EOF
Usage: scripts/stamp.sh --owner <github owner> --repo <repo name> --project <short name> \\
                        --bucket <state bucket> [--ns-prefix <prefix>] [--apply]
  --project    short lowercase name, e.g. mktp. Becomes the cluster names:
               k3d cluster <project>, EKS cluster <project>-eks.
  --ns-prefix  namespace prefix (default: the project), giving <prefix>-dev, <prefix>-prod
  --bucket     an S3 bucket you have already created for Terraform state
EOF
  exit 1
}

OWNER=""; REPO=""; PROJECT=""; BUCKET=""; NSP=""; APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift; continue ;;
    --owner|--repo|--project|--bucket|--ns-prefix) [[ $# -ge 2 ]] || usage ;;
    *) usage ;;
  esac
  case "$1" in
    --owner) OWNER="$2" ;;
    --repo) REPO="$2" ;;
    --project) PROJECT="$2" ;;
    --bucket) BUCKET="$2" ;;
    --ns-prefix) NSP="$2" ;;
  esac
  shift 2
done
[[ -n "$OWNER" && -n "$REPO" && -n "$PROJECT" && -n "$BUCKET" ]] || usage
NSP="${NSP:-$PROJECT}"
[[ "$PROJECT" =~ ^[a-z][a-z0-9]{1,15}$ ]] || { echo "ERROR: --project must be 2 to 16 lowercase letters and digits." >&2; exit 1; }
[[ "$NSP" =~ ^[a-z][a-z0-9]{1,15}$ ]] || { echo "ERROR: --ns-prefix must be 2 to 16 lowercase letters and digits." >&2; exit 1; }

OLD_OWNER="$(yq '.owner' "$REGISTRY")"; OLD_REPO="$(yq '.repo' "$REGISTRY")"
OLD_BUCKET="$(yq '.stateBucket' "$REGISTRY")"; OLD_NSP="$(yq '.namespacePrefix' "$REGISTRY")"
OLD_K3D="$(yq '.clusters[] | select(.kind == "k3d") | .clusterName' "$REGISTRY")"

[[ "$OLD_OWNER/$OLD_REPO" != "$OWNER/$REPO" ]] || { echo "ERROR: the registry already says $OWNER/$REPO. Nothing to stamp." >&2; exit 1; }

# Files that carry each old value. grep -rl lists them, so the dry run shows
# exactly what --apply would touch.
URL_FILES="$(grep -rl "github.com/$OLD_OWNER/$OLD_REPO.git" argocd 2>/dev/null || true)"
BACKEND_FILES="$(grep -rl "$OLD_BUCKET" terraform --include=backend.tf 2>/dev/null || true)"
NS_FILES="$(grep -rlE "(namespace: |')${OLD_NSP}-(dev|prod|\{\{)" argocd kubernetes/overlays 2>/dev/null || true)"
OWNER_FILES="$(grep -l "@$OLD_OWNER" .github/CODEOWNERS 2>/dev/null || true)"

echo "Stamping $OLD_OWNER/$OLD_REPO as $OWNER/$REPO (project $PROJECT, namespaces ${NSP}-dev and ${NSP}-prod)"
echo
echo "Registry:            platform/registry.yaml (owner, repo, bucket, prefixes, cluster names)"
echo "k3d cluster name:    $OLD_K3D -> $PROJECT   (terraform/local/01-cluster/k3d-config.yaml)"
echo "Repo URL in:         $(echo "$URL_FILES" | grep -c . || true) file(s) under argocd/"
echo "State bucket in:     $(echo "$BACKEND_FILES" | grep -c . || true) backend.tf file(s)"
echo "Namespace prefix in: $(echo "$NS_FILES" | grep -c . || true) file(s) under argocd/ and kubernetes/overlays/"
echo "Code owner in:       $(echo "$OWNER_FILES" | grep -c . || true) file(s)"

if [[ "$APPLY" -ne 1 ]]; then
  echo
  echo "Dry run. Nothing changed. Add --apply to make these changes."
  exit 0
fi

for f in $URL_FILES; do
  sed -i '' "s#github.com/$OLD_OWNER/$OLD_REPO.git#github.com/$OWNER/$REPO.git#g" "$f"
done
for f in $BACKEND_FILES; do
  sed -i '' "s#$OLD_BUCKET#$BUCKET#g" "$f"
done
for f in $NS_FILES; do
  sed -i '' -E "s#(namespace: |')${OLD_NSP}-(dev|prod|\{\{)#\1${NSP}-\2#g" "$f"
done
for f in $OWNER_FILES; do
  sed -i '' "s#@$OLD_OWNER#@$OWNER#g" "$f"
done

P="$PROJECT" yq -i '.metadata.name = strenv(P)' terraform/local/01-cluster/k3d-config.yaml

O="$OWNER" R="$REPO" B="$BUCKET" P="$PROJECT" N="$NSP" yq -i '
  .project = strenv(P) |
  .owner = strenv(O) |
  .repo = strenv(R) |
  .stateBucket = strenv(B) |
  .namespacePrefix = strenv(N) |
  (.clusters[] | select(.kind == "k3d") | .clusterName) = strenv(P) |
  (.clusters[] | select(.kind == "k3d") | .context) = "k3d-" + strenv(P) |
  (.clusters[] | select(.kind == "k3d") | .stateKeyPrefix) = strenv(P) + "-local" |
  (.clusters[] | select(.kind == "eks") | .clusterName) = strenv(P) + "-eks" |
  (.clusters[] | select(.kind == "eks") | .context) = strenv(P) + "-eks" |
  (.clusters[] | select(.kind == "eks") | .stateKeyPrefix) = strenv(P) + "-eks"
' "$REGISTRY"

echo
echo "Done. Verify:  scripts/check-contract.sh"
echo "Then commit, and create the GitHub repository with the name '$REPO'."
XEOF
chmod +x scripts/stamp.sh
```

**Validate** on a disposable copy, so this repo is untouched:
```bash
S="$PLATFORM_HOME/.tmp/g4"
rm -rf "$S/stamp-test"; mkdir -p "$S/stamp-test"
rsync -a --exclude .git --exclude .terraform --exclude .generated "$PLATFORM_HOME/lfi-infrastructure-gitops/" "$S/stamp-test/"
cd "$S/stamp-test"
scripts/stamp.sh --owner example --repo demo-gitops --project demo --bucket tfstate-example-demo
scripts/stamp.sh --owner example --repo demo-gitops --project demo --bucket tfstate-example-demo --apply
scripts/check-contract.sh
yq '.clusters[] | .name + " " + .context + " " + .stateKeyPrefix' platform/registry.yaml
for c in local eks; do for e in dev prod; do
  kustomize build kubernetes/overlays/$c/$e/service-1 | yq -N 'select(.kind == "Rollout") | .metadata.namespace'
done; done | sort -u
grep -rn "$(yq '.stateBucket' "$PLATFORM_HOME/lfi-infrastructure-gitops/platform/registry.yaml")" terraform | wc -l
```
Expected: the dry run lists counts and ends `Dry run. Nothing changed.`; the apply ends `Done. Verify:`; `check-contract.sh` prints `OK`; the clusters print as `local k3d-demo demo-local` and `eks demo-eks demo-eks`; the namespaces print as `demo-dev` and `demo-prod`; and the last count is `0` (the old bucket name appears nowhere under `terraform/`). Then `rm -rf "$S/stamp-test"`.

#### Task 21.4.2: Document it and mark the repo as a template

**Goal:** A README section that tells a future you how to start a project, and the GitHub "template repository" switch on.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
cat >> README.md <<'EOF'

## Creating a project from this template

This repository is a GitHub template. To start a new project (a different
application, its own clusters, its own state):

1. On GitHub, use **Use this template** to create `<owner>/<new-repo>`. A template
   copy starts with no history, which is what you want.
2. Create an S3 bucket for its Terraform state.
3. Clone it, then from its root:
   ```
   scripts/stamp.sh --owner <owner> --repo <new-repo> --project <short> --bucket <bucket>
   scripts/stamp.sh --owner <owner> --repo <new-repo> --project <short> --bucket <bucket> --apply
   scripts/check-contract.sh
   ```
4. Copy `.env.example` to `.env` and fill it in. Set `GITOPS_REPO_URL` to the new repository.
5. Bring up a cluster with `gmake up`. The two example services deploy from their
   public images so you have a working platform at once.
6. Replace them: `gmake add-service` for each of yours, then delete the examples
   (delete `kubernetes/base/<svc>` and `kubernetes/overlays/*/*/<svc>`, remove
   the entry from `platform/registry.yaml`).

Each service repository's CI names the GitOps repository and the overlays to
update. Copy an existing `ci.yaml` and change `IMAGE_NAME`, `SERVICE`, the
repository name and the `MANIFESTS` list. `gmake add-service` prints the lines.
EOF
git add scripts/stamp.sh README.md
bash "$PLATFORM_HOME/.tmp/g4/ship.sh" "add the stamp script and template instructions"
GH_HOST=github.com gh repo edit "$(yq '.owner' platform/registry.yaml)/$(yq '.repo' platform/registry.yaml)" --template
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
GH_HOST=github.com gh repo view "$(yq '.owner' platform/registry.yaml)/$(yq '.repo' platform/registry.yaml)" --json isTemplate -q .isTemplate
```
Expected: `true`. If `gh` reports an authentication problem, run `gh auth login --hostname github.com`. You can also switch it on in the repository's Settings page under "Template repository".

### Phase 21.5: Prove it on EKS

**Objective:** Bring EKS up once, validate everything from Sections 20 and 21 that could not be checked without it, run the add and remove drill across both clusters, and tear it down.

**Cost:** about 0.23 USD an hour from the moment `gmake up` starts until the cluster is destroyed. Budget 1.5 to 2 hours including the 15 to 25 minutes to build. Do not start this phase if you cannot finish it in one sitting. Guide 3's budget alarm (Task 15.1.3) is your safety net; confirm it exists in the next task.

#### Task 21.5.1: Confirm the guardrails, then bring EKS up

**Goal:** A running EKS cluster, built from the new layout, that nobody can forget about.

```bash
aws sts get-caller-identity --query Arn --output text
aws budgets describe-budgets --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --query 'Budgets[].BudgetName' --output text
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake up CLUSTER=eks
```
**Validate:** the first command prints your ARN, the second lists the budget alarm from Task 15.1.3 (if it is empty, stop and recreate it before paying for anything), and `gmake up` ends by printing what to run next. Then:
```bash
kubectl --context lfi-eks get nodes
kubectl --context lfi-eks -n argocd get applications
kubectl --context lfi-eks -n argocd get applicationsets
```
Expected: one node `Ready`; after ArgoCD's first sync (up to three minutes) `root` plus the six service and data Applications plus `addon-metrics-server-eks`, all `Synced` and `Healthy`; and three ApplicationSets: `services-eks`, `data-eks` and `addons-eks`. This cluster never had hand-written Applications in this layout. It built straight from the ApplicationSets, which is the "later cluster reads the new layout" claim from the start of Phase 20.3.

#### Task 21.5.2: Terraform agrees with itself on a real cluster

**Goal:** After a fresh apply using state keys from the registry, planning again finds nothing to do.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake _eks-plan; echo "exit code: $?"
```
**Validate:** two `No changes.` messages and `exit code: 0`.

#### Task 21.5.3: The pod limit went up

**Goal:** The node admits far more than 35 pods.

```bash
kubectl --context lfi-eks get nodes -o jsonpath='{.items[0].status.allocatable.pods}{"\n"}'
kubectl --context lfi-eks -n kube-system get ds aws-node \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | grep PREFIX
kubectl --context lfi-eks get pods -A --no-headers | wc -l
```
**Validate:** `110`, both `ENABLE_PREFIX_DELEGATION=true` and `WARM_PREFIX_TARGET=1` listed, and a current pod count comfortably under 110 (about 25 to 30). If the first command prints `35`, the setting reached the add-on but the node's kubelet did not pick up the higher limit; Appendix I has the fix, and you should apply it before guide 5.

#### Task 21.5.4: metrics-server works

**Goal:** `kubectl top` works on EKS, so the add-on layer ran end to end.

```bash
kubectl --context lfi-eks -n argocd get application addon-metrics-server-eks
kubectl --context lfi-eks top nodes
kubectl --context lfi-eks top pods -A --sort-by=memory | head -8
```
**Validate:** the Application `Synced` and `Healthy`, a node row with CPU and memory, and a pod table. `metrics not available yet` for the first minute is normal; retry. `error: Metrics API not available` after five minutes is Appendix I.

#### Task 21.5.5: Plug a service in and out on both clusters

**Goal:** One scaffold command and one merge deploys a service to **both** clusters; one deletion removes it from both. Each cluster acts on its own tree.

This needs the local cluster running too (`gmake up CLUSTER=local`). Both clusters run the same `main`, which is the independence claim: neither needs the other, and both converge from Git alone.
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
scripts/new-service.sh demo --image ghcr.io/stefanprodan/podinfo --tag 6.7.1 \
  --port 9898 --health /healthz --role "a throwaway demo"
scripts/check-contract.sh
git add kubernetes platform
bash "$S/ship.sh" "drill: plug in the demo service on both clusters"
```
**Validate** after a few minutes (the sets poll Git about every three minutes):
```bash
for ctx in k3d-platform lfi-eks; do
  echo "== $ctx"
  kubectl --context "$ctx" -n argocd get applications | grep -E 'NAME|demo'
  kubectl --context "$ctx" get pods -A -l app=demo --no-headers | wc -l
done
```
Expected on each cluster: `demo-dev` and `demo-prod` (with an `-eks` suffix on EKS), `Synced` and `Healthy`, and `3` demo pods (one in dev, two in prod).

Now take it out:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
git rm -q -r kubernetes/base/demo kubernetes/overlays/local/dev/demo kubernetes/overlays/local/prod/demo \
             kubernetes/overlays/eks/dev/demo kubernetes/overlays/eks/prod/demo
yq -i 'del(.services[] | select(.name == "demo"))' platform/registry.yaml
scripts/check-contract.sh
git add platform
bash "$S/ship.sh" "drill: plug out the demo service on both clusters"
```
```bash
for ctx in k3d-platform lfi-eks; do
  echo "== $ctx"
  kubectl --context "$ctx" -n argocd get applications | grep -c demo || true
  kubectl --context "$ctx" get pods -A -l app=demo --no-headers 2>/dev/null | wc -l
done
```
Expected after a few minutes: `0` and `0` on both clusters.

#### Task 21.5.6: Decide what to do with EKS

**Goal:** Either EKS is gone and nothing bills, or you have chosen on purpose to keep it for guide 5.

Guide 5's EKS work is batched the same way this phase was. Unless you are starting it now, destroy:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake destroy CLUSTER=eks
```
**Validate:**
```bash
REGION="$(yq '.clusters[] | select(.kind == "eks") | .region' "$PLATFORM_HOME/lfi-infrastructure-gitops/platform/registry.yaml")"
aws eks list-clusters --region "$REGION" --query clusters --output text
aws ec2 describe-nat-gateways --region "$REGION" --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text
aws elbv2 describe-load-balancers --region "$REGION" --query 'LoadBalancers[].LoadBalancerName' --output text
kubectl config get-contexts -o name | grep -c '^lfi-eks$' || true
```
Expected: no cluster name, no NAT gateway, no load balancer, and `0`. (The full post-teardown checklist is guide 3's Task 18.3.1.)

### Phase 21.6: Close

#### Task 21.6.1: Tag and confirm

**Goal:** A named point for this guide, and a final proof that the repo is consistent.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch main && git pull --ff-only
scripts/check-contract.sh
git tag -a guide-4-complete -m "State at the end of guide 4"
git push origin guide-4-complete
git branch -d feat/pluggable-structure
git push origin --delete feat/pluggable-structure 2>/dev/null || true
```
**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git ls-remote --tags origin guide-4-complete | wc -l
git status -sb | head -1
kubectl --context k3d-platform -n argocd get applications
```
Expected: `1`, `## main...origin/main` with no `ahead` or `behind`, and the local cluster's seven Applications `Synced` and `Healthy`.

**Checkpoint.** You now have a template: services and add-ons plug in by directory, both clusters read the same layout, the identity of a project is one file, and a new project is stamped in minutes. Guide 5 uses exactly this to add observability as add-ons.

---

## Appendix I: Troubleshooting

**`argocd-applicationset-controller` is missing (Task 19.1.1).** Your ArgoCD chart predates bundling it. Check `helm list -n argocd` for the chart version, and upgrade `argocd_chart_version` in `variables.tf` to a current pin, following Task 1.1.3's advice to keep it close to your `argocd` CLI.

**`unknown field` on a server dry run (Task 20.2.2).** The installed ApplicationSet CRD does not know a field. `applicationsSync` and `preserveResourcesOnDeletion` are the newest ones. Confirm with `kubectl --context k3d-platform explain applicationset.spec.syncPolicy`. If `applicationsSync` is missing, delete just that line from `data-local.yaml` and `data-eks.yaml`: `preserveResourcesOnDeletion` and `prune: false` still protect the database; `applicationsSync` only also stops the set deleting the Application.

**Finalizer still present after Move 2 (Task 20.3.3).** `root` did not sync the change, or the field was not removed from the live object. Force it, then look:
```bash
kubectl --context k3d-platform -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
kubectl --context k3d-platform -n argocd get applications \
  -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.finalizers}{"\n"}{end}'
```
If one still shows a finalizer after another minute, remove it directly, then re-run the guard from Task 20.3.3:
```bash
kubectl --context k3d-platform -n argocd patch application service-1-dev --type json \
  -p '[{"op":"remove","path":"/metadata/finalizers"}]'
```
Never continue to Move 3 while the guard prints `STOP`.

**No Applications appear after Move 4 (Task 20.3.5).** Read the controller log (`kubectl --context k3d-platform -n argocd logs deploy/argocd-applicationset-controller --tail=100`). Common causes: `repoURL` differs from the real repository (run `scripts/check-contract.sh`), the repo is private and ArgoCD has no credential for it (guide 1, Appendix A), or `revision: HEAD` points at a branch other than the one you merged to.

**Applications are `OutOfSync` or warn about a resource "shared with another application" after Move 4.** An old Application with the same name still exists, or the tracking identifier does not match. Compare `kubectl --context k3d-platform -n argocd get applications -o yaml | grep -c ownerReferences` with the expectation of six. If the old Applications are still present (Move 3 did not complete), the set cannot adopt the workloads: finish Move 3 first.

**Rolling back the cutover.** Each move is one merge commit on `main`. To undo Move 4 and Move 3, revert them in that order and let `root` sync:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch main && git pull --ff-only
git log --oneline --merges -5
git revert -m 1 <the Move 4 merge commit>
git revert -m 1 <the Move 3 merge commit>
git push origin main
```
That restores the six hand-written Applications **without** finalizers (Move 2 stays applied), and they adopt the workloads by name exactly as the sets did. Restore the finalizers afterwards by reverting Move 2 the same way, once you are back to a settled state.

**A merge conflict in a `newTag` line.** A service repo's CI pushed a new image tag to `main` while your branch had rewritten the same file. In the ship script's merge step you are on `main`, with the conflict pending. Keep the branch's slim file, re-apply the tag `main` just received, and finish the merge:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
for f in $(git diff --name-only --diff-filter=U); do
  tag="$(git show ":2:$f" | yq '.images[0].newTag')"   # :2 is main's version
  git checkout --theirs -- "$f"                        # the branch's slim file
  yq -i ".images[0].newTag = \"$tag\"" "$f"
  git add "$f"
done
git commit --no-edit
git push origin main
git switch feat/pluggable-structure
git merge --ff-only main
```
This applies only to the window before the slim overlays reach `main`; afterwards CI edits plain lines.

**`gmake` stops with "Could not read platform/registry.yaml".** `yq` is not installed or you are not in the GitOps repo root. `brew install yq`, and `cd "$PLATFORM_HOME/lfi-infrastructure-gitops"`.

**`terraform init` says "Backend configuration changed" (Task 21.2.3).** The state key on the command line differs from the one last used in this working directory. First check the key printed in the message against the old one (`local-platform/...` or `lfi-eks/...`). If they are the same string, run `terraform init -reconfigure -backend-config="key=<the same key>"` once from that stage's directory. **Never** answer `-migrate-state` here: no state is meant to move, and migrating would copy the wrong key's contents over the right one.

**The pod limit is still 35 (Task 21.5.3).** The CNI setting is applied but the node's kubelet was started with the old limit. Confirm the node is newer than the setting (`kubectl --context lfi-eks get nodes` shows its age against your `gmake up`). If so, set the limit explicitly on the node group. In `terraform/eks/01-cluster/eks.tf`, inside `eks_managed_node_groups.main`, add, then apply with `gmake _eks-cluster` and replace the node by scaling the group from 1 to 0 to 1 in the console or with `aws eks update-nodegroup-config`:
```hcl
      cloudinit_pre_nodeadm = [{
        content_type = "application/node.eks.aws"
        content      = <<-EOT
          ---
          apiVersion: node.eks.aws/v1alpha1
          kind: NodeConfig
          spec:
            kubelet:
              config:
                maxPods: 110
        EOT
      }]
```
This block is the documented way for Amazon Linux 2023 nodes but was not verified for your module version; check the module's `cloudinit_pre_nodeadm` documentation if `terraform plan` rejects it.

**`error: Metrics API not available` (Task 21.5.4).** Check the add-on Application is `Healthy`, then `kubectl --context lfi-eks get apiservice v1beta1.metrics.k8s.io`. `Available=False` with a connection error means the metrics-server pod cannot reach the kubelets; read its log with `kubectl --context lfi-eks -n kube-system logs deploy/metrics-server`. The chart's `args` value lets you add `--kubelet-preferred-address-types=InternalIP` if DNS for node names fails.

**`gmake -n` ran a destroy.** Expected, and the reason for the safety rule at the top: GNU make executes any recipe mentioning `$(MAKE)` even under `-n`, and `.ONESHELL` makes the whole recipe one script. Use the `_local-plan` and `_eks-plan` targets to preview Terraform.

**A new cluster or a stamped repo breaks a service's CI.** Each service repo's `ci.yaml` names the GitOps repository and lists the overlay files to update (the `MANIFESTS` array). Neither comes from the registry. After stamping, or after adding a cluster, edit those lines in each service repo. `scripts/new-service.sh` prints the exact lines for a new service.

**A stale `lfi-eks` context remains after a failed destroy.** `kubectl config delete-context lfi-eks`. Phase 20.3's precondition check counts this context, so a stale one blocks the cutover until it is removed.

## Appendix J: Glossary

**Adoption.** A new ArgoCD Application taking over resources that an earlier Application of the same name deployed, without recreating them. It works because ArgoCD tracks ownership by a label or annotation containing the Application's name.

**Add-on.** Third-party software installed from a Helm chart at a pinned version, enabled per cluster by the presence of `addons/<cluster>/<name>/`. Distinct from a service, which is your code.

**ApplicationSet.** An ArgoCD resource that is a template plus one or more generators. The controller creates one Application per set of values a generator produces.

**Component (Kustomize).** A bundle of patches an overlay opts into with `components:`. Here, one per cluster and environment, holding replicas or canary steps and the Ingress host.

**Contract check.** `scripts/check-contract.sh`. Compares the repository's directories and files to `platform/registry.yaml` and fails when they disagree.

**Finalizer.** A marker on a Kubernetes object that must be cleared before the object is deleted. `resources-finalizer.argocd.argoproj.io` makes deleting an Application delete everything it deployed.

**Git directory generator.** An ApplicationSet generator that yields one set of values per matching directory in a Git repository. Used for services and datastores.

**Git files generator.** An ApplicationSet generator that yields one set of values per matching file, taking the values from the file's contents. Used for add-ons.

**Prefix delegation.** A VPC CNI mode in which each network interface slot holds a `/28` prefix of 16 addresses instead of one, raising the number of pods a node can run.

**Registry.** `platform/registry.yaml`. The single file that names the clusters, environments, namespace prefix and services.

**Scaffolder.** `scripts/new-service.sh`, run as `gmake add-service`. Creates a service's base, every overlay and the registry entry.

**Stamp.** `scripts/stamp.sh`. Relabels a copy of this repository as a new project.

**Template repository.** A GitHub setting that lets anyone create a new repository with the same files and no history.

---

## Where to go next

**Guide 5: observability.** Prometheus and Grafana as add-ons, instrumented services, then tracing and logs, built on exactly the layer this guide added.

**The marketplace project.** A separate workspace, `project-marketplace`, stamped from this template.

**Service CI from the registry.** The last place that still hard-codes the cluster list is each service repo's `ci.yaml`. A reusable workflow in one repository, called by every service, would remove that.
