# A Pluggable Platform Template: A Build Guide

**Goal:** Turn the GitOps repo from "two clusters with hand-written Applications and every service's manifests inside it" into a template where a service is a subscription file plus a repository its team owns, where cluster identity is written once, where adding or removing a service or an add-on is a file or a directory, and where a new project can be stamped from it.

**Status:** DRAFT. Nothing in this guide has been executed against your clusters. What was checked offline, on scratch copies of the repos with local Git remotes standing in for GitHub:

| Checked | Not checked (each has a Validate block and a fallback) |
|---------|--------------------------------------------------------|
| Kustomize renders the new config repositories, with their components pulled from a pinned templates repository by remote reference, byte for byte the same as the 12 builds the old overlays produce | How the ApplicationSet controller handles a merge generator nested in a matrix, `pathParamPrefix`, a templated `revision` and the `get` and `default` template functions (Task 20.2.3 tests all of it before anything depends on it) |
| The generated ApplicationSets and the `teams` AppProject pass a server-side dry run on a live ArgoCD (v3.5), which checks field names and types only | Whether ArgoCD's repo server can fetch the remote components, and whether the AppProject's repository pattern accepts the config repositories |
| The registry and subscription readers, the contract check (including its drift check), the scaffolder, the stamp script, and the edited `lib.sh`, `canary.sh`, `status.sh` and `rollback.sh` and the new `release.sh` run under macOS bash 3.2 and behave as described, including on deliberately broken input | The cutover itself, and the behavior of `applicationsSync` and `preserveResourcesOnDeletion` |
| The rewritten CI promote job parses for both service repos, and its push logic ran against local remotes: both repos, a re-run, and a push race | That your `GITOPS_PAT` token can write to the new repositories |
| The Makefile and Terraform edits apply to the current repo, print the Terraform commands shown, and carry the state keys you already use (printed, never run) | The add-on chart version, and EKS prefix delegation |
| Every command block in Sections 19 and 20, and the script and edit blocks in Section 21, ran in order under zsh against scratch copies of your repos, with local Git remotes standing in for GitHub and no-op stand-ins for `kubectl apply`, `gmake up` and `gh`. The cluster, AWS and GitHub effects of those commands were not exercised | Anything that needs a running cluster, AWS or GitHub: the Validate output that shows live Applications, pods and workflow runs |

Progress is ticked in `tracker_4_pluggable.md`, not here.

**Relationship to the earlier guides:** This continues `docs/1-local-full-infra-guide.md` (Sections 1 to 9), `docs/2-multi-env-infra-guide.md` (Sections 10 to 13) and `docs/3-eks-counterpart-guide.md` (Sections 14 to 18). Numbering resumes at Section 19 and appendix lettering at I. It assumes you finished Section 18: both clusters can be brought up with `gmake up`, each runs `root` plus six child Applications, and Terraform state lives in S3.

**Tech stack added:** ArgoCD ApplicationSets (Git files and directories generators, a matrix and a merge generator; the controller has been installed by the ArgoCD chart since guide 1 and never used), an ArgoCD AppProject, Kustomize components pulled from another repository by remote reference, a small YAML registry and per-service subscription files read with `yq`, and an EKS VPC CNI setting (prefix delegation). No new cluster software is installed except one proof add-on, metrics-server, on EKS. Three new kinds of GitHub repository appear: a templates repository and one config repository per service.

**Cost:** nothing new for the local cluster. EKS bills about 0.23 USD an hour while it exists. This guide makes every change blind to EKS first and brings the cluster up **once**, in Phase 21.5, to validate all of it together, so you pay for a few hours and not for the whole guide.

---

## How to use this guide

Work top to bottom. Every task has a **Goal**, a **Why** where a choice could have gone another way, and a **Validate** block with the command and the output you should see. Do not move on until Validate passes.

Sections are separate parts of the system. Phases are milestones inside a section. Tasks are single actions, numbered `Task <section>.<phase>.<n>`.

Section 20 changes a live cluster and two CI pipelines, so it is written to be zero downtime, and it proves that with pod identifiers rather than with a glance at `kubectl get pods`. Read its primers before touching anything.

### Where commands run

Same rules as guide 3: every command block that depends on location **starts with an explicit `cd`**, and a block with no `cd` only talks to a cluster, to GitHub or to AWS.

| Name | Resolves to | Notes |
|------|-------------|-------|
| `$PLATFORM_HOME` | the workspace root | Set in guide 1, Task 1.2.1. Holds `docs/`, the trackers and `.tmp/`. |
| `$PLATFORM_HOME/lfi-infrastructure-gitops` | the GitOps repo | Its own Git repo. `gmake` runs here. Owned by the platform. |
| `$PLATFORM_HOME/lfi-service-templates` | the templates repo | New in Task 20.1.1. Components and starting points. Owned by the platform. |
| `$PLATFORM_HOME/lfi-service-1-config`, `lfi-service-2-config` | the config repos | New in Task 20.1.2. One per service. Each owned by that service's team. |
| `$PLATFORM_HOME/lfi-service-1-app`, `lfi-service-2-app` | the service repos | Code and CI. Their CI changes in Phase 20.3. |
| `$PLATFORM_HOME/.tmp/g4/` | scratch for this guide | Snapshots and staged files. Disposable. |

### Three safety rules for this machine

**Always pass `--context`.** A workstation's kubeconfig often holds many unrelated clusters, and this one does. A bare `kubectl` acts on whatever context is current, which may be a work cluster. Every cluster command in this guide names its context: `k3d-platform` for the local cluster and `lfi-eks` for EKS. Keep doing that in your own commands.

**`gmake -n` is not a dry run here.** GNU make runs any recipe that mentions `$(MAKE)` even under `-n`, and because the Makefile uses `.ONESHELL`, the **whole recipe** runs for real, including the Terraform lines in it. That covers `_local-destroy`, `_eks-destroy`, `up` and `destroy` paths that call sub-makes. To preview what a Terraform target would do, use the `_local-plan` and `_eks-plan` targets added in Task 21.2.1, which only plan.

**Public GitHub, not your default `gh` host.** The `gh` command on this machine may default to a different GitHub host than the one these repositories live on. Every `gh` command that is not run inside a repository directory (creating a repository, setting a secret) is written with `GH_HOST=github.com`. Inside a repository directory, `gh` reads the host from the remote and needs nothing.

---

## Decisions already made

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| 1 | Template, not fork | **Refactor `lfi-infrastructure-gitops` in place, tag the old state, and mark the repo as a GitHub template** | Guides 1 to 3 point at the repo. The tag `guide-3-complete` keeps them accurate. A new project is created from the template, not forked. GitHub does not let you fork your own repo into your own account anyway. |
| 2 | How a service is discovered | **A subscription file per service per cluster in the GitOps repo, and a matrix of two Git generators**: the subscription says a service exists and where its config repo is, then a files generator reads that repo for its environments | The platform decides what exists. The team decides how many environments it has and what runs in them. |
| 3 | Platform adjustments | **A merge generator** lays an optional platform override (`platform/overrides/<cluster>/<service>.yaml`) on top of the subscription | The platform needs one way to say "pin this service to a known-good revision" without editing the team's repo. |
| 4 | Environments | **Chosen by each team**: one directory per cluster and environment in its config repo, marked by an `env.yaml` file | An environment is a namespace. Which ones a service needs is the team's decision, not the platform's. The namespaces themselves are still created by Terraform (guide 1) for each name in its `environments` variable, so a new environment name is a one-line platform change plus the team's directory. A team can also point an environment at an existing namespace with `namespace:` in `env.yaml`. |
| 5 | Prod protection | **A team concern.** Nothing prod-specific in the GitOps repo. Each config repo has its own CODEOWNERS and branch rules. | The platform's CODEOWNERS protects what the platform owns: subscriptions, ApplicationSets, add-ons, Terraform, the deny list. |
| 6 | Shared behavior | **Components named for what they do, in a templates repo**: `replicas-1`, `canary-manual-gate`, `storage-gp3`. A team opts in from its own kustomization by remote reference, pinned to a tag | Environment names are the team's, so `components/<cluster>-<env>` cannot exist. A tag means a template change reaches an environment only when its team moves the `?ref=`. |
| 7 | Starting points | **Scaffolds in the templates repo are copied once**, not referenced | A service's manifests are its team's. A live reference would let a template edit change every service at once. |
| 8 | Datastores | **A second ApplicationSet, with no prune, no cascading delete and `preserveResourcesOnDeletion`** | One policy cannot be both "a removed service should disappear" and "a removed database must never disappear". |
| 9 | What CI writes | **`images[0].newTag` in `<cluster>/dev/app/kustomization.yaml` of the service's config repo.** The service's CI moves from the GitOps repo to its own config repo | The central repo is no longer written by teams. The change is made in two steps so CI never breaks (Phase 20.3). |
| 10 | Application names and namespaces | **Unchanged** for existing services: `service-1-dev`, `service-1-dev-eks`, namespace `platform-dev` | A generated Application with the same name as the old one adopts the running resources instead of recreating them. A new namespace would recreate every pod. |
| 11 | Team boundary | **One AppProject, `teams`**, per cluster: only `<project>-*-config` repositories, only `<prefix>-*` namespaces, nothing cluster-wide | The platform trusts a team's repo to say what runs. It must not trust it to run anything anywhere. |
| 12 | One source of truth | **`platform/registry.yaml`** holds project identity and clusters. **`platform/subscriptions/`** holds services. The ApplicationSets and the project are **generated** from them by `scripts/gen-appsets.sh` | ArgoCD cannot read the registry, so the few values it needs are written in by a generator, and the contract check regenerates and compares. |
| 13 | Add-ons | **`addons/<cluster>/<name>/addon.yaml` plus `values.yaml`, one ApplicationSet per cluster** | Enabled on a cluster by the presence of its directory, like a service. |
| 14 | EKS pod limit | **VPC CNI prefix delegation** | The `t3.large` caps at 35 pods by interface arithmetic. Prefix delegation moves the limit toward the kubelet ceiling of 110, with no second node. |
| 15 | Stamping | **A script, dry run by default, that relabels a copy of the repo, plus a checklist for the other repos** | Creating a goal project should be a few minutes and a checklist, not an afternoon of `grep`. |

### Primer: the four repositories

Before this guide, one repository held everything ArgoCD deployed. Every service's manifests lived in it, and each service's CI wrote its image tag into it. That works for one person. It does not work as a platform, because every team would need write access to the one repository that controls everything.

After this guide there are four kinds of repository, and each has one kind of writer:

| Repository | What it holds | Who writes to it |
|------------|---------------|------------------|
| **GitOps** (`lfi-infrastructure-gitops`) | The registry, one subscription per service, the ApplicationSets, add-ons, Terraform, scripts, the deny list | The platform |
| **Templates** (`lfi-service-templates`) | Components that give an environment a behavior, and scaffolds that start a new service | The platform, plus teams that open a PR for a template they need |
| **Config**, one per service (`lfi-service-1-config`) | That service's manifests, with a directory per cluster and environment, and its image tags | The service's team, and its CI |
| **App**, one per service (`lfi-service-1-app`) | The service's code and CI | The service's team |

The GitOps repo never contains a service's manifests. It contains a **subscription**: "service-1 exists on the local cluster, and its manifests are in this repository." ArgoCD follows the pointer. A team never needs write access to the GitOps repo, and the platform never needs write access to a team's repo.

### Primer: why an ApplicationSet and not more Applications

Guide 1 built an app-of-apps: a `root` Application watches a directory of Application manifests, and each manifest deploys one thing. It works, and it means that for every service, cluster and environment you write another nearly identical manifest. Guide 3 made that twelve files, two of which differ from the rest only by a `prune: false`.

An ApplicationSet is a template plus a generator. The generator emits one set of values per thing it finds. The controller stamps one Application out of the template for each. Delete the thing and its Application is removed. The `root` Application still exists, but what it now syncs is a handful of ApplicationSet manifests and one project, not a pile of Applications.

The controller is not new. The ArgoCD chart has installed `argocd-applicationset-controller` since Section 6. A comment in `values/argocd.yaml` said it was disabled, but the chart has no such switch, so it has been running, unused, the whole time. Task 20.2.1 fixes that comment.

### Primer: the generators used here

A **generator** produces the list of values a template is filled in with. This guide uses four kinds, and it helps to know what each one is for.

- **Git files generator.** One set of values per file that matches a path pattern, taking the values from the file's contents. `platform/subscriptions/local/*.yaml` yields one set per subscribed service: `name`, `team`, `configRepo` and so on. `local/*/env.yaml` in a team's repo yields one set per environment: `env`, and optionally `namespace`. The set also carries `path.path`, the directory the file sits in.
- **Git directories generator.** One set per matching directory, with `path.path`, `path.basename` and `path.segments`. Used for datastores, where the directory name (`postgres`) is the thing that matters.
- **Matrix generator.** Takes two generators and yields every combination. Here: every subscribed service, combined with every environment in that service's own repository. The second generator may use the first one's values, which is how it knows which repository to read.
- **Merge generator.** Takes a base generator and one or more others, and when two sets share a key (here `name`), lays the later set's values over the earlier one's. Here: a subscription, with the platform's optional override for the same service on top.

Two practical points. The templates use Go template functions: `get . "namespace"` reads a key that may be absent and returns an empty string instead of failing, and `default` supplies the fallback. And when two generators in one matrix both produce `path` values they would overwrite each other, so the first one's are renamed with `pathParamPrefix`.

### Primer: why finalizers decide whether the cutover is safe

Every hand-written Application carries `resources-finalizer.argocd.argoproj.io`. That finalizer means: **when this Application is deleted, delete everything it deployed first.** It is why deleting `root` cleans up a whole cluster, and it is a feature.

It is also the one way this guide could destroy the database. If you simply delete the six Application files from Git, `root` prunes six Applications, each cascades, and Postgres and its volume claim go with them. So the cutover removes the finalizers **first**, proves they are gone, and only then deletes the files. An Application without the finalizer can be deleted while the workload keeps running, and a new Application of the same name picks the workload back up. Phase 20.3 is built around that order.

### Primer: adoption by name

ArgoCD remembers which Application owns a resource by a tracking identifier that includes the Application's name. A new Application with the same name claims resources with that identifier as its own, finds they already match the Git state, and changes nothing. It does not matter that the new Application reads a different repository or belongs to a different project. This is why Decision 10 matters and why the cutover is validated by comparing pod identifiers before and after: identical identifiers mean nothing was recreated.

---

## What changes and what does not

| Changes | Does not change |
|---------|-----------------|
| Who creates the Applications: generated from subscriptions instead of twelve hand-written files | The base manifests themselves: they move into the config repos unchanged |
| Where a service's manifests live: its own config repo | Application names, namespaces, and the field that holds an image tag (`images[0].newTag`) |
| Where a service's CI writes: its config repo | The commands you type: `gmake up`, `status`, `release`, `canary`, `rollback` |
| Who protects prod: the team, in its own repo | The image repositories and the services' code |
| Scripts read services from subscriptions and tags from config repos | The state bucket and the Terraform state keys, so nothing migrates |
| EKS gets prefix delegation | Node count and instance type |
| New: `platform/subscriptions`, the templates repo, the config repos, the `teams` project, the scaffold and stamp scripts, `addons/` | The deny list and how a canary is judged |

## Directory layout after this guide

```
lfi-infrastructure-gitops/                  the platform
├── platform/
│   ├── registry.yaml                       project identity and clusters
│   ├── subscriptions/<cluster>/<svc>.yaml  one per service per cluster
│   └── overrides/<cluster>/                optional platform adjustments
├── argocd/
│   ├── apps-<cluster>/appsets/{services,data,addons}.yaml
│   └── apps-<cluster>/projects/teams.yaml  generated by scripts/gen-appsets.sh
├── addons/<cluster>/<name>/{addon.yaml,values.yaml}
├── releases/denied-builds.yaml             the platform's veto
├── scripts/                                reg.sh gen-appsets.sh check-contract.sh
│                                           new-service.sh stamp.sh, and the gmake commands
└── terraform/                              backends lose their hard-coded key

lfi-service-templates/                      the platform, with team PRs
├── components/{replicas-1,canary-manual-gate,storage-gp3}/
└── scaffolds/{web-service,db-service}/

lfi-service-1-config/                       owned by service-1's team
├── base/app/                               the service's manifests
├── base/postgres/                          its database, if it owns one
└── <cluster>/<environment>/
    ├── env.yaml                            marks an environment
    ├── app/kustomization.yaml              namespace, components, image tag
    └── postgres/kustomization.yaml         if it owns a database
```

## Resource budget

The ApplicationSet controller already runs; budget roughly 50 to 100 MB for it. The only workload this guide adds is metrics-server on EKS, requesting 25m CPU and 48Mi. Prefix delegation adds no pods. The throwaway `demo` service in the drills requests 25m and 64Mi per replica and is gone at the end of each drill. The temporary `spike` ApplicationSet in Task 20.2.3 creates Applications that deploy nothing.

---

## Table of Contents

- [Section 19: Baseline and contract](#section-19-baseline-and-contract)
- [Section 20: Pluggable services](#section-20-pluggable-services)
- [Section 21: Add-ons and multi-cluster](#section-21-add-ons-and-multi-cluster)
- [Appendix I: Troubleshooting](#appendix-i-troubleshooting)
- [Appendix J: Glossary](#appendix-j-glossary)

---

## Section 19: Baseline and contract

**Objective:** A known-good starting point you can return to, and a written statement of what exists: the project and its clusters in the registry, the services in subscriptions, and a check that fails loudly when anything disagrees.

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

**Why all three repos:** The guides' companion repos so far are these three. Only the GitOps repo changes before Phase 20.3, but tagging the other two now costs nothing and means a later reader can reproduce the exact set.

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

**Goal:** Two records to compare against later: the names of the Applications, and the identity of every running pod and claim in the local cluster.

**Why no snapshot of the manifests:** the old overlays stay in place until Task 20.4.5, so Phase 20.1 can compare them against the new config repos directly, at any moment, with a script. A snapshot would go stale the first time CI moves an image tag.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
mkdir -p "$S"

kubectl --context k3d-platform -n argocd get applications -o name | sort > "$S/apps-before.txt"

for ns in platform-dev platform-prod; do
  kubectl --context k3d-platform -n "$ns" get pods,pvc \
    -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.metadata.uid}{"\n"}{end}'
done | sort > "$S/uids-before.txt"
```

**Validate:**
```bash
S="$PLATFORM_HOME/.tmp/g4"
wc -l < "$S/apps-before.txt"
wc -l < "$S/uids-before.txt"
```
Expected: `7` (six children plus `root`), and a count of pods plus claims (about ten: one pod per service in dev, two per service in prod, and a Postgres pod and claim in each environment). Neither may be zero.

#### Task 19.1.4: Work on a clean branch

**Goal:** Nothing lands on `main` until it is validated. This guide merges to `main` several times, deliberately, in Phase 20.3, because ArgoCD reads `main`. Everything else merges once.

**Park leftovers first.** If a branch called `feat/pluggable-structure` already exists from an earlier attempt, its changes do not belong in this one. Check, and keep them on another name rather than deleting them:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git branch --list 'feat/pluggable-structure'
git status -sb | head -5
```
If the first command printed nothing, skip to the branch command below. Otherwise commit whatever is on it (this includes untracked files) and rename it:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch feat/pluggable-structure
git add -A
git diff --cached --quiet || git commit -m "wip: parked attempt"
git branch -m feat/pluggable-structure wip/parked-attempt
```
Then start clean from `main`:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch main
git pull --ff-only
git switch -c feat/pluggable-structure
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git branch --show-current
git status -sb | head -3
ls platform scripts/reg.sh 2>&1 | head -2
```
Expected: `feat/pluggable-structure`, a status line with no changed files, and `No such file or directory` for both `platform` and `scripts/reg.sh` (this guide creates them). If either exists, the branch was not clean; stop and repeat the parking step.

### Phase 19.2: The contract

#### Task 19.2.1: Write the registry

**Goal:** `platform/registry.yaml` exists and says, in one place, who owns this project and which clusters it runs on. It does **not** list services or environments: services are subscriptions (next task) and environments belong to teams.

**Why `stateKeyPrefix` is here:** the Terraform state keys already exist in S3 under `local-platform/` and `lfi-eks/`. Recording those exact strings is what lets Task 21.2.2 move the keys out of the backend blocks without migrating any state.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
mkdir -p platform
cat > platform/registry.yaml <<'XEOF'
# The one place that says what exists at the project level: who owns it, which
# clusters it runs on, and what they are called. Services are NOT here: each
# one is a file under platform/subscriptions/. Scripts, the Makefile and the
# stamp script read this file. ArgoCD cannot, so scripts/gen-appsets.sh writes
# the few values the ApplicationSets need into them, and
# scripts/check-contract.sh fails if a generated file has drifted.
project: lfi
owner: YOUR_GITHUB_USER
repo: lfi-infrastructure-gitops
stateBucket: YOUR_STATE_BUCKET
namespacePrefix: platform
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
XEOF
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
yq '.clusters[].name' platform/registry.yaml | tr '\n' ' '; echo
grep -h 'key ' terraform/*/*/backend.tf
```
Expected: your owner and bucket (neither may contain `YOUR_`), then `local eks`, then four keys beginning `local-platform/` (two) and `lfi-eks/` (two), matching `stateKeyPrefix`. Task 21.2.2 depends on that match.

#### Task 19.2.2: One subscription per service per cluster

**Goal:** `platform/subscriptions/<cluster>/<service>.yaml` for each of today's two services on each of the two clusters. Nothing reads them yet.

**Why a file per cluster and not one list:** clusters are allowed to differ. A service can be on `local` and not yet on `eks`, exactly as add-ons are enabled per cluster. A subscription is also the unit the ApplicationSets generate from, so one file means one thing deployed.

**What the fields mean.** `name`, `team` and `role` are for people and menus. `dependsOn` means "calls": the dependency is released and promoted first. `configRepo` is where ArgoCD finds the service's manifests; it must follow the pattern `<project>-<service>-config` because the `teams` project (Task 20.2.2) trusts repositories by that pattern. `promotion` tells the release tooling which two environments it moves a tag between; a team that calls its environments something else changes it here.

```bash
S="$PLATFORM_HOME/.tmp/g4"
mkdir -p "$S"
cat > "$S/subscribe.sh" <<'XEOF'
set -euo pipefail
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
OWNER="$(yq '.owner' platform/registry.yaml)"
PROJECT="$(yq '.project' platform/registry.yaml)"

# service|team|role|dependsOn (a YAML flow list, or empty)
SERVICES=(
  "service-1|team-1|the gateway. Calls service-2.|[service-2]"
  "service-2|team-2|the worker. Release and promote it first.|"
)

for cluster in $(yq '.clusters[].name' platform/registry.yaml); do
  mkdir -p "platform/subscriptions/$cluster"
  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r name team role deps <<< "$entry"
    f="platform/subscriptions/$cluster/$name.yaml"
    {
      echo "# $name on the $cluster cluster. The ApplicationSets read this file."
      echo "name: $name"
      echo "team: $team"
      echo "role: $role"
      [[ -n "$deps" ]] && echo "dependsOn: $deps"
      echo "# The repo ArgoCD reads this service's manifests from. The team owns it."
      echo "configRepo: https://github.com/$OWNER/$PROJECT-$name-config.git"
      echo "# Which environments a release promotes between. Defaults to dev then prod."
      echo "promotion:"
      echo "  from: dev"
      echo "  to: prod"
    } > "$f"
  done
done
XEOF
bash "$S/subscribe.sh"
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
ls platform/subscriptions/*
cat platform/subscriptions/local/service-1.yaml
```
Expected: `service-1.yaml` and `service-2.yaml` under both `eks` and `local`, and a service-1 file whose `configRepo` is `https://github.com/<your owner>/lfi-service-1-config.git` and whose `dependsOn` is `[service-2]`. The repositories it names do not exist yet. Phase 20.1 creates them.

#### Task 19.2.3: A contract check that fails loudly

**Goal:** `scripts/check-contract.sh`, a read-only script that compares the repo to the registry and the subscriptions and exits non-zero when they disagree. You run it after every structural change in this guide.

**Why:** Pluggable means many places must agree: a subscription must name a real cluster, a config repo that follows the naming convention, and dependencies that exist. The generated ApplicationSets repeat values from the registry, so they can drift. One wrong word otherwise shows up weeks later as an Application that silently never appears. The check turns that into an error at the moment you cause it.

First the small reader the script and later scripts share. It is written for macOS bash 3.2: no `mapfile`, no associative arrays, and no expanding an empty array under `set -u`.
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
mkdir -p scripts
cat > scripts/reg.sh <<'XEOF'
# Reads platform/registry.yaml and platform/subscriptions/. Sourced by other
# scripts, never run directly. Written for bash 3.2 (macOS): no mapfile and no
# associative arrays.
# bash sets BASH_SOURCE; zsh (an interactive shell here) sets $0 to the sourced file.
_reg_src="${BASH_SOURCE[0]:-$0}"
GITOPS_ROOT="$(cd "$(dirname "$_reg_src")/.." && pwd)"
REGISTRY="${REGISTRY:-$GITOPS_ROOT/platform/registry.yaml}"
SUBSCRIPTIONS="${SUBSCRIPTIONS:-$GITOPS_ROOT/platform/subscriptions}"

# registry_list '<yq expression>' fills REGISTRY_LIST, one array element per line.
registry_list() {
  REGISTRY_LIST=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && REGISTRY_LIST+=("$line")
  done < <(yq "$1" "$REGISTRY")
}

registry_list '.clusters[].name'; LFI_CLUSTERS=("${REGISTRY_LIST[@]}")
NAMESPACE_PREFIX="$(yq '.namespacePrefix' "$REGISTRY")"
PROJECT="$(yq '.project' "$REGISTRY")"
OWNER="$(yq '.owner' "$REGISTRY")"

# cluster_field <cluster> <field>: prints the value, or fails if there is none.
cluster_field() {
  local v
  v="$(C="$1" yq '.clusters[] | select(.name == strenv(C)) | .'"$2" "$REGISTRY")"
  [[ -n "$v" && "$v" != null ]] || return 1
  echo "$v"
}
cluster_context() { cluster_field "$1" context; }

# --- Services come from subscriptions, not from the registry. ---

# subscription_files lists every subscription file, one per service per cluster.
subscription_files() { ls "$SUBSCRIPTIONS"/*/*.yaml 2>/dev/null || true; }

# The services any cluster subscribes to, once each, in name order.
LFI_SERVICES=()
while IFS= read -r _f; do
  [[ -n "$_f" ]] && LFI_SERVICES+=("$(yq '.name' "$_f")")
done < <(subscription_files)
if [[ ${#LFI_SERVICES[@]} -gt 0 ]]; then
  LFI_SERVICES=($(printf '%s\n' "${LFI_SERVICES[@]}" | sort -u))
fi

# The first subscription file that names this service. Fields every cluster
# shares (role, dependsOn, configRepo, promotion) are read from it.
service_file() {
  local f
  for f in $(subscription_files); do
    [[ "$(yq '.name' "$f")" == "$1" ]] && { echo "$f"; return 0; }
  done
  return 1
}
service_field() { # <service> <yq path>, empty if unset
  local f v
  f="$(service_file "$1")" || return 0
  v="$(yq "$2" "$f")"
  [[ "$v" == null ]] && v=""
  echo "$v"
}
service_role()       { service_field "$1" .role; }
service_config_url() { service_field "$1" .configRepo; }
# Services that <service> calls.
service_deps() { local f; f="$(service_file "$1")" || return 0; yq '.dependsOn[]?' "$f"; }
# Services that call <service>.
service_dependents() {
  local s
  for s in "${LFI_SERVICES[@]}"; do
    [[ " $(service_deps "$s" | tr '\n' ' ') " == *" $1 "* ]] && echo "$s"
  done
  return 0
}

# The environment a release promotes from and to. A team declares it in its
# subscription; the default is dev to prod.
promote_from() { local v; v="$(service_field "$1" .promotion.from)"; echo "${v:-dev}"; }
promote_to()   { local v; v="$(service_field "$1" .promotion.to)";   echo "${v:-prod}"; }

# Where the service's config repo is checked out on this machine: a sibling of
# this repo, named like the repo on GitHub.
service_config_dir() {
  local url
  url="$(service_config_url "$1")"
  [[ -n "$url" ]] || return 1
  echo "$(dirname "$GITOPS_ROOT")/$(basename "$url" .git)"
}

# The environments a service has on a cluster: one directory per environment
# in its config repo, found by the env.yaml inside it.
service_envs() { # <service> <cluster>
  local dir f
  dir="$(service_config_dir "$1")" || return 0
  for f in "$dir/$2"/*/env.yaml; do
    [[ -f "$f" ]] && basename "$(dirname "$f")"
  done
  return 0
}
XEOF

cat > scripts/check-contract.sh <<'XEOF'
#!/usr/bin/env bash
# Fails loudly when the repo stops matching platform/registry.yaml and the
# subscriptions. Read-only. Run it after any structural change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/reg.sh"

# --online also checks that every config repository named by a subscription can
# be reached. One unreachable repository stops the ApplicationSets from
# generating anything at all until it is fixed, so this is worth asking before a
# subscription ships.
ONLINE=0
[[ "${1:-}" == "--online" ]] && ONLINE=1

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }

# Cluster identity agrees with the files that hard-code it.
for cluster in "${LFI_CLUSTERS[@]}"; do
  [[ -d "argocd/apps-$cluster" ]] || fail "missing argocd/apps-$cluster"
  [[ -d "terraform/$cluster" ]] || fail "missing terraform/$cluster"
done
k3d_name="$(yq '.clusters[] | select(.kind == "k3d") | .clusterName' "$REGISTRY")"
cfg_name="$(yq '.metadata.name' terraform/local/01-cluster/k3d-config.yaml)"
[[ "$k3d_name" == "$cfg_name" ]] || fail "registry says the k3d cluster is '$k3d_name' but k3d-config.yaml says '$cfg_name'"

# Every subscription is well formed, sits in the directory of a known cluster,
# and points at the config repo this project's naming convention allows. The
# AppProject trusts repos by that name pattern, so a subscription outside it
# would be created and then refused.
for f in $(subscription_files); do
  cluster="$(basename "$(dirname "$f")")"
  name="$(yq '.name' "$f")"
  url="$(yq '.configRepo' "$f")"
  [[ " ${LFI_CLUSTERS[*]} " == *" $cluster "* ]] || fail "$f is under '$cluster', which is not a cluster in the registry"
  [[ "$name" == "$(basename "$f" .yaml)" ]] || fail "$f names service '$name': the file name must match"
  for key in name team role configRepo; do
    v="$(K="$key" yq '.[strenv(K)]' "$f")"
    [[ -n "$v" && "$v" != null ]] || fail "$f has no '$key'"
  done
  want="https://github.com/$OWNER/$PROJECT-$name-config.git"
  [[ "$url" == "$want" ]] || fail "$f: configRepo is $url, expected $want"
  for dep in $(yq '.dependsOn[]?' "$f"); do
    [[ " ${LFI_SERVICES[*]} " == *" $dep "* ]] || fail "$f: dependsOn $dep, which has no subscription"
  done
done

# A service subscribed on one cluster must say the same thing about its config
# repo on every cluster, or the clusters would read different repos by accident.
for svc in "${LFI_SERVICES[@]}"; do
  urls="$(for f in $(subscription_files); do
    if [[ "$(yq '.name' "$f")" == "$svc" ]]; then yq '.configRepo' "$f"; fi
  done | sort -u | wc -l | tr -d ' ')"
  [[ "$urls" == 1 ]] || fail "$svc is subscribed with $urls different configRepo values"
done

# Manifests under argocd/ repeat the repo URL because ArgoCD cannot read the
# registry. Any Git URL (one ending in .git) in a repoURL field must match it.
# Helm chart repositories do not end in .git, so they are ignored.
want_url="https://github.com/$OWNER/$(yq '.repo' "$REGISTRY").git"
for f in $(find argocd -name '*.yaml' 2>/dev/null); do
  while IFS= read -r url; do
    [[ "$url" == "$want_url" ]] || fail "$f names repoURL $url, registry says $want_url"
  done < <(yq '.. | select(has("repoURL")) | .repoURL' "$f" 2>/dev/null | grep '\.git$' | grep -v '{{' || true)
done

if [[ "$ONLINE" -eq 1 ]]; then
  for svc in "${LFI_SERVICES[@]}"; do
    url="$(service_config_url "$svc")"
    # No credential prompt: a repository that does not exist asks for a login.
    if ! GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code "$url" HEAD >/dev/null 2>&1; then
      fail "$svc's config repository $url cannot be reached"
    fi
  done
fi

# The ApplicationSets and the teams project are generated from the registry.
# Regenerate into a temporary directory and compare, so a hand edit, or a
# registry change that forgot to regenerate, is caught. Only once the generator
# exists (Phase 20.2) and only for files that have been put in place.
if [[ -x "$SCRIPT_DIR/gen-appsets.sh" ]]; then
  gen="$(mktemp -d)"; trap 'rm -rf "$gen"' EXIT
  "$SCRIPT_DIR/gen-appsets.sh" "$gen" >/dev/null
  for cluster in "${LFI_CLUSTERS[@]}"; do
    for kind in services data; do
      f="argocd/apps-$cluster/appsets/$kind.yaml"
      if [[ -f "$f" ]] && ! diff -q "$f" "$gen/$kind-$cluster.yaml" >/dev/null; then
        fail "$f differs from scripts/gen-appsets.sh. Regenerate it: scripts/gen-appsets.sh"
      fi
    done
    f="argocd/apps-$cluster/projects/teams.yaml"
    if [[ -f "$f" ]] && ! diff -q "$f" "$gen/teams-$cluster.yaml" >/dev/null; then
      fail "$f differs from scripts/gen-appsets.sh. Regenerate it: scripts/gen-appsets.sh"
    fi
  done
fi

if [[ "$FAILS" -gt 0 ]]; then
  echo "$FAILS problem(s). The repo and its registry or subscriptions disagree." >&2
  exit 1
fi
echo "OK: ${#LFI_SERVICES[@]} service(s) x ${#LFI_CLUSTERS[@]} cluster(s) match the registry."
XEOF
chmod +x scripts/check-contract.sh
```

**Validate:** it passes on the repo as it is, and it fails when you break something.
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
scripts/check-contract.sh

mkdir -p platform/subscriptions/mars && cp platform/subscriptions/eks/service-2.yaml platform/subscriptions/mars/
scripts/check-contract.sh; echo "exit code: $?"
rm -r platform/subscriptions/mars

yq -i '.configRepo = "https://github.com/someone/else.git"' platform/subscriptions/eks/service-2.yaml
scripts/check-contract.sh; echo "exit code: $?"
yq -i ".configRepo = \"https://github.com/$(yq '.owner' platform/registry.yaml)/lfi-service-2-config.git\"" platform/subscriptions/eks/service-2.yaml

yq -i '.dependsOn = ["nope"]' platform/subscriptions/local/service-1.yaml
scripts/check-contract.sh; echo "exit code: $?"
yq -i '.dependsOn = ["service-2"]' platform/subscriptions/local/service-1.yaml

scripts/check-contract.sh
```
Expected: `OK: 2 service(s) x 2 cluster(s) match the registry.`, then `FAIL: ... is under 'mars', which is not a cluster in the registry` with exit code `1`, then `FAIL: ... configRepo is https://github.com/someone/else.git, expected ...` (and a second failure saying `service-2` is subscribed with 2 different `configRepo` values) with exit code `1`, then `FAIL: ... dependsOn nope, which has no subscription` with exit code `1`, then `OK` again. The last run proves you put everything back.

---

## Section 20: Pluggable services

**Objective:** Adding a service is a scaffold command, a repository and a merge. Removing one is deleting its subscriptions. A team adds an environment by adding a directory to its own repository. The six Applications on the local cluster are generated instead of hand-written, their manifests live in repositories their teams own, and you can prove nothing was recreated while that happened.

**Order of work:** Phase 20.1 creates the new repositories and changes nothing a cluster can see. Phase 20.2 generates the ApplicationSets without applying them, and tests the generators on a throwaway set. Phase 20.3 is the only phase that touches the live cluster and the services' CI. Phase 20.4 and 20.5 are tooling. Phase 20.6 proves the result.

**Freeze releases.** From the start of Task 20.1.2 until Task 20.4.2 has replaced `release.sh`, do not run `gmake release` and do not merge a release PR. The config repos are seeded from the current prod tags, and a prod tag that moves in the old overlays afterwards would make the two disagree. After the cutover the old script would edit files nothing reads. Dev is fine: CI writes both places during the migration, and only the config repo afterwards.

A note on merging. ArgoCD reads `main` of the GitOps repo, so several tasks here end with the same **ship** step. Create it once:
```bash
S="$PLATFORM_HOME/.tmp/g4"
cat > "$S/ship.sh" <<'XEOF'
#!/usr/bin/env bash
# usage: ship.sh "<commit message>"   Stage the files first with git add.
# Commits what is staged (if anything) on the feature branch, merges it into main
# with a merge commit, pushes,
# then brings the merge commit back so the next ship merges cleanly.
set -euo pipefail
: "${PLATFORM_HOME:?PLATFORM_HOME is not set. Export it (guide 1, Task 1.2.1).}"
BRANCH=feat/pluggable-structure
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
[[ "$(git branch --show-current)" == "$BRANCH" ]] || { echo "ERROR: not on $BRANCH." >&2; exit 1; }
git diff --cached --quiet || git commit -m "$1"
git switch main
git pull --ff-only
git merge --no-ff "$BRANCH" -m "Merge: $1"
git push origin main
git switch "$BRANCH"
git merge --ff-only main
echo "Shipped: $1"
XEOF
chmod +x "$S/ship.sh"
```
Run it as `bash "$S/ship.sh" "message"`. **Stop if `git merge` reports a conflict or `git push` is rejected.** Your work is safe on the branch and nothing has been deleted. A conflict on a file under `kubernetes/overlays/` means a service's CI pushed a new tag to `main` while you were working; Appendix I has the fix.

### Primer: what a Component is, and why it lives in another repository

A Kustomize **Component** is a bundle of patches that an environment opts into with `components:`. Unlike a base, it does not hold resources; it holds changes. Three behaviors were copy-pasted into every service's overlay in guides 2 and 3: the dev replica count, the prod canary steps and the Ingress host.

Two of them are properties of a *behavior* and not of a service: "run one replica" and "canary at 50 percent and wait for a person". Those become components in the templates repository, named for what they do. The patches target a *kind* and omit a name, so they apply to every Rollout in the service that opts in, and a patch whose target matches nothing is skipped by Kustomize 5.

The Ingress host is different. A component cannot take a parameter, so it cannot say `dev.localhost` for one environment and `prod.localhost` for another. That stays in the team's own kustomization, which is where the team's knowledge about its environment belongs anyway.

An environment names a component by **remote reference**, pinned to a tag:
```
components:
  - https://github.com/<owner>/lfi-service-templates//components/replicas-1?ref=v1.0.0
```
The part after `//` is a path inside the repository, and `?ref=` is a tag. ArgoCD's repo server fetches it when it renders the Application. Because it is pinned, a template change reaches an environment only when its team moves the tag, and a template tag is the platform's way of releasing a change to every team without a flag day.

### Primer: copy once, or reference live

The templates repository also holds **scaffolds**: a complete starting point for a web service and for a database. The scaffolder (Phase 20.5) copies one into a new config repository and fills in the name. From then on the manifests belong to the team.

They are copied, not referenced, on purpose. A reference would let one edit in the templates repository change every service at once, including ones whose team did not ask for it. Components get away with being references because they are small, pinned by tag and opt-in. A whole service's manifests are none of those.

The price is that an improvement to a scaffold reaches existing services only if their teams copy it. That is the right default for a platform that does not own its teams' code.

### Phase 20.1: The templates repo and the config repos

**Objective:** The new repositories exist on GitHub, the config repos render exactly what the old overlays render, and nothing about a cluster has changed.

#### Task 20.1.1: Build and publish the templates repo

**Goal:** `lfi-service-templates` on GitHub with three components and two scaffolds, tagged `v1.0.0`.

**Why public:** ArgoCD's repo server fetches the components anonymously when it renders an Application. Guide 1 already chose public repositories for the same reason.

The script writes the whole repository from nothing, and refuses to run if the directory exists:
```bash
S="$PLATFORM_HOME/.tmp/g4"
cat > "$S/build-templates.sh" <<'XEOF'
set -euo pipefail
: "${PLATFORM_HOME:?PLATFORM_HOME is not set. Export it (guide 1, Task 1.2.1).}"
PROJECT="$(yq '.project' "$PLATFORM_HOME/lfi-infrastructure-gitops/platform/registry.yaml")"
T="$PLATFORM_HOME/$PROJECT-service-templates"
[[ ! -e "$T" ]] || { echo "ERROR: $T already exists." >&2; exit 1; }
mkdir -p "$T/components/replicas-1" "$T/components/canary-manual-gate" "$T/components/storage-gp3" \
         "$T/scaffolds/web-service" "$T/scaffolds/db-service"
cd "$T"

# ---------------------------------------------------------------- components
cat > components/replicas-1/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
patches:
  # DO NOT use kustomize's `replicas:` field. Its built-in transformer only
  # knows Deployment, ReplicaSet, StatefulSet and ReplicationController. A
  # Rollout is a custom resource, so `replicas:` matches nothing and reports
  # nothing: you get the base's replica count and no sign anything is wrong.
  # A JSON6902 patch names the group and kind, so a mismatch is an error.
  #
  # No `name:` in the target, so this applies to every Rollout in the service.
  - target:
      group: argoproj.io
      version: v1alpha1
      kind: Rollout
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 1
EOF

cat > components/canary-manual-gate/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
patches:
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

cat > components/storage-gp3/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
patches:
  # The db-service scaffold asks for local-path, k3d's provisioner. On EKS the
  # equivalent is the gp3 class created in guide 3. No name in the target: it
  # applies to every StatefulSet in the service.
  - target:
      kind: StatefulSet
    patch: |-
      - op: replace
        path: /spec/volumeClaimTemplates/0/spec/storageClassName
        value: gp3
EOF

# ------------------------------------------------------- scaffold: web-service
cat > scaffolds/web-service/kustomization.yaml <<'EOF'
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
cat > scaffolds/web-service/rollout.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: __NAME__
  labels:
    app: __NAME__
spec:
  # The prod default. The replicas-1 component patches this down to 1.
  replicas: 2
  progressDeadlineSeconds: 600
  selector:
    matchLabels:
      app: __NAME__
  strategy:
    canary:
      # One step, straight to 100%. The canary-manual-gate component replaces
      # these steps with the 50 percent pause.
      steps:
        - setWeight: 100
  template:
    metadata:
      labels:
        app: __NAME__
    spec:
      containers:
        - name: __NAME__
          # Bare name, rewritten by the environment's images: block.
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
cat > scaffolds/web-service/service.yaml <<'EOF'
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

# -------------------------------------------------------- scaffold: db-service
cat > scaffolds/db-service/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - service.yaml
  - statefulset.yaml
# Labels on the objects and the pod template, never on selectors: a
# StatefulSet's selector is immutable once created.
labels:
  - pairs:
      app.kubernetes.io/part-of: local-platform
    includeTemplates: true
EOF
cat > scaffolds/db-service/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: __NAME__
  labels:
    app: __NAME__
spec:
  # Headless: no cluster IP, DNS resolves straight to the pod.
  clusterIP: None
  selector:
    app: __NAME__
  ports:
    - name: db
      port: __PORT__
      targetPort: db
EOF
cat > scaffolds/db-service/statefulset.yaml <<'EOF'
# A Postgres StatefulSet. The probes and the credentials Secret are
# Postgres-specific; for another database change the image, the port, the
# probes and the Secret reference together.
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: __NAME__
  labels:
    app: __NAME__
spec:
  serviceName: __NAME__
  # One replica. Raising this number gives two independent databases, not a
  # cluster. Real HA needs an operator.
  replicas: 1
  selector:
    matchLabels:
      app: __NAME__
  template:
    metadata:
      labels:
        app: __NAME__
    spec:
      securityContext:
        # The postgres image runs as uid/gid 999. fsGroup makes the mounted
        # volume group-writable by that user.
        fsGroup: 999
      containers:
        - name: db
          image: postgres:16-alpine
          ports:
            - name: db
              containerPort: __PORT__
          envFrom:
            # POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB, created by
            # Terraform in each environment's namespace.
            - secretRef:
                name: postgres-credentials
          env:
            # A subdirectory, because Postgres refuses to initialise into a
            # mount root that already holds anything (lost+found).
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
          readinessProbe:
            exec:
              command: ["sh", "-c", 'exec pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" -h 127.0.0.1']
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 6
          livenessProbe:
            exec:
              command: ["sh", "-c", 'exec pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" -h 127.0.0.1']
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests:
            storage: __STORAGE__
EOF

cat > README.md <<'EOF'
# Service templates

Owned by the platform. Teams may open PRs for templates they need.

## components/

Behaviour a service opts into from its own environment kustomization, as a
remote component pinned to a tag of this repository:

    components:
      - https://github.com/<owner>/<this repo>//components/replicas-1?ref=v1.0.0

| Component | What it does |
|-----------|--------------|
| `replicas-1` | Every Rollout runs one replica (dev). |
| `canary-manual-gate` | Every Rollout canaries at 50 percent and waits for a person. |
| `storage-gp3` | Every StatefulSet uses the `gp3` storage class (EKS). |

A component cannot take a parameter. Anything that differs per service or per
environment, such as an Ingress host, stays in the team's own kustomization.

## scaffolds/

Starting points. `scripts/new-service.sh` in the GitOps repo copies
`web-service` into a new config repo and fills in the `__PLACEHOLDERS__`.
After that the manifests belong to the team; they are copied once, not
referenced. For a database, copy `db-service` the same way.

## Versions

Every change that environments should pick up is a new tag (`v1.0.1`). Nothing
moves until a team changes the `?ref=` in its own repo.
EOF
git init -q -b main
git add -A
git commit -qm "templates: components and scaffolds"
echo "Created $T"
XEOF
bash "$S/build-templates.sh"
```
Publish it, with a tag teams can pin to:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
OWNER="$(yq '.owner' platform/registry.yaml)"; PROJECT="$(yq '.project' platform/registry.yaml)"
cd "$PLATFORM_HOME/$PROJECT-service-templates"
git tag -a v1.0.0 -m "First release: three components, two scaffolds"
GH_HOST=github.com gh repo create "$OWNER/$PROJECT-service-templates" --public --source . --push
git push origin v1.0.0
git branch -u origin/main main
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
OWNER="$(yq '.owner' platform/registry.yaml)"; PROJECT="$(yq '.project' platform/registry.yaml)"
git ls-remote --tags "https://github.com/$OWNER/$PROJECT-service-templates.git" v1.0.0 | wc -l
cd "$PLATFORM_HOME/$PROJECT-service-templates"
git status -sb | head -1
ls components scaffolds
```
Expected: `1`, `## main...origin/main`, and the directory names `canary-manual-gate replicas-1 storage-gp3` and `db-service web-service`.

#### Task 20.1.2: Seed the config repos from what runs today

**Goal:** `lfi-service-1-config` and `lfi-service-2-config` on GitHub. Each holds the service's current manifests and, for every cluster and environment, a directory that renders what the old overlay renders.

**Why seeded from the old overlays and not written fresh:** the point of this phase is that nothing changes. The script reads each old overlay's image name and tag, copies each service's base as it is, and writes the new environment files around them.

**Why service-1's config repo also holds Postgres:** only service-1 reads the database, so service-1's team owns it. It is a datastore directory beside `app/` (`<cluster>/<env>/postgres/`), and the data ApplicationSet gives it its own safer policy. If two services ever share a database, give it to one of them and document it.

**What each environment file does.** `env.yaml` marks the directory as an environment (and is where a team can set an optional `namespace`). `app/kustomization.yaml` holds the namespace, the behavior components the environment opts into, the Ingress host if the service has an Ingress, and the image. Dev gets `replicas-1`, prod gets `canary-manual-gate`, EKS Postgres gets `storage-gp3`.

First make sure the GitOps repo is at the latest tags, then seed:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git fetch origin
git merge --ff-only origin/main
S="$PLATFORM_HOME/.tmp/g4"
cat > "$S/seed-config-repos.sh" <<'XEOF'
set -euo pipefail
: "${PLATFORM_HOME:?PLATFORM_HOME is not set. Export it (guide 1, Task 1.2.1).}"
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
source scripts/reg.sh

# Where the templates live. Overridable so a rehearsal can point at a local copy.
TEMPLATES_URL="${TEMPLATES_URL:-https://github.com/$OWNER/$PROJECT-service-templates}"
TEMPLATES_REF="${TEMPLATES_REF:-v1.0.0}"
# Which service's team owns the shared database. Only service-1 reads it.
DB_OWNER="${DB_OWNER:-service-1}"
GH_URL="https://github.com/$OWNER"

# The remote component reference every environment uses.
comp() { echo "${TEMPLATES_URL}//components/$1?ref=${TEMPLATES_REF}"; }

for svc in "${LFI_SERVICES[@]}"; do
  CFG="$(service_config_dir "$svc")"
  [[ ! -e "$CFG" ]] || { echo "ERROR: $CFG already exists." >&2; exit 1; }
  mkdir -p "$CFG/base" "$CFG/.github"

  # The service's own manifests, copied as they are. From here on they belong
  # to the team, not to the platform.
  cp -R "kubernetes/base/$svc" "$CFG/base/app"
  if [[ "$svc" == "$DB_OWNER" ]]; then cp -R kubernetes/base/postgres "$CFG/base/postgres"; fi

  for cluster in "${LFI_CLUSTERS[@]}"; do
    for env in dev prod; do
      old="kubernetes/overlays/$cluster/$env/$svc/kustomization.yaml"
      name="$(yq '.images[0].newName' "$old")"
      tag="$(yq '.images[0].newTag' "$old")"
      dir="$CFG/$cluster/$env"
      mkdir -p "$dir/app"

      # Dev runs one replica. Prod canaries at 50 percent and waits for a person.
      if [[ "$env" == dev ]]; then behaviour=replicas-1; else behaviour=canary-manual-gate; fi

      printf '# This directory is one environment of %s on the %s cluster.\n# ArgoCD finds it by this file.\nenv: %s\n' "$svc" "$cluster" "$env" > "$dir/env.yaml"

      {
        cat <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# Injected into every resource the base produces.
namespace: $NAMESPACE_PREFIX-$env
resources:
  - ../../../base/app
# Behaviour this environment opts into, from the platform's template repository,
# pinned to a tag. Changing ?ref= is how this environment takes a new version.
components:
  - $(comp "$behaviour")
EOF
        if [[ -f "$CFG/base/app/ingress.yaml" ]]; then
          case "$cluster-$env" in
            local-dev) host=dev.localhost ;;   local-prod) host=prod.localhost ;;
            eks-dev)   host=dev.eks.test ;;    eks-prod)   host=prod.eks.test ;;
            *)         host="$env.$cluster.test" ;;
          esac
          cat <<EOF
patches:
  # The base Ingress deliberately has no host, so it matches any Host header.
  # Two of those would collide in one cluster, so each environment adds its own.
  # A component cannot take a parameter, so this stays here, in the team's file.
  # JSON6902, because Ingress \`rules\` is a list with no merge key and a strategic
  # merge would replace the whole list.
  - target:
      kind: Ingress
    patch: |-
      - op: add
        path: /spec/rules/0/host
        value: $host
EOF
        fi
        cat <<EOF
# The FULL image reference lives here, newName and newTag together. This newTag
# field is the only thing this service's CI ever writes.
images:
  - name: $svc
    newName: $name
    newTag: $tag
EOF
      } > "$dir/app/kustomization.yaml"

      if [[ "$svc" == "$DB_OWNER" ]]; then
        mkdir -p "$dir/postgres"
        {
          cat <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $NAMESPACE_PREFIX-$env
resources:
  - ../../../base/postgres
EOF
          if [[ "$cluster" == eks ]]; then
            cat <<EOF
# The base asks for local-path, k3d's provisioner. On EKS the equivalent is gp3.
components:
  - $(comp storage-gp3)
EOF
          fi
        } > "$dir/postgres/kustomization.yaml"
      fi
    done
  done

  cat > "$CFG/.github/CODEOWNERS" <<EOF
# This repository belongs to the team that runs $svc. What it protects is the
# team's decision; the platform only suggests. Prod changes need a review:
/*/prod/    @$OWNER
EOF
  cat > "$CFG/README.md" <<EOF
# $PROJECT-$svc-config

Kubernetes manifests for $svc, one directory per cluster and environment:

    <cluster>/<environment>/env.yaml       marks an environment (ArgoCD finds it)
    <cluster>/<environment>/app/           what runs
    <cluster>/<environment>/postgres/      the database, if this team owns one
    base/                                  the service's own manifests

The platform reads this repository because platform/subscriptions/ in
$PROJECT-infrastructure-gitops names it. CI writes \`images[0].newTag\` in
<cluster>/dev/app/kustomization.yaml. A release moves that tag to prod.
EOF
  git -C "$CFG" init -q -b main
  git -C "$CFG" add -A
  git -C "$CFG" commit -qm "seed: manifests and image tags from the GitOps repo"
  echo "Seeded $CFG"
done
XEOF
bash "$S/seed-config-repos.sh"
```
The `git merge --ff-only` brings your branch up to date with `main`, which is where CI commits tags. The branch has no commits of its own yet, so it is a fast-forward; if Git refuses, you committed something on the branch already, and `git rebase origin/main` is the fix.

Publish both:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
source scripts/reg.sh
for svc in "${LFI_SERVICES[@]}"; do
  dir="$(service_config_dir "$svc")"
  GH_HOST=github.com gh repo create "$OWNER/$(basename "$dir")" --public --source "$dir" --push
  git -C "$dir" branch -u origin/main main
done
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
source scripts/reg.sh
for svc in "${LFI_SERVICES[@]}"; do
  dir="$(service_config_dir "$svc")"
  printf '%s: ' "$(basename "$dir")"; git -C "$dir" ls-remote --heads origin main | wc -l
  git -C "$dir" status -sb | head -1
done
find "$(service_config_dir service-1)" -name env.yaml | wc -l
yq '.images[0].newTag' "$(service_config_dir service-1)/local/dev/app/kustomization.yaml" kubernetes/overlays/local/dev/service-1/kustomization.yaml
```
Expected: `1` and `## main...origin/main` for each repo, `4` environment files in service-1's repo (two clusters, two environments), and the same tag twice. The repos exist and match, but no cluster reads them yet.

#### Task 20.1.3: Prove the render did not change

**Goal:** Every service and datastore, on both clusters and both environments, renders exactly the same manifests from its config repo as from the old overlay. This is the whole safety argument for Phase 20.1.

**Why a script that builds both and compares, not a snapshot:** CI moves image tags in the old overlays at any time. A snapshot taken earlier goes stale and reports a difference that is only a tag. This script reads both sides now.

The script also fetches the pinned components from GitHub, exactly as ArgoCD will, so a wrong URL or a missing tag fails here, in a terminal, and not later inside a cluster.
```bash
S="$PLATFORM_HOME/.tmp/g4"
cat > "$S/parity.sh" <<'XEOF'
#!/usr/bin/env bash
# Builds every service and datastore twice, once from the GitOps repo's old
# overlays and once from the service's config repo, and compares the output.
# Identical output means moving the manifests changed nothing a cluster can see.
set -euo pipefail
: "${PLATFORM_HOME:?PLATFORM_HOME is not set. Export it (guide 1, Task 1.2.1).}"
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
source scripts/reg.sh
DB_OWNER="${DB_OWNER:-service-1}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

checked=0; bad=0
compare() { # <label> <old dir> <new dir>
  kustomize build "$2" > "$OUT/old.yaml"
  kustomize build "$3" > "$OUT/new.yaml"
  checked=$((checked + 1))
  if ! diff -q "$OUT/old.yaml" "$OUT/new.yaml" >/dev/null; then
    bad=$((bad + 1)); echo "DIFFERENT: $1"; diff "$OUT/old.yaml" "$OUT/new.yaml" | head -10
  fi
}

for svc in "${LFI_SERVICES[@]}"; do
  cfg="$(service_config_dir "$svc")"
  for cluster in "${LFI_CLUSTERS[@]}"; do
    for env in dev prod; do
      compare "$cluster/$env/$svc" "kubernetes/overlays/$cluster/$env/$svc" "$cfg/$cluster/$env/app"
      if [[ "$svc" == "$DB_OWNER" ]]; then
        compare "$cluster/$env/postgres" "kubernetes/overlays/$cluster/$env/postgres" "$cfg/$cluster/$env/postgres"
      fi
    done
  done
done

if [[ "$bad" -eq 0 ]]; then echo "IDENTICAL: $checked builds match."; else echo "$bad of $checked builds differ."; exit 1; fi
XEOF
chmod +x "$S/parity.sh"
"$S/parity.sh"
```

**Validate:** the last line is `IDENTICAL: 12 builds match.` (eight service builds and four Postgres builds) and nothing above it begins `DIFFERENT`. If it prints differences, read them: a difference in an `image:` line means a tag moved between your seed and now (re-run Task 20.1.2's tag check, or pull the config repo, since CI writes there too once Phase 20.3 starts); anything else is a bug in a component or in the seed, so fix the file in the config repo rather than the expectation. A `kustomize` error about fetching a URL means the templates tag or URL is wrong: check Task 20.1.1's validation.

#### Task 20.1.4: Decide how each team protects prod

**Goal:** A written decision, in each config repo, about who must review a change to prod. This is the team's call, not the platform's.

The seed already put a `.github/CODEOWNERS` in each config repo that names you as owner of `/*/prod/`. CODEOWNERS only gates anything once branch protection requires code owner review. Decide per repo whether you want that. The usual shape: require a pull request with a code owner review on `main`, and let the repository admin bypass it, because CI pushes dev tags straight to `main`.

Two things the platform does **not** do any more: it does not put prod paths in its own CODEOWNERS, and it does not pin prod to a revision. If a team wants prod gated, the team gates it. If the platform ever needs to stop a service quickly, it uses an override (Task 20.2.3 shows one), which is a platform tool and does not touch the team's repo.

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
source scripts/reg.sh
for svc in "${LFI_SERVICES[@]}"; do cat "$(service_config_dir "$svc")/.github/CODEOWNERS" | grep '^/'; done
```
Expected: `/*/prod/    @<your owner>` twice. Branch protection is optional and set in each repository's settings on GitHub; nothing later in this guide depends on it.

---

### Phase 20.2: Generate the ApplicationSets

**Objective:** The ApplicationSets and the project exist as generated files, staged outside the repo where nothing applies them, and the generator design is proven on a throwaway set before anything depends on it.

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

#### Task 20.2.2: Generate the ApplicationSets and the teams project

**Goal:** Six files staged in `$PLATFORM_HOME/.tmp/g4/appsets/` (services, data and the `teams` project, for each cluster), **not** in the repo, where `root` would apply them before you are ready.

**Why staged:** The `root` Application syncs everything under `argocd/apps-local`, recursively, as soon as it lands on `main`. An ApplicationSet whose generators match the services that today's Applications already manage would start creating duplicates. Staging keeps them inert until Phase 20.3 moves them in at the right moment.

**Why generated:** these files repeat three values the registry owns: the GitOps repo URL, the owner and the namespace prefix. ArgoCD cannot read the registry, so a script writes them in. The contract check regenerates into a temporary directory and compares, so a hand edit or a forgotten regeneration is caught.

**What the services set says.** The first generator reads the subscriptions for this cluster and, through a merge generator, lays the platform's optional override for the same `name` on top. The second generator reads the subscribed `configRepo` for `<cluster>/*/env.yaml`, one file per environment. The template names the Application `<service>-<env>` (with `-eks` on EKS), exactly as today's files do, points `source.path` at `<cluster>/<env>/app` in the team's repo, and belongs to the `teams` project. A team may put `namespace:` in its `env.yaml`; the project (below) refuses any that does not start with the platform's prefix.

**What the data set says.** Same first generator, then a directories generator over `<cluster>/*/postgres` in the team's repo. It carries every protection the hand-written Postgres Applications had: no prune, so a file removed from Git cannot delete the StatefulSet; `ignoreDifferences` for `volumeClaimTemplates`; no finalizer, so deleting the Application cannot delete the database; and `preserveResourcesOnDeletion`, so even deleting the *ApplicationSet* leaves the Postgres resources alone.

**What the project says.** AppProject `teams` is the boundary between "the platform trusts a team's repo to say what runs" and "a team's repo can run anything it likes". It allows only repositories named `<project>-*-config`, only namespaces starting with the platform's prefix, no cluster-scoped resources, and no Roles, RoleBindings, ResourceQuotas or LimitRanges, so a team cannot grant itself access or lift its limits.

Install the generator. It is a repo script because the stamp script (Task 21.4.1) and the contract check run it too:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
cat > scripts/gen-appsets.sh <<'XEOF'
#!/usr/bin/env bash
# Writes the ApplicationSets and the teams AppProject from platform/registry.yaml.
#
# Usage: scripts/gen-appsets.sh [output dir]
#   With no argument it writes into the repo, where the root Application picks
#   the files up:
#     argocd/apps-<cluster>/appsets/services.yaml
#     argocd/apps-<cluster>/appsets/data.yaml
#     argocd/apps-<cluster>/projects/teams.yaml
#   With a directory it writes services-<cluster>.yaml, data-<cluster>.yaml and
#   teams-<cluster>.yaml there instead, and touches nothing in the repo. The
#   cutover uses that to stage the files before they go live.
#
# ArgoCD cannot read the registry, so the few values the ApplicationSets need
# (the repo URL, the owner, the namespace prefix) are written into them here.
# scripts/check-contract.sh regenerates into a temporary directory and fails if
# a committed file differs, so a hand edit or a stale copy cannot go unnoticed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/reg.sh"

STAGE="${1:-}"
URL="https://github.com/$OWNER/$(yq '.repo' "$REGISTRY").git"

# out <kind> <cluster>: where a generated file goes.
out() {
  if [[ -n "$STAGE" ]]; then
    mkdir -p "$STAGE"; echo "$STAGE/$1-$2.yaml"
  else
    local dir="argocd/apps-$2/appsets"; [[ "$1" == teams ]] && dir="argocd/apps-$2/projects"
    mkdir -p "$dir"; echo "$dir/$1.yaml"
  fi
}

# Both ApplicationSets start from the same first generator: the services this
# cluster subscribes to. Written once here, indented to fit under
# `matrix.generators`. The merge generator lays a platform override on top of
# each subscription; if your ArgoCD does not accept the nesting, set
# `useMerge: false` in the registry and the plain subscription generator is
# used instead (Appendix I).
USE_MERGE="$(yq '.useMerge' "$REGISTRY")"
services_generator() { # <cluster>
  if [[ "$USE_MERGE" == "false" ]]; then
    cat <<EOF
          # 1. The services this cluster subscribes to.
          - git:
              repoURL: $URL
              revision: HEAD
              files:
                - path: platform/subscriptions/$1/*.yaml
EOF
    return 0
  fi
  cat <<EOF
          # 1. The services this cluster subscribes to. The merge generator
          #    takes each subscription as it is and lays the platform's optional
          #    override for the same name on top.
          - merge:
              mergeKeys: [name]
              generators:
                - git:
                    repoURL: $URL
                    revision: HEAD
                    # Keeps this generator's path values under .subscription, so
                    # they cannot collide with the .path of the second generator.
                    pathParamPrefix: subscription
                    files:
                      - path: platform/subscriptions/$1/*.yaml
                - git:
                    repoURL: $URL
                    revision: HEAD
                    pathParamPrefix: override
                    files:
                      - path: platform/overrides/$1/*.yaml
EOF
}

for c in $(yq '.clusters[].name' "$REGISTRY"); do
  sfx=""; [[ "$c" == eks ]] && sfx="-eks"

  cat > "$(out services "$c")" <<EOF
# One Application per service per environment on the $c cluster.
#
# Which services: platform/subscriptions/$c/*.yaml in this repository.
# Which environments: every <env>/env.yaml under $c/ in the service's own
# config repository. The team adds an environment by adding a directory; no
# change here is needed, though its namespace must exist (Terraform creates
# <prefix>-<env> for each name in its environments variable).
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
    - matrix:
        generators:
$(services_generator "$c")
          # 2. For each of those, the environments in its config repository.
          #    The second generator may use the first one's values: the
          #    repository to read is the subscription's configRepo.
          - git:
              repoURL: '{{ .configRepo }}'
              revision: '{{ get . "targetRevision" | default "HEAD" }}'
              files:
                - path: '$c/*/env.yaml'
  template:
    metadata:
      # Same names as the hand-written Applications this replaces, which is what
      # lets the new Application adopt what is already running.
      name: '{{ .name }}-{{ .env }}$sfx'
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      # Not "default": the teams project limits which repositories may be read,
      # which namespaces may be written, and forbids cluster-scoped resources.
      project: teams
      source:
        repoURL: '{{ .configRepo }}'
        targetRevision: '{{ get . "targetRevision" | default "HEAD" }}'
        # path.path is the directory env.yaml sits in, for example local/dev.
        path: '{{ .path.path }}/app'
      destination:
        server: https://kubernetes.default.svc
        # A team may name its own namespace in env.yaml. The project still
        # refuses any that does not start with the platform's prefix.
        namespace: '{{ get . "namespace" | default (printf "%s-%s" "$NAMESPACE_PREFIX" .env) }}'
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

  cat > "$(out data "$c")" <<EOF
# Datastores on the $c cluster. Same discovery as the services, but with every
# protection the hand-written postgres Applications had: no prune, no cascading
# delete, and the Application survives the directory being removed.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: data-$c
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  # If a postgres directory or a whole subscription disappears from Git, leave
  # the Application and everything it deployed alone. Losing a database to a bad
  # merge is not a mistake Git history can undo.
  syncPolicy:
    preserveResourcesOnDeletion: true
    applicationsSync: create-update
  generators:
    - matrix:
        generators:
$(services_generator "$c")
          # 2. Datastore directories in that service's config repository.
          - git:
              repoURL: '{{ .configRepo }}'
              revision: '{{ get . "targetRevision" | default "HEAD" }}'
              directories:
                # To add another kind of datastore, add a line here. Each one
                # needs this ApplicationSet's policy. Two services must not both
                # ship a datastore with the same directory name in one
                # environment: the Application names would collide.
                - path: '$c/*/postgres'
  template:
    metadata:
      # path.segments is [$c, <environment>, postgres].
      name: '{{ .path.basename }}-{{ index .path.segments 1 }}$sfx'
      # No finalizer: deleting this Application must not delete the database.
    spec:
      project: teams
      source:
        repoURL: '{{ .configRepo }}'
        targetRevision: '{{ get . "targetRevision" | default "HEAD" }}'
        path: '{{ .path.path }}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '$NAMESPACE_PREFIX-{{ index .path.segments 1 }}'
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

  cat > "$(out teams "$c")" <<EOF
# What team-owned repositories are allowed to do on the $c cluster. Every
# Application the ApplicationSets create belongs to this project, so this file
# is the boundary between "the platform trusts the team's repo to say what runs"
# and "the team's repo can run anything it likes".
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: teams
  namespace: argocd
spec:
  description: Services whose manifests live in team-owned config repositories.
  # Only repositories that follow the naming convention. The scaffolder and
  # scripts/check-contract.sh create and check names of this shape.
  sourceRepos:
    - https://github.com/$OWNER/$PROJECT-*-config.git
  # Only the platform's namespaces. A team that sets namespace: kube-system in
  # its env.yaml gets a sync error, not a deployment into kube-system.
  destinations:
    - server: https://kubernetes.default.svc
      namespace: '$NAMESPACE_PREFIX-*'
  # Nothing cluster-wide: no Namespaces, ClusterRoles, CRDs or webhooks.
  clusterResourceWhitelist: []
  # Inside its namespaces a team may not grant itself access or lift its limits.
  namespaceResourceBlacklist:
    - group: rbac.authorization.k8s.io
      kind: Role
    - group: rbac.authorization.k8s.io
      kind: RoleBinding
    - group: ""
      kind: ResourceQuota
    - group: ""
      kind: LimitRange
EOF
done
XEOF
chmod +x scripts/gen-appsets.sh
```
Create the platform override directories. An override is a file named for a service that carries that service's `name` and any values to lay over its subscription. The placeholder below names no service, so it changes nothing; it exists so the generator always has a file to read:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
for c in $(yq '.clusters[].name' platform/registry.yaml); do
  mkdir -p "platform/overrides/$c"
  cat > "platform/overrides/$c/_example.yaml" <<'XEOF'
# Platform overrides for this cluster. A file here is named after the service it
# adjusts and carries that service's name, plus the values to lay over its
# subscription. For example, to read a service's config repository at a tag,
# branch or commit instead of its main branch:
#
#   name: service-1
#   targetRevision: v1.4.0
#
# The team never sees this file and does not have to edit its own repository to
# be held back. Delete the file to release the hold.
#
# This placeholder names no service, so it changes nothing.
name: _example
XEOF
done
```
Generate into the staging directory:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
scripts/gen-appsets.sh "$PLATFORM_HOME/.tmp/g4/appsets"
ls "$PLATFORM_HOME/.tmp/g4/appsets"
```

**Validate.** Three checks, none of which touch the cluster's state.

First, the cluster's API server accepts the manifests' shape (this catches a misspelled field or a policy value the installed CRD does not know):
```bash
S="$PLATFORM_HOME/.tmp/g4"
for f in teams-local services-local data-local; do
  kubectl --context k3d-platform apply --dry-run=server -f "$S/appsets/$f.yaml"
done
```
Expected: `appproject.argoproj.io/teams created (server dry run)`, then the same shape for `services-local` and `data-local` as ApplicationSets. An `unknown field` error names the exact field; see Appendix I.

Second, the names the generators would produce are exactly the names that exist today. This reproduces the naming rule in shell from the config repos on disk, for both clusters:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
source scripts/reg.sh
for c in "${LFI_CLUSTERS[@]}"; do
  sfx=""; [[ "$c" == eks ]] && sfx="-eks"
  generated="$(for svc in "${LFI_SERVICES[@]}"; do
    cfg="$(service_config_dir "$svc")"
    for env in $(service_envs "$svc" "$c"); do
      echo "$svc-$env$sfx"
      if [[ -d "$cfg/$c/$env/postgres" ]]; then echo "postgres-$env$sfx"; fi
    done
  done | sort)"
  existing="$(yq -N '.metadata.name' argocd/apps-$c/*/*.yaml | sort)"
  if [[ "$generated" == "$existing" ]]; then echo "$c: names match ($(echo "$generated" | wc -l | tr -d ' ') Applications)"
  else echo "$c: MISMATCH"; diff <(echo "$generated") <(echo "$existing"); fi
done
```
Expected: `local: names match (6 Applications)` and `eks: names match (6 Applications)`. This is the adoption guarantee from the primer.

Third, the templates carry the same sync policy as the files they replace, so adoption changes no behavior:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
same_policy() { # <staged set> <existing application>; comment lines are ignored
  diff <(yq '.spec.template.spec.syncPolicy, .spec.template.spec.ignoreDifferences' "$1" | grep -v '^ *#') \
       <(yq '.spec.syncPolicy, .spec.ignoreDifferences' "$2" | grep -v '^ *#') \
    && echo "same policy: $(basename "$1")"
}
same_policy "$S/appsets/services-local.yaml" argocd/apps-local/dev/service-1.yaml
same_policy "$S/appsets/data-local.yaml"     argocd/apps-local/dev/postgres.yaml
```
Expected: `same policy: services-local.yaml` and `same policy: data-local.yaml`. Any output from `diff` instead is a real difference in behavior.

#### Task 20.2.3: Prove the generators on a throwaway set

**Goal:** Evidence, on your real ArgoCD, that the matrix, the nested merge, `pathParamPrefix`, the templated `revision` and the `get ... | default` calls all behave as this guide assumes, **before** the cutover depends on them. This is the part of the design no offline check could cover.

**Why a spike:** if a generator is wrong, the failure at cutover is the worst kind: an ApplicationSet that quietly produces nothing or the wrong thing after you have deleted the Applications it was meant to replace. Here the failure costs nothing, because the throwaway set creates Applications that deploy nothing.

**How it stays harmless.** The spike is the staged services set with five changes: a different name (`spike`), Application names prefixed `spike-`, no automated sync (so nothing is ever deployed), no finalizer (so deleting it removes only the Application objects), and `project: default` (the `teams` project does not exist yet). It reads the subscriptions from a branch of its own (`spike/generators`), not from `main`, and it is applied by hand, so `root` never sees it. The experiments below are commits on that branch, which is deleted at the end, so they never reach `main`.

Commit what exists so far on the feature branch and push it (not `main`). This is the first commit on the branch; the ship step later merges it. Then make the spike's own branch from it:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
scripts/check-contract.sh
git add platform scripts/reg.sh scripts/check-contract.sh scripts/gen-appsets.sh
git commit -m "platform: registry, subscriptions, contract check and ApplicationSet generator"
git push -u origin feat/pluggable-structure
git switch -c spike/generators
git push -u origin spike/generators
```
Build the spike from the staged set and apply it:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
yq '
  .metadata.name = "spike" |
  .spec.template.metadata.name = "spike-{{ .name }}-{{ .env }}" |
  .spec.template.metadata.labels.spike = "true" |
  del(.spec.template.metadata.finalizers) |
  del(.spec.template.spec.syncPolicy) |
  .spec.template.spec.project = "default" |
  (.spec.generators[0].matrix.generators[0].merge.generators[].git.revision) = "spike/generators"
' "$S/appsets/services-local.yaml" > "$S/spike.yaml"
kubectl --context k3d-platform apply -f "$S/spike.yaml"
kubectl --context k3d-platform -n argocd annotate applicationset spike argocd.argoproj.io/application-set-refresh=true --overwrite
```

**Validate, part 1: it generates the right Applications.** Give it a minute, then:
```bash
kubectl --context k3d-platform -n argocd get applications -l spike=true --no-headers \
  -o custom-columns=NAME:.metadata.name,PATH:.spec.source.path,REV:.spec.source.targetRevision,NS:.spec.destination.namespace,SYNC:.status.sync.status | sort
kubectl --context k3d-platform -n argocd get applicationset spike -o jsonpath='{.status.conditions[*].type}={.status.conditions[*].status}{"\n"}'
```
Expected: four Applications, `spike-service-1-dev`, `spike-service-1-prod`, `spike-service-2-dev`, `spike-service-2-prod`; each with `PATH` `local/<env>/app`, `REV` `HEAD`, `NS` `platform-<env>`; and `SYNC` of `Synced` or `OutOfSync`, **not** `Unknown`. `OutOfSync` is fine: the live resources carry the real Applications' tracking labels. `Unknown` or a `ComparisonError` means the repo server could not render the Application, which is almost always the remote component reference; read `kubectl --context k3d-platform -n argocd get application spike-service-1-dev -o jsonpath='{.status.conditions}'` and see Appendix I. The ApplicationSet's conditions should read `ErrorOccurred=False`.

**Validate, part 2: the merge generator lays an override on top.** Add a platform override for service-2 on the branch and watch only that service change:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
cat > platform/overrides/local/service-2.yaml <<'XEOF'
name: service-2
targetRevision: main
XEOF
git add platform/overrides/local/service-2.yaml
git commit -m "spike: pin service-2 to main"
git push
kubectl --context k3d-platform -n argocd annotate applicationset spike argocd.argoproj.io/application-set-refresh=true --overwrite
sleep 60
kubectl --context k3d-platform -n argocd get applications -l spike=true --no-headers \
  -o custom-columns=NAME:.metadata.name,REV:.spec.source.targetRevision | sort
```
Expected: `spike-service-1-*` still `HEAD`, and `spike-service-2-*` now `main`. That one change in Git, to a file the team never sees, moved only one service's source: it is the platform's hold.

**Validate, part 3: what one unreachable repository does.** Subscribe to a repository that does not exist, and in the same commit take the hold off service-2. If the set carries on around the broken repository, service-2 returns to `HEAD`. If one broken repository stops the whole set, service-2 stays at `main`:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
OWNER="$(yq '.owner' platform/registry.yaml)"
cat > platform/subscriptions/local/ghost.yaml <<XEOF
name: ghost
team: nobody
role: a service whose repository does not exist
configRepo: https://github.com/$OWNER/lfi-ghost-config.git
XEOF
git rm -q platform/overrides/local/service-2.yaml
git add platform/subscriptions/local/ghost.yaml
git commit -m "spike: subscribe to a repository that does not exist, release service-2"
git push
kubectl --context k3d-platform -n argocd annotate applicationset spike argocd.argoproj.io/application-set-refresh=true --overwrite
sleep 60
kubectl --context k3d-platform -n argocd get applicationset spike -o jsonpath='{.status.conditions[?(@.type=="ErrorOccurred")].message}{"\n"}'
kubectl --context k3d-platform -n argocd get applications -l spike=true --no-headers \
  -o custom-columns=NAME:.metadata.name,REV:.spec.source.targetRevision | sort
```
Expected: an error message that names `lfi-ghost-config` (the set reports the failure), and still four Applications, so a broken repository does **not** delete anyone's Application. **Write down what service-2's `REV` says.** The behavior to expect is that the set is *frozen*: it neither creates, updates nor deletes anything while one generator errors, so `spike-service-2-*` stays on `main` even though its hold was removed. That is safe, and it is also a real blast radius: one broken team repository blocks every other service's changes until it is fixed, which is why `scripts/check-contract.sh --online` exists (it fails on an unreachable config repository, and Task 20.3.1 runs it). If instead the count dropped to `0`, one bad repository removes every Application, and you must not use one set for all services; Appendix I describes the fallback.

Then take the ghost away and confirm it recovers:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git rm -q platform/subscriptions/local/ghost.yaml
git commit -m "spike: remove the experiments"
git push
kubectl --context k3d-platform -n argocd annotate applicationset spike argocd.argoproj.io/application-set-refresh=true --overwrite
sleep 60
kubectl --context k3d-platform -n argocd get applications -l spike=true --no-headers \
  -o custom-columns=NAME:.metadata.name,REV:.spec.source.targetRevision | sort
```
Expected: every `REV` is `HEAD` again, and the `ErrorOccurred` message is gone.

**Clean up the spike.** Delete the set, then the branch it read, so none of the experiments can reach `main`:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
kubectl --context k3d-platform -n argocd delete applicationset spike
git switch feat/pluggable-structure
git branch -D spike/generators
git push origin --delete spike/generators
```

**Validate:**
```bash
kubectl --context k3d-platform -n argocd get applicationsets
kubectl --context k3d-platform -n argocd get applications -l spike=true --no-headers | wc -l
kubectl --context k3d-platform -n argocd get applications
cd "$PLATFORM_HOME/lfi-infrastructure-gitops" && git branch --show-current && git log --oneline -3 && scripts/check-contract.sh
```
Expected: no ApplicationSets, `0`, the original seven Applications `Synced` and `Healthy`, the branch name `feat/pluggable-structure` with a log whose newest commit is the `platform: ...` one (no `spike:` commits), and `OK`. If the spike's Applications linger, wait a minute: deleting the set removes them.

#### Task 20.2.4: Gate what the platform owns

**Goal:** The platform's CODEOWNERS covers the places that now decide what is deployed and where, and no longer needs to name a cluster.

**Why:** ApplicationSets and subscriptions now decide what runs. A change to `platform/` can add a service to every cluster, and a change to `argocd/` can change the policy every service runs under, so they get the review gate that `kubernetes/overlays/*/prod/` had. The old prod overlay lines stay until Task 20.4.5 deletes the overlays they protect. Prod for a service is its team's concern now; the GitOps repo no longer says anything about it.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
OWNER="$(yq '.owner' platform/registry.yaml)"
cat > .github/CODEOWNERS <<XEOF
# Changes under these paths require review from the listed owner. This repository
# is the platform's. A service's prod environment is protected by that service's
# own config repository, not here.

# Subscriptions decide what exists. The ApplicationSets and the teams project
# decide how it is deployed and what a team may do. Add-ons are platform software.
/platform/                       @$OWNER
/argocd/                         @$OWNER
/addons/                         @$OWNER

# The platform's veto list, and the commands that act on it.
/releases/                       @$OWNER
/scripts/                        @$OWNER

# Terraform provisions both clusters.
/terraform/                      @$OWNER

# Removed in Task 20.4.5, together with the overlays they protect.
/kubernetes/overlays/local/prod/ @$OWNER
/kubernetes/overlays/eks/prod/   @$OWNER
XEOF
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
grep -c '^/' .github/CODEOWNERS
grep -c 'YOUR_\|@$' .github/CODEOWNERS
```
Expected: `8` and `0`.

---

### Phase 20.3: Cutover on the local cluster

**Objective:** Replace six hand-written Applications with generated ones that read the new config repos, move the services' CI to write there, and prove with pod identifiers that nothing was recreated.

**The plan, in order, each step merged and verified before the next:**

| Step | What changes | What the cluster does | Danger if skipped |
|------|--------------|------------------------|-------------------|
| CI dual write (20.3.2) | Each service's CI writes its dev tag to the old overlay **and** to its config repo | Nothing. ArgoCD still reads the old overlays. | The config repos would go stale while you work, and Move 4 would deploy old images. |
| Move 1 (20.3.3) | Subscriptions, registry and scripts reach `main` | Nothing. Nothing reads them yet. | None, but it proves the shipping path. |
| Move 2 (20.3.4) | Remove the finalizer from the six Applications | Children lose their delete-cascade | Move 3 would delete the workloads, database included. |
| Move 3 (20.3.5) | Delete the six Application files | `root` prunes six Applications. The workloads keep running, unmanaged, for a few minutes. | Deleting with finalizers still present deletes everything. |
| Move 4 (20.3.6) | Add the ApplicationSets and the project | They generate six Applications with the same names, reading the config repos, which re-adopt the running workloads | Adding them at the same time as Move 3 risks the controller and `root` fighting over the same names. |
| CI single write (20.3.7) | CI stops writing to the old overlays | A new build reaches dev through the config repo only | The old overlays would keep receiving tags nothing reads. |

**Only run this phase with EKS down.** The EKS cluster, if it existed, would hold its own six hand-written Applications and need the same four moves. With it down, `argocd/apps-eks` can change in one step (Task 20.3.6) because a cluster that gets created later simply reads the new layout. If you left EKS up, destroy it (`gmake destroy CLUSTER=eks`) before continuing. That costs nothing you built: everything on it is reproduced from Git.

#### Task 20.3.1: Confirm the preconditions and record pod identity

**Goal:** Facts true before you start, and the identifiers to compare against at every later step.

```bash
S="$PLATFORM_HOME/.tmp/g4"
cat > "$S/uids.sh" <<'XEOF'
#!/usr/bin/env bash
# Prints "<kind>/<name> <uid>" for every pod and claim in both environments of
# the local cluster. The same output before and after a change means nothing
# was recreated: a recreated pod has a new name and a new uid.
PREFIX="$(yq '.namespacePrefix' "$PLATFORM_HOME/lfi-infrastructure-gitops/platform/registry.yaml")"
for env in dev prod; do
  kubectl --context k3d-platform -n "$PREFIX-$env" get pods,pvc \
    -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.metadata.uid}{"\n"}{end}'
done | sort
XEOF
cat > "$S/refresh.sh" <<'XEOF'
#!/usr/bin/env bash
# Asks ArgoCD to re-read Git for every Application now, instead of waiting up to
# three minutes for the next poll.
for a in $(kubectl --context k3d-platform -n argocd get applications -o name); do
  kubectl --context k3d-platform -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
done
XEOF
chmod +x "$S/uids.sh" "$S/refresh.sh"

cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
kubectl config get-contexts -o name | grep -c '^lfi-eks$' || true
kubectl --context k3d-platform -n argocd get applications
kubectl --context k3d-platform get rollouts -A
"$S/uids.sh" | tee "$S/uids-cutover-before.txt" | wc -l
"$S/parity.sh"
scripts/check-contract.sh --online
```

**Validate:** the context count is `0` (EKS is not registered; if it is `1`, stop as described above), all seven Applications are `Synced` and `Healthy`, every Rollout is `Healthy` with none mid-canary (a rollout in flight makes pod identity a moving target), the identity count matches the count from Task 19.1.3, `parity.sh` ends `IDENTICAL: 12 builds match.`, and the contract check, which also reaches each config repository over the network this time, prints `OK`.

#### Task 20.3.2: CI writes the dev tag to both places

**Goal:** Each service's CI promote job writes the new dev tag to its old overlay **and** to its config repo, so the config repo is current on the day ArgoCD starts reading it.

**Why two steps and not one:** if CI switched to the config repo now, ArgoCD (still reading the old overlays) would stop receiving new builds until the cutover finished. If the cutover happened first, the Applications would read config repos whose tags CI no longer updates. Writing to both for a while means neither order can strand you. This is the same pattern as renaming a database column: expand, migrate, contract.

**Why the credential matters.** The promote job checks out another repository with the `GITOPS_PAT` secret, because the automatic `GITHUB_TOKEN` only covers the repository running the workflow. That token was created in guide 1 for the GitOps repo alone. It now needs the two config repos too. In GitHub: **Settings, Developer settings, Personal access tokens, Fine-grained tokens, `gitops-promote`**, then under **Repository access** add `lfi-service-1-config` and `lfi-service-2-config`. The permission stays **Contents: read and write**. Nothing else changes, and the secret you stored in both service repos stays as it is. (If the token is set to all repositories, there is nothing to do.)

The edit replaces only the `promote` job, the last job in each workflow, and refuses to run if the file is not shaped that way:
```bash
S="$PLATFORM_HOME/.tmp/g4"
cat > "$S/edit-ci.py" <<'XEOF'
import os, re, sys

mode = os.environ["MODE"]            # dual: write to both repos. config: config repo only.
repo = os.environ["REPO_DIR"]        # a service's app repo
project = os.environ["PROJECT"]      # for example lfi
path = os.path.join(repo, ".github/workflows/ci.yaml")
s = open(path).read()

# The promote job is the last job in the file. Replace it, comments and all,
# and nothing else in the workflow changes.
head, sep, tail = s.partition("\n  promote:\n")
if not sep:
    sys.exit(f"ERROR: {path}: no 'promote:' job found.")
if re.search(r"^  [A-Za-z_-]+:\s*$", tail, re.M):
    sys.exit(f"ERROR: {path}: another job follows 'promote:'. Edit it by hand.")
m = re.search(r"SERVICE:\s*(service-\d+)", tail)
if not m:
    sys.exit(f"ERROR: {path}: could not read SERVICE from the promote job.")
svc = m.group(1)

gitops_checkout = """      - name: Check out the GitOps repo
        uses: actions/checkout@v7
        with:
          repository: ${{ github.repository_owner }}/lfi-infrastructure-gitops
          token: ${{ secrets.GITOPS_PAT }}
          path: gitops
"""
config_checkout = """      - name: Check out this service's config repo
        uses: actions/checkout@v7
        with:
          # A different repository from the one running this workflow, so the
          # automatic GITHUB_TOKEN is not enough. The PAT must list this repo.
          repository: ${{ github.repository_owner }}/%s-%s-config
          token: ${{ secrets.GITOPS_PAT }}
          path: config
""" % (project, svc)

gitops_step = """          # While both are live, the GitOps overlays are still what ArgoCD deploys
          # from. This write goes away in Task 20.3.7.
          push_tag gitops \\
            "kubernetes/overlays/local/dev/${SERVICE}/kustomization.yaml" \\
            "kubernetes/overlays/eks/dev/${SERVICE}/kustomization.yaml"
"""
config_step = """          push_tag config \\
            "local/dev/app/kustomization.yaml" \\
            "eks/dev/app/kustomization.yaml"
"""

body = """\
  promote:
    name: promote
    # Only runs if `build` succeeded, so a tag is never written for an image
    # that does not exist in GHCR. This ordering is the whole CI/CD seam.
    needs: build
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
""" + (gitops_checkout if mode == "dual" else "") + config_checkout + """
      - name: Update the image tag and push
        # Passed as env vars rather than interpolated into the script with
        # ${{ }}. Interpolation splices text into the shell before it runs,
        # which is a script-injection route; env vars are just data.
        env:
          BUILD_TAG: ${{ needs.build.outputs.build_tag }}
          SERVICE: %s
        run: |
          set -euo pipefail

          # push_tag <checkout dir> <manifest>...: set images[0].newTag in each
          # manifest, commit, and push with a rebase-and-retry loop.
          push_tag() {
            local dir="$1"; shift
            cd "$dir"
            # Commit as the Actions bot. This exact address is what makes the
            # bot avatar render on the commit in the GitHub UI.
            git config user.name  "github-actions[bot]"
            git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

            # yq -i against a missing file does not reliably fail, so check.
            local m
            for m in "$@"; do
              [[ -f "$m" ]] || { echo "ERROR: ${dir}/${m} does not exist." >&2; return 1; }
            done
            # The one-field edit that constitutes the deployment.
            for m in "$@"; do
              yq -i '.images[0].newTag = strenv(BUILD_TAG)' "$m"
            done
            # Re-running the same commit is not an error.
            if git diff --quiet; then
              echo "${dir}: tag already at ${BUILD_TAG}."
              cd - >/dev/null
              return 0
            fi
            git add "$@"
            git commit -m "deploy(${SERVICE}): ${BUILD_TAG}"

            # Rebase and retry, because another run may push at the same moment.
            local attempt
            for attempt in 1 2 3 4 5; do
              if git push; then
                echo "${dir}: promoted ${SERVICE} to ${BUILD_TAG} on attempt ${attempt}."
                cd - >/dev/null
                return 0
              fi
              echo "Push rejected (attempt ${attempt}). Rebasing and retrying..."
              git pull --rebase --autostash
              sleep $(( attempt * 3 ))
            done
            echo "Could not push ${dir} after 5 attempts." >&2
            return 1
          }

""" % svc + (gitops_step if mode == "dual" else "") + config_step

open(path, "w").write(head + "\n" + body)
print(f"{mode}: rewrote the promote job in {path} for {svc}")
XEOF

PROJECT="$(yq '.project' "$PLATFORM_HOME/lfi-infrastructure-gitops/platform/registry.yaml")"
for n in 1 2; do
  cd "$PLATFORM_HOME/lfi-service-$n-app"
  git switch main
  git pull --ff-only
  git switch -c ci/promote-to-config-repo
  MODE=dual REPO_DIR="$PWD" PROJECT="$PROJECT" python3 "$S/edit-ci.py"
  git diff --stat
done
```
Read one of the diffs before going on (`git -C "$PLATFORM_HOME/lfi-service-1-app" diff`). The `promote` job now has a `push_tag` function that edits the manifests in a checkout, commits, and pushes with the same rebase-and-retry loop as before, and it calls the function once for the GitOps checkout and once for the config checkout. The two service workflows differ only in the `SERVICE` value, and the script read that from each file.

Commit, open a pull request in each service repo, wait for its checks and merge. Merging to `main` is what runs the whole pipeline and the promote job:
```bash
for n in 1 2; do
  cd "$PLATFORM_HOME/lfi-service-$n-app"
  git add .github/workflows/ci.yaml
  git commit -m "ci: also write the dev tag to the service's config repo"
  git push -u origin ci/promote-to-config-repo
  gh pr create --fill --base main
  sleep 10
  gh pr checks --watch
  gh pr merge --squash --delete-branch
done
```
Watch the two pipelines finish (each builds an image, so allow several minutes):
```bash
for n in 1 2; do
  cd "$PLATFORM_HOME/lfi-service-$n-app"
  sleep 20
  gh run watch "$(gh run list --branch main --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status
done
```

**Validate:** pull everything and compare.
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git fetch origin
git merge --ff-only origin/main
source scripts/reg.sh
for svc in "${LFI_SERVICES[@]}"; do git -C "$(service_config_dir "$svc")" pull --ff-only --quiet; done
git log -1 --format='gitops: %s' origin/main -- kubernetes/overlays/local/dev/service-1
git -C "$(service_config_dir service-1)" log -1 --format='config: %s'
"$PLATFORM_HOME/.tmp/g4/parity.sh"
```
Expected: both log lines read `deploy(service-1): <the same new tag>`, and `parity.sh` ends `IDENTICAL: 12 builds match.` A promote job that fails at **Check out this service's config repo** with a 404 means the token cannot see the repository: fix the token and re-run the job (Appendix I). Nothing is half done in that case, because both checkouts happen before any edit.

#### Task 20.3.3: Move 1: ship the subscriptions and scripts

**Goal:** The registry, the subscriptions, the generator and the contract check on `main`, with the cluster unaffected.

**Why this is safe:** `root` watches `argocd/apps-local`, not `platform/`, and nothing reads the subscriptions yet. The only live change is the ArgoCD values comment from Task 20.2.1, which Terraform already applied.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
git add platform scripts/reg.sh scripts/check-contract.sh scripts/gen-appsets.sh \
        .github/CODEOWNERS terraform/local/02-platform/values/argocd.yaml terraform/eks/02-platform/values/argocd.yaml
git status --short | head -30
scripts/check-contract.sh
bash "$S/ship.sh" "platform: subscriptions, registry, generator and contract check"
"$S/refresh.sh"
```

**Validate:** wait a minute, then:
```bash
S="$PLATFORM_HOME/.tmp/g4"
kubectl --context k3d-platform -n argocd get applications
diff "$S/uids-cutover-before.txt" <("$S/uids.sh") && echo NOTHING RECREATED
```
Expected: seven Applications `Synced` and `Healthy`, and `NOTHING RECREATED` with no `diff` output above it. The `git status` listing before the ship should show only the paths you staged. If the listing shows `kubernetes/` files as modified, an earlier step touched the old overlays; stop and look.

#### Task 20.3.4: Move 2: remove the finalizers

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

#### Task 20.3.5: Move 3: delete the six Application files

**Goal:** `root` prunes the six child Applications. The workloads stay.

**Why a placeholder file:** `root` watches `argocd/apps-local`. Git does not store empty directories, so deleting the last files would remove the path, and `root` would report that the path does not exist and stop syncing, which is a worse state than the one you are trying to reach. A `README.md` keeps the directory. ArgoCD reads only YAML and JSON from a directory source, so the file is inert.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
git rm -q -r argocd/apps-local/dev argocd/apps-local/prod
# Git removed the now-empty directory along with its last files. Bring it back.
mkdir -p argocd/apps-local
cat > argocd/apps-local/README.md <<'XEOF'
# apps-local

The local cluster's `root` Application watches this directory. It holds the
generated ApplicationSets under `appsets/` and the `teams` project under
`projects/`, written by `scripts/gen-appsets.sh`. They create every service and
datastore Application from `platform/subscriptions/local/` and the team-owned
config repositories those name. There are no hand-written service Applications
here.
XEOF
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

#### Task 20.3.6: Move 4: add the ApplicationSets and the project

**Goal:** `services-local` and `data-local` exist, generate the six Applications under their old names from the config repos, and those Applications re-adopt the running workloads. The `teams` project exists. The EKS tree receives the same files at the same time.

**Check the config repos once more first.** Move 4 is the moment the cluster starts reading them, so they must say what the old overlays say now:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git fetch origin
git merge --ff-only origin/main
source scripts/reg.sh
for svc in "${LFI_SERVICES[@]}"; do git -C "$(service_config_dir "$svc")" pull --ff-only --quiet; done
"$PLATFORM_HOME/.tmp/g4/parity.sh"
```
It must end `IDENTICAL: 12 builds match.` If it does not, fix the difference first (Appendix I). Adopting an Application onto manifests with a different image would roll that image out.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
scripts/gen-appsets.sh

# EKS is down, so its hand-written Applications can go in the same step.
git rm -q -r argocd/apps-eks/dev argocd/apps-eks/prod
sed 's/apps-local/apps-eks/; s/local cluster/EKS cluster/; s#platform/subscriptions/local/#platform/subscriptions/eks/#' \
  argocd/apps-local/README.md > argocd/apps-eks/README.md

scripts/check-contract.sh
git add argocd
git status --short | head -20
bash "$S/ship.sh" "cutover 3/3: ApplicationSets generate the service and data Applications"
"$S/refresh.sh"
```

**Validate:** wait up to three minutes. The ApplicationSet controller polls Git on its own interval, so the refresh above speeds `root` but not necessarily the set.
```bash
S="$PLATFORM_HOME/.tmp/g4"
kubectl --context k3d-platform -n argocd get applicationsets,appprojects
kubectl --context k3d-platform -n argocd get applications
diff "$S/apps-before.txt" <(kubectl --context k3d-platform -n argocd get applications -o name | sort) && echo SAME NAMES
diff "$S/uids-cutover-before.txt" <("$S/uids.sh") && echo NOTHING RECREATED
kubectl --context k3d-platform -n argocd get application service-1-dev -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
kubectl --context k3d-platform -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}={.spec.project}{"\n"}{end}'
kubectl --context k3d-platform -n argocd get application postgres-prod -o jsonpath='prune={.spec.syncPolicy.automated.prune} finalizers={.metadata.finalizers}{"\n"}'
```
Expected: `services-local` and `data-local` listed beside the `default` and `teams` projects; `root` plus six children all `Synced` and `Healthy`; `SAME NAMES`; `NOTHING RECREATED`; `ApplicationSet`; `root=default` and every other Application `=teams`; and `prune=false finalizers=`. A short window where the Applications report a missing project is normal: `root` creates the project and the ApplicationSets together and the Applications settle once it exists.

If the sets produce no Applications after five minutes, or they appear `OutOfSync` or `Missing`, read the controller log before touching anything:
```bash
kubectl --context k3d-platform -n argocd logs deploy/argocd-applicationset-controller --tail=50
```
The usual causes, and how to roll back, are in Appendix I. `gmake status` still reads the old overlays until Phase 20.4, so its GIT column is stale; the Applications are the truth for now.

#### Task 20.3.7: CI stops writing to the old overlays

**Goal:** Each service's CI writes the dev tag to its config repo **only**, and a new build reaches dev through that path alone. This completes the cutover end to end.

```bash
S="$PLATFORM_HOME/.tmp/g4"
PROJECT="$(yq '.project' "$PLATFORM_HOME/lfi-infrastructure-gitops/platform/registry.yaml")"
for n in 1 2; do
  cd "$PLATFORM_HOME/lfi-service-$n-app"
  git switch main
  git pull --ff-only
  git switch -c ci/promote-to-config-repo-only
  MODE=config REPO_DIR="$PWD" PROJECT="$PROJECT" python3 "$S/edit-ci.py"
  git diff --stat
  git add .github/workflows/ci.yaml
  git commit -m "ci: write the dev tag to the config repo only"
  git push -u origin ci/promote-to-config-repo-only
  gh pr create --fill --base main
  sleep 10
  gh pr checks --watch
  gh pr merge --squash --delete-branch
done
for n in 1 2; do
  cd "$PLATFORM_HOME/lfi-service-$n-app"
  sleep 20
  gh run watch "$(gh run list --branch main --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status
done
```

**Validate:** the new build is running in dev, and the old overlay did not move.
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
source scripts/reg.sh
git fetch --quiet origin
for svc in "${LFI_SERVICES[@]}"; do
  git -C "$(service_config_dir "$svc")" pull --ff-only --quiet
  cfg_tag="$(yq '.images[0].newTag' "$(service_config_dir "$svc")/local/dev/app/kustomization.yaml")"
  old_tag="$(git show "origin/main:kubernetes/overlays/local/dev/$svc/kustomization.yaml" | yq '.images[0].newTag')"
  live="$(kubectl --context k3d-platform -n platform-dev get rollout "$svc" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "$svc  config=$cfg_tag  old-overlay=$old_tag  live=${live##*:}"
done
kubectl --context k3d-platform -n argocd get applications
```
Expected: for each service `config` and `live` are the same new tag (allow a few minutes for ArgoCD to poll and the rollout to finish), `old-overlay` is the previous tag and no longer moves, and all Applications are `Synced` and `Healthy`. A build you pushed in the app repo has now reached the cluster without a single commit to the GitOps repo.

---

### Phase 20.4: The commands follow the config repos

**Objective:** `gmake status`, `release`, `canary` and `rollback` find services, environments and tags in the subscriptions and the config repos, and nothing in `scripts/` names `service-1`, `service-2`, `platform-prod` or a cluster context any more, except in examples.

**Why now:** before this, a new service was in Git and ArgoCD and invisible to every command. After the cutover the commands are also wrong in a worse way: `status` and `release` still read the old overlays, which stopped moving in Task 20.3.7. This phase fixes both.

Two things change in kind, not only in path:

- **A release is now one PR per service, in that service's repository.** The tag lives in the team's repo, so the PR does too, and the team's own review rules gate prod. The deny list stays here, in the GitOps repo, as the platform's veto.
- **The tooling no longer assumes which environments exist.** It promotes from the `promotion.from` environment to the `promotion.to` environment in the subscription (dev to prod by default), and it only shows a service in an environment that service has.

The scripts find a service's config repo as a sibling directory of the GitOps repo, named like the repo on GitHub. If you have not cloned one, the commands say so and name the path.

#### Task 20.4.1: Edit `lib.sh`, `canary.sh` and `status.sh`

**Goal:** Adding a service to a cluster is a subscription, and that is enough for the commands to offer it. The three hard-coded "service-2 goes first" hints become a question the subscriptions answer (`dependsOn`).

Snapshot what `gmake status` says now, so you can read the difference:
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
""", """# LFI_CLUSTERS, LFI_SERVICES, NAMESPACE_PREFIX and the cluster_*, service_* and
# promote_* readers come from platform/registry.yaml and platform/subscriptions/,
# so adding a service or a cluster never means editing this file.
source "$(dirname "${BASH_SOURCE[0]}")/reg.sh"

# The environments that exist: every environment any service has on any cluster,
# found in the config repositories checked out next to this one. Teams choose
# their own, so this cannot be a fixed list. Empty if no config repo is cloned.
LFI_STAGES=()
for _s in "${LFI_SERVICES[@]}"; do
  for _c in "${LFI_CLUSTERS[@]}"; do
    for _e in $(service_envs "$_s" "$_c"); do
      [[ " ${LFI_STAGES[*]-} " == *" $_e "* ]] || LFI_STAGES+=("$_e")
    done
  done
done
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
("""  menu_note() {
    case "$1" in
      dev)  echo "follows every build automatically" ;;
      prod) echo "changes only when a release PR is merged" ;;
      both) echo "dev and prod" ;;
    esac
  }
  pick_generic "environment\"""", """  [[ ${#LFI_STAGES[@]} -gt 0 ]] \\
    || usage_error "No environments found. Clone each service's config repository next to this repository."
  menu_note() {
    case "$1" in
      both) echo "${LFI_STAGES[*]}" ;;
      *)    echo "" ;;
    esac
  }
  pick_generic "environment\""""),
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
("""# Compare against what is on the remote, not whatever this checkout last pulled.
git fetch --quiet origin 2>/dev/null || echo "NOTE: could not fetch origin; the GIT column may be stale." >&2

git_tag() { # <cluster> <stage> <service>
  git show "origin/main:kubernetes/overlays/$1/$2/$3/kustomization.yaml" 2>/dev/null \\
    | SVC="$3" yq '.images[] | select(.name == strenv(SVC)) | .newTag' 2>/dev/null || true
}""", """# Compare against what is on the remote, not whatever each checkout last pulled.
# The tags live in each service's own config repository.
for _svc in "${LFI_SERVICES[@]}"; do
  _cfg="$(service_config_dir "$_svc")"
  if [[ -d "$_cfg/.git" ]]; then
    git -C "$_cfg" fetch --quiet origin 2>/dev/null || echo "NOTE: could not fetch $_cfg; its GIT column may be stale." >&2
  else
    echo "NOTE: $_svc's config repo is not checked out at $_cfg; its GIT column will show ?." >&2
  fi
done

git_tag() { # <cluster> <stage> <service>
  local cfg
  cfg="$(service_config_dir "$3")" || return 0
  git -C "$cfg" show "origin/main:$1/$2/app/kustomization.yaml" 2>/dev/null \\
    | SVC="$3" yq '.images[] | select(.name == strenv(SVC)) | .newTag' 2>/dev/null || true
}"""),
("""    ns="platform-${stage}\"""", """    ns="${NAMESPACE_PREFIX}-${stage}\""""),
("""    for svc in "${LFI_SERVICES[@]}"; do
      git_t="$(git_tag "$cluster" "$stage" "$svc")"; git_t="${git_t:-?}\"""", """    for svc in "${LFI_SERVICES[@]}"; do
      # A team chooses its own environments, so a service may not have this one.
      if [[ " $(service_envs "$svc" "$cluster" | tr '\\n' ' ') " != *" $stage "* ]]; then
        printf '  %-11s %s\\n' "$svc" "(no ${stage} environment on ${cluster})"
        continue
      fi
      git_t="$(git_tag "$cluster" "$stage" "$svc")"; git_t="${git_t:-?}\""""),
("Promote service-2 first.", "Promote dependencies first."),
])
print("Edited lib.sh, canary.sh and status.sh.")
PYEOF
```

**Validate:** the scripts parse, the readers return what the subscriptions say, and `gmake status` now reads the config repos.
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
for f in scripts/*.sh; do bash -n "$f" || echo "SYNTAX ERROR in $f"; done
bash -c 'source scripts/lib.sh; echo "clusters: ${LFI_CLUSTERS[*]}"; echo "services: ${LFI_SERVICES[*]}"; echo "stages: ${LFI_STAGES[*]}"; echo "first to promote: $(first_to_promote service-1 service-2)"; echo "note: $(called_by_note service-2)"'
grep -n 'platform-\|k3d-platform\|lfi-eks\|service-[12]' scripts/lib.sh scripts/canary.sh scripts/status.sh | grep -v '^\S*:[0-9]*:\s*#'
gmake status CLUSTER=local ENVIRONMENT=both
```
Expected: no `SYNTAX ERROR`; `clusters: local eks`, `services: service-1 service-2`, `stages: dev prod`, `first to promote: service-2`, `note: : it is called by service-1`; the `grep` prints only lines that mention a service inside an example string or usage message (none should name `platform-`, `k3d-platform` or `lfi-eks`); and `gmake status` printing `GIT` and `RUNNING` tags that agree for every service, with the new dev build from Task 20.3.7. The `grep` is informational: review what it prints rather than expecting silence.

#### Task 20.4.2: Replace `release.sh`

**Goal:** `gmake release` opens one PR per service in that service's config repo, moving the tag from the "from" environment to the "to" environment, honoring the deny list, and with `DRY_RUN=1` showing what it would do without touching anything.

**Why a replacement and not an edit:** the old script is one repository, one branch and one PR. This one is a loop over services, each with its own repository, branch and PR. The behavior you rely on is kept: the deny list, the partial-release label in the title, the `release/<ISO week>-B<newest build>` branch name, the dependency note in the PR body, and the refusal to run on a dirty tree.

The PR title keeps its shape, `release(prod): 2026-W40-B3`, because `gmake rollback` finds releases by it. The service is implied by the repository the PR is in.
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
cat > scripts/release.sh <<'XEOF'
#!/usr/bin/env bash
# Opens the weekly prod release PRs, one in each service's config repository.
#
# Usage: scripts/release.sh
#   Asks which cluster (local, eks, or both) and which service (or both). Name
#   them up front and nothing is asked:
#     gmake release CLUSTER=eks SVC=service-1
#   DRY_RUN=1 shows what would be released and stops, touching nothing.
#   Clusters are allowed to drift apart: releasing to one leaves the other where
#   it was, until you release to it.
#
# Reads the image tag the "from" environment (dev, unless the service's
# subscription says otherwise) is running and writes it into the "to"
# environment (prod). Nothing is built: the images already exist in GHCR and
# have been serving dev traffic all week. This script only moves a reference.
#
# Each service's manifests live in that service's own config repository, which
# the team owns. So a release is one PR per service, opened in that repository,
# and that team's review rules (its CODEOWNERS) are what gate prod. The deny
# list stays here, in the GitOps repository: it is the platform's veto.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"

pick_cluster "release to" yes
pick_service "release" yes
TREES=("${PICKED_CLUSTERS[@]}")
SERVICES=("${PICKED_SERVICES[@]}")
show_equivalent "gmake release"

SCOPE="${TREES[*]} / ${SERVICES[*]}"
PARTIAL=0
[[ ${#TREES[@]} -lt ${#LFI_CLUSTERS[@]} || ${#SERVICES[@]} -lt ${#LFI_SERVICES[@]} ]] && PARTIAL=1
# %G is the ISO week-numbering year, not the calendar year. They diverge at
# New Year: 2027-01-01 falls in ISO week 53 of 2026, so %Y-W%V would name that
# release 2027-W53, a week that does not exist. UTC to match CI.
WEEK="$(date -u +%G-W%V)"

DENYLIST="releases/denied-builds.yaml"
if [[ ! -f "$DENYLIST" ]]; then
  echo "ERROR: ${DENYLIST} is missing. Refusing to release without it." >&2
  exit 1
fi

# Every config repo that takes part must be a clean checkout on an up-to-date
# main, for the reason a release commit must never carry an unrelated change.
for svc in "${SERVICES[@]}"; do
  cfg="$(service_config_dir "$svc")"
  [[ -d "$cfg/.git" ]] || { echo "ERROR: $svc's config repo is not checked out at $cfg." >&2; exit 1; }
  if [[ -n "$(git -C "$cfg" status --porcelain)" ]]; then
    echo "ERROR: $cfg has uncommitted changes. Commit or stash first." >&2
    exit 1
  fi
  git -C "$cfg" switch main >/dev/null 2>&1
  git -C "$cfg" pull --ff-only --quiet
done

tag_in() { # <file> <service>
  SVC="$2" yq '.images[] | select(.name == strenv(SVC)) | .newTag' "$1"
}

# Collect what would change, before changing anything, so the script can decide
# whether there is a release to make and can build the PR bodies.
declare -a CHANGES=()    # svc|cluster|from|to
declare -a BLOCKED=()    # svc|cluster|tag|reason
for svc in "${SERVICES[@]}"; do
  cfg="$(service_config_dir "$svc")"
  from_env="$(promote_from "$svc")"; to_env="$(promote_to "$svc")"
  for tree in "${TREES[@]}"; do
    src="$cfg/$tree/$from_env/app/kustomization.yaml"
    dst="$cfg/$tree/$to_env/app/kustomization.yaml"
    if [[ ! -f "$src" || ! -f "$dst" ]]; then
      echo "NOTE: $svc has no $from_env and $to_env on $tree. Skipped." >&2
      continue
    fi
    dev_tag="$(tag_in "$src" "$svc")"
    prod_tag="$(tag_in "$dst" "$svc")"
    [[ "$dev_tag" == "$prod_tag" ]] && continue

    # A denied build drops out of the release. It is never silently replaced
    # with an older one: shipping something other than what you asked for is
    # exactly the surprise this whole process exists to prevent. strenv reads
    # the values as strings so a numeric-looking tag is not coerced.
    reason="$(SVC="$svc" TAG="$dev_tag" yq '
      .denied[] | select(.service == strenv(SVC) and .build == strenv(TAG)) | .reason
    ' "$DENYLIST")"

    if [[ -n "$reason" ]]; then
      BLOCKED+=("$svc|$tree|$dev_tag|$reason")
      continue
    fi
    CHANGES+=("$svc|$tree|$prod_tag|$dev_tag")
  done
done

if [[ ${#BLOCKED[@]} -gt 0 ]]; then
  echo "Denied builds, excluded from this release:" >&2
  for blocked in "${BLOCKED[@]}"; do
    IFS='|' read -r svc tree tag reason <<< "$blocked"
    printf '  %-18s %-10s %s\n' "$tree/$svc" "$tag" "$reason" >&2
  done
fi

# "Nothing changed" and "everything I would have shipped is poisoned" are
# different states and must never print the same message.
if [[ ${#CHANGES[@]} -eq 0 && ${#BLOCKED[@]} -gt 0 ]]; then
  echo "ERROR: every candidate build is denied. Nothing released." >&2
  exit 1
fi

if [[ ${#CHANGES[@]} -eq 0 ]]; then
  echo "Nothing to release: prod already matches dev for ${SCOPE}."
  next_steps "gmake status           compare dev and prod on every cluster" \
             "gmake release          choose a different cluster or service"
  exit 0
fi

# DRY_RUN=1 shows what would be released and stops, touching nothing.
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "Would release (dry run, nothing changed):"
  for change in "${CHANGES[@]}"; do
    IFS='|' read -r svc tree from to <<< "$change"
    printf '  %-10s %-6s %s -> %s\n' "$svc" "$tree" "$from" "$to"
  done
  exit 0
fi

# One pass per service that has something to ship.
PRS=()
for svc in "${SERVICES[@]}"; do
  cfg="$(service_config_dir "$svc")"
  from_env="$(promote_from "$svc")"; to_env="$(promote_to "$svc")"

  # This service's changes only.
  MINE=()
  for change in "${CHANGES[@]}"; do
    [[ "${change%%|*}" == "$svc" ]] && MINE+=("$change")
  done
  [[ ${#MINE[@]} -gt 0 ]] || continue

  # Name the branch after the newest build in this release, so each release says
  # what it contains: release/2026-W40-B3. Tags look like 26W40B3, so the build
  # ordinal is whatever follows the B. A tag that does not parse (a SHA, say) is
  # ignored, and a release with no parsable tag falls back to release/2026-W40.
  BUILD_N=0
  for change in "${MINE[@]}"; do
    tag="${change##*|}"
    if [[ "$tag" =~ ^[0-9]{2}W[0-9]{2}B([0-9]+)$ ]]; then
      ordinal=$((10#${BASH_REMATCH[1]}))
      (( ordinal > BUILD_N )) && BUILD_N=$ordinal
    fi
  done
  BASE_BRANCH="release/${WEEK}"
  (( BUILD_N > 0 )) && BASE_BRANCH+="-B${BUILD_N}"

  # The branch from an earlier release still exists locally and on the remote.
  # Fall back to a -2, -3 suffix. The remote check matters: a free local name
  # that exists on origin would build the release commit and fail at the push.
  git -C "$cfg" fetch --quiet --prune origin
  BRANCH="$BASE_BRANCH"
  n=2
  while git -C "$cfg" show-ref --verify --quiet "refs/heads/${BRANCH}" \
     || git -C "$cfg" show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; do
    BRANCH="${BASE_BRANCH}-${n}"
    n=$((n + 1))
  done
  RELEASE_ID="${BRANCH#release/}"
  TITLE="release(${to_env}): ${RELEASE_ID}"
  [[ "$PARTIAL" -eq 1 ]] && TITLE+=" [${SCOPE}]"

  git -C "$cfg" switch -c "$BRANCH" >/dev/null

  # Write the new tags. This is the entire mechanical content of a release.
  BODY="## Release ${RELEASE_ID}: ${svc}"$'\n\n'"Scope: ${SCOPE}"$'\n\n'"| Cluster | From | To |"$'\n'"|---|---|---|"$'\n'
  for change in "${MINE[@]}"; do
    IFS='|' read -r _ tree from to <<< "$change"
    file="$cfg/$tree/$to_env/app/kustomization.yaml"
    yq -i '(.images[] | select(.name == "'"$svc"'") | .newTag) = "'"$to"'"' "$file"
    git -C "$cfg" add "$tree/$to_env/app/kustomization.yaml"
    BODY+="| \`$tree\` | \`${from:0:12}\` | \`${to:0:12}\` |"$'\n'
  done

  # Dependencies go first, so each canary judgment is about one change.
  for dep in $(service_deps "$svc"); do
    if [[ " ${SERVICES[*]} " == *" $dep "* ]]; then
      BODY+=$'\n'"Promote **${dep} before ${svc}**: ${svc} calls ${dep}, so promoting the dependency"
      BODY+=" first keeps each canary judgment about one change."
    fi
  done

  # Reviewers need to see what is NOT in the release as much as what is.
  MY_BLOCKED=()
  for blocked in ${BLOCKED[@]+"${BLOCKED[@]}"}; do
    [[ "${blocked%%|*}" == "$svc" ]] && MY_BLOCKED+=("$blocked")
  done
  if [[ ${#MY_BLOCKED[@]} -gt 0 ]]; then
    BODY+=$'\n\n'"### Excluded by the deny list"$'\n\n'"| Cluster | Build | Reason |"$'\n'"|---|---|---|"$'\n'
    for blocked in "${MY_BLOCKED[@]}"; do
      IFS='|' read -r _ tree tag reason <<< "$blocked"
      BODY+="| \`$tree\` | \`$tag\` | $reason |"$'\n'
    done
  fi

  git -C "$cfg" commit -q -m "$TITLE"
  git -C "$cfg" push -q -u origin "$BRANCH"
  url="$(cd "$cfg" && gh pr create --title "$TITLE" --body "$BODY" --base main)"
  git -C "$cfg" switch main >/dev/null 2>&1
  PRS+=("$svc  $url")
done

echo "PRs opened. Review each diff: it is your release note."
for pr in "${PRS[@]}"; do echo "  $pr"; done
next_steps "merge the PRs          ArgoCD then starts a canary that pauses at 50 percent." \
           "gmake status           watch the new build arrive" \
           "gmake canary           promote it. Dependencies first, as the PR says." \
           "gmake rollback         go back to the last good build if it misbehaves"
XEOF
chmod +x scripts/release.sh
```

**Validate:** release nothing, safely.
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
bash -n scripts/release.sh && echo "syntax ok"
DRY_RUN=1 gmake release CLUSTER=local SVC=both
```
Expected: `syntax ok`, then either `Nothing to release: prod already matches dev for local / service-1 service-2.` or a short `Would release (dry run, nothing changed)` table listing the services whose dev tag is ahead of prod. Either way no branch is pushed and no PR opens. The freeze from the start of this section is over once this passes.

#### Task 20.4.3: Edit `rollback.sh`

**Goal:** `gmake rollback` reads a service's prod history from its config repo and opens the rollback PR there.

**What changes:** every Git command goes through one helper that names the service's config repo; the prod file is `<cluster>/<to>/app/kustomization.yaml`; and the cluster and service are asked first, because the history, the tags and the PR all belong to one repository that is not known until then. One real limitation: the config repos begin at the seed. A build that last ran in prod **before** the move cannot be found in their history, and the script says so; for one of those, edit the tag by hand in a PR.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
python3 - <<'PYEOF'
import sys

path = "scripts/rollback.sh"
s = open(path).read()

def swap(old, new):
    global s
    if s.count(old) != 1:
        sys.exit(f"ERROR: {path}: expected one match, found {s.count(old)} for:\n{old[:120]}")
    s = s.replace(old, new)

def swap_between(start, end, new):
    """Replace everything from `start` up to (not including) `end`."""
    global s
    if s.count(start) != 1 or s.count(end) != 1:
        sys.exit(f"ERROR: {path}: cannot find the section starting '{start[:60]}'")
    a = s.index(start); b = s.index(end)
    if b < a:
        sys.exit(f"ERROR: {path}: section markers out of order.")
    s = s[:a] + new + s[b:]

swap("""# A rollback is a Git commit, like every other change here: it sets newTag in
# the prod overlay back to an older value and ArgoCD does the rest. The change
# goes through a PR, so the prod gate (CODEOWNERS) still applies.""",
"""# A rollback is a Git commit, like every other change here: it sets newTag in
# the prod environment of the service's config repository back to an older value
# and ArgoCD does the rest. The change goes through a PR in that repository, so
# the team's own review rules still apply.""")

swap("""#   <service>  service-1 or service-2""", """#   <service>  a service with a subscription (gmake status lists them)""")

# Everything between the argument handling and usage() reads history, and all of
# it now reads the history of ONE repository: the chosen service's config repo.
swap_between('REPO_ROOT="$(git rev-parse --show-toplevel)"', "usage() {", '''cd "$SCRIPT_DIR/.."

# The config repository of the service being rolled back. Set once the service
# is chosen, below. Every Git command in this script goes through cfg_git.
CFG=""
cfg_git() { git -C "$CFG" "$@"; }

# Where, inside the config repo, a cluster's prod environment keeps its tag.
prod_file() { echo "$1/$(promote_to "$2")/app/kustomization.yaml"; }

# The tag a file holds at a given commit. Empty if the file does not exist there.
tag_at() { # <commit> <path> <service>
  cfg_git show "$1:$2" 2>/dev/null \\
    | SVC="$3" yq '.images[] | select(.name == strenv(SVC)) | .newTag' 2>/dev/null || true
}

# Prod's tag for a service as of a commit.
prod_tag_at() { # <commit> <tree> <service>
  tag_at "$1" "$(prod_file "$2" "$3")" "$3"
}

# Prod tags this service has had, newest first, deduplicated. Used for hints and
# to check that a named build really existed.
recent_tags() { # <service> [count]
  local svc="$1" count="${2:-5}" c
  cfg_git log --format=%H -n 60 -- "$(prod_file "${TREES[0]}" "$svc")" | while read -r c; do
    prod_tag_at "$c" "${TREES[0]}" "$svc"
  done | awk 'NF && !seen[$0]++' | head -n "$count"
}

recent_releases() { # [count]
  # --no-merges: a merge commit's body repeats the PR title, which would list
  # "Merge pull request ..." lines. Only the release commits themselves count.
  cfg_git log main --no-merges --format='%s' -n 200 \\
    | grep '^release(' | sed 's/^release([a-z0-9-]*): //' | awk '!seen[$0]++' | head -n "${1:-5}"
}

''')

# Ask which cluster and service first: the history, the tags and the PR all
# belong to one config repo, which is not known until then.
swap_between("# Refuse a dirty tree, for the same reason release.sh does", "if [[ -z \"$TO\" ]]; then", '''# Interactive when a person is at the keyboard (stdin is a terminal). With
# SVC and TO both given it behaves exactly as before, and in a pipe or CI with
# either missing it still fails with the usage hint instead of waiting forever.
INTERACTIVE=0
[[ -t 0 ]] && INTERACTIVE=1

# Cluster first, since the prod tags, the history and the PR all belong to one.
pick_cluster "roll back" no "running"
TREES=("${PICKED_CLUSTERS[0]}")
CLUSTER_NAME="${TREES[0]}"
pick_service "roll back" no
SVC="${PICKED_SERVICES[0]}"

CFG="$(service_config_dir "$SVC")"
[[ -d "$CFG/.git" ]] || { echo "ERROR: $SVC's config repo is not checked out at $CFG." >&2; exit 1; }

# Refuse a dirty tree, for the same reason release.sh does: a rollback commit
# that quietly carries an unrelated change is the surprise this process avoids.
if [[ -n "$(cfg_git status --porcelain)" ]]; then
  echo "ERROR: $CFG has uncommitted changes. Commit or stash first." >&2
  exit 1
fi

# Before any prompt, so the "prod is on ..." and recent-builds lists reflect main.
cfg_git switch main >/dev/null 2>&1
cfg_git pull --ff-only --quiet
cfg_git fetch --quiet --prune origin

''')

swap("""  MATCHES="$(git log main --no-merges --format=%h --grep="^release(prod): ${TO}\\$")\"""",
     """  MATCHES="$(cfg_git log main --no-merges --format=%h --grep="^release([a-z0-9-]*): ${TO}\\$")\"""")
swap("""  COMMIT="$(git rev-parse --verify --quiet "${TO}^{commit}")" \\
    || usage "'$TO' is not a commit in this repository."
  COMMIT="$(git rev-parse --short "$COMMIT")\"""",
     """  COMMIT="$(cfg_git rev-parse --verify --quiet "${TO}^{commit}")" \\
    || usage "'$TO' is not a commit in $SVC's config repository."
  COMMIT="$(cfg_git rev-parse --short "$COMMIT")\"""")

swap("""# --- Resolve to a tag, per tree. Old commits predate overlays/local, so fall
# back to the pre-restructure path. ---""", """# --- Resolve to a tag, per tree. ---""")

swap("""    if ! recent_tags "$SVC" 40 | grep -qx "$to"; then
      # It may have only ever run in dev, so check there too.
      dev_file="kubernetes/overlays/$tree/dev/$SVC/kustomization.yaml"
      if ! git log -S"newTag: ${to}" --format=%h -- "$dev_file" "$file" \\
            "kubernetes/overlays/dev/$SVC/kustomization.yaml" "kubernetes/overlays/prod/$SVC/kustomization.yaml" | grep -q .; then
        usage "build '$to' never appears in $SVC's history."
      fi
    fi""", """    if ! recent_tags "$SVC" 40 | grep -qx "$to"; then
      # It may have only ever run in dev, so check there too.
      dev_file="$tree/$(promote_from "$SVC")/app/kustomization.yaml"
      if ! cfg_git log -S"newTag: ${to}" --format=%h -- "$dev_file" "$file" | grep -q .; then
        usage "build '$to' never appears in $SVC's config repository history. History from before the move to config repositories stays in the GitOps repository: for a build from then, edit the tag by hand in a PR."
      fi
    fi""")

swap("""while git show-ref --verify --quiet "refs/heads/${BRANCH}" \\
   || git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; do""",
     """while cfg_git show-ref --verify --quiet "refs/heads/${BRANCH}" \\
   || cfg_git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; do""")
swap("""git switch -c "$BRANCH"

BODY=""", """cfg_git switch -q -c "$BRANCH"

BODY=""")
swap("""  yq -i '(.images[] | select(.name == "'"$SVC"'") | .newTag) = "'"$to"'"' "$file"
  git add "$file\"""", """  yq -i '(.images[] | select(.name == "'"$SVC"'") | .newTag) = "'"$to"'"' "$CFG/$file"
  cfg_git add "$file\"""")
swap("""BODY+="\\`gmake release\\` promotes the same build again. After merging, the prod canary\"""",
     """BODY+="\\`gmake release\\` promotes the same build again. After merging, the prod canary\"""")
swap("""git commit -m "rollback(prod): ${CLUSTER_NAME}/${SVC} ${FROM_TAG} -> ${FIRST_TO}"
git push -u origin "$BRANCH"

gh pr create --title "rollback(prod): ${CLUSTER_NAME}/${SVC} ${FROM_TAG} -> ${FIRST_TO}" --body "$BODY" --base main

git switch main""", """cfg_git commit -q -m "rollback(prod): ${CLUSTER_NAME}/${SVC} ${FROM_TAG} -> ${FIRST_TO}"
cfg_git push -q -u origin "$BRANCH"

(cd "$CFG" && gh pr create --title "rollback(prod): ${CLUSTER_NAME}/${SVC} ${FROM_TAG} -> ${FIRST_TO}" --body "$BODY" --base main)

cfg_git switch -q main""")
swap("""echo "Rollback PR opened. Review the diff, then merge it.\"""", """echo "Rollback PR opened in $(basename "$CFG"). Review the diff, then merge it.\"""")

open(path, "w").write(s)
print("Edited rollback.sh.")
PYEOF
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
bash -n scripts/rollback.sh && echo "syntax ok"
source scripts/reg.sh
CUR="$(yq '.images[0].newTag' "$(service_config_dir service-2)/local/prod/app/kustomization.yaml")"
gmake rollback CLUSTER=local SVC=service-2 TO="$CUR"
gmake rollback CLUSTER=local SVC=service-2 TO=26W01B99 </dev/null 2>&1 | head -3
```
Expected: `syntax ok`, then `Nothing to do: service-2 prod is already at <tag>.`, then an `ERROR: build '26W01B99' never appears in service-2's config repository history` message. The second command asks for nothing and changes nothing. A real rollback is exercised in Section 21's drill only if you choose to; it opens a PR.

#### Task 20.4.4: Ship the commands

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
scripts/check-contract.sh
git add scripts
bash "$PLATFORM_HOME/.tmp/g4/ship.sh" "scripts: read services, environments and tags from subscriptions and config repos"
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git status -sb
kubectl --context k3d-platform -n argocd get applications
```
Expected: a first line that names `feat/pluggable-structure` with no changed files listed below it, and the seven Applications `Synced` and `Healthy`.

#### Task 20.4.5: Retire the old tree

**Goal:** `kubernetes/` is gone from the GitOps repo, CODEOWNERS and the README stop describing it, and nothing is left that could be mistaken for a second source of truth.

**Why it is safe now:** ArgoCD reads the config repos (Task 20.3.6), CI writes to them (Task 20.3.7) and the commands read them (Phase 20.4). `parity.sh` stops being meaningful: it compares the old tree with the new one, and the old one is going away.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
git fetch origin
git merge --ff-only origin/main
git rm -q -r kubernetes
sed -i '' '/kubernetes\/overlays/d;/Removed in Task 20.4.5/d' .github/CODEOWNERS
python3 - <<'PYEOF'
import sys

path = "README.md"
s = open(path).read()
start, end = "## The two rules", "## Common commands"
if s.count(start) != 1 or s.count(end) != 1:
    sys.exit(f"ERROR: {path}: could not find the '{start}' and '{end}' headings. Edit it by hand.")
a, b = s.index(start), s.index(end)

new = """## The rules

**Nobody runs `kubectl apply` against the cluster.** ArgoCD reconciles continuously, so
a manual change is reverted within a reconciliation window, silently and with no error.
Deploying means committing.

**This repository holds no service manifests.** A service is a subscription under
`platform/subscriptions/` that points at a config repository its team owns, and the
ApplicationSets read that repository. Prod is protected by the team's own repository.
CODEOWNERS here covers what the platform owns: `platform/`, `argocd/`, `addons/`,
`releases/`, `scripts/` and `terraform/`.

## Layout

~~~
platform/
  registry.yaml          project identity and clusters
  subscriptions/         one file per service per cluster: where its config repo is
  overrides/             optional platform adjustments to a subscription
terraform/
  local/, eks/           01-cluster and 02-platform for each cluster
argocd/
  apps-<cluster>/        what root watches: generated ApplicationSets and the teams
                         project (scripts/gen-appsets.sh writes them)
addons/<cluster>/        third-party software, one directory per add-on
scripts/                 the commands behind gmake, the registry readers, the contract
                         check, the generator, the scaffolder and the stamp script
releases/                denied-builds.yaml, the veto list.
~~~

Service manifests live in each service's own `<project>-<service>-config` repository, and
the components they build on live in `<project>-service-templates`.

Terraform is split into two root modules because the `kubernetes` and `helm` providers
need a reachable cluster at plan time, and the cluster does not exist during the first
apply. Collapse them into one and the first run can never succeed.

"""
open(path, "w").write(s[:a] + new + s[b:])
print("Edited README.md.")
PYEOF
scripts/check-contract.sh
git add -A .github README.md
git status --short | head -20
bash "$S/ship.sh" "retire the kubernetes/ tree: manifests live in the config repos"
"$S/refresh.sh"
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
test ! -d kubernetes && echo "kubernetes/ is gone"
grep -c '^/' .github/CODEOWNERS
grep -rn 'kubernetes/overlays\|kubernetes/base' Makefile scripts terraform argocd README.md .github | grep -v 'parity' || echo "no references left"
kubectl --context k3d-platform -n argocd get applications
diff "$S/uids-cutover-before.txt" <("$S/uids.sh") && echo NOTHING RECREATED
```
Expected: `kubernetes/ is gone`, `6` (the remaining ownership lines), `no references left`, seven Applications `Synced` and `Healthy`, and `NOTHING RECREATED`. If the merge step reports a conflict on a file under `kubernetes/overlays/`, a stray CI run wrote to the old tree after all; Appendix I has the one-line fix.

### Phase 20.5: The scaffolder

#### Task 20.5.1: The scaffold script

**Goal:** `scripts/new-service.sh <name> --image ... --tag ...` creates a service's subscriptions, creates its config repository as a ready-to-push directory from the templates repo's `web-service` scaffold, and prints what to do in the service's own repository.

**Why it writes the config repo and the subscriptions together:** that is the contract Task 19.2.3 checks. A scaffolder that produced only one of them would create exactly the drift the check exists to catch. It reads the templates repo's newest tag and pins the new service's components to it, so a new service starts on a released version.

**Why environments are a flag:** teams choose them. The default is `dev,prod`; for those two names the scaffolder opts in to the platform's usual behavior (`replicas-1` for dev, `canary-manual-gate` for prod). Any other environment name starts plain and the team adds the components it wants.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
cat > scripts/new-service.sh <<'XEOF'
#!/usr/bin/env bash
# Scaffolds a service: one subscription per cluster in this repository, and a new
# config repository (a sibling directory, ready to push) holding the service's
# manifests, copied from the templates repository's web-service scaffold.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/reg.sh"

usage() {
  cat >&2 <<EOF
Usage: scripts/new-service.sh <name> --image <repo> --tag <tag> [options]
  --image <repo>      image repository without a tag, e.g. ghcr.io/you/orders
  --tag <tag>         first image tag to deploy, e.g. 1.0.0
  --port <n>          container port (default 8000)
  --health <path>     liveness and readiness path (default /healthz)
  --role <text>       one line for the menus (default: a service)
  --team <name>       owning team (default: team-<name>)
  --envs <a,b>        environments to create (default: dev,prod)
  --clusters <a,b>    clusters to subscribe to (default: all in the registry)
  --depends-on <s>    a service this one calls (repeatable)
EOF
  exit 1
}

NAME="${1:-}"; [[ -n "$NAME" ]] || usage; shift
PORT=8000; HEALTH=/healthz; IMAGE=""; TAG=""; ROLE="a service"; TEAM=""; ENVS="dev,prod"; CLUSTERS=""; DEPS=()
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || usage
  case "$1" in
    --image) IMAGE="$2" ;;
    --tag) TAG="$2" ;;
    --port) PORT="$2" ;;
    --health) HEALTH="$2" ;;
    --role) ROLE="$2" ;;
    --team) TEAM="$2" ;;
    --envs) ENVS="$2" ;;
    --clusters) CLUSTERS="$2" ;;
    --depends-on) DEPS+=("$2") ;;
    *) usage ;;
  esac
  shift 2
done
[[ -n "$IMAGE" && -n "$TAG" ]] || usage
TEAM="${TEAM:-team-$NAME}"
CLUSTERS="${CLUSTERS:-$(IFS=,; echo "${LFI_CLUSTERS[*]}")}"

[[ "$NAME" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "ERROR: name must be lowercase letters, digits and dashes." >&2; exit 1; }
[[ "$NAME" != postgres ]] || { echo "ERROR: postgres is a datastore, not a service." >&2; exit 1; }
[[ " ${LFI_SERVICES[*]-} " != *" $NAME "* ]] || { echo "ERROR: $NAME already has a subscription." >&2; exit 1; }
for c in ${CLUSTERS//,/ }; do
  [[ " ${LFI_CLUSTERS[*]} " == *" $c "* ]] || { echo "ERROR: '$c' is not a cluster in the registry." >&2; exit 1; }
done
# `${DEPS[@]+...}` because bash 3.2 treats an empty array as unset under set -u.
for d in ${DEPS[@]+"${DEPS[@]}"}; do
  [[ " ${LFI_SERVICES[*]-} " == *" $d "* ]] || { echo "ERROR: --depends-on $d has no subscription." >&2; exit 1; }
done

TEMPLATES_DIR="$(dirname "$GITOPS_ROOT")/$PROJECT-service-templates"
SCAFFOLD="$TEMPLATES_DIR/scaffolds/web-service"
[[ -d "$SCAFFOLD" ]] || { echo "ERROR: $SCAFFOLD not found. Clone the templates repository next to this one." >&2; exit 1; }
CFG="$(dirname "$GITOPS_ROOT")/$PROJECT-$NAME-config"
[[ ! -e "$CFG" ]] || { echo "ERROR: $CFG already exists." >&2; exit 1; }

# Pin to the newest tag of the templates repository, so the new service starts on
# a released version and not on whatever main happens to hold.
TEMPLATES_URL="${TEMPLATES_URL:-https://github.com/$OWNER/$PROJECT-service-templates}"
TEMPLATES_REF="${TEMPLATES_REF:-$(git -C "$TEMPLATES_DIR" describe --tags --abbrev=0 2>/dev/null || true)}"
[[ -n "$TEMPLATES_REF" ]] || { echo "ERROR: the templates repository has no tag. Tag a release first." >&2; exit 1; }
comp() { echo "${TEMPLATES_URL}//components/$1?ref=${TEMPLATES_REF}"; }

# --- The config repository ---
mkdir -p "$CFG/base/app" "$CFG/.github"
for f in kustomization.yaml rollout.yaml service.yaml; do
  sed -e "s#__NAME__#$NAME#g" -e "s#__PORT__#$PORT#g" -e "s#__HEALTH__#$HEALTH#g" \
    "$SCAFFOLD/$f" > "$CFG/base/app/$f"
done

for cluster in ${CLUSTERS//,/ }; do
  for env in ${ENVS//,/ }; do
    dir="$CFG/$cluster/$env"
    mkdir -p "$dir/app"
    printf '# This directory is one environment of %s on the %s cluster.\n# ArgoCD finds it by this file.\nenv: %s\n' "$NAME" "$cluster" "$env" > "$dir/env.yaml"
    {
      cat <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${NAMESPACE_PREFIX}-${env}
resources:
  - ../../../base/app
EOF
      # Environments called dev and prod get the platform's usual behaviour.
      # Any other name starts plain; add the components you want.
      case "$env" in
        dev)  printf 'components:\n  - %s\n' "$(comp replicas-1)" ;;
        prod) printf 'components:\n  - %s\n' "$(comp canary-manual-gate)" ;;
      esac
      cat <<EOF
images:
  - name: ${NAME}
    newName: ${IMAGE}
    newTag: ${TAG}
EOF
    } > "$dir/app/kustomization.yaml"
  done
done

cat > "$CFG/.github/CODEOWNERS" <<EOF
# This repository belongs to the team that runs $NAME. What it protects is the
# team's decision; the platform only suggests. Prod changes need a review:
/*/prod/    @$OWNER
EOF
cat > "$CFG/README.md" <<EOF
# $PROJECT-$NAME-config

Kubernetes manifests for $NAME, one directory per cluster and environment:

    <cluster>/<environment>/env.yaml       marks an environment (ArgoCD finds it)
    <cluster>/<environment>/app/           what runs
    base/app/                              the service's own manifests

The platform reads this repository because platform/subscriptions/ in
$PROJECT-infrastructure-gitops names it. CI writes \`images[0].newTag\` in
<cluster>/dev/app/kustomization.yaml. A release moves that tag to prod.
EOF
git -C "$CFG" init -q -b main
git -C "$CFG" add -A
git -C "$CFG" commit -q -m "scaffold $NAME from web-service $TEMPLATES_REF"

# --- The subscriptions ---
for cluster in ${CLUSTERS//,/ }; do
  mkdir -p "$SUBSCRIPTIONS/$cluster"
  f="$SUBSCRIPTIONS/$cluster/$NAME.yaml"
  {
    echo "# $NAME on the $cluster cluster. The ApplicationSets read this file."
    echo "name: $NAME"
    echo "team: $TEAM"
    echo "role: $ROLE"
    if [[ ${#DEPS[@]} -gt 0 ]]; then
      echo "dependsOn: [$(IFS=,; echo "${DEPS[*]}" | sed 's/,/, /g')]"
    fi
    echo "# The repo ArgoCD reads this service's manifests from. The team owns it."
    echo "configRepo: https://github.com/$OWNER/$PROJECT-$NAME-config.git"
    echo "# Which environments a release promotes between."
    echo "promotion:"
    echo "  from: dev"
    echo "  to: prod"
  } > "$f"
done

echo "Created $CFG and subscriptions on: ${CLUSTERS//,/ }."
echo
echo "Next:"
echo "  1. Create and push the config repository:"
echo "       cd $CFG && gh repo create $OWNER/$PROJECT-$NAME-config --public --source . --push"
echo "  2. In the service's own repository, point its CI at the config repository (guide 4, Task 20.3.7 shows the edit):"
echo "       the promote job checks out $OWNER/$PROJECT-$NAME-config and edits"
for cluster in ${CLUSTERS//,/ }; do
  echo "         $cluster/dev/app/kustomization.yaml"
done
echo "  3. Here: scripts/check-contract.sh, commit the subscriptions, merge. ArgoCD creates ${NAME}-<env> on its own."
XEOF
chmod +x scripts/new-service.sh
```

**Validate.** Prove it works on a disposable copy, so your repos are untouched. The copy needs the templates repo beside it, because the script looks for a sibling:
```bash
S="$PLATFORM_HOME/.tmp/g4"
rm -rf "$S/scaffold-test"; mkdir -p "$S/scaffold-test"
rsync -a --exclude .git --exclude .terraform --exclude .generated "$PLATFORM_HOME/lfi-infrastructure-gitops/" "$S/scaffold-test/lfi-infrastructure-gitops/"
PROJECT="$(yq '.project' "$PLATFORM_HOME/lfi-infrastructure-gitops/platform/registry.yaml")"
cp -R "$PLATFORM_HOME/$PROJECT-service-templates" "$S/scaffold-test/"
cd "$S/scaffold-test/lfi-infrastructure-gitops"
scripts/new-service.sh demo --image ghcr.io/example/demo --tag 1.0.0 --port 9898 --role "a throwaway demo" --depends-on service-2
for c in local eks; do for e in dev prod; do
  kustomize build "../$PROJECT-demo-config/$c/$e/app" \
    | yq -N 'select(.kind == "Rollout") | "'"$c $e"' replicas=" + (.spec.replicas | tostring) + " ns=" + .metadata.namespace + " steps=" + (.spec.strategy.canary.steps | length | tostring)'
done; done
scripts/check-contract.sh
scripts/new-service.sh demo --image x --tag 1 2>&1 | tail -1
scripts/new-service.sh other --image x --tag 1 --depends-on nope 2>&1 | tail -1
scripts/new-service.sh other --image x --tag 1 --clusters mars 2>&1 | tail -1
ls .. | grep -c "$PROJECT-other" || true
```
Expected: the scaffold's "Created" message and next steps, then four lines, `local dev replicas=1 ns=platform-dev steps=1`, `local prod replicas=2 ns=platform-prod steps=3`, then the same two for `eks`; then `OK: 3 service(s) x 2 cluster(s) match the registry.`; then `ERROR: demo already has a subscription.`, `ERROR: --depends-on nope has no subscription.` and `ERROR: 'mars' is not a cluster in the registry.`; and finally `0`, proving the three rejected runs wrote nothing. Delete the copy with `rm -rf "$S/scaffold-test"`.

Ship it:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git add scripts/new-service.sh
bash "$PLATFORM_HOME/.tmp/g4/ship.sh" "add the scaffold script"
```

### Phase 20.6: Plug-in drill (local)

**Objective:** Add a real service by creating a repository and a subscription, see it appear, remove it by deleting the subscription, see it vanish, and prove the existing services never noticed.

The service is **podinfo**, a small public demo application. It needs no database, listens on 9898 and serves `/healthz`. It is a stand-in for whatever you build next.

#### Task 20.6.1: Plug a service in

**Goal:** `demo-dev` and `demo-prod` Applications appear on the local cluster, healthy, from one scaffold command, one new repository and one merge.

First confirm the image tag exists; pick any published tag from the project's release page if this one does not:
```bash
docker manifest inspect ghcr.io/stefanprodan/podinfo:6.7.1 >/dev/null && echo "tag exists"
```
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
"$S/uids.sh" > "$S/uids-drill-before.txt"
scripts/new-service.sh demo --image ghcr.io/stefanprodan/podinfo --tag 6.7.1 \
  --port 9898 --health /healthz --role "a throwaway demo" --clusters local
source scripts/reg.sh
GH_HOST=github.com gh repo create "$OWNER/$PROJECT-demo-config" --public --source "$(dirname "$GITOPS_ROOT")/$PROJECT-demo-config" --push
git -C "$(dirname "$GITOPS_ROOT")/$PROJECT-demo-config" branch -u origin/main main
scripts/check-contract.sh
git add platform
bash "$S/ship.sh" "drill: plug in the demo service"
"$S/refresh.sh"
kubectl --context k3d-platform -n argocd annotate applicationset services-local \
  argocd.argoproj.io/application-set-refresh=true --overwrite
```
The last line asks the controller to re-read Git now; if your version ignores it, the set notices within three minutes anyway. The order matters: the config repository exists on GitHub **before** the subscription reaches `main`, so the set never reads a repository that is not there.

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

**Goal:** Deleting the subscription removes the Applications and the pods, and leaves everything else alone. The team's repository is the team's to keep or delete.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
git rm -q platform/subscriptions/local/demo.yaml
scripts/check-contract.sh
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
Expected: `root` plus the six original children, `No resources found` for the demo pods, and `BACK TO THE START`. The namespaces remain because Terraform owns them. Now remove what the drill created outside the cluster:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
source scripts/reg.sh
GH_HOST=github.com gh repo delete "$OWNER/$PROJECT-demo-config" --yes
rm -rf "$(dirname "$GITOPS_ROOT")/$PROJECT-demo-config"
```
If `gh` refuses with a scope error, run `GH_HOST=github.com gh auth refresh -h github.com -s delete_repo` once, or delete the repository on GitHub's settings page.

**Checkpoint.** Section 20 is a complete outcome on its own: a local platform whose services are plugged in and out by subscription, whose manifests belong to their teams, and whose CI writes only to those teams' repos. Everything after this is making the same true across clusters and for add-ons.

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

# Scaffolds a service: a subscription per cluster and a config repository, ready
# to push. Extra flags go in ARGS, e.g. ARGS="--port 9898 --health /healthz".
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
grep -c '^ *key  *=' terraform/*/*/backend.tf
awk '/^variable "(region|cluster_name|kube_context)"/{v=$2} /^}/{v=""} v && /^[[:space:]]*default[[:space:]]*=/{print FILENAME": variable "v" still has a default"}' \
  terraform/eks/01-cluster/variables.tf terraform/eks/02-platform/variables.tf \
  terraform/local/01-cluster/main.tf terraform/local/02-platform/variables.tf | grep . || echo "no defaults left for the registry's variables"
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

**Objective:** Creating the next project from this one is a short checklist, not an afternoon.

#### Task 21.4.1: The stamp script

**Goal:** `scripts/stamp.sh` relabels a fresh copy of the GitOps repo as a new project: owner, repository name, cluster names, namespaces, Terraform state keys and bucket, code owner, and the names of the config repositories its subscriptions point at. It is a dry run unless you pass `--apply`.

**What it deliberately leaves alone:** the two example services and their images. They keep deploying from the original project's public images, so a stamped repo is a working platform on the first `gmake up`, and the next project replaces them by plugging services in and out, which is the point of this whole guide. It does not touch the templates repo, the config repos or the service repos, because those are separate repositories: it prints the names it expects them to have, and the README section in the next task gives the commands to create them. A service repo's CI names its own config repository and must be edited by hand (Appendix I).

**What it regenerates rather than edits:** the ApplicationSets and the `teams` project hold the owner, the repo URL and the namespace prefix. After it updates the registry it runs `scripts/gen-appsets.sh`, so those files are rewritten from the one source and the contract check stays green.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
cat > scripts/stamp.sh <<'XEOF'
#!/usr/bin/env bash
# Re-labels a copy of this repo as a new project: new GitHub owner and repo,
# new cluster names, new namespaces, new state bucket, and the names of the
# config and templates repositories it expects to find. Run it once, in a fresh
# copy made from the GitHub template, before anything is applied.
#
# Dry run by default. Add --apply to change files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source "$SCRIPT_DIR/reg.sh"
# reg.sh reads the project's current owner and name into OWNER and PROJECT.
# Keep them under other names; the arguments below use OWNER and PROJECT for the new ones.
OWNER_NOW="$OWNER"; PROJECT_NOW="$PROJECT"

usage() {
  cat >&2 <<EOF
Usage: scripts/stamp.sh --owner <github owner> --repo <repo name> --project <short name> \\
                        --bucket <state bucket> [--ns-prefix <prefix>] [--apply]
  --project    short lowercase name, e.g. mktp. Becomes the cluster names:
               k3d cluster <project>, EKS cluster <project>-eks.
  --ns-prefix  namespace prefix (default: the project), giving <prefix>-<environment>
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

OLD_OWNER="$OWNER_NOW"; OLD_REPO="$(yq '.repo' "$REGISTRY")"; OLD_PROJECT="$PROJECT_NOW"
OLD_BUCKET="$(yq '.stateBucket' "$REGISTRY")"; OLD_NSP="$(yq '.namespacePrefix' "$REGISTRY")"
OLD_K3D="$(yq '.clusters[] | select(.kind == "k3d") | .clusterName' "$REGISTRY")"

[[ "$OLD_OWNER/$OLD_REPO" != "$OWNER/$REPO" ]] || { echo "ERROR: the registry already says $OWNER/$REPO. Nothing to stamp." >&2; exit 1; }

# Files that carry each old value. grep -rl lists them, so the dry run shows
# exactly what --apply would touch.
URL_FILES="$(grep -rl "github.com/$OLD_OWNER/$OLD_REPO.git" argocd 2>/dev/null || true)"
BACKEND_FILES="$(grep -rl "$OLD_BUCKET" terraform --include=backend.tf 2>/dev/null || true)"
OWNER_FILES="$(grep -l "@$OLD_OWNER" .github/CODEOWNERS 2>/dev/null || true)"
# Subscriptions name the config repositories, which are called <project>-<service>-config.
SUB_FILES="$(grep -rl "github.com/$OLD_OWNER/$OLD_PROJECT-" platform/subscriptions 2>/dev/null || true)"

echo "Stamping $OLD_OWNER/$OLD_REPO as $OWNER/$REPO (project $PROJECT, namespaces ${NSP}-<environment>)"
echo
echo "Registry:            platform/registry.yaml (owner, repo, bucket, prefixes, cluster names)"
echo "k3d cluster name:    $OLD_K3D -> $PROJECT   (terraform/local/01-cluster/k3d-config.yaml)"
echo "Repo URL in:         $(echo "$URL_FILES" | grep -c . || true) file(s) under argocd/"
echo "State bucket in:     $(echo "$BACKEND_FILES" | grep -c . || true) backend.tf file(s)"
echo "Subscriptions:       $(echo "$SUB_FILES" | grep -c . || true) file(s) naming config repositories"
echo "Generated files:     ApplicationSets and teams project, regenerated from the registry"
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
for f in $SUB_FILES; do
  sed -i '' "s#github.com/$OLD_OWNER/$OLD_PROJECT-#github.com/$OWNER/$PROJECT-#g" "$f"
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

# The ApplicationSets and the project hold the owner, repo and namespace prefix.
# Regenerate them instead of editing them.
scripts/gen-appsets.sh

echo
echo "Done. Verify:  scripts/check-contract.sh"
echo "Then commit, and create these GitHub repositories under $OWNER:"
echo "  $REPO                          (this repository)"
echo "  $PROJECT-service-templates     (from $OLD_OWNER/$OLD_PROJECT-service-templates)"
for svc in $(yq -N '.name' $(ls platform/subscriptions/*/*.yaml) | sort -u); do
  echo "  $PROJECT-$svc-config           (from $OLD_OWNER/$OLD_PROJECT-$svc-config)"
done
echo "See 'Creating a project from this template' in README.md for the commands."
XEOF
chmod +x scripts/stamp.sh
```

**Validate** on a disposable copy, so this repo is untouched:
```bash
S="$PLATFORM_HOME/.tmp/g4"
rm -rf "$S/stamp-test"; mkdir -p "$S/stamp-test/lfi-infrastructure-gitops"
rsync -a --exclude .git --exclude .terraform --exclude .generated "$PLATFORM_HOME/lfi-infrastructure-gitops/" "$S/stamp-test/lfi-infrastructure-gitops/"
cd "$S/stamp-test/lfi-infrastructure-gitops"
scripts/stamp.sh --owner example --repo demo-gitops --project demo --bucket tfstate-example-demo
scripts/stamp.sh --owner example --repo demo-gitops --project demo --bucket tfstate-example-demo --apply
scripts/check-contract.sh
yq '.clusters[] | .name + " " + .context + " " + .stateKeyPrefix' platform/registry.yaml
yq '.configRepo' platform/subscriptions/local/service-1.yaml
yq '.spec.sourceRepos[0]' argocd/apps-local/projects/teams.yaml
grep -rn "$(yq '.stateBucket' "$PLATFORM_HOME/lfi-infrastructure-gitops/platform/registry.yaml")" terraform | wc -l
```
Expected: the dry run lists counts and ends `Dry run. Nothing changed.`; the apply ends with the list of repositories to create (`demo-service-templates`, `demo-service-1-config`, `demo-service-2-config` and so on); `check-contract.sh` prints `OK`; the clusters print as `local k3d-demo demo-local` and `eks demo-eks demo-eks`; the config repository prints as `https://github.com/example/demo-service-1-config.git`; the project's repository pattern prints as `https://github.com/example/demo-*-config.git`; and the last count is `0` (the old bucket name appears nowhere under `terraform/`). Then `rm -rf "$S/stamp-test"`.

#### Task 21.4.2: Document it and mark the repos as templates

**Goal:** A README section that tells a future you how to start a project, and the GitHub "template repository" switch on for every repository the new project needs a copy of.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
cat >> README.md <<'XEOF'

## Creating a project from this template

A project is this repository, a templates repository and one config repository per
service. All of them are GitHub template repositories, so a new project starts with
no history and none of the old project's tags or secrets.

1. Create the repositories from the templates. `OLD` is the project you are copying
   (owner and project name), `NEW` is the new one:
   ~~~
   OLD_OWNER=<owner>; OLD=lfi; NEW_OWNER=<owner>; NEW=<short>
   gh repo create $NEW_OWNER/$NEW-infrastructure-gitops --template $OLD_OWNER/$OLD-infrastructure-gitops --public --clone
   gh repo create $NEW_OWNER/$NEW-service-templates --template $OLD_OWNER/$OLD-service-templates --public --clone
   for s in service-1 service-2; do
     gh repo create $NEW_OWNER/$NEW-$s-config --template $OLD_OWNER/$OLD-$s-config --public --clone
   done
   ~~~
2. Give the new templates repository its first tag, because a template copy carries
   files and not tags, and every config repository pins one:
   ~~~
   cd $NEW-service-templates && git tag -a v1.0.0 -m "First release" && git push origin v1.0.0
   ~~~
3. Point the copied config repositories at the new templates repository:
   ~~~
   for s in service-1 service-2; do
     cd $NEW-$s-config
     grep -rl "github.com/$OLD_OWNER/$OLD-service-templates" . --include=kustomization.yaml \
       | xargs sed -i '' "s#github.com/$OLD_OWNER/$OLD-service-templates#github.com/$NEW_OWNER/$NEW-service-templates#g"
     git commit -am "point at the new templates repository" && git push
     cd ..
   done
   ~~~
   If you will give the new project a different namespace prefix (`--ns-prefix`), change it
   in the config repositories too, because each environment kustomization names its namespace:
   ~~~
   grep -rl 'namespace: platform-' $NEW-service-1-config $NEW-service-2-config --include=kustomization.yaml \
     | xargs sed -i '' "s#namespace: platform-#namespace: <prefix>-#g"
   ~~~
4. Create an S3 bucket for the new project's Terraform state, then, in the new GitOps repo:
   ~~~
   scripts/stamp.sh --owner <owner> --repo <new-repo> --project <short> --bucket <bucket>
   scripts/stamp.sh --owner <owner> --repo <new-repo> --project <short> --bucket <bucket> --apply
   scripts/check-contract.sh
   ~~~
5. Copy `.env.example` to `.env` and fill it in. Set `GITOPS_REPO_URL` to the new repository.
6. Bring up a cluster with `gmake up`. The two example services deploy from their
   public images, so you have a working platform at once.
7. Replace them: `gmake add-service` for each of yours, then delete the examples'
   subscriptions (`platform/subscriptions/*/service-*.yaml`) and their config repositories.

Each service repository's CI names its own config repository and the files to update
(see the `promote` job). Copy an existing `ci.yaml` and change `IMAGE_NAME`,
`SERVICE` and the config repository name. `gmake add-service` prints the lines.
XEOF
git add scripts/stamp.sh README.md
bash "$PLATFORM_HOME/.tmp/g4/ship.sh" "add the stamp script and template instructions"
OWNER="$(yq '.owner' platform/registry.yaml)"; PROJECT="$(yq '.project' platform/registry.yaml)"
for r in "$(yq '.repo' platform/registry.yaml)" "$PROJECT-service-templates" "$PROJECT-service-1-config" "$PROJECT-service-2-config"; do
  GH_HOST=github.com gh repo edit "$OWNER/$r" --template
done
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
OWNER="$(yq '.owner' platform/registry.yaml)"; PROJECT="$(yq '.project' platform/registry.yaml)"
for r in "$(yq '.repo' platform/registry.yaml)" "$PROJECT-service-templates" "$PROJECT-service-1-config" "$PROJECT-service-2-config"; do
  printf '%s: ' "$r"; GH_HOST=github.com gh repo view "$OWNER/$r" --json isTemplate -q .isTemplate
done
```
Expected: `true` four times. If `gh` reports an authentication problem, run `gh auth login --hostname github.com`. You can also switch it on in each repository's Settings page under "Template repository".

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
kubectl --context lfi-eks -n argocd get applicationsets,appprojects
```
Expected: one node `Ready`; after ArgoCD's first sync (up to three minutes) `root` plus the six service and data Applications plus `addon-metrics-server-eks`, all `Synced` and `Healthy`; three ApplicationSets (`services-eks`, `data-eks` and `addons-eks`); and the `teams` project beside `default`. This cluster never had hand-written Applications in this layout. It built straight from the subscriptions and the config repos, which is the "later cluster reads the new layout" claim from the start of Phase 20.3.

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

**Goal:** One scaffold command, one new repository and one merge deploys a service to **both** clusters; one deletion removes it from both. Each cluster acts on its own subscriptions.

This needs the local cluster running too (`gmake up CLUSTER=local`). Both clusters run the same `main`, which is the independence claim: neither needs the other, and both converge from Git alone.
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
S="$PLATFORM_HOME/.tmp/g4"
scripts/new-service.sh demo --image ghcr.io/stefanprodan/podinfo --tag 6.7.1 \
  --port 9898 --health /healthz --role "a throwaway demo"
source scripts/reg.sh
GH_HOST=github.com gh repo create "$OWNER/$PROJECT-demo-config" --public --source "$(dirname "$GITOPS_ROOT")/$PROJECT-demo-config" --push
git -C "$(dirname "$GITOPS_ROOT")/$PROJECT-demo-config" branch -u origin/main main
scripts/check-contract.sh --online
git add platform
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
git rm -q platform/subscriptions/local/demo.yaml platform/subscriptions/eks/demo.yaml
scripts/check-contract.sh
bash "$S/ship.sh" "drill: plug out the demo service on both clusters"
```
```bash
for ctx in k3d-platform lfi-eks; do
  echo "== $ctx"
  kubectl --context "$ctx" -n argocd get applications | grep -c demo || true
  kubectl --context "$ctx" get pods -A -l app=demo --no-headers 2>/dev/null | wc -l
done
```
Expected after a few minutes: `0` and `0` on both clusters. Then remove the drill's repository, as in Task 20.6.2:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
source scripts/reg.sh
GH_HOST=github.com gh repo delete "$OWNER/$PROJECT-demo-config" --yes
rm -rf "$(dirname "$GITOPS_ROOT")/$PROJECT-demo-config"
```

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

**`unknown field` on a server dry run (Task 20.2.2).** The installed ApplicationSet CRD does not know a field. `applicationsSync`, `preserveResourcesOnDeletion` and `pathParamPrefix` are the newest ones. Confirm with `kubectl --context k3d-platform explain applicationset.spec.syncPolicy` (or `...generators.git`). If `applicationsSync` is missing, delete just that line from `scripts/gen-appsets.sh` and regenerate: `preserveResourcesOnDeletion` and `prune: false` still protect the database; `applicationsSync` only also stops the set deleting the Application. If `pathParamPrefix` is missing, your ArgoCD is too old for this design; upgrade it.

**The spike shows `Unknown` or a `ComparisonError` (Task 20.2.3).** The repo server could not render the Application. Read the message: `kubectl --context k3d-platform -n argocd get application spike-service-1-dev -o jsonpath='{.status.conditions}'`. The usual causes are, in order: the templates tag the config repo pins does not exist (`git ls-remote --tags https://github.com/<owner>/<project>-service-templates.git`), the templates repository is private (it must be public, or ArgoCD needs a credential for it), a remote reference with a typo (the `//` before `components` and the `?ref=` are both required), or the config repository is not on GitHub yet.

**The spike generates nothing, or the wrong Applications.** Read the controller log: `kubectl --context k3d-platform -n argocd logs deploy/argocd-applicationset-controller --tail=100`. Three things to check. First, `revision: feat/pluggable-structure` only works once the branch is pushed. Second, a `path` in an error message that is empty means the two generators' `path` values collided: `pathParamPrefix` on the first generator's children is what prevents that, so check the generated file has it. Third, a template error naming `get` or `default` means a Go template function the controller does not provide; replace `{{ get . "namespace" | default (printf ...) }}` with `{{ if hasKey . "namespace" }}{{ .namespace }}{{ else }}...{{ end }}` in `scripts/gen-appsets.sh`.

**Fallback A: the merge generator does not nest.** If the dry run accepts it but the controller rejects a merge inside a matrix, set `useMerge: false` in `platform/registry.yaml` and run `scripts/gen-appsets.sh`. The first generator becomes the plain subscription generator. You lose platform overrides (`targetRevision` pins) and nothing else, because the template reads them with `get`, which returns an empty string when the key is absent.

**Fallback B: one broken repository must not block everyone.** The spike (Task 20.2.3) shows what happens when a subscribed repository cannot be read: the set stops generating anything until it is fixed. `scripts/check-contract.sh --online` catches an unreachable repository before the subscription ships, and that is usually enough. If you need hard isolation, split the services set: one ApplicationSet per subscription file, each with the first generator pointed at that file instead of a glob. The generator would write `services-<cluster>-<service>.yaml` per subscription and the contract check would compare them one by one. This is deliberately not built here because it multiplies the files `root` watches; it is a known option, not a tested one.

**Finalizer still present after Move 2 (Task 20.3.4).** `root` did not sync the change, or the field was not removed from the live object. Force it, then look:
```bash
kubectl --context k3d-platform -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
kubectl --context k3d-platform -n argocd get applications \
  -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.finalizers}{"\n"}{end}'
```
If one still shows a finalizer after another minute, remove it directly, then re-run the guard from Task 20.3.4:
```bash
kubectl --context k3d-platform -n argocd patch application service-1-dev --type json \
  -p '[{"op":"remove","path":"/metadata/finalizers"}]'
```
Never continue to Move 3 while the guard prints `STOP`.

**No Applications appear after Move 4 (Task 20.3.6).** Read the controller log (`kubectl --context k3d-platform -n argocd logs deploy/argocd-applicationset-controller --tail=100`). Common causes: `repoURL` differs from the real repository (run `scripts/check-contract.sh`), a config repository is missing or private (`scripts/check-contract.sh --online`), the repository is private and ArgoCD has no credential for it (guide 1, Appendix A), or `revision: HEAD` points at a branch other than the one you merged to.

**Applications are `OutOfSync`, or the project refuses them, after Move 4.** An old Application with the same name still exists (Move 3 did not complete), the tracking identifier does not match, or the `teams` project rejects the repository or the namespace. The Application's conditions name which: `kubectl --context k3d-platform -n argocd get application service-1-dev -o jsonpath='{.status.conditions}'`. A message about the repository not being permitted means the project's pattern (`<project>-*-config`) does not match the config repository's name. A message about the destination means a namespace outside `platform-*`.

**Applications run the wrong image after Move 4.** The config repo's tag differed from the old overlay's at that moment. Task 20.3.6 runs `parity.sh` for exactly this. If you skipped it, the fix is forward: set the right tag in the config repo (`<cluster>/dev/app/kustomization.yaml` for dev, the prod file for prod) and let ArgoCD roll it.

**Rolling back the cutover.** Each move is one merge commit on `main`. To undo Move 4 and Move 3, revert them in that order and let `root` sync:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch main && git pull --ff-only
git log --oneline --merges -5
git revert -m 1 <the Move 4 merge commit>
git revert -m 1 <the Move 3 merge commit>
git push origin main
```
That restores the six hand-written Applications **without** finalizers (Move 2 stays applied), and they adopt the workloads by name exactly as the sets did. This works only while the old `kubernetes/` tree still exists and is current, which means before Task 20.3.7 (after it, CI no longer writes there, so the old overlays hold old tags). After Task 20.3.7, fix forward instead: the config repos are the source of truth, and a problem in them is fixed in them. Restore the finalizers afterwards by reverting Move 2 the same way, once you are back to a settled state.

**A promote job fails at "Check out this service's config repo" with a 404 (Task 20.3.2).** The `GITOPS_PAT` token cannot see the repository. Fine-grained tokens list their repositories explicitly: open the token in GitHub's developer settings, add the config repository under **Repository access**, and re-run the failed job. Nothing is half done, because both checkouts happen before any edit.

**A promote job fails with "does not exist" (Task 20.3.2 or 20.3.7).** The workflow edits `local/dev/app/kustomization.yaml` and `eks/dev/app/kustomization.yaml` in the config repo. A team that renamed its environments, or removed a cluster directory, must edit the paths in its own `ci.yaml`. The same applies to a service scaffolded with `--clusters local`: delete the `eks` line.

**A merge conflict on a file under `kubernetes/overlays/` when retiring the old tree (Task 20.4.5).** A CI run wrote to the old overlay after your branch deleted it. Resolve by deleting it, which is what you want:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git rm -q -r kubernetes
git commit --no-edit
git push origin main
git switch feat/pluggable-structure
git merge --ff-only main
```
If CI is still writing there, Task 20.3.7 did not take effect: check the service repo's workflow before deleting anything.

**`gmake release` says a config repo is not checked out.** The commands find each service's config repo as a sibling of the GitOps repo, named like the repo on GitHub. Clone it there: `git clone https://github.com/<owner>/<project>-service-1-config.git "$PLATFORM_HOME/<project>-service-1-config"`.

**`gmake rollback` says a build never appears in the history.** The config repos begin at the seed. A build that last ran in prod before the move is in the GitOps repo's history, not theirs. Set the tag by hand in a PR in the config repo.

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

**A new cluster or a stamped repo breaks a service's CI.** Each service repo's `ci.yaml` names its config repository and lists the manifest files to update. Neither comes from the registry. After stamping, or after adding a cluster, edit those lines in each service repo. `scripts/new-service.sh` prints the exact lines for a new service.

**A stale `lfi-eks` context remains after a failed destroy.** `kubectl config delete-context lfi-eks`. Phase 20.3's precondition check counts this context, so a stale one blocks the cutover until it is removed.

**`gh` creates the repository on the wrong host.** The `gh` default host on this machine may not be github.com. Every `gh` command that runs outside a repository directory in this guide is written with `GH_HOST=github.com`; keep that if you run your own.

## Appendix J: Glossary

**Adoption.** A new ArgoCD Application taking over resources that an earlier Application of the same name deployed, without recreating them. It works because ArgoCD tracks ownership by a label or annotation containing the Application's name.

**Add-on.** Third-party software installed from a Helm chart at a pinned version, enabled per cluster by the presence of `addons/<cluster>/<name>/`. Distinct from a service, which is your code.

**AppProject.** An ArgoCD resource that limits what the Applications in it may do: which repositories they may read, which clusters and namespaces they may write to, and which kinds of resource they may create. The `teams` project is where every team-owned service lives.

**ApplicationSet.** An ArgoCD resource that is a template plus one or more generators. The controller creates one Application per set of values a generator produces.

**Component (Kustomize).** A bundle of patches an environment opts into with `components:`. Here, `replicas-1`, `canary-manual-gate` and `storage-gp3`, in the templates repository, referenced by URL and pinned to a tag.

**Config repository.** A service's own repository of Kubernetes manifests, with a directory per cluster and environment. Owned by the team. The GitOps repo points at it through a subscription.

**Contract check.** `scripts/check-contract.sh`. Compares the repository's registry, subscriptions and generated files to each other, and with `--online` checks that every config repository can be reached. Fails when they disagree.

**Dual write.** The migration step in which a service's CI writes its dev tag to both the old and the new location, so either can be switched to without a gap. Followed by writing to the new one only.

**Finalizer.** A marker on a Kubernetes object that must be cleared before the object is deleted. `resources-finalizer.argocd.argoproj.io` makes deleting an Application delete everything it deployed.

**Git directories generator.** An ApplicationSet generator that yields one set of values per matching directory in a Git repository. Used for datastores.

**Git files generator.** An ApplicationSet generator that yields one set of values per matching file, taking the values from the file's contents. Used for subscriptions, environments and add-ons.

**Matrix generator.** An ApplicationSet generator that combines two others, yielding every pairing. The second may use values from the first.

**Merge generator.** An ApplicationSet generator that combines the sets of several generators by a key, with later generators' values overriding earlier ones'. Here, a subscription with a platform override on top.

**Prefix delegation.** A VPC CNI mode in which each network interface slot holds a `/28` prefix of 16 addresses instead of one, raising the number of pods a node can run.

**Registry.** `platform/registry.yaml`. The file that names the project, its owner and its clusters.

**Remote reference.** A Kustomize resource or component named by a Git URL, with a path after `//` and a version after `?ref=`.

**Scaffold.** A starting point in the templates repository, copied once into a new config repository by `scripts/new-service.sh`.

**Scaffolder.** `scripts/new-service.sh`, run as `gmake add-service`. Creates a service's subscriptions and its config repository.

**Stamp.** `scripts/stamp.sh`. Relabels a copy of the GitOps repository as a new project.

**Subscription.** `platform/subscriptions/<cluster>/<service>.yaml`. A statement that a service exists on a cluster and where its config repository is.

**Template repository.** Two meanings. A GitHub setting that lets anyone create a new repository with the same files and no history. And `lfi-service-templates`, the repository of components and scaffolds.

---

## Where to go next

**Guide 5: observability.** Prometheus and Grafana as add-ons, instrumented services, then tracing and logs, built on exactly the layer this guide added.

**The marketplace project.** A separate workspace, `project-marketplace`, stamped from this template.

**Service CI from the registry.** The last place that still hard-codes a cluster list is each service repo's `ci.yaml`. A reusable workflow in one repository, called by every service, would remove that.

**Config repos as pull-request-only.** The platform could require every config repo to protect prod with a code owner review, and check it. This guide leaves that to each team on purpose.
