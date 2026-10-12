# An EKS Counterpart to the Local Platform: A Build Guide

**Goal:** Add a managed AWS cluster (EKS, ap-southeast-2) that runs the same platform as the local k3d cluster. Either cluster can exist alone, or both can exist together. Neither knows about the other.

**Status:** DRAFT. Nothing in this guide has been executed. Progress is ticked in `tracker_3_eks.md`, not here.

**Relationship to the earlier guides:** This continues `docs/1-local-full-infra-guide.md` (Sections 1 to 9) and `docs/2-multi-env-infra-guide.md` (Sections 10 to 13). Numbering resumes at Section 14 and appendix lettering at G. Every task assumes you finished Section 13, so a local platform with dev and prod namespaces is running and Terraform state lives in S3.

**Tech stack added:** Amazon EKS (managed Kubernetes), a VPC, EBS volumes through the EBS CSI driver and EKS Pod Identity, and an AWS load balancer in front of Traefik. Terraform modules `terraform-aws-modules/vpc` 6.x and `terraform-aws-modules/eks` 21.x.

**Cost:** unlike guides 1 and 2, this one is not free. The cluster bills about 0.23 USD an hour (roughly 5 to 6 USD a day) from the moment it exists until you destroy it. The guide sets a budget alarm before creating anything and makes teardown a task of its own.

---

## How to use this guide

Work top to bottom. Every task has a **Goal**, a **Why** where a choice could have gone another way, and a **Validate** block with the command and the output you should see. Do not move on until Validate passes.

Sections are separate parts of the system. Phases are milestones inside a section. Tasks are single actions, numbered `Task <section>.<phase>.<n>`.

Section 14 changes the live local setup, so it is written to be zero downtime. Read its primer before touching anything.

### Where commands run

The workspace is several directories and three separate Git repos, so a command that works in one place does nothing, or the wrong thing, in another. Every command block that depends on location **starts with an explicit `cd`**. A block with no `cd` only talks to a cluster or to AWS, so it runs from any directory.

| Name | Resolves to | Notes |
|------|-------------|-------|
| `$PLATFORM_HOME` | the project root | Set in guide 1, Task 1.2.1. **Not** a Git repo. Holds `docs/`, the trackers and `.tmp/`, which is gitignored here. |
| `$PLATFORM_HOME/lfi-infrastructure-gitops` | the GitOps repo | Its own Git repo. Holds `kubernetes/`, `argocd/`, `terraform/`, `scripts/` and the `Makefile`, so `gmake` runs here. |
| `$PLATFORM_HOME/lfi-service-1-app`, `lfi-service-2-app` | the service repos | Their own Git repos. Only `.github/workflows/ci.yaml` is touched. |

**Why `.tmp/` matters.** Scratch files go in `$PLATFORM_HOME/.tmp/`, which the root `.gitignore` covers. The GitOps repo does **not** ignore `.tmp/`, so a scratch folder created inside it shows up as an untracked change.

---

## Decisions already made

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| 1 | Cluster independence | **One ArgoCD per cluster, each pulling the same repo** | Nothing needs to know the other cluster exists. A hub ArgoCD with ApplicationSets would couple them. |
| 2 | Manifest layout | `kubernetes/overlays/local/{dev,prod}` and `kubernetes/overlays/eks/{dev,prod}` | The cluster is the first dimension, the environment the second. |
| 3 | ArgoCD layout | `argocd/apps-local` and `argocd/apps-eks` | Each cluster's root Application watches only its own directory, so neither deploys the other's apps. |
| 4 | Terraform layout | `terraform/local/` and `terraform/eks/`, one tree per cluster | Same convention as the overlays and the ArgoCD apps. The local modules are moved in Task 14.5.1, which changes no state, and nothing in the EKS tree is shared with them. |
| 5 | Nodes | **One `t3.large` in a managed node group** | Simplest to teach, no node lifecycle code. One node mirrors local. `t3.large` (2 vCPU, 8 GiB) rather than `t3.medium` because of the pod limit, not memory. See the sizing primer. |
| 6 | Environments | One EKS cluster, namespaces `platform-dev` and `platform-prod` | Mirrors local exactly. |
| 7 | Region | `ap-southeast-2` (Sydney) | One region for everything: the cluster runs in the same region as the Terraform state bucket from guide 1, so there is nothing to keep straight and nothing to migrate. Prices are the same as Singapore's. |
| 8 | Ingress controller | **Traefik via Helm on EKS** | Keeps `ingressClassName: traefik` in the base unchanged. See primer below. |
| 9 | Image tag source | **Every overlay file carries its own `newTag`. CI and `release.sh` write to all of them.** | The EKS tree stands alone and depends on nothing under `overlays/local`. The cost is a second write in both service repos' CI and in `release.sh`, added in Task 17.4.1. |
| 10 | Node subnets | Public subnets, no NAT gateway | Saves roughly 45 USD a month on a learning cluster. Trade-off documented in Task 15.2.1. |
| 11 | Commands | **A small set that asks: cluster, service, environment** | Two clusters would otherwise double the command list. Each command asks for what it needs, offers a default, and ends by suggesting what to run next. Introduced in Task 18.1.1. |

### Primer: why an ingress controller is needed at all

An `Ingress` object is inert YAML. A controller is the program that reads it and actually routes traffic. k3s ships with Traefik built in, which is why the local base manifests work with no setup. EKS ships with no controller. Without one, applying the Ingress succeeds and nothing happens, with no error.

Two ways to fix it: install Traefik on EKS so the base is unchanged (chosen), or install the AWS Load Balancer Controller and patch the ingress class to `alb`. The second creates a real ALB per Ingress and needs IAM wiring. It is the more AWS-native answer and a fine follow-up, but it makes the cloud overlay differ from local in more places.

### Primer: sizing the node

The local platform's resource requests total about 850m CPU and 1.9 GiB, and the live k3d nodes use well under that. Memory alone would fit a `t3.medium` (4 GiB), but the binding limit on AWS is **pods per node**. On EKS each pod takes a VPC IP from the instance's network interfaces, so the instance type caps the pod count: 17 for `t3.medium`, 35 for `t3.large`.

The pod count here is roughly 7 system pods (CNI, kube-proxy, CoreDNS, EBS CSI), 5 to 7 ArgoCD, 1 Rollouts, 1 Traefik, 2 Postgres, 2 dev and 4 prod service pods, plus up to 2 canary surge pods. That is about 25 and does not fit 17. One `t3.large` fits with headroom.

### Primer: the cost of leaving it on

EKS bills while it exists. Figures for ap-southeast-2 (the same as ap-southeast-1), checked in October 2026 in Task 15.1.2; confirm them again before relying on them:

| Item | Per hour | Per month |
|------|----------|-----------|
| EKS control plane (fixed, whatever the node count) | 0.10 USD | about 73 USD |
| One `t3.large` in ap-southeast-2 | about 0.11 USD | about 77 USD |
| Load balancer for Traefik | about 0.02 USD | about 16 USD |
| EBS volumes | negligible | a few USD |
| **Total** | **about 0.23 USD** | **about 165 USD** |

So roughly 5 to 6 USD a day. The control plane is the largest single line and is fixed, so a one-node cluster is not much cheaper than a bigger one. That is why teardown matters more than node count. Section 18 makes teardown a first-class step. Set the budget alarm in Task 15.1.3 before creating anything.

---

## Section 14: Restructure for two targets

**Why this section exists.** Today the cluster is implicit. The paths `kubernetes/overlays/dev`, `kubernetes/overlays/prod` and `argocd/apps` all mean "local". Adding EKS needs the cluster to become an explicit part of the path.

### Primer: why a plain `git mv` is dangerous here

The local root Application watches `argocd/apps` with `prune: true`. If that directory vanishes from Git before the root is pointed elsewhere, ArgoCD sees every child Application as deleted and prunes them, cascading to the workloads. Postgres is the one that hurts.

The safe order is therefore **add new, repoint, then delete old**, never move. At every step the live cluster has a valid source.

Paths hardcoded outside this repo that must change in the cutover: both service repos' `ci.yaml` (`kubernetes/overlays/dev/...`), `scripts/release.sh`, `.github/CODEOWNERS`, the root Application template, and every child Application's `source.path`.

### Phase 14.1: Preflight

#### Task 14.1.1: Prove the local cluster is healthy

**Goal:** A known-good baseline, so any later breakage is attributable.

If the cluster is not running (`kubectl config get-contexts k3d-platform` prints nothing), bring it up first. This takes several minutes, and ArgoCD needs up to a few more to sync everything:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake up
```

**Validate:**
```bash
kubectl --context k3d-platform -n argocd get applications
```
Expected: `root` plus six children, all `Synced` and `Healthy`.

#### Task 14.1.2: Snapshot the rendered manifests

**Goal:** A byte-for-byte record of what each overlay renders today, to diff against after the restructure.

```bash
cd "$PLATFORM_HOME"
mkdir -p .tmp/render-before
for env in dev prod; do for svc in service-1 service-2 postgres; do
  kustomize build "lfi-infrastructure-gitops/kubernetes/overlays/$env/$svc" > ".tmp/render-before/$env-$svc.yaml"
done; done
```

**Validate:**
```bash
cd "$PLATFORM_HOME"
ls .tmp/render-before | wc -l
find .tmp/render-before -empty
```
Expected: `6`, and no output from `find`.

#### Task 14.1.3: Work on a branch

**Goal:** Nothing in this section lands on `main` until validated.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch -c feat/eks-counterpart
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git branch --show-current
```
Expected: `feat/eks-counterpart`.

### Phase 14.2: Build the new paths beside the old

#### Task 14.2.1: Copy overlays to `overlays/local`

**Goal:** `kubernetes/overlays/local/{dev,prod}/<svc>` exists and old paths still exist.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
mkdir -p kubernetes/overlays/local/dev kubernetes/overlays/local/prod
cp -R kubernetes/overlays/dev/.  kubernetes/overlays/local/dev/
cp -R kubernetes/overlays/prod/. kubernetes/overlays/local/prod/
sed -i '' 's#\.\./\.\./\.\./base/#../../../../base/#' kubernetes/overlays/local/*/*/kustomization.yaml
```

The trailing `/.` copies the directory's *contents* into the existing destination, so rerunning is harmless. Plain `cp -R overlays/dev overlays/local/dev` on a second run would nest a `dev` inside `dev`.

Copy, do not move: the live Applications still point at `overlays/dev` and `overlays/prod`. The overlays use `../../../base/...` relative paths, which gain one level, so each `resources:` entry becomes `../../../../base/<svc>`. Skip the `sed` and every build fails, because `../../../base` now resolves to `kubernetes/overlays/base`.

**Validate:** the rendered output is identical to the snapshot. This loop reports a failed build explicitly, because an empty snapshot and a failed build would otherwise both diff as "identical":
```bash
cd "$PLATFORM_HOME"
for env in dev prod; do for svc in service-1 service-2 postgres; do
  out=$(kustomize build "lfi-infrastructure-gitops/kubernetes/overlays/local/$env/$svc") \
    || { echo "$env/$svc BUILD FAILED"; continue; }
  [ -s ".tmp/render-before/$env-$svc.yaml" ] || { echo "$env/$svc SNAPSHOT EMPTY"; continue; }
  diff <(echo "$out") ".tmp/render-before/$env-$svc.yaml" >/dev/null && echo "$env/$svc identical" || echo "$env/$svc DIFFERS"
done; done
```
Expected: six `identical` lines. Any `BUILD FAILED`, `SNAPSHOT EMPTY` or `DIFFERS` line means stop and fix it first.

#### Task 14.2.2: Create `argocd/apps-local`

**Goal:** In the GitOps repo, a copy of `argocd/apps/{dev,prod}` whose `source.path` fields point at `kubernetes/overlays/local/...`. Application names stay **identical** to the old ones.

**Why:** same names means ArgoCD treats the cutover as an in-place update of existing Applications rather than a delete and recreate.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
mkdir -p argocd/apps-local
cp -R argocd/apps/. argocd/apps-local/
sed -i '' -E 's#path: kubernetes/overlays/(dev|prod)/#path: kubernetes/overlays/local/\1/#' argocd/apps-local/*/*.yaml
```

Copy, do not move, for the same reason as Task 14.2.1: the live root Application still watches `argocd/apps`. The `sed` rewrites only the `source.path` line. Application names are untouched.

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
yq -N '.spec.source.path' argocd/apps-local/*/*.yaml | sort | uniq -c
yq -N '.metadata.name' argocd/apps-local/*/*.yaml | sort > /tmp/new-names
yq -N '.metadata.name' argocd/apps/*/*.yaml | sort > /tmp/old-names
diff /tmp/new-names /tmp/old-names && echo names-identical
```
Expected: six paths all under `kubernetes/overlays/local/`, and `names-identical`.

### Phase 14.3: Cutover

This guide merges to `main` locally and pushes `main` directly, with no pull requests. Each block works on a feature branch, then merges it with `--no-ff` so the history keeps an explicit merge commit, then pushes. If you later turn on branch protection that blocks direct pushes to `main`, switch back to pull requests.

`gh` is still used by `gmake release`, which opens a PR on purpose, because the release PR is the prod gate. If `gh` ever fails with `HTTP 401: Bad credentials`, an invalid `GITHUB_TOKEN` exported from `~/.zshrc` is the cause. Check with `gh auth status`, then `unset GITHUB_TOKEN` in the terminal or prefix `gh` with `env -u GITHUB_TOKEN`.

#### Task 14.3.1: Commit and merge the additive change

**Goal:** `main` of the GitOps repo contains both old and new paths. The live cluster is still reading the old ones and does not change.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git status --short
```
Expected: only `kubernetes/overlays/local/` and `argocd/apps-local/` appear, as untracked. Anything else means stop and find out why.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git add kubernetes/overlays/local argocd/apps-local
git commit -m "feat: add overlays/local and argocd/apps-local beside the old paths"
git switch main
git pull --ff-only
git merge --no-ff feat/eks-counterpart -m "Merge feat/eks-counterpart"
git push origin main
```
**Stop here if `git merge` reports a conflict or `git push` is rejected.** Your work is safe on the branch and nothing has been deleted. (A rejection by branch protection means `main` does not accept direct pushes. That is a repository setting to change deliberately, not to work around.) Do not touch the branch until the push of `main` has succeeded.

Then keep the branch on the remote and remove the local copy:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git push -u origin feat/eks-counterpart
git branch -d feat/eks-counterpart
git status -sb | head -1
git ls-remote --heads origin feat/eks-counterpart
```
Expected: `git branch -d` reports the branch deleted, the status line is `## main...origin/main` with no `ahead` or `behind`, and `ls-remote` prints one line for the branch. The remote branch is your record of the work, and the local one is no longer needed.

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git ls-files kubernetes/overlays argocd | sed -E 's#/[^/]+/kustomization.yaml$##; s#/[^/]+\.yaml$##' | sort -u
kubectl --context k3d-platform -n argocd get applications
```
Expected: the file list shows both `overlays/dev`, `overlays/prod`, `overlays/local/...` and both `argocd/apps/...`, `argocd/apps-local/...`. The Applications are unchanged from Task 14.1.1.

#### Task 14.3.2: Repoint the root Application

**Goal:** The root Application watches `argocd/apps-local`.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch -c feat/local-cutover
sed -i '' 's#path: argocd/apps$#path: argocd/apps-local#; s#argocd/apps now contains#argocd/apps-local contains#' \
  terraform/02-platform/bootstrap/root-app.yaml.tftpl
git diff --stat
```
Expected: one file, `root-app.yaml.tftpl`, with a one or two line change.

Terraform reads the working tree, so you apply before committing:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake platform-up
```
The template content hash changes, so Terraform re-applies the root Application.

**Validate:**
```bash
kubectl --context k3d-platform -n argocd get application root -o jsonpath='{.spec.source.path}{"\n"}'
kubectl --context k3d-platform -n argocd get applications
kubectl --context k3d-platform -n platform-prod get pods
```
Expected: `argocd/apps-local`, all six children still `Synced` and `Healthy`, and Postgres pods **with the same age as before** (they were not recreated). Give ArgoCD up to the 3 minute poll if a child briefly shows `OutOfSync`.

#### Task 14.3.3: Repoint the writers

**Goal:** Everything that writes or reads overlay paths targets `overlays/local`. Do the GitOps repo first, then the service repos.

You are still on `feat/local-cutover`. Edit `scripts/release.sh` and `.github/CODEOWNERS`:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
sed -i '' -E 's#kubernetes/overlays/(dev|prod)#kubernetes/overlays/local/\1#g' scripts/release.sh
sed -i '' -E 's#^(/kubernetes/overlays/)(prod|dev)/#\1local/\2/#; s#^\# (/kubernetes/overlays/)dev/#\# \1local/dev/#' .github/CODEOWNERS
git diff scripts/release.sh .github/CODEOWNERS | grep '^[+-]' | grep -v '^+++\|^---'
bash -n scripts/release.sh && echo syntax-ok
```
Expected: four changed lines in `release.sh`, two in `CODEOWNERS`, and `syntax-ok`.

Commit, merge, and update `main`:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git add terraform/02-platform/bootstrap/root-app.yaml.tftpl scripts/release.sh .github/CODEOWNERS
git commit -m "feat: point root app, release script and CODEOWNERS at overlays/local"
git switch main
git pull --ff-only
git merge --no-ff feat/local-cutover -m "Merge feat/local-cutover"
git push origin main
```
**Stop here if `git merge` reports a conflict or `git push` is rejected.** Your work is safe on the branch and nothing has been deleted. (A rejection by branch protection means `main` does not accept direct pushes. That is a repository setting to change deliberately, not to work around.) Do not touch the branch until the push of `main` has succeeded.

Then keep the branch on the remote and remove the local copy:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git push -u origin feat/local-cutover
git branch -d feat/local-cutover
git status -sb | head -1
git ls-remote --heads origin feat/local-cutover
```
Expected: `git branch -d` reports the branch deleted, the status line is `## main...origin/main` with no `ahead` or `behind`, and `ls-remote` prints one line for the branch. The remote branch is your record of the work, and the local one is no longer needed.

Then the two service repos. Do this immediately and not while a build is in flight: CI retries on a missing path, then fails.
```bash
cd "$PLATFORM_HOME/lfi-service-1-app"
git switch main && git pull --ff-only
sed -i '' 's#kubernetes/overlays/dev/#kubernetes/overlays/local/dev/#' .github/workflows/ci.yaml
git diff --stat
git add .github/workflows/ci.yaml
git commit -m "ci: write the image tag to overlays/local/dev"
git push
```
```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
git switch main && git pull --ff-only
sed -i '' 's#kubernetes/overlays/dev/#kubernetes/overlays/local/dev/#' .github/workflows/ci.yaml
git diff --stat
git add .github/workflows/ci.yaml
git commit -m "ci: write the image tag to overlays/local/dev"
git push
```
The `git push` of a workflow change itself triggers a CI run. That run is your validation.

**Validate:** once the service-1 run finishes (watch it with `gh run watch` from `lfi-service-1-app`):
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git pull --ff-only
git log -1 --stat -- kubernetes/overlays/local/dev/service-1/kustomization.yaml
kubectl --context k3d-platform -n argocd get application service-1-dev
```
Expected: a fresh `deploy(service-1)` commit touching only the `overlays/local/dev` path, and `service-1-dev` `Synced`. If the run did not change the tag (the build was already current), push an empty-change commit such as a README tweak in `lfi-service-1-app` to force a new build.

### Phase 14.4: Remove the old paths

#### Task 14.4.1: Delete `overlays/dev`, `overlays/prod`, `argocd/apps`

**Goal:** One location for each fact. The cluster already reads only the new ones, so this changes nothing live.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch main && git pull --ff-only
git switch -c feat/remove-old-paths
git rm -r kubernetes/overlays/dev kubernetes/overlays/prod argocd/apps
git commit -m "chore: remove the pre-restructure overlay and app paths"
git switch main
git pull --ff-only
git merge --no-ff feat/remove-old-paths -m "Merge feat/remove-old-paths"
git push origin main
```
**Stop here if `git merge` reports a conflict or `git push` is rejected.** Your work is safe on the branch and nothing has been deleted. (A rejection by branch protection means `main` does not accept direct pushes. That is a repository setting to change deliberately, not to work around.) Do not touch the branch until the push of `main` has succeeded.

Then keep the branch on the remote and remove the local copy:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git push -u origin feat/remove-old-paths
git branch -d feat/remove-old-paths
git status -sb | head -1
git ls-remote --heads origin feat/remove-old-paths
```
Expected: `git branch -d` reports the branch deleted, the status line is `## main...origin/main` with no `ahead` or `behind`, and `ls-remote` prints one line for the branch. The remote branch is your record of the work, and the local one is no longer needed.

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
ls kubernetes/overlays argocd
kubectl --context k3d-platform -n argocd get applications
```
Expected: `kubernetes/overlays` shows only `local`, `argocd` shows only `apps-local`, and all Applications still `Synced` and `Healthy` after the next poll.

#### Task 14.4.2: Re-run the release path end to end

**Goal:** Confirm the gated promotion still works after the move.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake release
```

**Validate:** either `Nothing to release: prod already matches dev.` (then make a dev change first by pushing a service change, wait for dev to update, and rerun), or a PR whose diff touches exactly one line per changed service, all under `kubernetes/overlays/local/prod/`. Close or merge that PR as you prefer. (Extending this to the EKS tree is Task 17.4.1.)

### Phase 14.5: Move the local Terraform

The manifests and the ArgoCD apps now say `local`. The Terraform should too, so each cluster has one directory per layer and the EKS modules in Section 15 have an obvious sibling: `terraform/local/` and `terraform/eks/`.

**Why this is safe.** Terraform state lives in S3 under keys fixed in each `backend.tf` (`local-platform/01-cluster/...` and `local-platform/02-platform/...`), not under anything derived from the folder, so moving the folder does not touch state. The modules refer to their own files through `${path.module}`, which is `.` when you run Terraform from inside the module, so no file path inside them changes either. The untracked `.terraform/` and `.generated/` folders move along with the directory.

#### Task 14.5.1: Move the local Terraform under `terraform/local`

**Goal:** `terraform/local/01-cluster` and `terraform/local/02-platform` exist, `terraform/01-cluster` and `terraform/02-platform` do not, and both modules still plan with no changes.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch main && git pull --ff-only
git switch -c feat/terraform-local
mkdir -p terraform/local
git mv terraform/01-cluster  terraform/local/01-cluster
git mv terraform/02-platform terraform/local/02-platform
```

Point the Makefile at the new paths. Four recipe lines and one comment mention them:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
sed -i '' 's#terraform/01-cluster#terraform/local/01-cluster#g; s#terraform/02-platform#terraform/local/02-platform#g' Makefile
grep -n 'terraform/' Makefile
```
Expected: every `terraform/` path in the Makefile now reads `terraform/local/...`, except the EKS targets you add in Task 18.1.1, which use `terraform/eks/...`. Then look for any other mention in the repo:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
grep -rnE 'terraform/0[12]-' . --exclude-dir=.git --exclude-dir=.terraform
```
Expected: no output. Anything listed is a stale path to fix.

**Validate:** the Makefile resolves, and neither module sees a change. The local cluster must be running for the second module, because its providers connect to it.
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake -n up | grep 'cd terraform'
ls terraform terraform/local
```
Expected: two `cd terraform/local/...` lines, and `terraform` lists only `local` (plus `eks` once Section 15 has created it).

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops/terraform/local/01-cluster"
terraform init -input=false
terraform plan -detailed-exitcode -input=false; echo "exit=$?"
```
Expected: `No changes.` and `exit=0`. Exit `2` means Terraform wants to change something, which the move should never cause, so stop and read the plan.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
set -a; source .env; set +a
export TF_VAR_postgres_user="$POSTGRES_USER"
export TF_VAR_postgres_password_dev="$POSTGRES_PASSWORD_DEV"
export TF_VAR_postgres_password_prod="$POSTGRES_PASSWORD_PROD"
export TF_VAR_postgres_db="$POSTGRES_DB"
export TF_VAR_gitops_repo_url="$GITOPS_REPO_URL"
cd terraform/local/02-platform
terraform init -input=false
terraform plan -detailed-exitcode -input=false; echo "exit=$?"
```
Expected: `No changes.` and `exit=0`.

Commit, merge and clean up the branch:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git add -A terraform Makefile
git status --short
git commit -m "chore: move the local Terraform under terraform/local"
git switch main
git pull --ff-only
git merge --no-ff feat/terraform-local -m "Merge feat/terraform-local"
git push origin main
```
Check `git status --short` before committing: it should show renames (`R`) for the moved files and a change to `Makefile`, and nothing under `.terraform` or `.generated`. **Stop here if `git merge` reports a conflict or `git push` is rejected.** Do not touch the branch until the push of `main` has succeeded. Then keep the branch on the remote and remove the local copy:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git push -u origin feat/terraform-local
git branch -d feat/terraform-local
git status -sb | head -1
git ls-remote --heads origin feat/terraform-local
```
Expected: `git branch -d` reports the branch deleted, the status line is `## main...origin/main` with no `ahead` or `behind`, and `ls-remote` prints one line for the branch.

> **What just happened.** The cluster is now an explicit dimension in the repo, the local platform never stopped serving, and nothing yet mentions AWS.

---

## Section 15: EKS infrastructure

Lives in `lfi-infrastructure-gitops/terraform/eks/01-cluster`. Same two-module split as local, for the same reason: the `kubernetes` and `helm` providers need a reachable cluster at plan time, so the cluster is created in one module and configured in the next.

### Phase 15.1: Prerequisites and guardrails

#### Task 15.1.1: AWS access

**Goal:** A working CLI profile whose default region is `ap-southeast-2`.

```bash
aws configure list-profiles
export AWS_PROFILE=<the profile you want>
aws configure set region ap-southeast-2 --profile "$AWS_PROFILE"
```
This guide assumes an IAM user with access keys. If the profile has no keys yet, run `aws configure --profile "$AWS_PROFILE"` and paste them in; there is no login step after that. Confirm with `aws sts get-caller-identity`. Add the `export AWS_PROFILE=...` line to `~/.zshrc` so Terraform sees it in every terminal.

**Validate:**
```bash
aws sts get-caller-identity --query Arn --output text
aws configure get region --profile "$AWS_PROFILE"
```
Expected: an ARN, and `ap-southeast-2`. Do not paste the account ID into any tracked file.

#### Task 15.1.2: Verify module, chart and Kubernetes versions, and prices

**Goal:** Pinned versions you have confirmed exist, same discipline as Task 1.1.3 in guide 1. A yanked or renamed version fails halfway through an apply, which is a worse place to discover it.

```bash
cd "$PLATFORM_HOME"
for m in vpc eks; do
  printf '%s module: ' "$m"
  curl -s "https://registry.terraform.io/v1/modules/terraform-aws-modules/$m/aws" | jq -r .version
done
aws eks describe-cluster-versions --region ap-southeast-2 \
  --query 'clusterVersions[?status==`STANDARD_SUPPORT`].clusterVersion' --output text
helm repo add traefik https://traefik.github.io/charts
helm repo update traefik
helm search repo traefik/traefik --versions | head -5
```
Record the results in `$PLATFORM_HOME/.tmp/eks-versions.txt` (the root `.tmp/` is gitignored).

**Major versions matter.** The Terraform in Section 15 is written against `terraform-aws-modules/vpc` **6.x** and `terraform-aws-modules/eks` **21.x**, and against the AWS provider **6.x**. That is what the registry reports as latest, and this guide was checked against the module source at the exact versions `6.7.3` and `21.26.0`. A later minor release in the same major should work. A new major will probably rename inputs again (the 21 release renamed `cluster_name` to `name`, `cluster_version` to `kubernetes_version`, `cluster_addons` to `addons`, and `cluster_endpoint_public_access` to `endpoint_public_access`), so re-read the module's variables before moving to it. The module source and its `examples/` directory on GitHub are the reference.

**What pinning means here.** `eks-versions.txt` is only your record of what you checked. The pin is the version written in the Terraform itself, and three things need it:

| What | Where it is pinned | Locked by a file? |
|---|---|---|
| VPC and EKS modules | the `version = "..."` line in each `module` block | No. Only the line itself holds it. |
| AWS provider | the `required_providers` constraint, plus the generated `.terraform.lock.hcl` | Yes. Commit the lock file. |
| Traefik chart | the `traefik_chart_version` variable default (Section 16) | No. Only the default holds it. |
| Kubernetes version | the `kubernetes_version` variable default | No. |

The code blocks in this guide already carry the versions you recorded (`6.7.3`, `21.26.0`, `41.6.1`). The Kubernetes version is pinned the same way, to `1.36`.

Also confirm the hourly prices in the cost primer against the AWS pricing page for ap-southeast-2 (EKS control plane, `t3.large` on-demand Linux, Network Load Balancer), and correct the primer if they differ.

**Validate:** `cat "$PLATFORM_HOME/.tmp/eks-versions.txt"` shows five values with a source for each: the vpc module, the eks module, the Kubernetes version, the Traefik chart version and the date you checked prices.

#### Task 15.1.3: Budget alarm before any resource exists

**Goal:** An email when actual monthly spend crosses 80 percent of 50 USD.

**Why first:** this is the control that protects you from the failure mode of this whole guide, forgetting the cluster.

```bash
cd "$PLATFORM_HOME"
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export ALERT_EMAIL="<your email>"

cat > .tmp/budget.json <<'EOF'
{
  "BudgetName": "lfi-eks-monthly",
  "BudgetLimit": { "Amount": "50", "Unit": "USD" },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
EOF

cat > .tmp/budget-notifications.json <<EOF
[
  {
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 80,
      "ThresholdType": "PERCENTAGE"
    },
    "Subscribers": [ { "SubscriptionType": "EMAIL", "Address": "$ALERT_EMAIL" } ]
  }
]
EOF

aws budgets create-budget --account-id "$ACCOUNT_ID" \
  --budget file://.tmp/budget.json \
  --notifications-with-subscribers file://.tmp/budget-notifications.json
```
The email address stays in the ignored `.tmp/` and never enters a tracked file.

**Validate:**
```bash
aws budgets describe-budgets --account-id "$(aws sts get-caller-identity --query Account --output text)" --query 'Budgets[].BudgetName'
```
Expected: `lfi-eks-monthly` is listed.

#### Task 15.1.4: Confirm the images are pullable from AWS

**Goal:** EKS nodes can pull `ghcr.io/<you>/service-1` and `service-2` with no credentials, or you know to add an image pull secret.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
TAG="$(yq '.images[0].newTag' kubernetes/overlays/local/prod/service-1/kustomization.yaml)"
docker logout ghcr.io
docker pull "ghcr.io/YOUR_GITHUB_USER/service-1:$TAG"
```

**Validate:** the pull succeeds with no login. If it reports `denied` or `unauthorized`, the package is private: either make it public in GitHub (Packages, Package settings) or plan an `imagePullSecret` before Section 17.

### Phase 15.2: Network and cluster

All files in this phase go in `lfi-infrastructure-gitops/terraform/eks/01-cluster/`.

#### Task 15.2.1: Provider, backend and VPC

**Goal:** A VPC with public subnets in two availability zones, no NAT gateway, planned but not yet applied.

**Why public subnets:** a NAT gateway is the single largest fixed cost after the control plane. Nodes in public subnets with a locked-down security group are acceptable for a learning cluster and not for anything holding real data. Moving to private subnets later is a Terraform change, not a redesign.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
mkdir -p terraform/eks/01-cluster
```

**File:** `terraform/eks/01-cluster/backend.tf`

```hcl
# Same bucket as the local modules, different key. The bucket and the cluster
# are both in ap-southeast-2. The backend region is where the state is stored
# and the provider region is where resources are created. They are separate
# settings that happen to agree here, so a change to one does not move the other.
terraform {
  backend "s3" {
    bucket       = "tfstate-YOUR_GITHUB_USER-local-platform"
    key          = "lfi-eks/01-cluster/terraform.tfstate"
    region       = "ap-southeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
```

**File:** `terraform/eks/01-cluster/variables.tf`

```hcl
variable "region" {
  type        = string
  description = "Region the cluster runs in."
  default     = "ap-southeast-2"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name. The kube context alias is set to the same value."
  default     = "lfi-eks"
}

variable "kubernetes_version" {
  type        = string
  description = "EKS Kubernetes version, from Task 15.1.2."
  # The version recorded in Task 15.1.2: 1.36, in standard support until 2027-08.
  default     = "1.36"
}
```

**File:** `terraform/eks/01-cluster/main.tf`

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # The EKS module 21.x needs 6.59 or later, the VPC module 6.x needs 6.28.
      version = ">= 6.59, < 7.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Two AZs because the EKS control plane requires subnets in at least two.
# The node group below will use only the first one, see Task 15.2.2.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  # Pinned exactly, to the version recorded in Task 15.1.2. Modules are not
  # covered by the .terraform.lock.hcl file (only providers are), so this line
  # is the only thing that keeps a later init from fetching a newer release.
  version = "6.7.3"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs            = ["${var.region}a", "${var.region}b"]
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

  # No private subnets and no NAT gateway: see the Why above.
  enable_nat_gateway      = false
  enable_dns_hostnames    = true
  map_public_ip_on_launch = true

  # Tells Kubernetes which subnets may hold internet-facing load balancers.
  # Without it, Traefik's Service sits at <pending> forever.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
}
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops/terraform/eks/01-cluster"
terraform init -input=false
terraform plan -input=false -out=/dev/null | grep -E 'aws_nat_gateway|Plan:'
```
Expected: a `Plan:` line, and **no** `aws_nat_gateway` line. The plan creates the VPC, two subnets, route table, route table associations and an internet gateway.

#### Task 15.2.2: EKS cluster and managed node group

**Goal:** Control plane plus a managed node group of one `t3.large`, applied.

**Why not `t3.medium`:** the pod limit, not memory. See the sizing primer.

**Why the node group uses one subnet:** an EBS volume exists in a single availability zone. If the one node is ever replaced and lands in the other zone, the Postgres volumes cannot attach and the pods sit `Pending`. Pinning the node group to the first subnet makes replacement stay in the same zone.

**File:** `terraform/eks/01-cluster/eks.tf`

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  # Pinned exactly, for the same reason as the VPC module above.
  version = "21.26.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id = module.vpc.vpc_id
  # Nodes go here, and the control plane's network interfaces too, which need
  # two AZs. The node group below narrows the nodes to one of them.
  subnet_ids = module.vpc.public_subnets

  # kubectl from your Mac has to reach the API server. The module default is
  # private only, which would leave you unable to connect.
  endpoint_public_access = true
  # The identity that creates the cluster becomes an admin of it. The module
  # default is false, and then you create a cluster you cannot log into.
  enable_cluster_creator_admin_permissions = true

  addons = {
    coredns = {}
    # Lets pods receive AWS permissions through the EKS Pod Identity feature.
    # Task 15.3.1 uses it for the EBS driver, so it has to be running first.
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    # Networking has to exist before a node can become Ready, hence before
    # the node group is created.
    vpc-cni = {
      before_compute = true
    }
  }

  eks_managed_node_groups = {
    main = {
      instance_types = ["t3.large"]
      ami_type       = "AL2023_x86_64_STANDARD"
      min_size       = 1
      max_size       = 1
      # The module ignores changes to this after the first apply.
      desired_size = 1
      # One subnet, so one AZ. See the Why above.
      subnet_ids = [module.vpc.public_subnets[0]]
    }
  }
}
```

**File:** `terraform/eks/01-cluster/outputs.tf`

```hcl
output "cluster_name" {
  value = module.eks.cluster_name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}"
}
```

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops/terraform/eks/01-cluster"
terraform init -input=false -upgrade
terraform apply
```
Review the plan, then type `yes`. The apply takes 10 to 15 minutes. **From here the meter is running.**

```bash
aws eks update-kubeconfig --region ap-southeast-2 --name lfi-eks --alias lfi-eks
```

**Validate:**
```bash
kubectl --context lfi-eks get nodes \
  -o custom-columns='NAME:.metadata.name,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,PODS:.status.allocatable.pods,READY:.status.conditions[-1].type'
```
Expected: one node, type `t3.large`, allocatable pods `35`, `Ready`.

#### Task 15.2.3: State in S3

**Goal:** State under its own key in the existing bucket.

**Validate:**
```bash
aws s3 ls s3://tfstate-YOUR_GITHUB_USER-local-platform/lfi-eks/ --recursive
```
Expected: `lfi-eks/01-cluster/terraform.tfstate` is listed. Also confirm no `terraform.tfstate` file was left in the module directory: `ls "$PLATFORM_HOME/lfi-infrastructure-gitops/terraform/eks/01-cluster"` shows no `*.tfstate`.

### Phase 15.3: Storage

#### Task 15.3.1: EBS CSI driver

**Goal:** The cluster can provision EBS volumes for PVCs.

EKS does not provision EBS volumes on its own. The EBS CSI driver does, and it needs AWS permissions to create and attach volumes.

**Why Pod Identity and not the node's role.** The obvious shortcut is to attach the EBS policy to the node group's role. It does not work here: the module sets the node's metadata service to require tokens with a hop limit of 1, so a pod cannot reach the node's credentials. The driver would start and then fail with permission errors the first time a PVC needs a volume. Pod Identity gives the driver's own service account a role instead, which is also the better practice.

**File:** `terraform/eks/01-cluster/ebs-csi.tf`

```hcl
# The role the EBS CSI driver's pods assume. The trust policy names the
# EKS Pod Identity service, not an OIDC provider.
data "aws_iam_policy_document" "ebs_csi_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_trust.json
}

# AWS maintains this policy. It is scoped to what the driver needs.
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
```

Then add the addon inside the `addons` block of `eks.tf`, next to `coredns`:

```hcl
    aws-ebs-csi-driver = {
      # Binds the role above to the driver's service account in kube-system.
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
```
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops/terraform/eks/01-cluster"
terraform apply
```

**Validate:**
```bash
kubectl --context lfi-eks -n kube-system get pods -l app.kubernetes.io/name=aws-ebs-csi-driver
```
Expected: the controller pods and one node pod, all `Running`. The `gp3` StorageClass itself is created in Section 16, because it needs the Kubernetes provider.

> **What just happened.** You have an empty, correctly provisioned cluster that nothing deploys to yet. `terraform destroy` here would leave nothing behind.

---

## Section 16: EKS platform bootstrap

Lives in `lfi-infrastructure-gitops/terraform/eks/02-platform`. It reuses the local module's shape and removes the k3d specifics.

### Phase 16.1: Platform module

#### Task 16.1.1: Copy the local module and remove the k3d pieces

**Goal:** `terraform/eks/02-platform` exists, validates, and has not been applied.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch main && git pull --ff-only
git switch -c feat/eks-platform
mkdir -p terraform/eks/02-platform
rsync -a --exclude .terraform --exclude .terraform.lock.hcl --exclude .generated --exclude '*.tfstate*' \
  terraform/local/02-platform/ terraform/eks/02-platform/
```
Then make four edits.

1. **State key.**
   ```bash
   cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
   sed -i '' 's#local-platform/02-platform#lfi-eks/02-platform#' terraform/eks/02-platform/backend.tf
   grep key terraform/eks/02-platform/backend.tf
   ```
   Expected: `key = "lfi-eks/02-platform/terraform.tfstate"`.

2. **Root Application path.** This must be done **before the first apply**. The copied template says `argocd/apps-local`, and applying it as is would make the EKS cluster deploy the local apps.
   ```bash
   cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
   sed -i '' 's#path: argocd/apps-local#path: argocd/apps-eks#; s#argocd/apps-local contains#argocd/apps-eks contains#' \
     terraform/eks/02-platform/bootstrap/root-app.yaml.tftpl
   grep -n 'apps-' terraform/eks/02-platform/bootstrap/root-app.yaml.tftpl
   ```
   Expected: lines mention `apps-eks` only.

3. **Kube context default.** In `terraform/eks/02-platform/variables.tf`, change the `kube_context` default from `"k3d-platform"` to `"lfi-eks"`, and change its description to match.

4. **Remove the localhost ingress for ArgoCD.** In `terraform/eks/02-platform/main.tf`, delete everything from the comment line `# Reach ArgoCD through the Traefik ingress that already fronts the cluster on` down to and including the closing `}` of `resource "kubernetes_ingress_v1" "argocd_server"`, which ends just before the comment `# Rendered to disk rather than piped inline`. Then in `variables.tf` delete the whole `variable "argocd_host"` block, which nothing uses any more.

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops/terraform/eks/02-platform"
grep -c kubernetes_ingress_v1 main.tf
grep -c argocd_host main.tf variables.tf
terraform init -input=false
terraform validate
```
Expected: `0`, `0` for both files, and `Success! The configuration is valid.`

#### Task 16.1.2: Guard the context

**Goal:** An apply meant for EKS can never land on k3d, and the reverse.

**Why:** the existing module pins `config_context` for exactly this reason. A `validation` block goes further: it refuses at plan time, before Terraform reads any cluster state.

In `terraform/eks/02-platform/variables.tf`, replace the `kube_context` block with:

```hcl
variable "kube_context" {
  type        = string
  description = "kubectl context to target. Pinned to the EKS cluster."
  default     = "lfi-eks"

  validation {
    condition     = var.kube_context == "lfi-eks"
    error_message = "This module only targets the lfi-eks context. Refusing to plan against another cluster."
  }
}
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops/terraform/eks/02-platform"
terraform plan -input=false -var kube_context=k3d-platform 2>&1 | grep -A2 'Invalid value'
```
Expected: an `Invalid value for variable` error carrying your message. (If it complains first about missing `postgres_*` variables, set dummy ones for this check: `-var postgres_user=x -var postgres_db=x -var postgres_password_dev=x -var postgres_password_prod=y -var gitops_repo_url=x`.)

#### Task 16.1.3: gp3 StorageClass

**Goal:** A `gp3` StorageClass backed by the EBS CSI driver, set as the default.

**Why `reclaimPolicy: Delete`:** on a learning cluster you want `terraform destroy` to remove the volumes, not leave billing orphans. For real data you would choose `Retain`.

Append to `terraform/eks/02-platform/main.tf`:

```hcl
# EKS ships a default class named gp2 using the old in-tree driver. Demote it
# so the class below is the only default.
resource "kubernetes_annotations" "gp2_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }
  force = true
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  # Wait until a pod is scheduled, so the volume is created in the same AZ as
  # the node that will use it.
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type = "gp3"
  }

  depends_on = [kubernetes_annotations.gp2_not_default]
}
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops/terraform/eks/02-platform"
terraform validate
```
Expected: `Success! The configuration is valid.` The StorageClass is created in Task 16.3.1.

### Phase 16.2: Ingress

#### Task 16.2.1: Traefik via Helm

**Goal:** Traefik with an `IngressClass` named `traefik`, fronted by an AWS Network Load Balancer, defined and ready to apply.

**File:** `terraform/eks/02-platform/values/traefik.yaml`

```yaml
# Registers an IngressClass named "traefik", which is what the base
# manifests ask for with ingressClassName: traefik.
ingressClass:
  enabled: true
  isDefaultClass: true

service:
  type: LoadBalancer
  annotations:
    # Without this the in-tree cloud provider creates a Classic ELB. An NLB is
    # cheaper and is what the validation commands in this guide expect.
    service.beta.kubernetes.io/aws-load-balancer-type: nlb

# Report the load balancer address on Ingress status objects, so
# `kubectl get ingress` shows where traffic should go.
providers:
  kubernetesIngress:
    publishedService:
      enabled: true

# Same discipline as the ArgoCD values: say what you reserve.
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    memory: 192Mi
```

Add a variable to `variables.tf`, using the chart version you recorded in Task 15.1.2:

```hcl
variable "traefik_chart_version" {
  type        = string
  description = "Pinned traefik Helm chart version, from Task 15.1.2."
  # The version recorded in Task 15.1.2. A Helm chart has no lock file either.
  default     = "41.6.1"
}
```

Append to `main.tf`:

```hcl
resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.traefik_chart_version
  namespace        = "traefik"
  create_namespace = true

  wait    = true
  timeout = 300

  values = [file("${path.module}/values/traefik.yaml")]
}
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops/terraform/eks/02-platform"
terraform validate
helm show values traefik/traefik --version "$(grep -A3 traefik_chart_version variables.tf | grep default | cut -d'"' -f2)" | grep -c isDefaultClass
```
Expected: `Success! The configuration is valid.` and a count of at least `1`, proving the chart version exists and has the key you set.

### Phase 16.3: Apply and hand over to GitOps

#### Task 16.3.1: Apply the platform stage

**Goal:** Namespaces, secrets, Argo Rollouts, ArgoCD, the `gp3` class, Traefik and the root Application exist on EKS.

This uses the same `.env` to `TF_VAR_` bridge as the Makefile does for local. The Makefile wrapper comes in Task 18.1.1, so for now type it out:

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
set -a; source .env; set +a
export TF_VAR_postgres_user="$POSTGRES_USER"
export TF_VAR_postgres_password_dev="$POSTGRES_PASSWORD_DEV"
export TF_VAR_postgres_password_prod="$POSTGRES_PASSWORD_PROD"
export TF_VAR_postgres_db="$POSTGRES_DB"
export TF_VAR_gitops_repo_url="$GITOPS_REPO_URL"
cd terraform/eks/02-platform
terraform apply
```
Review the plan, then type `yes`. Allow about 10 minutes. These exports last for this terminal only.

**Validate:**
```bash
kubectl --context lfi-eks get ns platform-dev platform-prod argocd argo-rollouts traefik
kubectl --context lfi-eks -n platform-prod get secret postgres-credentials
kubectl --context lfi-eks get storageclass
kubectl --context lfi-eks get ingressclass
kubectl --context lfi-eks -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'
```
Expected: five namespaces, the secret, `gp3 (default)` and `gp2` without the default marker, an `IngressClass` named `traefik`, and a load balancer hostname ending `.elb.ap-southeast-2.amazonaws.com` (it can take a few minutes to appear; rerun until it does).

Then a second plan:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops/terraform/eks/02-platform"
terraform plan
```
Expected: `No changes.`

#### Task 16.3.2: Confirm the root Application watches `apps-eks`

**Goal:** Prove the trap from Task 16.1.1 did not fire.

**Validate:**
```bash
kubectl --context lfi-eks -n argocd get application root -o jsonpath='{.spec.source.path}{"\n"}'
kubectl --context lfi-eks -n argocd get applications
```
Expected: `argocd/apps-eks`, and the `root` Application present. It reports `Unknown` with a path-not-found condition until Section 17 adds `argocd/apps-eks`, which is expected. There must be **no** child Applications yet.

#### Task 16.3.3: Reach the ArgoCD UI

**Goal:** Admin access to ArgoCD on EKS.

Use `kubectl port-forward` here. Guide 1 explains why that is fragile for the CLI, but for an occasional look at a short-lived cluster it is the proportionate choice. In one terminal, leave this running:
```bash
kubectl --context lfi-eks -n argocd port-forward svc/argocd-server 8081:80
```
In a second terminal:
```bash
PASSWORD="$(kubectl --context lfi-eks -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
argocd login localhost:8081 --insecure --username admin --password "$PASSWORD"
argocd app list
```

**Validate:** login succeeds and `argocd app list` shows `root`. Open `http://localhost:8081` in a browser for the UI.

Commit the Terraform now, before moving on:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git add terraform/eks
git status --short
git commit -m "feat: add terraform/eks cluster and platform modules"
git switch main
git pull --ff-only
git merge --no-ff feat/eks-platform -m "Merge feat/eks-platform"
git push origin main
```
**Stop here if `git merge` reports a conflict or `git push` is rejected.** Your work is safe on the branch and nothing has been deleted. (A rejection by branch protection means `main` does not accept direct pushes. That is a repository setting to change deliberately, not to work around.) Do not touch the branch until the push of `main` has succeeded.

Then keep the branch on the remote and remove the local copy:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git push -u origin feat/eks-platform
git branch -d feat/eks-platform
git status -sb | head -1
git ls-remote --heads origin feat/eks-platform
```
Expected: `git branch -d` reports the branch deleted, the status line is `## main...origin/main` with no `ahead` or `behind`, and `ls-remote` prints one line for the branch. The remote branch is your record of the work, and the local one is no longer needed.
Check `git status --short` before committing: it must list only files under `terraform/eks`, and no `.terraform`, `.generated` or `*.tfstate` entries (the repo's `.gitignore` covers them).

---

## Section 17: EKS overlays and apps

### Phase 17.1: Overlays

#### Task 17.1.1: `overlays/eks/{dev,prod}/<svc>`

**Goal:** Standalone overlays that reference `base` directly, with their own namespace, `newTag`, replicas, canary steps and host. Nothing under `overlays/eks` references `overlays/local`.

**Why standalone:** decision 9. The cost is that the prod canary patch and replica counts are duplicated from the local prod overlay. That duplication is the price of the EKS tree surviving the local one being deleted.

Start from a copy of the local overlays. The relative `../../../../base/` paths stay correct because `eks/` sits at the same depth as `local/`.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git switch main && git pull --ff-only
git switch -c feat/eks-overlays
mkdir -p kubernetes/overlays/eks/dev kubernetes/overlays/eks/prod
cp -R kubernetes/overlays/local/dev/.  kubernetes/overlays/eks/dev/
cp -R kubernetes/overlays/local/prod/. kubernetes/overlays/eks/prod/
```

Cluster-specific differences, two of them. First, the Ingress hostnames. There is no DNS for these names, you reach them with a `Host` header, so any unused name works. `.test` is reserved for this purpose.
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
sed -i '' 's#value: dev.localhost#value: dev.eks.test#'   kubernetes/overlays/eks/dev/service-1/kustomization.yaml
sed -i '' 's#value: prod.localhost#value: prod.eks.test#' kubernetes/overlays/eks/prod/service-1/kustomization.yaml
grep -rn 'localhost' kubernetes/overlays/eks
```
Expected: the `grep` prints nothing.

Second, the Postgres storage class. Append a `patches:` block to both Postgres overlays:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
for env in dev prod; do
cat >> "kubernetes/overlays/eks/$env/postgres/kustomization.yaml" <<'EOF'
patches:
  # The base asks for local-path, k3d's provisioner. On EKS the equivalent is
  # the gp3 class created in Task 16.1.3.
  - target:
      kind: StatefulSet
      name: postgres
    patch: |-
      - op: replace
        path: /spec/volumeClaimTemplates/0/spec/storageClassName
        value: gp3
EOF
done
```

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
kustomize build kubernetes/overlays/eks/prod/postgres | yq 'select(.kind=="StatefulSet") | .spec.volumeClaimTemplates[0].spec.storageClassName'
kustomize build kubernetes/overlays/eks/prod/service-1 | yq 'select(.kind=="Ingress") | .spec.rules[0].host'
kustomize build kubernetes/overlays/eks/dev/service-1  | yq 'select(.kind=="Ingress") | .spec.rules[0].host'
grep -rn 'overlays/local' kubernetes/overlays/eks | wc -l
diff <(kustomize build kubernetes/overlays/local/prod/service-1) <(kustomize build kubernetes/overlays/eks/prod/service-1)
```
Expected: `gp3`, `prod.eks.test`, `dev.eks.test`, `0`, and a diff containing **only** the host line.

#### Task 17.1.2: Gate the EKS prod path

**Goal:** Changes under `kubernetes/overlays/eks/prod/` need your review, exactly as local prod does.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
python3 - <<'EOF'
p = ".github/CODEOWNERS"
s = open(p).read()
line = "/kubernetes/overlays/local/prod/    @YOUR_GITHUB_USER\n"
assert line in s
s = s.replace(line, line + "/kubernetes/overlays/eks/prod/      @YOUR_GITHUB_USER\n", 1)
open(p, "w").write(s)
EOF
grep -n 'overlays' .github/CODEOWNERS
```
Expected: both `local/prod` and `eks/prod` are listed.

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
grep -n 'overlays' .github/CODEOWNERS
```
Expected: both prod paths are listed. Note that CODEOWNERS only triggers a review request on pull requests, and this guide pushes to `main` directly, so the gate takes effect for the release PRs that `gmake release` opens (see Task 17.4.1). It does not block your own direct pushes.

### Phase 17.2: Applications

#### Task 17.2.1: `argocd/apps-eks/{dev,prod}`

**Goal:** Six Applications named with an `-eks` suffix, each with `source.path` under `kubernetes/overlays/eks/` and the in-cluster destination.

**Why the suffix:** it keeps names unique if anyone ever registers both clusters in one ArgoCD, at no cost today.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
mkdir -p argocd/apps-eks
cp -R argocd/apps-local/. argocd/apps-eks/
# metadata.name is the only line with exactly two spaces then "name:".
sed -i '' -E 's#^(  name: [a-z0-9-]+)$#\1-eks#' argocd/apps-eks/*/*.yaml
sed -i '' 's#kubernetes/overlays/local/#kubernetes/overlays/eks/#' argocd/apps-eks/*/*.yaml
```
Keep `prune: false` on both Postgres Applications, as local does. The copy already preserves it.

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
yq -N '.metadata.name' argocd/apps-eks/*/*.yaml | sort
yq -N '.spec.source.path' argocd/apps-eks/*/*.yaml | grep -vc 'overlays/eks/'
grep -c 'prune: false' argocd/apps-eks/dev/postgres.yaml argocd/apps-eks/prod/postgres.yaml
```
Expected: six names ending `-eks`, `0` paths outside `overlays/eks/`, and `1` for each Postgres file. (`yq -N` suppresses the `---` document separators that `yq` otherwise prints between files, which would pollute the counts.)

### Phase 17.3: First sync

#### Task 17.3.1: Merge and watch it converge

**Goal:** Merge the overlays, the CODEOWNERS line and the Applications, and let the EKS ArgoCD pick them up.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git add kubernetes/overlays/eks argocd/apps-eks .github/CODEOWNERS
git status --short
git commit -m "feat: add EKS overlays and Applications"
git switch main
git pull --ff-only
git merge --no-ff feat/eks-overlays -m "Merge feat/eks-overlays"
git push origin main
```
**Stop here if `git merge` reports a conflict or `git push` is rejected.** Your work is safe on the branch and nothing has been deleted. (A rejection by branch protection means `main` does not accept direct pushes. That is a repository setting to change deliberately, not to work around.) Do not touch the branch until the push of `main` has succeeded.

Then keep the branch on the remote and remove the local copy:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git push -u origin feat/eks-overlays
git branch -d feat/eks-overlays
git status -sb | head -1
git ls-remote --heads origin feat/eks-overlays
```
Expected: `git branch -d` reports the branch deleted, the status line is `## main...origin/main` with no `ahead` or `behind`, and `ls-remote` prints one line for the branch. The remote branch is your record of the work, and the local one is no longer needed.
ArgoCD polls every 3 minutes. To avoid waiting, force a refresh:
```bash
kubectl --context lfi-eks -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
```

**Validate:**
```bash
kubectl --context lfi-eks -n argocd get applications
kubectl --context lfi-eks -n platform-prod get pods,pvc
```
Expected: `root` plus six children `Synced` and `Healthy`, Postgres `Running` with a `Bound` PVC on `gp3`. Image pulls on a fresh node take a minute or two, so repeat the command until the pods are `Running`. The **local** cluster is unaffected: `kubectl --context k3d-platform -n argocd get applications` still shows its own six.

#### Task 17.3.2: Hit it through the load balancer

**Goal:** A request reaches service-1 on EKS.

```bash
LB="$(kubectl --context lfi-eks -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
curl -s -H "Host: prod.eks.test" "http://$LB/"
curl -s -H "Host: dev.eks.test"  "http://$LB/"
```
**Validate:** both return the same JSON the local cluster returns for the same path (compare with `curl -s http://prod.localhost:8080/` against the local cluster if it is running). A `404 page not found` from Traefik means the `Host` header matched no Ingress. NLB DNS can take a few minutes to start resolving after creation.

### Phase 17.4: Releases

#### Task 17.4.1: CI and `release.sh` write every overlay

**Goal:** One build updates `newTag` in both `overlays/local/dev/<svc>` and `overlays/eks/dev/<svc>`. `gmake release` copies dev tags to prod in both trees, in one PR.

**Why here:** the EKS overlays must be on `main` before anything writes to them. CI fails fast with `ERROR: ... does not exist` on a missing path.

**CI, both service repos.** In `.github/workflows/ci.yaml`, in the promote job's `run:` script, replace the single-path block:

```bash
          MANIFEST="kubernetes/overlays/local/dev/${SERVICE}/kustomization.yaml"

          # yq -i against a missing file does not reliably fail, so check.
          if [[ ! -f "$MANIFEST" ]]; then
            echo "ERROR: ${MANIFEST} does not exist." >&2
            exit 1
          fi

          yq -i '.images[0].newTag = strenv(BUILD_TAG)' "$MANIFEST"
```
with a loop over both trees (keep the surrounding indentation, 10 spaces):

```bash
          MANIFESTS=(
            "kubernetes/overlays/local/dev/${SERVICE}/kustomization.yaml"
            "kubernetes/overlays/eks/dev/${SERVICE}/kustomization.yaml"
          )

          for MANIFEST in "${MANIFESTS[@]}"; do
            # yq -i against a missing file does not reliably fail, so check.
            if [[ ! -f "$MANIFEST" ]]; then
              echo "ERROR: ${MANIFEST} does not exist." >&2
              exit 1
            fi
            yq -i '.images[0].newTag = strenv(BUILD_TAG)' "$MANIFEST"
          done
```
and change the staging line `git add "$MANIFEST"` to `git add "${MANIFESTS[@]}"`. The text of service-2's step differs slightly in its comments, so match on the code lines, not the comments. Everything else (the no-op guard, the commit message, the rebase-and-retry loop) stays.

```bash
cd "$PLATFORM_HOME/lfi-service-1-app" && git diff --stat && bash -c 'grep -n "MANIFEST" .github/workflows/ci.yaml'
cd "$PLATFORM_HOME/lfi-service-2-app" && git diff --stat && bash -c 'grep -n "MANIFEST" .github/workflows/ci.yaml'
```

**`release.sh`, GitOps repo.** Four edits in `scripts/release.sh`:

1. After the `SERVICES=(...)` line add:
   ```bash
   TREES=(local eks)
   ```
2. Wrap the collection loop in a loop over trees, and carry the tree in each record. Replace the block from `for svc in "${SERVICES[@]}"; do` through its closing `done` (the one that ends just before `if [[ ${#BLOCKED[@]} -gt 0 ]]; then`) with the same loop nested inside `for tree in "${TREES[@]}"; do ... done`, using these three changes inside it:
   - paths: `"kubernetes/overlays/$tree/dev/$svc/kustomization.yaml"` and `"kubernetes/overlays/$tree/prod/$svc/kustomization.yaml"`
   - `BLOCKED+=("$tree|$svc|$dev_tag|$reason")`
   - `CHANGES+=("$tree|$svc|$prod_tag|$dev_tag")`
3. Every `IFS='|' read -r svc from to <<< "$change"` becomes `IFS='|' read -r tree svc from to <<< "$change"`, and every `IFS='|' read -r svc tag reason <<< "$blocked"` becomes `IFS='|' read -r tree svc tag reason <<< "$blocked"`. In the write loop use `"kubernetes/overlays/$tree/prod/$svc/kustomization.yaml"`, and print `$tree/$svc` where `$svc` was printed.
4. Replace `git add kubernetes/overlays/local/prod` with:
   ```bash
   git add kubernetes/overlays/local/prod kubernetes/overlays/eks/prod
   ```
The deny list is keyed by service and build, so a denied build is excluded from both trees and is listed once per tree in the PR body. That duplication is cosmetic.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
bash -n scripts/release.sh && echo syntax-ok
git switch main && git pull --ff-only
git switch -c feat/eks-writers
git add scripts/release.sh
git commit -m "feat: release.sh promotes both overlay trees"
git switch main
git pull --ff-only
git merge --no-ff feat/eks-writers -m "Merge feat/eks-writers"
git push origin main
```
**Stop here if `git merge` reports a conflict or `git push` is rejected.** Your work is safe on the branch and nothing has been deleted. (A rejection by branch protection means `main` does not accept direct pushes. That is a repository setting to change deliberately, not to work around.) Do not touch the branch until the push of `main` has succeeded.

Then keep the branch on the remote and remove the local copy:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git push -u origin feat/eks-writers
git branch -d feat/eks-writers
git status -sb | head -1
git ls-remote --heads origin feat/eks-writers
```
Expected: `git branch -d` reports the branch deleted, the status line is `## main...origin/main` with no `ahead` or `behind`, and `ls-remote` prints one line for the branch. The remote branch is your record of the work, and the local one is no longer needed.
Then commit and push the two CI changes, GitOps repo first as above:
```bash
cd "$PLATFORM_HOME/lfi-service-1-app"
git add .github/workflows/ci.yaml
git commit -m "ci: write the image tag to both overlay trees"
git push
```
```bash
cd "$PLATFORM_HOME/lfi-service-2-app"
git add .github/workflows/ci.yaml
git commit -m "ci: write the image tag to both overlay trees"
git push
```

**Validate:** push a service-1 change (or watch the run triggered by the CI commit itself), then:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
git pull --ff-only
git log -1 --stat -- kubernetes/overlays/local/dev/service-1 kubernetes/overlays/eks/dev/service-1
yq -N '.images[0].newTag' kubernetes/overlays/local/dev/service-1/kustomization.yaml kubernetes/overlays/eks/dev/service-1/kustomization.yaml
```
Expected: one `deploy(service-1)` commit touching both files, and identical tags. Then `gmake release` opens a PR whose diff touches one line per changed service **per tree**.

#### Task 17.4.2: Canary on EKS

**Goal:** A real release reaches the EKS prod cluster, pauses at the 50 percent gate, and finishes only when you promote it.

**Why there is a pause now and not in Task 17.3.1:** the first deploy of a Rollout skips its canary steps, because there is no earlier version to compare against. This release is a change to a Rollout that already exists, so the steps run.

**Step 1: merge the release PR.** This is the PR that `gmake release` opened in Task 17.4.1. Review its diff first: it should change one line in each of the four prod overlay files. Then merge it in GitHub.

**Step 2: ask ArgoCD to look now** (optional). It polls Git every 3 minutes, so without this you wait up to that long.
```bash
kubectl --context lfi-eks -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
kubectl --context lfi-eks -n argocd annotate application service-2-prod-eks argocd.argoproj.io/refresh=hard --overwrite
kubectl --context lfi-eks -n argocd annotate application service-1-prod-eks argocd.argoproj.io/refresh=hard --overwrite
```

**Step 3: check that the gate holds.**
```bash
kubectl --context lfi-eks argo rollouts get rollout service-1 -n platform-prod
kubectl --context lfi-eks argo rollouts get rollout service-2 -n platform-prod
```
**Validate:** both show `Paused` at step 2 of 3, with the new build beside the old one. One pod is on each. Nothing moves until you act.

**Step 4: promote, service-2 first** (service-1 calls service-2, so the dependency goes first): (After Task 18.1.1, `gmake canary` does the same with menus and the same safeguards.)
```bash
kubectl --context lfi-eks argo rollouts promote service-2 -n platform-prod
kubectl --context lfi-eks argo rollouts promote service-1 -n platform-prod
```

**Validate:** both Rollouts reach `Healthy` on the new build.
```bash
kubectl --context lfi-eks argo rollouts get rollout service-1 -n platform-prod
kubectl --context lfi-eks argo rollouts get rollout service-2 -n platform-prod
```
Expected: `Healthy`, two pods each, all on the new build.

> **What just happened.** The same Git repo now drives two clusters through two independent ArgoCD instances, and the only things that differ are the ones you wrote down in the EKS overlays.

---

## Section 18: Operating both

### Phase 18.1: One small set of commands

By now the Makefile has grown a command per cluster per action: `cluster-up`, `platform-up`, `up`, `eks-up`, `urls`, `canary-promote` and so on. With two clusters that is twenty-odd names to remember. This phase replaces them with about ten commands that each **ask what they need**: which cluster, which service, which environment.

#### Task 18.1.1: Replace the per-cluster commands with commands that ask

**Goal:** `gmake help` lists a short set of commands. Each asks for the cluster (local, eks, or both where that is safe), the service, or the environment, offers a sensible default, and finishes by suggesting what to run next.

| Command | Asks | Replaces |
|---|---|---|
| `gmake up` | cluster: local, eks, both | `cluster-up`, `platform-up`, `up`, `eks-up` and its two stages |
| `gmake down` | cluster: local, eks, both | `down`, `eks-down` |
| `gmake destroy` | cluster: local, eks, both. Makes you type `destroy`. | `destroy`, `eks-destroy` |
| `gmake pause`, `gmake resume` | nothing: local only | unchanged |
| `gmake status` | cluster, then environment | `prod-current`, `dev-current`, `urls`, `eks-urls` |
| `gmake release` | cluster (local, eks, both), then service (service-1, service-2, both) | `release` |
| `gmake rollback` | cluster (one), service (one), then what to go back to | `rollback` |
| `gmake canary` | action (watch, promote, abort), cluster (one), service | `canary-status`, `canary-promote`, `canary-abort` |

**Which choices allow "both", and why.** `up`, `down`, `status` and `release` do. `destroy` does too, but asks you to type the word. `rollback` and `canary` do not: a rollback or a promotion is a judgment about one cluster's traffic, and two at once would hide which one you were judging. Clusters are allowed to drift apart: releasing to EKS leaves local prod where it was, until you release to local.

**Every question can be answered up front,** which is what scripts and muscle memory want:
```bash
gmake release CLUSTER=eks SVC=service-1
gmake canary ACTION=promote CLUSTER=local SVC=service-2
gmake rollback CLUSTER=eks SVC=service-1 TO=26W39B2
```
The variables are `CLUSTER`, `SVC`, `ENVIRONMENT`, `ACTION` and `TO`; `YES=1` skips the confirmations. After an interactive run, each command prints the exact non-interactive form it corresponds to, so the prompts teach the arguments. With no terminal (a pipe, CI), a missing answer is an error with examples, never a prompt that waits.

**Each command ends by suggesting the next one,** based on what it just saw. `gmake status` is the hub: it points to `gmake canary` when a canary is paused, to `gmake release` when dev is ahead of prod, and to `gmake up` or `gmake resume` for a cluster that is not reachable.

**Where things live.** The questions and the hints are in `scripts/`; the Makefile stays thin.

| File | Role |
|---|---|
| `scripts/lib.sh` | shared menus, defaults, confirmations and the "same thing without the questions" line. Written for macOS's default bash 3.2, so no associative arrays. |
| `scripts/cluster.sh` | `up`, `down`, `destroy`: picks the order (local first going up, EKS first going down, since EKS bills), checks AWS credentials before a 20 minute EKS build, states the cost |
| `scripts/status.sh` | the Git versus cluster table, addresses, and the follow-up hints |
| `scripts/release.sh`, `scripts/rollback.sh`, `scripts/canary.sh` | the three ship-related commands, each gaining the cluster question |

**1. Rename the Makefile's own cluster variable.** The Makefile already uses `CLUSTER` for the k3d cluster's name, which would collide with `CLUSTER=eks` on the command line (the command line wins, and `k3d cluster stop eks` would be the result). Rename it:
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
sed -i '' 's/^CLUSTER  := platform/K3D_CLUSTER := platform/; s/\$(CLUSTER)/$(K3D_CLUSTER)/g' Makefile
grep -n 'CLUSTER' Makefile
```
Expected: `K3D_CLUSTER` is defined once and used in `CONTEXT`, `pause` and `resume`, and the bare word `CLUSTER` only appears in the `PASS` line you add in step 3.

**2. Turn the old per-cluster targets into internal ones.** Rename them with a leading underscore and drop their `##` descriptions, so `gmake help` stops listing them and the scripts can still call them:

| Old | New |
|---|---|
| `cluster-up` | `_local-cluster` |
| `platform-up` | `_local-platform` |
| `up` (the two together) | `_local-up: _local-cluster _local-platform` |
| `down` | `_local-down` |
| `destroy` | `_local-destroy` (its inner `$(MAKE) down` becomes `$(MAKE) _local-down`) |
| `eks-cluster-up`, `eks-platform-up`, `eks-up`, `eks-down`, `eks-destroy` | `_eks-cluster`, `_eks-platform`, `_eks-up`, `_eks-down`, `_eks-destroy` |

Delete `urls`, `eks-urls`, `prod-current`, `dev-current`, `canary-status`, `canary-promote` and `canary-abort`, and the `@echo` hint lines inside the renamed targets: the scripts print the hints now. `_eks-cluster` no longer needs `check-env`, since it uses no secrets.

**3. Add the public commands.** One variable that hands your answers to the scripts, and one target per command:
```make
PASS := CLUSTER="$(CLUSTER)" SVC="$(SVC)" ENVIRONMENT="$(ENVIRONMENT)" ACTION="$(ACTION)" TO="$(TO)" ASSUME_YES="$(YES)" MAKE="$(MAKE)"

up: ## Bring a cluster up. Asks: local, eks or both
	$(PASS) ./scripts/cluster.sh up
down: ## Remove a cluster's platform but keep the cluster. Asks which
	$(PASS) ./scripts/cluster.sh down
destroy: ## Destroy a cluster and its data. Asks which, and makes you type it
	$(PASS) ./scripts/cluster.sh destroy
status: ## Show which build runs where, in Git and in the cluster. Asks cluster and environment
	$(PASS) ./scripts/status.sh
release: ## Open a release PR promoting dev to prod. Asks: cluster, service
	$(PASS) ./scripts/release.sh
rollback: ## Open a PR going back to an earlier prod build. Asks: cluster, service, target
	$(PASS) ./scripts/rollback.sh "$(SVC)" "$(TO)"
canary: ## Watch, promote or abort a prod canary. Asks: what, cluster, service
	$(PASS) NAMESPACE=platform-prod ./scripts/canary.sh "$(ACTION)" "$(SVC)"
```
Recipe lines start with a **tab**. Update `.PHONY` to list the public commands and the internal ones. Finally rewrite the footer of `help` to explain that commands ask, and to list the variables.

**4. Make the scripts executable:** `chmod +x scripts/*.sh`.

**Validate:**
```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake help
gmake -n up CLUSTER=eks | head -3
gmake status
gmake canary </dev/null
```
Expected:
- `gmake help` lists about ten commands in these groups: Help, Setup, Cluster lifecycle, Look and Ship. The internal `_local-*` and `_eks-*` targets are **not** listed.
- `gmake -n up CLUSTER=eks` prints the `cluster.sh up` command with `CLUSTER="eks"` already filled in.
- `gmake status` shows a menu asking which cluster and which environment, with each cluster marked `running` or `not reachable`. Pick one, and it prints the table, the addresses, and a `Next:` list.
- `gmake canary </dev/null` (no terminal) fails with `ACTION is required` and an example, and does not hang.

> **What just happened.** The number of names to remember stopped growing with the number of clusters. Adding a third cluster later means one more entry in `scripts/lib.sh`, not a new set of commands.

### Phase 18.2: Independence drills

The point of the guide is that existence is independent. Prove it. These drills destroy and recreate clusters, which costs money and time: about 25 minutes each way for EKS and 5 for local.

#### Task 18.2.1: Local only

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake destroy CLUSTER=eks
```
Then push a trivial change to `lfi-service-1-app` (for example a README line) and let CI finish.

**Validate:**
```bash
kubectl config get-contexts -o name | grep -c lfi-eks
kubectl --context k3d-platform -n argocd get applications
cd "$PLATFORM_HOME/lfi-infrastructure-gitops" && git pull --ff-only && git log -1 --oneline
```
Expected: `0`, local ArgoCD `Synced` and `Healthy`, and a `deploy(service-1)` commit that CI wrote with no error even though the EKS cluster does not exist. CI writes to Git, not to a cluster, which is why nothing breaks.

#### Task 18.2.2: EKS only

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake destroy CLUSTER=local
gmake up CLUSTER=eks
```
Then push another trivial service-1 change.

**Validate:**
```bash
kubectl config get-contexts -o name | grep -c k3d-platform
kubectl --context lfi-eks -n argocd get applications
cd "$PLATFORM_HOME/lfi-infrastructure-gitops" && git pull --ff-only
yq '.images[0].newTag' kubernetes/overlays/eks/dev/service-1/kustomization.yaml
kubectl --context lfi-eks -n platform-dev get rollout service-1 -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```
Expected: `0`, EKS Applications `Synced` and `Healthy`, and the Rollout's image tag equals the overlay's `newTag` (after the next poll).

#### Task 18.2.3: Both

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake up CLUSTER=both
gmake release CLUSTER=both SVC=both
```
Merge the release PR.

**Validate:**
```bash
kubectl --context k3d-platform argo rollouts get rollout service-1 -n platform-prod
kubectl --context lfi-eks      argo rollouts get rollout service-1 -n platform-prod
```
Expected: both show `Paused` at the 50 percent gate. Promote one and confirm the other is unchanged:
```bash
kubectl --context lfi-eks argo rollouts promote service-1 -n platform-prod
kubectl --context k3d-platform argo rollouts get rollout service-1 -n platform-prod | head -8
```
The local rollout must still show `Paused`.

### Phase 18.3: Teardown and cost

#### Task 18.3.1: Full EKS teardown leaves nothing billing

**Goal:** Destroy ordering that removes the load balancer before the VPC.

**Why ordering matters:** Traefik's Service created an AWS load balancer outside Terraform's knowledge. If the cluster is destroyed first, the load balancer and its network interfaces block VPC deletion. `gmake destroy CLUSTER=eks` removes the platform stage first for this reason.

```bash
cd "$PLATFORM_HOME/lfi-infrastructure-gitops"
gmake destroy CLUSTER=eks
```

**Validate:**
```bash
aws elbv2 describe-load-balancers --region ap-southeast-2 --query 'LoadBalancers[].LoadBalancerName'
aws elb describe-load-balancers --region ap-southeast-2 --query 'LoadBalancerDescriptions[].LoadBalancerName'
aws ec2 describe-volumes --region ap-southeast-2 --filters Name=tag-key,Values='kubernetes.io/cluster/lfi-eks' --query 'Volumes[].VolumeId'
aws eks list-clusters --region ap-southeast-2 --query clusters
aws ec2 describe-vpcs --region ap-southeast-2 --filters Name=tag:Name,Values='lfi-eks-vpc' --query 'Vpcs[].VpcId'
```
Expected: all five empty (`[]`). Orphaned EBS volumes from the Postgres PVCs are the usual leftover. If one remains and `terraform destroy` hung on the VPC, delete the leftover load balancer or volume from the console or CLI, then rerun `gmake destroy CLUSTER=eks`. Check the cost tomorrow: in the AWS Billing console, the daily EKS and EC2 line items should stop.

#### Task 18.3.2: Update the published docs

**Goal:** README and guides match the new layout, and the README links to this guide.

1. In `lfi-infrastructure-gitops/README.md`, make the layout block describe both clusters: add lines for `terraform/eks/`, `kubernetes/overlays/eks/` and `argocd/apps-eks/`, and a sentence that each cluster runs its own ArgoCD against this repo.
2. In the project root `README.md`, add guide 3 to the guide list.
3. Search for stale paths:
   ```bash
   cd "$PLATFORM_HOME"
   grep -rnE 'overlays/(dev|prod)|argocd/apps[^-]' README.md docs lfi-infrastructure-gitops --exclude-dir=.git
   ```
   Expected: nothing outside text that deliberately quotes the old layout (guide 1, which builds the flat layout, and the description of the old paths in Section 14 of this guide).
4. To publish guide 3 and its tracker, add `!docs/3-eks-counterpart-guide.md` and `!tracker_3_eks.md` to the allowlists in the project root `.gitignore`.

**Validate:** the grep in step 3 prints only the expected quoted history, and `git -C "$PLATFORM_HOME" status --short` shows the README and `.gitignore` edits plus the two new files.

---

## Appendix G: Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Root on EKS is `Unknown`, path not found | `apps-eks` not merged yet | Expected until Task 17.2.1 lands. |
| Postgres PVC `Pending` | The `gp3` StorageClass is missing, or the EBS CSI driver is not running | Re-check Task 16.1.3 and Task 15.3.1. |
| Ingress applied, no response | No controller, or wrong ingress class | `kubectl get ingressclass`, then Task 16.2.1. |
| Traefik Service stuck `<pending>` | Load balancer provisioning, or subnets missing the ELB tag | Wait a few minutes, then check subnet tags in the VPC module. |
| `ImagePullBackOff` | GHCR package is private | Make it public or add an image pull secret. |
| `terraform destroy` hangs on the VPC | A load balancer or ENI created by Kubernetes still exists | Delete the Traefik release first, see Task 18.3.1. |
| CI fails with `no such file` after Section 14 | Service repo still points at `overlays/dev` | Task 14.3.3. |

## Appendix H: Glossary

**Overlay.** A Kustomize directory holding only the differences from a base.
**Root Application.** The one ArgoCD Application Terraform applies. It discovers all others from Git.
**Prune.** ArgoCD deleting live objects that no longer exist in Git.
**EBS CSI driver.** The component that turns a PVC into an AWS EBS volume.
**Managed node group.** EKS-managed EC2 nodes, with upgrades and replacement handled by AWS.
**Ingress controller.** The program that makes an Ingress object do anything.

## Where to Go Next

**Private subnets and a NAT gateway.** The honest production posture, and a good exercise in what the cost actually buys.
**AWS Load Balancer Controller.** Swap Traefik for ALB and patch the ingress class in the EKS overlay only.
**Pod Identity for your own workloads.** The EBS driver already uses it. Give the services their own roles the same way, without keys.
**External Secrets with AWS Secrets Manager.** On EKS this closes the "reproducible from Git alone" gap more naturally than Sealed Secrets.
**Karpenter.** Replace the fixed node group with just-in-time nodes.
