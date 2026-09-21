# Two Environments, Gated Releases, and Canary: A Build Guide

**Goal:** Split the single-environment platform into `dev` and `prod`, make dev deploy continuously while prod changes only through a reviewed weekly release, and make each prod release reach half the fleet and wait for your judgment before completing.

**Relationship to the parent guide:** This continues `docs/1-local-full-infra-guide.md`, which built Sections 1 through 9. Numbering resumes at Section 10 and appendix lettering at E. Every task assumes you finished Section 9, so `gmake up` currently gives you a working single-environment platform with Terraform state in S3.

**Tech stack added:** Argo Rollouts (chart 2.43.1, controller v1.10.0), Kustomize overlays, GitHub CODEOWNERS and branch protection.

**What you already have:** one namespace `platform`, three ArgoCD child Applications, image tags in `kubernetes/<service>/kustomization.yaml` rewritten by CI in the two service repos.

---

## How to Use This Guide

Same Sections, Phases, Tasks structure as the parent guide. Every task has four parts:

- **Goal** is the concrete state that exists when the task is done. If you cannot see that state, the task is not finished.
- **Why** is the reason it is worth doing, usually by naming what breaks without it.
- The **commands or file contents** to write.
- **Validate** is the exact command and the output you should see. Tick the box when Validate passes, not when you have typed the code.

**One difference from the parent guide worth knowing.** That guide built new things, so a broken step usually meant something did not exist yet. This guide *changes* things that currently work, which means a mistake can leave you with a platform that looks healthy and is quietly wrong. Three specific ways that happens, all flagged where they occur:

- Kustomize's `replicas:` field silently does nothing to a Rollout. No error, no warning, wrong replica count.
- A root Application without `recurse` finds zero children and reports Synced and Healthy having deployed nothing.
- The promote jobs in your service repos write to a path that Section 10 moves. CI keeps passing and dev quietly stops receiving builds.

The Validate blocks in Tasks 10.2.6, 10.4.2, and 10.4.5 exist specifically to catch those three.

**Time.** Roughly 4 to 5 hours. Section 12 is about half of that, and most of it is deliberately breaking things to see what a bad release looks like, which is the point rather than overhead.

**Where you can stop.** Section 10 alone is a coherent outcome: two real environments. Section 11 adds the release process. Section 12 adds the canary. Section 13 is scoped but deliberately unbuilt.

**Where the tracker lives.** Not here. `tracker_2_multi_env.md` at the workspace root, beside the parent guide's `tracker_1_local_infra.md`. Note that the workspace is not a Git repository, so ticking a box commits nothing. If you want the trackers versioned, `git init` the workspace after adding the three repo directories to a workspace `.gitignore`, exactly as the parent guide's note on nesting Git repos describes.

**If you get stuck.** Appendix E is a symptom-to-cause table for the failures specific to this work.

---

## What You Will Learn

| Section | The idea it teaches |
|---|---|
| 10 | Why environments belong in directories rather than branches, and what "base plus overlay" actually buys you |
| 11 | The difference between a deploy and a promotion, and how to build a release gate that leaves an audit trail |
| 12 | Progressive delivery, and the much harder skill of judging a canary you cannot see from the edge |
| 13 | Where automated analysis plugs in, and why the obvious way to build its dashboards breaks weekly |

### The one mental model that matters

The parent guide's shift was push to pull. This guide's shift is smaller and easier to miss: **a release is a copy, not a build.**

```
        kubernetes/base/                one definition of each workload
                |
        +-------+-------+
        |               |
   overlays/dev/   overlays/prod/       two sets of differences
        |               |
   platform-dev    platform-prod        two namespaces
        |               |
   every merge      one commit a week
```

When you release to prod, nothing is built, nothing is pushed, and no new artifact comes into existence. The image tag that dev has been running all week is copied from one directory into another. **The thing you release is byte-identical to the thing you already tested**, because it is the same image.

Two consequences, both of which show up in Section 11:

1. **Promotion is a one-line diff.** That is why the release pull request is readable, and why it doubles as your release note.
2. **Rollback is a revert.** Because the previous tag is in Git history rather than reconstructed from a build, undoing a release is the same operation as any other revert.

If you find yourself wanting to rebuild something during a promotion, something has gone wrong in the design.

---

## Table of Contents

- [How to Use This Guide](#how-to-use-this-guide)
- [What You Will Learn](#what-you-will-learn)
- [Decisions Locked](#decisions-locked)
- [What Changes and What Does Not](#what-changes-and-what-does-not)
- [Directory Layout After This Guide](#directory-layout-after-this-guide)
- [Resource Budget](#resource-budget)
- [Progress](#progress)
- [Section 10: Two Environments](#section-10-two-environments)
- [Section 11: The Weekly Release](#section-11-the-weekly-release)
- [Section 12: Canary With a Human in the Loop](#section-12-canary-with-a-human-in-the-loop)
- [Section 13: Observability and Automated Analysis](#section-13-observability-and-automated-analysis)
- [Appendix E: Troubleshooting](#appendix-e-troubleshooting)
- [Appendix F: Command Cheat Sheet Additions](#appendix-f-command-cheat-sheet-additions)
- [Where to Go Next](#where-to-go-next)

---

## Decisions Locked

| # | Decision | Choice | Why it matters |
|---|---|---|---|
| 1 | Environment separation | **Directory overlays on one branch** | Dev and prod differ in four fields in the same file. On separate branches every merge conflicts on all four, forever. See the note below. |
| 2 | Cluster topology | **Two namespaces, one cluster** | `platform-dev` and `platform-prod`. Enough isolation to exercise the mechanics at half the resource cost of two clusters and with one kube context to keep straight. |
| 3 | Database | **One Postgres per environment** | A shared instance gives dev and prod shared fate. A dev migration that locks a table would take prod with it, which is the opposite of the point. |
| 4 | Credentials | **Separate password per environment** | A dev credential must not open prod. Costs two extra keys in `.env`. |
| 5 | Sizing | **Dev at 1 replica, prod at 2** | Saves memory, and gives the overlays something meaningful to differ on. Also why dev does not canary: one replica cannot express 50%. |
| 6 | Ingress | **Host-based: `dev.localhost` and `prod.localhost`** | The base ingress has no host, so two copies would both match any Host header and collide. Reuses the pattern already working for `argocd.localhost`. |
| 7 | Release trigger | **A pull request that copies dev's tags into prod** | The gate is the merge. The diff is the release note. |
| 8 | Prod sync policy | **Auto-sync stays ON** | See the note below. A manual UI sync would break the property that makes GitOps worth the ceremony. |
| 9 | Canary mechanism | **Argo Rollouts, both services** | `pause: {}` is a first-class manual gate, `abort` is instant, and automated analysis slots in later without restructuring. See the note below for the two rejected alternatives. |
| 10 | Promote order | **service-2 before service-1** | Convention, not enforcement. service-1 calls service-2, so promoting the dependency first means each judgment covers one change. |
| 11 | Node memory | **Optional honest per-node caps** | Both k3d nodes currently report the full VM memory while sharing one VM, so the scheduler believes it has double what exists. |
| 12 | Image tag scheme | **Weekly build ordinals, `26W38B1`, plus a SHA tag on the same image** | A 40-character SHA is unreadable in a release PR and impossible to say out loud. The second tag and the OCI labels keep the commit recoverable, which is the property the SHA was there for. |
| 13 | Vetoing a bad build | **A deny list in the GitOps repo** | Green CI is not the same as "works". A veto needs an author, a timestamp, a diff, and a revert like every other decision here. |

### Note on decision 1

The four fields that differ per environment are namespace, image tag, replica count, and ingress host. With overlays they live in separate files that never interact, and promotion is a one-line edit to one of them.

With `dev` and `prod` branches they live at the *same path* on divergent branches. Every merge conflicts on all four lines, every week, and the resolution is a manual three-way judgment each time: take prod's replicas, prod's host, prod's namespace, dev's tag. Get it wrong once in a hurry and a dev hostname is now in prod. Adding a third `main` branch makes it worse, because main would have to hold some replica count and no value is correct for both environments.

### Note on decision 8

Leaving auto-sync on for prod looks like it removes the gate. It does not. The gate moved to the merge.

```
manual UI sync                        gated commit + auto-sync
------------------------------        ------------------------------
prod runs something Git               Git always describes prod
  says it does not
no record of who released what        author, timestamp, diff, revert
git revert does nothing               git revert is the rollback
```

The gate has to be somewhere that leaves a trace. A button does not.

### Note on decision 9

Two alternatives were considered and rejected, and it is worth knowing why so you do not reach for either later.

**A dedicated `service-1-canary` Deployment.** Promotion stops being atomic. The commit that points stable at the new tag makes stable roll its pods while the canary is scaled away, so the one pod you have evidence about is destroyed and recreated at the exact moment you remove your fallback, with a capacity dip in between. Rollouts instead scales the existing canary ReplicaSet up, so the validated pod keeps serving without interruption. The Deployment approach also leaves a permanent mostly-empty object in every diff, duplicates the pod spec, and puts the replica arithmetic in your hands.

**`kubectl rollout pause` on a plain Deployment.** Genuinely zero new resources, and the closest thing to a canary that native Kubernetes offers. Rejected because `paused` lives in `spec`, so ArgoCD `selfHeal` reverts it within seconds. The workarounds are more awkward than the controller they avoid. Rollouts keeps pause state in `status`, which is exactly why it does not have this problem.

**Postgres never gets a canary** for a different reason entirely: two pods of a single-writer database are two divergent databases, not a weighted rollout.

---

## What Changes and What Does Not

Worth reading before you start, because the amount of *unchanged* material is the point of the design.

**Unchanged.** Every pod spec. Every probe. Every resource request. The two-module Terraform split. The `.env` to `TF_VAR_` bridge. The app-of-apps pattern. Postgres as a StatefulSet with `prune: false`. The `ignoreDifferences` on `volumeClaimTemplates`. The application code in both service repos.

**Changed.**

| Thing | From | To |
|---|---|---|
| Manifest layout | `kubernetes/<svc>/` | `kubernetes/base/<svc>/` plus two overlays |
| Workload kind | `Deployment` | `Rollout` |
| Namespace | one, `platform` | two, `platform-dev` and `platform-prod` |
| ArgoCD child apps | 3 | 6 |
| Root app source | `argocd/apps` flat | `argocd/apps` with `recurse: true` |
| Terraform namespace/secret | one each | `for_each` over environments |
| `.env` password keys | `POSTGRES_PASSWORD` | `POSTGRES_PASSWORD_DEV` and `_PROD` |
| Service repo CI target path | `kubernetes/<svc>/` | `kubernetes/overlays/dev/<svc>/` |

---

## Directory Layout After This Guide

The workspace, with both guides now under `docs/`:

```text
$PLATFORM_HOME/                             # NOT a Git repo. Guides and trackers live here.
├── docs/
│   ├── 1-local-full-infra-guide.md               # Sections 1 to 9
│   └── 2-multi-env-infra-guide.md           # this guide, Sections 10 to 13
├── docker-compose.dev.yaml
├── diagrams/
├── lfi-service-1-app/
├── lfi-service-2-app/
└── lfi-infrastructure-gitops/              # everything below changes in this guide
```

And the GitOps repo:

```text
lfi-infrastructure-gitops/
├── .env                                    # GITIGNORED. Now two passwords.
├── .env.example
├── .github/
│   └── CODEOWNERS                          # the prod gate
├── Makefile                                # + release, tag-release, canary-*, urls
├── scripts/
│   └── release.sh                          # opens the weekly prod release PR
│
├── terraform/
│   ├── 01-cluster/
│   │   ├── main.tf
│   │   └── k3d-config.yaml                 # + optional node memory caps
│   └── 02-platform/
│       ├── main.tf                         # for_each namespaces + secrets, argo-rollouts
│       ├── variables.tf                    # environments, per-env passwords
│       ├── values/argocd.yaml
│       └── bootstrap/root-app.yaml.tftpl   # + directory.recurse
│
├── kubernetes/
│   ├── base/                               # one definition of each workload
│   │   ├── postgres/
│   │   │   ├── kustomization.yaml
│   │   │   ├── service.yaml
│   │   │   └── statefulset.yaml
│   │   ├── service-1/
│   │   │   ├── kustomization.yaml
│   │   │   ├── rollout.yaml                # was deployment.yaml
│   │   │   ├── service.yaml
│   │   │   └── ingress.yaml
│   │   └── service-2/
│   │       ├── kustomization.yaml
│   │       ├── rollout.yaml
│   │       └── service.yaml
│   └── overlays/                           # only the differences
│       ├── dev/
│       │   ├── postgres/kustomization.yaml
│       │   ├── service-1/kustomization.yaml
│       │   └── service-2/kustomization.yaml
│       └── prod/
│           ├── postgres/kustomization.yaml
│           ├── service-1/kustomization.yaml
│           └── service-2/kustomization.yaml
│
└── argocd/
    └── apps/
        ├── dev/
        │   ├── postgres.yaml
        │   ├── service-1.yaml
        │   └── service-2.yaml
        └── prod/
            ├── postgres.yaml
            ├── service-1.yaml
            └── service-2.yaml
```

---

## Resource Budget

Requests, not limits.

| | CPU | Memory |
|---|---|---|
| dev (1 replica each) | 175m | 416Mi |
| prod (2 replicas each) | 250m | 576Mi |
| prod canary surge, both services | +75m | +160Mi |
| ArgoCD | ~250m | ~600Mi |
| Argo Rollouts | ~100m | ~128Mi |
| **Total** | **~850m** | **~1.9Gi** |
| Available (Docker Desktop VM) | 8 CPU | ~7.9Gi |

**On the "1.5 to 2.5 GB budget" in your code comments.** Nothing enforces it. It is a design note. The real ceiling is the Docker Desktop VM, currently `"MemoryMiB": 8092` in `~/Library/Group Containers/group.com.docker/settings-store.json`, adjustable under Settings, Resources, Memory. The full stack including Section 13's Prometheus fits without touching it.

**A stale comment to be aware of.** Several comments in the repo reference OrbStack, but the active Docker context on this machine is `desktop-linux`. Check with `docker context ls`. It does not affect anything in this guide, but it means the OrbStack instructions in the parent guide's Task 1.1.1 no longer describe what is running.

---

## Progress

Same convention as the parent guide: this file is not a tracker and carries no
status of its own.

**Tick your progress in [`tracker_2_multi_env.md`](../tracker_2_multi_env.md)**,
at the workspace root beside the parent guide's `tracker_1_local_infra.md`. That file holds
the phase summary, a checkbox per task, the milestone table, and a Notes and
Deviations log.

---

## Section 10: Two Environments

**Objective:** Two namespaces fed by two overlays over one base, with separate Postgres instances and separate credentials, reachable at distinct hostnames, and both services running as Rollouts that currently behave exactly like Deployments.

### Phase 10.1: Preparation and teardown

#### Task 10.1.1: Confirm the starting state and record the current image tags

**Goal:** The two current image tags written down somewhere outside the repo, and a baseline you have confirmed is healthy.

**Why:** Two reasons, and the second is the important one. The tags are needed in Task 10.2.4, and after teardown they are only recoverable from Git history. More importantly, every Validate block later in this guide compares against a working baseline. If something is already broken now, you will spend Section 10 debugging a Section 6 problem.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"

kubectl --context k3d-platform -n platform get all
kubectl --context k3d-platform -n argocd get applications
grep -n 'newTag' kubernetes/*/kustomization.yaml
```

**Validate:** three healthy workloads in `platform`, four Applications in `argocd` (`root` plus three children), and two 40-character SHA tags printed. If any Application is not `Synced` and `Healthy`, fix that before continuing.

#### Task 10.1.2: Install the Argo Rollouts kubectl plugin

**Goal:** `kubectl argo rollouts` runs and prints a version.

**Why:** Section 12 promotes and aborts rollouts through this plugin. Installing it now means the toolchain is complete before you are mid-release with a paused canary and no way to advance it.

```bash
brew install argoproj/tap/kubectl-argo-rollouts
```

**Validate:**

```bash
kubectl argo rollouts version
```

Expected: a version string. `unknown command "argo"` means the binary is not on your `PATH` under the name `kubectl-argo-rollouts`, which is how kubectl discovers plugins.

The tap currently ships `v1.9.0`, one minor behind the `v1.10.0` controller this guide pins in Task 10.1.3. That gap is expected and harmless: the plugin is a thin client that reads the Rollout object and patches it, and `get`, `promote`, and `abort` behave identically across the two. Chase exact parity only if you need a field added in 1.10, in which case take the binary from the `v1.10.0` GitHub release rather than the tap.

#### Task 10.1.3: Verify the argo-rollouts chart version

**Goal:** A chart version you have confirmed exists, ready to pin in Terraform.

**Why:** Same discipline as the parent guide's Task 1.1.3. A yanked or renamed version fails during `terraform apply`, halfway through configuring a cluster, which is a considerably worse place to discover it than here.

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
helm search repo argo/argo-rollouts --versions | head -5
```

**Validate:** `2.43.1` appears with `v1.10.0` in the APP VERSION column. If not, take the newest `2.x` shown and use that number everywhere this guide says `2.43.1`. Keep the controller version reasonably close to your plugin version from Task 10.1.2, for the same reason the parent guide keeps the ArgoCD CLI and server in step. One minor apart is close enough, as the note at the end of Task 10.1.2 explains.

#### Task 10.1.4: Tear down the cluster

**Goal:** No `platform` cluster, and Terraform state that honestly records an empty world.

**Why:** Task 10.3.1 renames the namespace from `platform` to `platform-dev`. Terraform treats a rename as replace rather than update, so the namespace and everything ArgoCD created inside it goes away regardless of what you do. State surgery could preserve the PVC but not the namespace it lived in, so it buys nothing. **This destroys the database.**

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake destroy
```

**Validate:**

```bash
k3d cluster list
```

Expected: `platform` is absent. Your Terraform state is in S3 as of Section 9, so it correctly records an empty world rather than a stale cluster.

### Phase 10.2: Restructure the manifests

#### Task 10.2.1: Move the three service directories into base/

**Goal:** Three service directories under `kubernetes/base/`, and six empty overlay directories waiting.

**Why:** Use `git mv` rather than `mv` so history follows the files. When you review this change later, or bisect a problem to it, a diff showing three renames is legible and a diff showing three deletions plus three additions is not.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"

mkdir -p kubernetes/base
git mv kubernetes/service-1 kubernetes/base/service-1
git mv kubernetes/service-2 kubernetes/base/service-2
git mv kubernetes/postgres  kubernetes/base/postgres

mkdir -p kubernetes/overlays/dev/{service-1,service-2,postgres}
mkdir -p kubernetes/overlays/prod/{service-1,service-2,postgres}
```

**Validate:**

```bash
git status --short
ls kubernetes/base kubernetes/overlays/dev kubernetes/overlays/prod
```

Expected: `git status` shows three renames (lines starting `R`), not deletions plus additions. If you see `D` and `??` pairs, you used `mv`; `git add -A` will usually let Git detect the rename anyway.

#### Task 10.2.2: Strip environment-specific fields from the base kustomizations

**Goal:** Three base kustomizations that name no namespace and pin no image tag.

**Why:** These two fields are the entire reason a base and overlay split exists. A base that names a namespace can only ever produce one environment. A base that pins an image tag means dev and prod can never run different versions, which is precisely what a release is. Everything else in the base is genuinely shared and stays.

`kubernetes/base/service-1/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# No `namespace:` and no `images:` block here. Both are environment-specific
# and live in the overlays. This is the whole reason a base exists: it holds
# what is true everywhere, and nothing else.
resources:
  - rollout.yaml
  - service.yaml
  - ingress.yaml
# Unchanged. Labels on the objects and the pod template, never on the
# selector, because selectors are immutable once created.
labels:
  - pairs:
      app.kubernetes.io/part-of: local-platform
    includeTemplates: true
```

`kubernetes/base/service-2/kustomization.yaml`: identical, but `resources` lists only `rollout.yaml` and `service.yaml`.

`kubernetes/base/postgres/kustomization.yaml`: remove only the `namespace:` line. Postgres had no `images:` block, and it keeps `service.yaml` and `statefulset.yaml`.

**Validate:**

```bash
grep -rn 'namespace:\|newTag\|newName' kubernetes/base/
```

Expected: no output at all. Any hit means an environment-specific field is still in the base, and both environments will inherit it.

#### Task 10.2.3: Convert both services from Deployment to Rollout

**Goal:** Both services defined as Rollouts with a single-step strategy, behaving identically to the Deployments they replace.

**Why:** Doing this now rather than in Section 12 removes a risk entirely. Converting a *running* Deployment means a window where two controllers manage identically labelled pods. The cluster is already destroyed, so the Rollout is simply what gets created first and no Deployment ever exists. A Rollout whose only canary step is `setWeight: 100` behaves exactly like a Deployment's rolling update, so nothing observable changes until Section 12 replaces those steps.

```bash
git mv kubernetes/base/service-1/deployment.yaml kubernetes/base/service-1/rollout.yaml
git mv kubernetes/base/service-2/deployment.yaml kubernetes/base/service-2/rollout.yaml
```

Then in each file, change the top and add the strategy. For `service-1/rollout.yaml`:

```yaml
# A Rollout is Argo Rollouts' replacement for a Deployment. Everything below
# `template:` is unchanged from the Deployment it replaces.
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: service-1
  labels:
    app: service-1
spec:
  # The prod default. The dev overlay patches this down to 1.
  replicas: 2
  # If a new version has not become healthy within this window, the rollout
  # aborts itself rather than sitting paused forever waiting for a human who
  # is not coming.
  progressDeadlineSeconds: 600
  selector:
    matchLabels:
      app: service-1
  strategy:
    canary:
      # One step, straight to 100%, so this behaves exactly like a Deployment's
      # rolling update. The prod overlay replaces these steps in Section 12.
      # Keeping the shape here means that change is three lines rather than a
      # restructure.
      steps:
        - setWeight: 100
  template:
    # ... unchanged from deployment.yaml, every line ...
```

Do the same to `service-2/rollout.yaml`, substituting the name.

**Why not omit `strategy` entirely.** A Rollout with no strategy is invalid. `canary: {}` would also roll straight through, but writing the explicit single step makes the Section 12 diff obvious: you are replacing a list of one with a list of three.

**Validate:**

```bash
grep -c 'kind: Rollout' kubernetes/base/service-1/rollout.yaml kubernetes/base/service-2/rollout.yaml
grep -rn 'kind: Deployment' kubernetes/
```

Expected: `1` for each Rollout file, and no `kind: Deployment` anywhere. A leftover Deployment reference in a `resources:` list will fail the build in Task 10.2.6.

#### Task 10.2.4: Write the dev overlay

**Goal:** Three dev kustomizations supplying namespace, full image reference, replica count, and ingress host.

**Why:** This is where every environment difference lives, so it is the file you will return to most. Two of the choices in it are deliberate and easy to get wrong, and both are commented in place: the image reference must be complete rather than split with the base, and the replica count must be a JSON patch rather than kustomize's `replicas:` field.

`kubernetes/overlays/dev/service-1/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Injected into every resource the base produces. One line, and this whole
# overlay lands in a different namespace.
namespace: platform-dev

resources:
  - ../../../base/service-1

# The FULL image reference lives here, newName and newTag together. Splitting
# newName into the base does not work: the overlay's transformer runs against
# already-rewritten output, where the image is no longer the bare name it is
# trying to match.
#
# This newTag field is the only thing service-1's CI ever writes.
images:
  - name: service-1
    newName: ghcr.io/YOUR_GITHUB_USER/service-1
    newTag: 863c56aaa7e25f3a2e42d0b528226573a399e1f4

patches:
  # DO NOT use kustomize's `replicas:` field here. Its built-in transformer
  # only knows Deployment, ReplicaSet, StatefulSet, and ReplicationController.
  # A Rollout is a custom resource, so `replicas:` matches nothing, changes
  # nothing, and reports nothing. You get prod's replica count in dev and no
  # indication anything went wrong. A JSON6902 patch names the group and kind
  # explicitly, so a mismatch is an error rather than a silence.
  - target:
      group: argoproj.io
      version: v1alpha1
      kind: Rollout
      name: service-1
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 1

  # The base Ingress deliberately has no host, so it matches any Host header.
  # Two of those would collide in one cluster, so each environment adds its own.
  #
  # This is a JSON6902 patch rather than a strategic merge patch because
  # Ingress `rules` is a list with no merge key: a strategic merge would
  # replace the entire list instead of adding one field to its first element.
  - target:
      kind: Ingress
      name: service-1
    patch: |-
      - op: add
        path: /spec/rules/0/host
        value: dev.localhost
```

`kubernetes/overlays/dev/service-2/kustomization.yaml`: the same, minus the Ingress patch (service-2 has no Ingress), with `service-2` and its own tag `44365106b8ebc12b6775f18e40d7a8ed3c50ebcb`.

`kubernetes/overlays/dev/postgres/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: platform-dev
resources:
  - ../../../base/postgres
# No patches. Postgres is identical in both environments except for the
# namespace it lands in and the Secret it reads, and Terraform creates that
# Secret per namespace under the same name. That is why the StatefulSet needs
# no environment awareness at all.
```

**Validate:** deferred to Task 10.2.6, which proves all six overlays at once.

#### Task 10.2.5: Write the prod overlay

**Goal:** Three prod kustomizations differing from dev in exactly three ways: namespace, ingress host, and no replica patch.

**Why:** Copying dev and editing is less error-prone than writing from scratch, but it is also exactly the operation that leaves a stray `platform-dev` behind in a file you thought you had finished. The Validate below hunts for that specifically.

**Why prod has no replica patch.** The base declares `replicas: 2`, which is prod's value. Prod inherits it and dev patches down. Patching both would restate a value that is already correct. Note the consequence: changing the base replica count now changes prod silently, so if you ever want them independent, add the patch back.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops/kubernetes/overlays"

for svc in service-1 service-2 postgres; do
  sed -e 's/platform-dev/platform-prod/' \
      -e 's/dev\.localhost/prod.localhost/' \
      "dev/$svc/kustomization.yaml" > "prod/$svc/kustomization.yaml"
done
```

Then hand-edit `prod/service-1/kustomization.yaml` and `prod/service-2/kustomization.yaml` to delete the Rollout replica patch, leaving the Ingress patch in service-1.

**Validate:**

```bash
grep -c 'spec/replicas' prod/service-1/kustomization.yaml || echo "no replica patch, correct"
grep -rn 'platform-dev\|dev.localhost' prod/
```

Expected: the replica patch is gone from both prod service overlays, and no `platform-dev` or `dev.localhost` survives anywhere under `prod/`. That second grep is the one that catches a missed `sed`.

#### Task 10.2.6: Prove all six overlays before ArgoCD sees any of them

**Goal:** Six rendered manifests, each confirmed to carry the right namespace, image, replica count, and host.

**Why:** This is the most valuable Validate in the section. `kustomize build` runs the same transformation ArgoCD will, so every mistake made above becomes visible here, on your terminal, in seconds. The alternative is discovering it as an ambiguous Application status after a cluster bring-up, where a wrong replica count looks like a scheduling problem.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"

for env in dev prod; do
  for svc in service-1 service-2 postgres; do
    echo "=== $env/$svc ==="
    kustomize build "kubernetes/overlays/$env/$svc" \
      | yq '[.kind, .metadata.name, .metadata.namespace, (.spec.replicas // "n/a")] | @csv'
  done
done
```

**Validate:** every line names the right namespace, and specifically:

| overlay | expected replicas |
|---|---|
| `dev/service-1` Rollout | **1** |
| `dev/service-2` Rollout | **1** |
| `prod/service-1` Rollout | **2** |
| `prod/service-2` Rollout | **2** |

If a dev Rollout shows `2`, the replica patch did not apply. That is the silent failure warned about in Task 10.2.4, and it is why this table exists rather than a general "looks right".

Then confirm the hosts and images:

```bash
kustomize build kubernetes/overlays/dev/service-1  | yq 'select(.kind == "Ingress") | .spec.rules[0].host'
kustomize build kubernetes/overlays/prod/service-1 | yq 'select(.kind == "Ingress") | .spec.rules[0].host'
kustomize build kubernetes/overlays/prod/service-1 | yq 'select(.kind == "Rollout") | .spec.template.spec.containers[0].image'
```

Expected: `dev.localhost`, then `prod.localhost`, then a full `ghcr.io/YOUR_GITHUB_USER/service-1:<sha>` reference. A bare `service-1` on that last one means the `images:` block did not match, usually because the base still has one competing with it.

### Phase 10.3: Terraform and the Makefile

#### Task 10.3.1: Two namespaces and two Secrets, with for_each

**Goal:** One resource block each producing `platform-dev` and `platform-prod`, with a `postgres-credentials` Secret in both carrying different passwords.

**Why:** The Secret has the **same name** in both namespaces, which is what lets the base StatefulSet and Rollout reference `postgres-credentials` with no environment awareness whatsoever. Namespace scoping does the work. Terraform creates them rather than ArgoCD because the Secret must exist before anything mounts it, and Terraform runs first.

Replace the single `kubernetes_namespace` and `kubernetes_secret` resources in `terraform/02-platform/main.tf`:

```hcl
locals {
  # Per-environment passwords, assembled from two scalar variables rather than
  # one map variable. A map would be tidier HCL, but passing JSON through
  # TF_VAR_* from a Makefile requires quoting that is easy to get wrong and
  # hard to debug. Two plain strings keep the bridge in Task 10.3.4 readable.
  env_postgres_passwords = {
    dev  = var.postgres_password_dev
    prod = var.postgres_password_prod
  }
}

resource "kubernetes_namespace" "env" {
  for_each = toset(var.environments)

  metadata {
    name = "${var.namespace_prefix}-${each.key}"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      # Makes `kubectl get ns -l platform.local/environment=prod` work, which
      # is more useful than it sounds once there are two of everything.
      "platform.local/environment" = each.key
    }
  }
}

resource "kubernetes_secret" "postgres" {
  for_each = toset(var.environments)

  metadata {
    name      = "postgres-credentials"
    namespace = kubernetes_namespace.env[each.key].metadata[0].name
  }

  data = {
    POSTGRES_USER     = var.postgres_user
    POSTGRES_PASSWORD = local.env_postgres_passwords[each.key]
    POSTGRES_DB       = var.postgres_db
  }

  type = "Opaque"
}
```

In `terraform/02-platform/variables.tf`, delete `namespace` and `postgres_password`, and add:

```hcl
variable "environments" {
  type        = list(string)
  description = "Environment names. Each gets a namespace and its own Secret."
  default     = ["dev", "prod"]
}

variable "namespace_prefix" {
  type        = string
  description = "Namespaces are <prefix>-<environment>, so platform-dev and platform-prod."
  default     = "platform"
}

variable "postgres_password_dev" {
  type        = string
  description = "Supplied from .env via TF_VAR_postgres_password_dev."
  sensitive   = true
}

variable "postgres_password_prod" {
  type        = string
  description = "Supplied from .env via TF_VAR_postgres_password_prod. Must differ from dev."
  sensitive   = true
}
```

**Validate:** deferred to Task 10.4.2. A `terraform plan` here would fail on the unset variables, which the Makefile supplies.

#### Task 10.3.2: Add the Argo Rollouts controller

**Goal:** The controller running in its own namespace, with the Rollout CRD registered.

**Why:** Without it, ArgoCD will happily sync a Rollout object and then report it `Unknown` forever, because nothing in the cluster knows what a Rollout is or creates pods for it. `wait = true` matters for a second reason: it guarantees the CRD is registered before the root Application tries to sync something that references it, which is the same "no matches for kind" race the existing `root_application` null_resource already guards against for ArgoCD.

Append to `terraform/02-platform/main.tf`:

```hcl
resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  version          = var.argo_rollouts_chart_version
  namespace        = "argo-rollouts"
  create_namespace = true

  wait    = true
  timeout = 300
}
```

And in `variables.tf`:

```hcl
variable "argo_rollouts_chart_version" {
  type        = string
  description = "Pinned argo-rollouts chart version. Verified in Task 10.1.3."
  # 2.43.1 deploys controller v1.10.0. Keep close to your kubectl plugin version.
  default     = "2.43.1"
}
```

**Validate:** deferred to Task 10.4.2.

#### Task 10.3.3: Teach the root Application to recurse

**Goal:** A root Application that discovers Applications inside `argocd/apps/dev/` and `argocd/apps/prod/`.

**Why:** ArgoCD reads only the files directly in a directory unless told otherwise. Without this one setting, the root Application finds zero children and reports `Synced` and `Healthy` having deployed absolutely nothing. That is the worst failure mode in this guide: green status, empty cluster, no error message anywhere.

In `terraform/02-platform/bootstrap/root-app.yaml.tftpl`, under `source:`:

```yaml
    path: argocd/apps
    directory:
      # argocd/apps now contains dev/ and prod/ subdirectories rather than
      # Application manifests directly. Without recurse, ArgoCD reads only the
      # top level, finds nothing, and reports Synced/Healthy having deployed
      # nothing at all.
      recurse: true
```

**Validate:**

```bash
yq '.spec.source.directory.recurse' terraform/02-platform/bootstrap/root-app.yaml.tftpl
```

Expected: `true`.

#### Task 10.3.4: Per-environment passwords in .env and the guard

**Goal:** Two distinct passwords flowing from `.env` through `TF_VAR_*` into two Secrets, with `check-env` refusing to proceed if they are identical.

**Why:** A dev credential must not open prod. The identical-password check is the interesting half: it catches the shortcut that the old single-password design made structurally invisible, which is setting both to the same value and telling yourself you will fix it later.

Update `.env.example`:

```bash
# Postgres credentials. Terraform creates one "postgres-credentials" Secret per
# environment namespace, each with its own password.
#
# The user and database name are shared; only the password differs. A dev
# credential must not open prod.
POSTGRES_USER=platform
POSTGRES_DB=platform
POSTGRES_PASSWORD_DEV=change-me
POSTGRES_PASSWORD_PROD=change-me

# The GitOps repo ArgoCD watches. Public HTTPS URL.
GITOPS_REPO_URL=https://github.com/YOUR_GITHUB_USER/lfi-infrastructure-gitops.git

# Your GitHub owner, used to build GHCR image references.
GH_OWNER=YOUR_GITHUB_USER
```

Then in the `Makefile`, the `check-env` required-keys loop:

```make
	for var in POSTGRES_USER POSTGRES_DB GITOPS_REPO_URL \
	           POSTGRES_PASSWORD_DEV POSTGRES_PASSWORD_PROD; do
	  if [[ -z "$${!var:-}" ]]; then
	    echo "ERROR: $$var is unset or empty in .env" >&2
	    exit 1
	  fi
	done
```

And the placeholder rejection, now covering both:

```make
	for var in POSTGRES_PASSWORD_DEV POSTGRES_PASSWORD_PROD; do
	  if [[ "$${!var}" == "change-me" ]]; then
	    echo "ERROR: $$var is still the placeholder value." >&2
	    exit 1
	  fi
	done
	if [[ "$$POSTGRES_PASSWORD_DEV" == "$$POSTGRES_PASSWORD_PROD" ]]; then
	  echo "ERROR: dev and prod passwords are identical, which defeats the point." >&2
	  exit 1
	fi
```

And in `platform-up`, replace the single password export:

```make
	export TF_VAR_postgres_password_dev="$$POSTGRES_PASSWORD_DEV"
	export TF_VAR_postgres_password_prod="$$POSTGRES_PASSWORD_PROD"
```

Now update your real `.env` with two distinct passwords.

**Validate:**

```bash
gmake check-env
```

Expected: `OK: .env looks complete.` Then prove the guard fires, because an untested guard is not a guard: temporarily set both passwords the same and re-run.

```bash
gmake check-env    # expect the "identical" error and exit 1
```

Restore two distinct values afterwards.

#### Task 10.3.5: (Optional) Honest node memory limits

**Goal:** Node capacity that reflects physical memory rather than double it.

**Why:** Both k3d nodes are containers in one Docker Desktop VM, and each reports the whole VM's memory as its own capacity. The scheduler therefore believes it has roughly 15 GiB to allocate when there are about 8. It will schedule past physical memory, and the symptom is OOM kills scattered across unrelated pods rather than pods sitting in `Pending`. The second is trivial to diagnose; the first sends you reading application logs for a scheduling problem.

Skip this if you want the shortest path to a working platform. Nothing downstream depends on it.

```bash
kubectl --context k3d-platform get nodes \
  -o custom-columns='NODE:.metadata.name,ALLOCATABLE:.status.allocatable.memory'
```

In `terraform/01-cluster/k3d-config.yaml`, add:

```yaml
options:
  k3d:
    wait: true
    timeout: "180s"
  # NEW. Caps each node container so the scheduler's view matches reality.
  # 3g x 2 nodes leaves room for the k3d load balancer, containerd, and the
  # VM's own kernel.
  #
  # k3d implements this with a synthetic /proc/meminfo and flags the feature
  # experimental. If the cluster misbehaves after this change, delete these two
  # lines and rebuild; nothing else depends on them.
  runtime:
    serversMemory: 3g
    agentsMemory: 3g
  kubeconfig:
    updateDefaultKubeconfig: true
    switchCurrentContext: true
```

**This forces a cluster rebuild.** `null_resource.cluster` triggers on `filesha256` of this file, deliberately, because port mappings and node memory are both fixed at creation time. You are rebuilding anyway, so do this before Task 10.4.2 and it costs nothing.

**Validate:** after `gmake up` in Task 10.4.2, re-run the node capacity command above. Expected: roughly 3 GiB per node rather than 7.65.

### Phase 10.4: Bring up and verify

#### Task 10.4.1: Six ArgoCD child Applications

**Goal:** Six Application manifests with six distinct names, each pointing at one overlay and one namespace.

**Why:** Application names must be unique within the `argocd` namespace, so the environment has to go in the name. This is the one identifier the two environments cannot share. If two Applications end up with the same name, ArgoCD silently manages one and ignores the other, and the ignored environment simply never updates.

`argocd/apps/dev/service-1.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  # Names must be unique within the argocd namespace, so the environment goes
  # in the name. This is the one place the two environments cannot share an
  # identifier.
  name: service-1-dev
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_GITHUB_USER/lfi-infrastructure-gitops.git
    targetRevision: HEAD
    # The overlay, not the base. Pointing an Application at a base would
    # deploy something belonging to no environment.
    path: kubernetes/overlays/dev/service-1
  destination:
    server: https://kubernetes.default.svc
    # Redundant with the overlay's `namespace:` field, which wins for any
    # resource that has one. Kept because ArgoCD uses it for resources that
    # arrive without a namespace, and because it documents intent at the
    # Application level where you are most likely to read it.
    namespace: platform-dev
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
```

`argocd/apps/dev/service-2.yaml`: same shape, `service-2-dev`.

`argocd/apps/dev/postgres.yaml`: same shape, `postgres-dev`, plus the two settings from the original that must survive:

```yaml
  syncPolicy:
    automated:
      # FALSE for the data layer, in both environments. An accidental deletion
      # in Git must not take a database with it.
      prune: false
      selfHeal: true
  ignoreDifferences:
    # volumeClaimTemplates are immutable after creation and the API server
    # returns them with defaulted fields, which ArgoCD reads as permanent
    # drift. Without this the app sits OutOfSync forever and you learn to
    # ignore the status, which defeats having one.
    - group: apps
      kind: StatefulSet
      jsonPointers:
        - /spec/volumeClaimTemplates
```

Then the prod set, identical but for `-prod` names, `overlays/prod/` paths, and `platform-prod` destinations. Finally:

```bash
git rm argocd/apps/service-1.yaml argocd/apps/service-2.yaml argocd/apps/postgres.yaml
```

**Validate:**

```bash
ls argocd/apps/dev argocd/apps/prod
yq '.metadata.name' argocd/apps/*/*.yaml | sort | uniq -d
grep -c 'prune: false' argocd/apps/dev/postgres.yaml argocd/apps/prod/postgres.yaml
```

Expected: three files per directory, **no output** from the `uniq -d` (no duplicate names), and `1` for each Postgres app.

#### Task 10.4.2: Bring the platform up

**Goal:** Seven Applications, all `Synced` and `Healthy`, across two namespaces.

**Why:** Push before you run `gmake up`. ArgoCD reads from GitHub, not from your working tree, so an unpushed overlay does not exist as far as the cluster is concerned. The resulting `app path does not exist` error sends you hunting for a typo in a file that is perfectly correct.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git add -A && git commit -m "feat(platform): split into dev and prod environments"
git push
gmake up
```

**Validate:**

```bash
kubectl --context k3d-platform get ns -l platform.local/environment
kubectl --context k3d-platform -n argocd get applications
```

Expected: two namespaces, and seven Applications (`root` plus six children) all `Synced` and `Healthy`.

Two failures to distinguish here. **Six Applications instead of seven**, or a root app that is Healthy with no children, means `recurse` is missing (Task 10.3.3). **`Unknown` health on a Rollout** means the argo-rollouts controller is not running: check `kubectl -n argo-rollouts get pods`.

#### Task 10.4.3: Verify the two environments are genuinely independent

**Goal:** Four independence properties, each proved by its own command.

**Why:** This is the payoff for the whole section, and proving the properties separately is deliberate. A single end-to-end smoke test that passes tells you little; four separate proofs mean that when one fails, you know which property broke and therefore which task to revisit.

```bash
# 1. Distinct hostnames, same port, different environments answering.
curl -s -H 'Host: dev.localhost'  http://localhost:8080/healthz
curl -s -H 'Host: prod.localhost' http://localhost:8080/healthz

# 2. Different replica counts, proving the overlay patch landed.
kubectl --context k3d-platform get rollouts -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,DESIRED:.spec.replicas'

# 3. Different database passwords, proving the for_each Secret worked.
for ns in platform-dev platform-prod; do
  printf '%-16s ' "$ns"
  kubectl --context k3d-platform -n "$ns" get secret postgres-credentials \
    -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d | shasum | cut -c1-12
done

# 4. Two separate databases, not one shared one.
kubectl --context k3d-platform get pvc -A | grep postgres
```

**Validate:** both curls answer. Dev Rollouts show `1` and prod show `2`. The two password hashes differ. Two distinct PVCs exist, one per namespace.

Comparing password hashes rather than the passwords themselves keeps secrets off your terminal and out of your shell history while still proving they differ.

#### Task 10.4.4: Write and test the build tag calculator

**Goal:** `ci/next-build-tag.sh` in `lfi-service-1-app`, with a passing test script.

**Why:** Decision 12. From here on an image is tagged `26W38B1`, meaning the first build of ISO week 38 of 2026, rather than by a 40-character commit SHA. A SHA is unreadable in a release PR and impossible to say out loud in a handover; a build ordinal is both.

The ordinal is the only part of this with real edge cases: numeric rather than lexical comparison, other weeks' tags, SHA tags, and an empty registry. Buried in a `run:` block the only way to test it is to push and wait four minutes. Taking the tag list on stdin keeps the logic pure and the test instant.

`lfi-service-1-app/ci/next-build-tag.sh`:

```bash
#!/usr/bin/env bash
# Prints the next build tag for the current ISO week, e.g. 26W38B3.
#
# Existing tags arrive on stdin, one per line, so this script needs no registry
# and no network. Whoever calls it decides where the list came from; this only
# decides the number. That is what makes it testable.
#
#   printf '%s\n' 26W38B1 26W38B2 | ci/next-build-tag.sh   ->   26W38B3
#
# WEEK can be set to override the current week, which the tests rely on.
set -euo pipefail

# %g is the two-digit ISO week-numbering year, NOT the calendar year. The two
# diverge around New Year: 2027-01-01 falls in ISO week 53 of 2026, so %Y%V
# would print 202753 while %g%V correctly prints 2653. UTC because CI runs in
# UTC and your laptop does not.
WEEK="${WEEK:-$(date -u +%g)W$(date -u +%V)}"

highest=0
while IFS= read -r tag; do
  [[ "$tag" =~ ^"${WEEK}"B([0-9]+)$ ]] || continue
  n="${BASH_REMATCH[1]}"
  # Arithmetic comparison. A lexical one would rank B9 above B10.
  (( n > highest )) && highest="$n"
done

# Always highest+1, never filling gaps. A reused ordinal would point at two
# different images over time, which is the one thing a tag must never do.
echo "${WEEK}B$(( highest + 1 ))"
```

`lfi-service-1-app/ci/test-next-build-tag.sh`:

```bash
#!/usr/bin/env bash
# Exercises ci/next-build-tag.sh against fixed tag lists. No registry and no
# network: the script reads tags from stdin precisely so this can run anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

check() {
  local name="$1" want="$2" week="$3"; shift 3
  local got
  got="$(printf '%s\n' "$@" | WEEK="$week" ci/next-build-tag.sh)"
  if [[ "$got" == "$want" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: want ${want}, got ${got}"
    fail=1
  fi
}

check "first build of the week"   26W38B1  26W38
check "increments the highest"    26W38B3  26W38  26W38B1 26W38B2
check "numeric, not lexical"      26W38B11 26W38  26W38B9 26W38B10
check "ignores other weeks"       26W38B1  26W38  26W37B4 26W39B2
check "ignores sha tags"          26W38B2  26W38  26W38B1 \
                                                  863c56aaa7e25f3a2e42d0b528226573a399e1f4
check "gaps are not reused"       26W38B6  26W38  26W38B5 26W38B2
check "prefix is not a substring" 26W38B1  26W38  126W38B7 26W380B2

exit "$fail"
```

```bash
cd "$PLATFORM_HOME/lfi-service-1-app"
chmod +x ci/next-build-tag.sh ci/test-next-build-tag.sh
```

**Validate:**

```bash
ci/test-next-build-tag.sh
```

Expected: seven `ok` lines and exit 0. A failure on `numeric, not lexical` means the `(( ))` became a string comparison. A failure on `prefix is not a substring` means the regex lost an anchor.

Commit, but do not push yet. Pushing before Task 10.4.5 triggers a build that still tags by SHA, which is harmless but wastes a run.

```bash
git add ci && git commit -m "ci: weekly build tag calculator"
```

#### Task 10.4.5: Switch service-1's CI to build tags and the dev overlay path

**Goal:** service-1's pipeline pushing `ghcr.io/YOUR_GITHUB_USER/service-1:26W38Bn` and `:<sha>` for the same image, and writing the build tag to the **dev** overlay.

**Why:** Two separate problems are fixed here, and the second is the one that fails silently.

The **path** is the single most forgettable change in this guide. The promote job writes to a path Task 10.2.1 moved. CI keeps passing, the commit it makes changes nothing meaningful, and dev quietly stops receiving builds. You notice days later, wondering why dev looks stale.

The **tagging** has three parts, each with a reason. The **second tag** is what preserves two-way traceability: a build ordinal alone cannot get you back to a commit, and that property is the entire argument against `latest`. The **concurrency group on `build`** exists because reading the highest tag and pushing one higher is a read-modify-write against a shared registry; two overlapping runs would both read `B2`, both produce `B3`, and the loser's image would be unreachable. The existing group only covers `promote`, which is far too late. The **manifest existence guard** is there because `yq -i` against a missing file does not reliably fail, which is exactly the silent breakage above.

Five edits to `lfi-service-1-app/.github/workflows/ci.yaml`.

**1.** In the `build` job, immediately under `runs-on: ubuntu-latest`:

```yaml
    # Computing the next ordinal is a read-modify-write against GHCR: read the
    # highest 26W38B* tag, push one higher. Two overlapping runs would both
    # read B2 and both push B3, and the loser's image would be unreachable.
    # A DIFFERENT group name from the promote job: two jobs in one run sharing
    # a group, where one `needs` the other, deadlock.
    concurrency:
      group: build-${{ github.repository }}
      cancel-in-progress: false

    outputs:
      build_tag: ${{ steps.tag.outputs.build_tag }}
```

**2.** A new step, after `Log in to GHCR` and before `Build and push`:

```yaml
      - name: Compute the build tag
        id: tag
        env:
          GHCR_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          OWNER: ${{ github.repository_owner }}
        run: |
          set -euo pipefail

          # GHCR's v2 API wants a bearer that is the base64-encoded token, not
          # the token itself. A registry quirk, not a general pattern.
          BEARER="$(printf '%s' "$GHCR_TOKEN" | base64 -w0)"
          URL="https://ghcr.io/v2/${OWNER}/${IMAGE_NAME}/tags/list?n=1000"

          # Capture the status separately so a 404, meaning the package does
          # not exist yet and this is the first ever build, is handled while
          # anything else is loud. `curl -f` alone collapses those two cases.
          RESPONSE="$(curl -sSL -w '\n%{http_code}' -H "Authorization: Bearer ${BEARER}" "$URL")"
          CODE="$(tail -n1 <<<"$RESPONSE")"
          BODY="$(sed '$d' <<<"$RESPONSE")"

          case "$CODE" in
            200) TAGS="$(jq -r '.tags[]? // empty' <<<"$BODY")" ;;
            404) echo "No existing package; this is the first build."; TAGS="" ;;
            *)   echo "ERROR: GHCR tag list returned HTTP ${CODE}" >&2
                 echo "$BODY" >&2
                 exit 1 ;;
          esac

          BUILD_TAG="$(printf '%s\n' "$TAGS" | ci/next-build-tag.sh)"
          echo "Build tag: ${BUILD_TAG}"
          echo "build_tag=${BUILD_TAG}" >> "$GITHUB_OUTPUT"
```

**3.** Replace the `tags:` line in `Build and push`, and add labels:

```yaml
          # Two tags, one image. The build tag is what humans and the dev
          # overlay use; the SHA tag is what keeps the image traceable back to
          # a commit. The labels carry the same fact inside the image, so a
          # running pod can be traced without consulting the registry at all.
          tags: |
            ghcr.io/${{ github.repository_owner }}/${{ env.IMAGE_NAME }}:${{ steps.tag.outputs.build_tag }}
            ghcr.io/${{ github.repository_owner }}/${{ env.IMAGE_NAME }}:${{ github.sha }}
          labels: |
            org.opencontainers.image.revision=${{ github.sha }}
            org.opencontainers.image.version=${{ steps.tag.outputs.build_tag }}
            org.opencontainers.image.source=https://github.com/${{ github.repository }}
```

**4.** In the `promote` job's `Update the image tag and push` step, the `env:` block becomes:

```yaml
        env:
          # Was SHA. The manifest names the build now, not the commit.
          BUILD_TAG: ${{ needs.build.outputs.build_tag }}
          SERVICE: service-1
```

**5.** In that step's script, the path, the guard, the write, and the commit message:

```bash
          # Task 10.2.1 moved this. Writing to the old path keeps CI green
          # while dev quietly stops receiving builds.
          MANIFEST="kubernetes/overlays/dev/${SERVICE}/kustomization.yaml"

          # yq -i against a missing file does not reliably fail, so check.
          if [[ ! -f "$MANIFEST" ]]; then
            echo "ERROR: ${MANIFEST} does not exist." >&2
            exit 1
          fi

          yq -i '.images[0].newTag = strenv(BUILD_TAG)' "$MANIFEST"
```

```bash
          git commit -m "deploy(${SERVICE}): ${BUILD_TAG}"
```

Also replace the two `${SHA}` references in the retry loop's `echo` lines with `${BUILD_TAG}`. Note the path targets **dev only**. Nothing automated ever writes to `overlays/prod/`; that is Section 11's job.

**Validate:**

```bash
cd "$PLATFORM_HOME/lfi-service-1-app"
yq '.jobs.build.concurrency.group, .jobs.build.outputs.build_tag, .jobs.promote.steps[-1].env.BUILD_TAG' \
  .github/workflows/ci.yaml
grep -n 'SHA' .github/workflows/ci.yaml
```

Expected: three non-null values, and every remaining `SHA` match is a `github.sha` interpolation. A surviving bare `$SHA` in the promote script writes an empty string into the manifest, which `yq` accepts without complaint.

```bash
git add .github/workflows/ci.yaml
git commit -m "ci: tag images by build number, write dev overlay path"
```

#### Task 10.4.6: Mirror both changes into service-2

**Goal:** `lfi-service-2-app` carrying byte-identical `ci/` scripts and the equivalent workflow changes.

**Why:** The two workflows are deliberately near-identical, and the comment at the top of each says so: the only difference is the service name. Copying rather than retyping keeps that true. Drift between them is the kind of thing nobody notices until one service stops deploying.

```bash
cd "$PLATFORM_HOME"
mkdir -p lfi-service-2-app/ci
cp lfi-service-1-app/ci/next-build-tag.sh      lfi-service-2-app/ci/
cp lfi-service-1-app/ci/test-next-build-tag.sh lfi-service-2-app/ci/
cd lfi-service-2-app && ci/test-next-build-tag.sh
```

Neither script names a service, so no edit is needed. Then apply the same five workflow edits from Task 10.4.5 to `lfi-service-2-app/.github/workflows/ci.yaml`, with `SERVICE: service-2`. `IMAGE_NAME` is already `service-2` at the top of that file and does not change.

**Validate:**

```bash
cd "$PLATFORM_HOME"

# Comments are stripped before comparing. The parent guide gave the two
# workflows different comment prose, so a raw diff is never empty and the
# real signal drowns in it. Blank lines go too, so an extra one is not a
# finding. Safe here only because no string in either file contains a #.
norm() {
  sed -e 's/service-[12]/SVC/g' \
      -e 's/[[:space:]]*#.*$//' \
      -e '/^[[:space:]]*$/d' "$1"
}

diff <(norm lfi-service-1-app/.github/workflows/ci.yaml) \
     <(norm lfi-service-2-app/.github/workflows/ci.yaml)
```

Expected: no output, and seven `ok` lines from the test run above. Every line this prints is real structural drift. Run it before applying the five edits too: it should list exactly those five as missing, which is a useful check that you have understood what you are about to change.

```bash
cd lfi-service-2-app
git add ci .github/workflows/ci.yaml
git commit -m "ci: tag images by build number, write dev overlay path"
```

#### Task 10.4.7: Verify the tagging end to end

**Goal:** A build tag in GHCR, the same tag in the dev overlay, a pod running it, and the commit SHA recoverable from the image.

**Why:** Every task above validated one part. This is the only check that the parts connect, and it is where the traceability claim in decision 12 gets tested rather than asserted.

```bash
cd "$PLATFORM_HOME/lfi-service-1-app" && git push
cd "$PLATFORM_HOME/lfi-service-2-app" && git push
```

Wait for both pipelines, then:

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops" && git pull
grep newTag kubernetes/overlays/dev/service-1/kustomization.yaml
git log --oneline -1 -- kubernetes/overlays/prod/service-1/kustomization.yaml
kubectl -n platform-dev get rollout service-1 \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

**Validate:** a `26W..B..` tag in the dev overlay, **no new commit** against prod, and the pod running that same tag. Both files changing means the workflow is writing to a glob rather than an explicit path, which silently removes the gate Section 11 is about to build.

Then prove traceability in the direction the build tag would otherwise have cost you:

```bash
TAG="$(yq '.images[0].newTag' kubernetes/overlays/dev/service-1/kustomization.yaml)"
docker pull "ghcr.io/YOUR_GITHUB_USER/service-1:${TAG}"
docker inspect "ghcr.io/YOUR_GITHUB_USER/service-1:${TAG}" \
  --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}'
```

Expected: a 40-character SHA that `git log -1 --oneline <sha>` resolves in `lfi-service-1-app`. An empty label means the `labels:` block in Task 10.4.5 did not apply.

#### Task 10.4.8: Commit Section 10

**Goal:** The work committed, and the tracker table above updated.

**Why:** Phase boundaries are the natural commit points, and the tracker only helps across sessions if it reflects reality.

```bash
git add -A
git commit -m "feat(platform): dev and prod environments with per-env credentials"
git push
```

**Validate:** Phases 10.1 through 10.4 are marked ☑ Done in the tracker, and `git status` is clean in the GitOps repo. The tracker itself lives in the workspace, which is not a repo, so there is nothing to commit for it.

---

## Section 11: The Weekly Release

**Objective:** Dev keeps deploying on every merge. Prod changes only through a pull request that copies dev's tags forward, requires your review, and leaves a named release behind.

### Phase 11.1: The promotion script

#### Task 11.1.1: Create the deny list

**Goal:** `releases/denied-builds.yaml` in the GitOps repo, empty and committed.

**Why:** Decision 13. Green CI means the code compiles and the unit tests pass, on a runner, in isolation, in two minutes. It does not mean the thing works. A slow memory leak, a connection pool that exhausts after six hours, a migration meeting accumulated rows: CI structurally cannot see any of those, and dev can. When dev shows you one, you need somewhere to record that this build must never reach prod.

That somewhere is a file in Git rather than a conversation, so a veto has an author, a timestamp, a diff, and a revert like everything else here.

It lives **outside** `kubernetes/` on purpose. Every path under there is either a kustomize base or an overlay some Application points at, and a stray YAML document in that tree is an invitation for something to try applying it.

`releases/denied-builds.yaml`:

```yaml
# Builds that must never be promoted to prod.
#
# Adding an entry vetoes a build. Removing one unblocks it. Both are commits,
# so the history here is the permanent record of why something never shipped.
#
# This file is deliberately outside kubernetes/: it is not a manifest and no
# ArgoCD Application should ever see it.
#
# `service` is required. Build ordinals are per-service, so 26W38B3 for
# service-1 and 26W38B3 for service-2 are unrelated images.
#
# Example:
#   denied:
#     - build: 26W38B3
#       service: service-1
#       reason: OOMs at real queue depth after ~6h
#       denied_by: mhonn
denied: []
```

**Validate:**

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
yq '.denied | type' releases/denied-builds.yaml
```

Expected: `!!seq`. A result of `!!null` means the `[]` is missing, and every lookup in the next task will error rather than return empty.

> **Detection is still manual, and that is the honest position for now.** Nothing watches dev. The signals you have are ArgoCD reporting `Degraded`, pod restart counts, and the `/healthz` and `persisted_id` checks from the parent guide. Automating the veto needs something scheduled that can reach the cluster, and dev is k3d on a laptop that sleeps. Section 13 is where that changes.

#### Task 11.1.2: Write scripts/release.sh

**Goal:** A script that reads the tags dev is running, writes them into the prod overlay, and opens a pull request.

**Why:** It builds nothing, and that is the whole idea. The images already exist in GHCR and have been serving dev traffic all week, so a release moves a reference and nothing more. The script also refuses to run from a dirty tree, because a release commit that quietly carries an unrelated working change is exactly the surprise this process exists to prevent.

`scripts/release.sh`:

```bash
#!/usr/bin/env bash
# Opens the weekly prod release PR.
#
# Reads the image tags the dev overlay is currently running and writes them
# into the prod overlay. Nothing is built: the images already exist in GHCR and
# have been serving dev traffic all week. This script only moves a reference.
set -euo pipefail

SERVICES=(service-1 service-2)
# %G is the ISO week-numbering year, not the calendar year. They diverge at
# New Year: 2027-01-01 falls in ISO week 53 of 2026, so %Y-W%V would name that
# release 2027-W53, a week that does not exist. UTC to match CI.
WEEK="$(date -u +%G-W%V)"     # ISO week, so release/2026-W36
BRANCH="release/${WEEK}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Refuse to run from a dirty tree. A release commit that quietly carries an
# unrelated working change is exactly the kind of surprise this whole process
# exists to prevent.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: working tree is dirty. Commit or stash first." >&2
  exit 1
fi

git switch main >/dev/null 2>&1
git pull --ff-only

DENYLIST="releases/denied-builds.yaml"
if [[ ! -f "$DENYLIST" ]]; then
  echo "ERROR: ${DENYLIST} is missing. Refusing to release without it." >&2
  exit 1
fi

# Collect what would change, before changing anything, so the script can decide
# whether there is a release to make and can build the PR body.
declare -a CHANGES=()
declare -a BLOCKED=()
for svc in "${SERVICES[@]}"; do
  dev_tag="$(yq '.images[] | select(.name == "'"$svc"'") | .newTag' \
    "kubernetes/overlays/dev/$svc/kustomization.yaml")"
  prod_tag="$(yq '.images[] | select(.name == "'"$svc"'") | .newTag' \
    "kubernetes/overlays/prod/$svc/kustomization.yaml")"

  [[ "$dev_tag" == "$prod_tag" ]] && continue

  # A denied build drops out of the release. It is never silently replaced
  # with an older one: shipping something other than what you asked for is
  # exactly the surprise this whole process exists to prevent. strenv reads
  # the values as strings so a numeric-looking tag is not coerced.
  reason="$(SVC="$svc" TAG="$dev_tag" yq '
    .denied[] | select(.service == strenv(SVC) and .build == strenv(TAG)) | .reason
  ' "$DENYLIST")"

  if [[ -n "$reason" ]]; then
    BLOCKED+=("$svc|$dev_tag|$reason")
    continue
  fi

  CHANGES+=("$svc|$prod_tag|$dev_tag")
done

if [[ ${#BLOCKED[@]} -gt 0 ]]; then
  echo "Denied builds, excluded from this release:" >&2
  for blocked in "${BLOCKED[@]}"; do
    IFS='|' read -r svc tag reason <<< "$blocked"
    printf '  %-12s %-10s %s\n' "$svc" "$tag" "$reason" >&2
  done
fi

# "Nothing changed" and "everything I would have shipped is poisoned" are
# different states and must never print the same message.
if [[ ${#CHANGES[@]} -eq 0 && ${#BLOCKED[@]} -gt 0 ]]; then
  echo "ERROR: every candidate build is denied. Nothing released." >&2
  exit 1
fi

if [[ ${#CHANGES[@]} -eq 0 ]]; then
  echo "Nothing to release: prod already matches dev."
  exit 0
fi

git switch -c "$BRANCH"

# Write the new tags. This is the entire mechanical content of a release.
BODY="## Release ${WEEK}"$'\n\n'"| Service | From | To |"$'\n'"|---|---|---|"$'\n'
for change in "${CHANGES[@]}"; do
  IFS='|' read -r svc from to <<< "$change"
  yq -i '(.images[] | select(.name == "'"$svc"'") | .newTag) = "'"$to"'"' \
    "kubernetes/overlays/prod/$svc/kustomization.yaml"
  BODY+="| \`$svc\` | \`${from:0:12}\` | \`${to:0:12}\` |"$'\n'
done

BODY+=$'\n'"Promote **service-2 before service-1**: service-1 calls service-2, so"
BODY+=" promoting the dependency first keeps each canary judgment about one change."

# Reviewers need to see what is NOT in the release as much as what is.
if [[ ${#BLOCKED[@]} -gt 0 ]]; then
  BODY+=$'\n\n'"### Excluded by the deny list"$'\n\n'"| Service | Build | Reason |"$'\n'"|---|---|---|"$'\n'
  for blocked in "${BLOCKED[@]}"; do
    IFS='|' read -r svc tag reason <<< "$blocked"
    BODY+="| \`$svc\` | \`$tag\` | $reason |"$'\n'
  done
fi

git add kubernetes/overlays/prod
git commit -m "release(prod): ${WEEK}"
git push -u origin "$BRANCH"

gh pr create --title "release(prod): ${WEEK}" --body "$BODY" --base main

git switch main
echo "PR opened. Review the diff: it is your release note."
```

```bash
chmod +x scripts/release.sh
```

**Validate:**

```bash
bash -n scripts/release.sh && echo "syntax OK"
```

Expected: `syntax OK`. Running it for real is Task 11.1.4.

#### Task 11.1.3: Wire it into the Makefile

**Goal:** `gmake release` and `gmake urls`, both listed by `gmake help`.

**Why:** `release` deliberately applies nothing. It opens a pull request and stops. Prod changes when you merge, and ArgoCD takes it from there. That separation between "prepare the release" and "make the release happen" is the gate, so it is worth the target doing less than you might expect.

Add both to `.PHONY`, then:

```make
# ---------------------------------------------------------------------------
# release: open the weekly prod promotion PR.
#
# Deliberately does NOT apply anything. It only opens a PR. Prod changes when
# you merge, and ArgoCD picks it up from there. That separation is the gate.
# ---------------------------------------------------------------------------
release: ## Open the weekly prod release PR
	./scripts/release.sh

# ---------------------------------------------------------------------------
# urls: print where each environment answers. Trivial, and saves you
# remembering which hostname is which every time.
# ---------------------------------------------------------------------------
urls: ## Print the ingress URLs for both environments
	@echo "dev    http://dev.localhost:8080"
	@echo "prod   http://prod.localhost:8080"
	@echo "argocd http://argocd.localhost:8080"
```

**Validate:**

```bash
gmake help | grep -E 'release|urls'
```

Expected: both targets listed with their descriptions, which also confirms the `##` comments match the format the `help` target's grep expects.

#### Task 11.1.4: Dry run the release

**Goal:** A release PR whose diff is exactly one line per changed service.

**Why:** The diff is the release note, so its readability is a feature rather than a nicety. Anything in that diff beyond the tag lines is either a bug in the script or a working-tree change that slipped past the dirty check, and both are worth knowing about now rather than during a real release.

Make a trivial change in a service repo, let CI deploy it to dev, then:

```bash
gmake release
```

**Validate:** the PR opens, and its diff touches **exactly one line per changed service**, all under `kubernetes/overlays/prod/`.

**A real flaw worth understanding rather than working around.** If you run `gmake release` again before merging, it will happily open a second branch for the same week. The no-op check compares `main` against `main`, and your first release lives on a branch, so from `main`'s point of view there is still a release to make. Merge the PR, then re-run to see the genuine `Nothing to release` path. If this bothers you in practice, add a guard that refuses to run when a `release/*` branch already exists on the remote.

#### Task 11.1.5: Verify a denial actually blocks

**Goal:** Observed proof that a denied build is excluded, that the other service still ships, and that a fully denied release fails loudly.

**Why:** A safety mechanism nobody has watched fire is a guess. This costs three minutes and converts it into a fact, which is the same reason Section 12 spends most of its time deliberately breaking things.

Deny whatever dev is currently running for service-1:

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
DEV_TAG="$(yq '.images[0].newTag' kubernetes/overlays/dev/service-1/kustomization.yaml)"
TAG="$DEV_TAG" yq -i '.denied += [{
  "build": strenv(TAG),
  "service": "service-1",
  "reason": "deliberate test of the deny path",
  "denied_by": "you"
}]' releases/denied-builds.yaml
git add releases/denied-builds.yaml && git commit -m "test: deny service-1 build"
gmake release
```

**Validate:** stderr carries the exclusion:

```
Denied builds, excluded from this release:
  service-1    26W..B..   deliberate test of the deny path
```

followed by one of two correct outcomes. If service-2 also has an unreleased build, a PR opens containing **service-2 only**, with the "Excluded by the deny list" table in its body. If service-2 had nothing to ship, the script exits 1 with `ERROR: every candidate build is denied.` Which you get depends on the state of service-2, and both are right.

A PR that includes service-1 means the lookup returned empty: check that `service:` in the deny entry matches the name in the `images:` block exactly.

Then clean up, confirming prod was never touched:

```bash
git switch main && git pull --ff-only
grep newTag kubernetes/overlays/prod/service-1/kustomization.yaml
yq -i '.denied = []' releases/denied-builds.yaml
git add releases/denied-builds.yaml && git commit -m "test: remove the test denial"
gmake release
```

Expected: the prod tag unchanged throughout, and the final `gmake release` printing either a normal PR or `Nothing to release`, with no exclusion list. Close and delete any `release/` branch the test opened.

### Phase 11.2: The gate

#### Task 11.2.1: CODEOWNERS

**Goal:** Changes under `kubernetes/overlays/prod/` requiring your review, and changes under `dev/` requiring nothing.

**Why:** This gives you branch-protection semantics on a *directory*, which is the capability people usually reach for environment branches to get. It is the concrete reason decision 1 costs you nothing: you keep the gate and skip the weekly merge conflicts.

`.github/CODEOWNERS`:

```
# Changes under this path require review from the listed owner. This is the
# prod release gate, and it is why environment branches are unnecessary: a
# directory can be protected just as effectively as a branch.
/kubernetes/overlays/prod/    @YOUR_GITHUB_USER

# Terraform provisions both environments, so it gets the same treatment.
/terraform/                   @YOUR_GITHUB_USER

# Deliberately unowned: dev is meant to be continuous, and requiring review
# here would defeat the purpose of automated promotion.
# /kubernetes/overlays/dev/
```

**Validate:**

```bash
gh api "repos/:owner/:repo/codeowners/errors" --jq '.errors'
```

Expected: `[]`. A non-empty array means a path pattern matches nothing or an owner is not a valid collaborator, and GitHub silently ignores a broken rule rather than warning you at review time.

#### Task 11.2.2: Branch protection

**Goal:** A direct push of a prod overlay change to `main` that is rejected.

**Why:** Without this, `CODEOWNERS` is advisory and the gate does not exist. This task deliberately ends by trying to break its own gate, because an untested gate is decoration and you will not find out otherwise until the day it mattered.

In the GitHub UI: Settings, Branches, add a rule for `main`:

- Require a pull request before merging
- Require review from Code Owners
- Do not allow bypassing the above settings

**Validate:** try to push a prod overlay change directly.

```bash
git switch main
yq -i '(.images[] | select(.name == "service-1") | .newTag) = "deadbeef"' \
  kubernetes/overlays/prod/service-1/kustomization.yaml
git commit -am "test: should be rejected" && git push
```

Expected: the push is **rejected**. Then undo it:

```bash
git reset --hard origin/main
```

If the push succeeded, the rule is not active.

#### Task 11.2.3: Tag each release

**Goal:** A `release/YYYY-WW` tag on each merged release commit.

**Why:** The tag is not the deploy trigger. Prod tracks `HEAD` and syncs from the merge. The tag gives you a name you can say out loud in a conversation and a fixed point to diff against or return to. A tag rather than a branch specifically because it is an immutable pointer: nothing to merge, nothing to conflict, nothing to keep in sync.

```make
# ---------------------------------------------------------------------------
# tag-release: name the release you just merged.
#
# A tag, not a branch. Immutable pointer, nothing to merge, nothing to
# conflict. Run this after a release PR merges and its canaries are promoted.
# ---------------------------------------------------------------------------
tag-release: ## Tag the current main as this week's release
	git switch main
	git pull --ff-only
	git tag -a "release/$$(date +%Y-W%V)" -m "Prod release $$(date +%Y-W%V)"
	git push --tags
```

**Validate:**

```bash
gmake tag-release
git tag -l 'release/*'
```

Expected: a `release/YYYY-WW` tag exists locally and on the remote.

#### Task 11.2.4: Practise the rollback before you need it

**Goal:** A measured number: how long from merging a revert to the old image serving in prod.

**Why:** Rolling back a release you chose is a completely different experience from rolling back one that surprised you at 11pm. Doing it now is the only time you will do it calmly, and the number you measure is the one you will quote when someone asks how fast you can undo a bad release.

```bash
git log --oneline --grep '^release(prod)' -1

git switch -c revert-release
git revert --no-edit <sha>
git push -u origin revert-release
gh pr create --title "revert: release(prod)" --body "Rollback drill." --base main
```

Note the revert goes through the same PR gate. That is correct: a rollback is a change to prod and should be recorded like any other.

**Validate:** merge it, then:

```bash
kubectl --context k3d-platform -n argocd get application service-1-prod \
  -o jsonpath='{.status.sync.status}{"\n"}'
kubectl --context k3d-platform -n platform-prod get rollout service-1 \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

Expected: `Synced`, and the image tag back to the previous SHA. Write down how long it took from merge to old image serving.

#### Task 11.2.5: Commit Section 11

**Goal:** Section 11 committed, tracker updated.

**Why:** Phase boundary.

**Validate:** Phases 11.1 and 11.2 marked ☑ Done, GitOps repo clean.

---

## Section 12: Canary With a Human in the Loop

**Objective:** A merged release reaches half of prod, stops, and waits indefinitely for your judgment. You can complete it with one command or remove it from service with another.

**Why promote and abort are CLI commands, given Section 11 argued against UI gates.** These are different kinds of action, and the distinction is worth holding onto. A release commit changes *desired state*: it says what prod should run, and that belongs in Git. Promoting a paused rollout advances an in-progress convergence toward state Git already declares, and aborting returns to the last state Git successfully converged on. Neither changes what Git says prod should be running, so neither belongs in a commit.

### Phase 12.1: The canary strategy

#### Task 12.1.1: Add canary steps to the prod overlay

**Goal:** Prod rollouts that stop at 50 percent and wait; dev rollouts unchanged.

**Why:** Three lines of real change, because Task 10.2.3 already put the strategy in the right shape. Two details in it matter. `setWeight` is a proportion of *pods*, not a traffic rule, which is why no Traefik configuration appears anywhere in this guide: the existing ClusterIP splits requests across canary and stable by endpoint count. And `pause: {}` with no duration waits indefinitely, so no timer is racing your judgment.

Add to both `kubernetes/overlays/prod/service-1/kustomization.yaml` and `service-2/kustomization.yaml`, under `patches:`:

```yaml
  # Replaces the base's single-step strategy with a real canary. Dev keeps the
  # single setWeight: 100 step and continues rolling straight through.
  #
  # setWeight is a proportion of pods, not a traffic rule. With replicas: 2,
  # 50 means one canary pod beside one stable pod, and the existing ClusterIP
  # splits requests across them by endpoint count. This is why no Traefik
  # configuration or traffic router appears anywhere in this guide.
  #
  # `pause: {}` with no duration waits INDEFINITELY. That is the manual gate:
  # no timer is racing your judgment.
  - target:
      group: argoproj.io
      version: v1alpha1
      kind: Rollout
      name: service-1
    patch: |-
      - op: replace
        path: /spec/strategy/canary/steps
        value:
          - setWeight: 50
          - pause: {}
          - setWeight: 100
```

**Validate:**

```bash
kustomize build kubernetes/overlays/prod/service-1 \
  | yq 'select(.kind == "Rollout") | .spec.strategy.canary.steps'
kustomize build kubernetes/overlays/dev/service-1 \
  | yq 'select(.kind == "Rollout") | .spec.strategy.canary.steps'
```

Expected: three steps for prod, one for dev. Both showing three means you edited the wrong overlay, and dev would then require a manual promote on every merge, which presents as broken CI.

#### Task 12.1.2: Verify ArgoCD does not fight the pause

**Goal:** A paused rollout that is still paused five minutes later, with the Application reporting `Synced` and `Progressing`.

**Why:** This is the assumption the entire section rests on, so it gets tested rather than trusted. `selfHeal` exists to revert cluster state that Git did not ask for, and a paused rollout is exactly that. It works because Rollouts keeps pause state in `status` while ArgoCD compares `spec`. That difference is also precisely why `kubectl rollout pause` on a plain Deployment would not work here, since `paused` there lives in `spec`.

Commit and push Task 12.1.1, let a release reach prod, and while it sits paused:

```bash
kubectl --context k3d-platform -n argocd get application service-1-prod \
  -o custom-columns='SYNC:.status.sync.status,HEALTH:.status.health.status'

kubectl argo rollouts get rollout service-1 -n platform-prod
```

**Validate:** `Synced` and `Progressing`. Wait five minutes and check again: still paused.

`Degraded` instead of `Progressing` means `progressDeadlineSeconds` fired, so raise it. A rollout that resumes on its own means a `pause` has a duration somewhere, so re-read the built output from Task 12.1.1.

#### Task 12.1.3: Makefile helpers

**Goal:** Three targets for operating on an in-flight rollout, each taking `SVC=`.

**Why:** These change no desired state, which is why they are commands rather than commits. The abort target prints a reminder deliberately, because abort and revert are two different levers and you need both: abort stops the bleeding in seconds, revert is what stops it coming back on the next sync.

```make
# ---------------------------------------------------------------------------
# canary-*: operate on an in-flight prod rollout.
#
# These change no desired state, which is why they are commands rather than
# commits. They advance or unwind a convergence toward what Git already says.
#
# Usage: gmake canary-status SVC=service-1
# ---------------------------------------------------------------------------
ROLLOUT_NS := platform-prod

canary-status: ## Watch an in-flight prod rollout. SVC=service-1
	kubectl argo rollouts get rollout $(SVC) -n $(ROLLOUT_NS) --watch

canary-promote: ## Complete a paused prod rollout. SVC=service-1
	kubectl argo rollouts promote $(SVC) -n $(ROLLOUT_NS)

canary-abort: ## Scale the canary to zero, leaving stable serving. SVC=service-1
	kubectl argo rollouts abort $(SVC) -n $(ROLLOUT_NS)
	@echo
	@echo "Canary removed from service. Stable is unaffected."
	@echo "This does NOT undo the release: Git still points prod at the bad tag,"
	@echo "so the next sync will try again. Revert the release PR to make it stick."
```

**Validate:**

```bash
gmake help | grep canary
gmake canary-status SVC=service-1     # Ctrl-C to exit
```

Expected: three targets listed, and the status view renders showing the Rollout, its ReplicaSets, and their pods.

### Phase 12.2: Learn to judge

This phase produces no code. It is the part that matters.

#### Task 12.2.1: Answer two questions about service-1's client behaviour

**Goal:** Two written answers, recorded in the runbook in Task 12.3.1.

**Why:** Both change how much a clean service-2 bake is actually worth, and neither is answerable from the GitOps repo. Reading the code now means you are not guessing about it while judging a live canary.

Read `lfi-service-1-app/src/main.py` and `config.py`:

1. **Does service-1 retry its calls to service-2?** If yes, a fully broken service-2 canary is partly masked: some retries land on the stable pod and succeed, so a 50 percent failure rate presents as intermittent slowness. You would be judging something that looks half-fine when it is entirely broken. If yes, note the retry count and timeout too, since they determine how long you must watch before a problem is visible.
2. **Does `readyz` check service-2, or only Postgres?** If only Postgres, a service-2 canary that is up but returning wrong answers stays in the Service endpoints indefinitely. Nothing removes it automatically. Only you do.

**Validate:** you can state both answers without looking again.

#### Task 12.2.2: Rehearse a bad service-1 release

**Goal:** Direct experience of catching a bad canary at the edge, and proof that stable traffic was never affected.

**Why:** The edge-facing service is the easy case, so it comes first. Failures here show up as HTTP status codes, which lets you learn the mechanics of watch, abort, and revert before Task 12.2.3 removes that visibility.

In `lfi-service-1-app`, make `/healthz` return a 500, or have startup raise. Let CI deploy it to dev, then release it to prod and merge. While it is paused:

```bash
gmake canary-status SVC=service-1

# In another terminal, hammer prod and count failures.
for i in $(seq 1 100); do
  curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: prod.localhost' \
    http://localhost:8080/healthz
done | sort | uniq -c
```

**Validate:** you see roughly half 200s and half failures, **or** the canary never becomes ready and you see all 200s. Both are informative, and it is worth knowing which you got: the second means your readiness probe caught it before any request reached the bad pod.

Then abort and confirm stable was untouched:

```bash
gmake canary-abort SVC=service-1

for i in $(seq 1 100); do
  curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: prod.localhost' \
    http://localhost:8080/healthz
done | sort | uniq -c
```

Expected: 100 responses, all 200. Then revert the release PR so the next sync does not redeploy the broken tag.

#### Task 12.2.3: Rehearse a bad service-2 release

**Goal:** Either the demonstrated ability to detect an internal failure, or a written list of what you could not see.

**Why:** This is the rehearsal that matters. service-2 is internal, so nothing about its failure appears at the ingress as a status code. You have to find it from service-1's behaviour and service-2's own logs, which is the realistic version of this skill. Break it **up but wrong** rather than crashing: return a valid response with an incorrect value. A crash would be caught by the readiness probe and would teach you nothing new after Task 12.2.2.

Release it, and while paused, judge it using only:

```bash
# service-2's canary pod logs. Get the hash from the rollout view first.
kubectl argo rollouts get rollout service-2 -n platform-prod
kubectl --context k3d-platform -n platform-prod logs \
  -l app=service-2,rollouts-pod-template-hash=<canary-hash> -f

# service-1's view of its upstream: exercise the path that calls service-2.
for i in $(seq 1 50); do
  curl -s -H 'Host: prod.localhost' http://localhost:8080/compute
done | sort | uniq -c
```

**Validate:** you can tell there is a problem, and say which half of the fleet has it, using only what you would have in a real incident.

**If you cannot detect it, the rehearsal has succeeded at its actual job.** It means the bake procedure is inadequate, and that is a finding rather than a failure. Do not proceed to Section 13 assuming metrics will fix it. Write down exactly what you were missing, because that list is the specification for what Section 13 has to provide.

#### Task 12.2.4: Release both services at once

**Goal:** A judgment about whether the promote-order convention holds up under real use.

**Why:** A release PR that bumps both tags starts both canaries on the same sync, so a failure could be from either. Feeling that confounding is the point of this task, because it is what tells you whether to keep trusting the convention or to enforce it.

Release both, then promote **service-2 first** because service-1 depends on it:

```bash
gmake canary-status  SVC=service-2
gmake canary-promote SVC=service-2
# only once service-2 is fully promoted and healthy:
gmake canary-status  SVC=service-1
gmake canary-promote SVC=service-1
```

**Validate:** both rollouts complete and prod is healthy.

Then answer honestly: was keeping the order straight easy, or did you have to think about it? If the latter, enforce it with `argocd.argoproj.io/sync-wave` annotations on the two child Applications. That works because a paused Rollout reports `Progressing` rather than `Healthy`, so ArgoCD holds the next wave until you promote the current one. Only add it if you found you needed it.

### Phase 12.3: Write down what you learned

#### Task 12.3.1: The bake runbook

**Goal:** A filled-in runbook in this file, written from what actually happened.

**Why:** A runbook written from experience is worth several written from theory, and the difference is entirely in whether it names the things that surprised you. Write it now, while the rehearsals are fresh, rather than reconstructing it later.

> **Bake runbook** (fill this in from Tasks 12.2.2 through 12.2.4)
>
> - First signal I check:
> - Does service-1 retry calls to service-2:
> - Does `readyz` cover service-2:
> - A bad service-2 canary presented as:
> - Minimum bake time before I trust a clean result:
> - What I could not see, and what Section 13 must therefore provide:

**Validate:** all six lines filled in, and none of them says "not sure".

#### Task 12.3.2: Commit Section 12

**Goal:** Section 12 committed, tracker updated, release tagged.

**Why:** Phase boundary, and this is the one where you have a genuinely complete release process worth naming.

**Validate:** Phases 12.1 through 12.3 marked ☑ Done, GitOps repo clean, a `release/*` tag on the current main.

---

## Section 13: Observability and Automated Analysis

**Objective:** Replace your eyes with a query, keeping the manual pause as a second gate.

**Status: scoped, not scheduled.** This section is written down so the shape is known and so Task 12.2.3's findings have somewhere to go. Do not start it until Section 12's rehearsals are done, because those rehearsals define what these metrics need to answer.

### Phase 13.1: Metrics and dashboards

#### Task 13.1.1: Prometheus and Grafana via Terraform

**Goal:** Both namespaces being scraped.

**Why:** Budget about 1 GiB, which still fits inside the Docker Desktop VM without raising it.

#### Task 13.1.2: Expose /metrics from both services

**Goal:** Request counts and error counts per service, labelled by pod.

**Why:** This is work in the service repos, not the GitOps repo, so it is the one part of this section that touches application code.

#### Task 13.1.3: Dashboards separating canary from stable

**Goal:** A panel that keeps working next week.

**Why:** **Do not hardcode a `rollouts-pod-template-hash`.** It is opaque and rotates on every release, so a panel built that way works for exactly one week and then silently shows nothing, which is worse than showing an error. Two ways out: set `canaryService` and `stableService` in the canary strategy, which makes Rollouts maintain two Services whose selectors track the hashes and gives you two stable names to scrape; or drive the hash from a dashboard variable.

### Phase 13.2: Automated analysis

#### Task 13.2.1: An AnalysisTemplate comparing canary to stable error rate

**Goal:** A query that runs against whichever hashes are current.

**Why:** Use the hashes Rollouts injects as template arguments rather than literals, for the same rotation reason as Task 13.1.3.

#### Task 13.2.2: Wire the analysis into the prod strategy

**Goal:** A breach that aborts the rollout automatically, with `pause: {}` still after it.

**Why:** Automated analysis catches what you told it to look for. The pause is what catches everything else, which is why it stays rather than being replaced.

#### Task 13.2.3: Confirm the metrics answer the service-2 question

**Goal:** Evidence that the metrics detect a canary returning **wrong answers**, not just one returning errors.

**Why:** Error rate will not show wrong answers, and wrong answers are the most likely failure mode of a service that is largely a stub. This is where Task 12.2.3's findings get satisfied, or shown to be still unsatisfied.

---

## Appendix E: Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Dev Rollout runs 2 replicas instead of 1, no error anywhere | Kustomize's `replicas:` field was used on a Rollout. Its built-in transformer only knows Deployment, ReplicaSet, StatefulSet, and ReplicationController, so a custom resource matches nothing and it reports nothing | Use the JSON6902 patch from Task 10.2.4. Confirm with the replicas table in Task 10.2.6. |
| Root Application is `Synced`/`Healthy` but no child Applications exist | `directory.recurse` missing, so ArgoCD read only the top level of `argocd/apps` and correctly found nothing | Task 10.3.3. Green status with an empty cluster is this, essentially every time. |
| ArgoCD reports a Rollout as `Unknown` health forever | The argo-rollouts controller is not running, so nothing is reconciling the object | `kubectl -n argo-rollouts get pods`. If empty, `gmake platform-up` did not create the Helm release. |
| `no matches for kind "Rollout"` during sync | The CRD is not registered yet | The `wait = true` on the Helm release should prevent this. If it recurs, the root Application synced before Terraform finished; re-sync it. |
| Only one of two same-named Applications is managed | Two Application manifests share a `metadata.name`, and names must be unique per namespace | Task 10.4.1. The `uniq -d` in its Validate finds the duplicate. |
| CI passes but dev stops receiving new builds | The promote job still writes to `kubernetes/<svc>/kustomization.yaml`, a path that no longer exists. `yq -i` on a missing file is not always an error | Task 10.4.5, whose guard turns this into a hard failure. |
| Both dev and prod tags change on every merge | The promote job's path is a glob rather than an explicit dev path | Task 10.4.5. This silently removes the gate entirely, so check it even if things look fine. |
| `Compute the build tag` fails with HTTP 403 | The `build` job cannot read the package. The workflow-level `permissions:` block needs `packages: write`, which implies read | Check `permissions:` at the top of `ci.yaml`. A 401 instead means the token was not base64-encoded before being sent as the bearer. |
| Two builds land on the same ordinal, and one image is unreachable | The `concurrency` block on the `build` job is missing, so two runs both read the same highest tag | Task 10.4.5, edit 1. Note the group name must differ from the promote job's. |
| The build tag advances but the dev overlay keeps the old one | The promote job still reads `$SHA`, which is now unset, and `yq` accepted the empty string | Task 10.4.5, edit 5. The `grep -n 'SHA'` in its Validate finds the survivor. |
| `docker inspect` shows an empty `image.revision` label | The `labels:` block did not apply, so the build tag can no longer be traced to a commit | Task 10.4.5, edit 3. |
| `gmake release` says every candidate is denied, but you denied only one service | The other service had nothing to ship, so there were no unblocked changes left | Expected, and deliberately an error rather than `Nothing to release`. Task 11.1.5. |
| A denied build gets released anyway | `service:` in the deny entry does not match the name in the `images:` block, so the lookup returned empty | Ordinals are per-service; both fields must match. Task 11.1.1. |
| `curl -H 'Host: prod.localhost'` returns the dev response | Both Ingresses still lack a host, so Traefik matched the first rule it found | Confirm both host patches applied: Task 10.2.6's host checks. |
| `curl: (52) Empty reply` on one environment only | That environment's Rollout has no ready pods | `kubectl -n platform-<env> get rollout,pods`. An unready pod with a failing readiness probe usually means that namespace's Postgres Secret is wrong. |
| Postgres in one namespace crash-loops with an auth error, the other is fine | That namespace's Secret was created before you changed the password | `gmake down && gmake platform-up`. The Secret is Terraform-managed and a running pod does not see an updated one until it restarts. |
| `gmake check-env` fails with "identical" after you set two passwords | They are genuinely the same string | Decision 4. A dev credential must not open prod. |
| Paused rollout resumes on its own after a few minutes | A `pause` with a `duration`, or `progressDeadlineSeconds` firing and aborting | Confirm the built output shows `pause: {}` with no duration: Task 12.1.1. If it aborted, the Application reads `Degraded`, not `Progressing`. |
| Paused rollout gets reverted within seconds | Not `selfHeal`, which compares `spec` while pause lives in `status`. Something else is writing to the Rollout spec | Check for a stray `kubectl rollout pause`, which sets `spec.paused` and *would* be reverted. Task 12.1.2. |
| `kubectl argo rollouts promote` says the rollout is not paused | It already completed, or it aborted | `kubectl argo rollouts get rollout <svc> -n platform-prod` shows the current step and status. |
| After an abort, the bad version comes back on the next sync | Expected. Abort changes the cluster; Git still points prod at the bad tag | Revert the release PR. The `canary-abort` target prints this reminder for exactly this reason. |
| Push to `main` with a prod overlay change succeeds | Branch protection is not active, so CODEOWNERS is advisory | Task 11.2.2. Test it rather than assuming it. |
| `gmake release` opens a duplicate branch for the same week | The previous release PR is not merged, so `main` still shows the old prod tags | Merge first. See the note in Task 11.1.4. |
| Pods OOM-killed at random across unrelated workloads | Two node containers each reporting the full VM memory, so the scheduler overcommits | Task 10.3.5, or raise the Docker Desktop allocation. |

---

## Appendix F: Command Cheat Sheet Additions

```bash
# --- Both environments at once -------------------------------------------
kubectl get rollouts -A -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,DESIRED:.spec.replicas'

kubectl get applications -n argocd -o custom-columns=\
'NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

curl -s -H 'Host: dev.localhost'  http://localhost:8080/healthz
curl -s -H 'Host: prod.localhost' http://localhost:8080/healthz

# --- Canary --------------------------------------------------------------
gmake canary-status  SVC=service-1
gmake canary-promote SVC=service-1
gmake canary-abort   SVC=service-1

# Canary pod logs only. Get the hash from the rollouts get output first.
kubectl -n platform-prod logs -l app=service-1,rollouts-pod-template-hash=<hash> -f

# What is each environment actually running?
for env in dev prod; do
  printf '%-5s ' "$env"
  kubectl -n "platform-$env" get rollout service-1 \
    -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
done

# --- Release -------------------------------------------------------------
gmake release            # open the weekly PR
gmake tag-release        # name it, after promoting
git log --oneline --grep '^release(prod)'

# --- Overlay debugging ---------------------------------------------------
kustomize build kubernetes/overlays/prod/service-1
diff <(kustomize build kubernetes/overlays/dev/service-1) \
     <(kustomize build kubernetes/overlays/prod/service-1)
```

That last `diff` is the single most useful command in this guide. It shows the complete difference between your two environments as rendered YAML, which is exactly the question you want answered when something behaves differently in prod.

---

## Where to Go Next

**Finish Section 13.** The manual bake works, but it does not scale past one person watching one release. Task 12.2.3 will have told you specifically what it cannot see.

**Narrow the canary.** Fifty percent is a large canary; real ones are 1 to 5 percent. That needs more prod replicas, which needs the memory conversation in Task 10.3.5.

**A third environment.** With base plus overlays this is one directory, one Terraform list entry, and three Application manifests. Adding `staging` is a good test of whether the structure actually generalises, and it is the exercise that shows most clearly why the branch-based alternative would not have.

**Sealed Secrets.** The per-environment passwords still come from your laptop, so the cluster is not reproducible from Git alone. This is the same limitation the parent guide's decision 4 flagged, now doubled.

**A real AppProject.** Everything uses `default`, which permits any repo and any destination. A per-environment AppProject could prevent a dev Application from ever targeting `platform-prod`, turning a convention into a constraint. That is also where `syncWindows` lives if you ever want the weekly cadence enforced rather than chosen.
