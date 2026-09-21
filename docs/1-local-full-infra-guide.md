# Local Full Infrastructure: A Build Guide

**Goal:** Build a fully automated, GitOps-driven Kubernetes platform that runs entirely on a Mac, using cloud services only for source control, CI, image storage, and Terraform state, for $0 in compute cost.

**Architecture:** A k3d cluster (k3s inside Docker, hosted by OrbStack) runs a 2-tier microservice stub backed by a PostgreSQL StatefulSet. Terraform provisions the cluster and bootstraps ArgoCD. ArgoCD then owns everything else, pulling desired state from a dedicated GitOps repository. Application repos never touch the cluster: their CI builds an image, pushes it to GHCR, and commits the new tag to the GitOps repo, which ArgoCD reconciles.

**Tech stack:** OrbStack, k3d, k3s, Traefik, Terraform (or OpenTofu), Helm, ArgoCD, Kustomize, PostgreSQL 16, Python 3.12, FastAPI, GitHub Actions, GHCR, AWS S3.

**Source spec:** the original `plan.md`, which this guide supersedes and whose four open decisions it resolves. Both this guide and its follow-on, `2-multi-env-infra-guide.md`, now live in `$PLATFORM_HOME/docs/`.

---

## How to Use This Guide

This is a build guide, not a reference manual. It is written to be worked through in order, and it assumes you want to understand what you are building rather than just get it running.

**Who it is for.** An engineer who is comfortable in a terminal and knows roughly what a container is, but who has not necessarily run Kubernetes locally, written Terraform, or set up GitOps before. Where a concept is load-bearing, there is a primer explaining it before you use it. Where a choice could reasonably have gone another way, the reasoning is spelled out rather than assumed.

**How it is organised.** Three levels:

- **Sections** are one part of the system (the cluster, the data layer, CI, and so on)
- **Phases** are milestone-sized chunks within a section
- **Tasks** are single concrete actions. Each one opens with a **Goal** and a **Why**, and closes with a **Validate** block

**About Goal and Why.** The Goal is the concrete state that exists once the task is done, so you can tell whether you actually finished rather than merely typed the code. The Why is the reason it is worth doing, usually by naming what breaks without it. Read the Why on any task that looks like busywork: several of them exist to catch failures that produce no error message at all.

**About the Validate blocks.** Every task tells you the exact command to run and what you should see. These are not ceremony. They exist so that when something breaks three sections later, you know with certainty which steps were genuinely working. If a Validate block does not produce what it says it should, stop and fix it there. Debugging one broken layer is straightforward; debugging four stacked broken layers is not.

**Tracking your progress.** Not in this file. Tick tasks in `tracker_1_local_infra.md` at the workspace root, and tick one when its Validate passes rather than when you have typed the code. Keeping status out of the plan means the plan never goes stale.

**Time.** Roughly 8 to 10 hours of focused work end to end, though a fair amount of that is waiting on image pulls. Per-section estimates are in the tracker file.

**If you get stuck.** Appendix B is a symptom-to-cause table covering the failures that are actually likely here, and Appendix D is a glossary. Both are worth skimming once before you start so you know what is in them.

**Where you can stop.** Section 6 is a complete and genuinely useful local platform. Sections 7 through 9 add cloud CI, automated deployment, and remote state. Stopping after 6 is a coherent outcome, not an abandoned project.

---

## What You Will Learn

Each section teaches something specific. If you already know one of these cold, you can move through that section quickly, but do run its Validate blocks so later sections stand on solid ground.

| Section | The idea it teaches |
|---|---|
| 1 | Keeping secrets out of Git from the very first commit, rather than cleaning up later |
| 2 | Infrastructure as Code, and why Terraform's provider model forces a two-stage apply here |
| 3 | Designing service boundaries that survive contact with a cluster, and testing I/O-heavy code without I/O |
| 4 | How Kubernetes handles state: StatefulSets, PersistentVolumeClaims, and what actually survives a pod dying |
| 5 | Declarative deployment with Kustomize, and why proving manifests manually before automating pays for itself |
| 6 | What GitOps actually is: pull-based reconciliation, continuous drift correction, and the app-of-apps pattern |
| 7 | CI that produces immutable, traceable, multi-architecture artifacts |
| 8 | The seam between CI and CD, and why it should be exactly one field wide |
| 9 | Remote state with locking, and the difference between believing something is reproducible and knowing it |

### The one mental model that matters

Most of this guide is in service of a single shift, and it is worth having in your head before you start.

Most deployment systems **push**. Something outside the cluster (a CI job, an engineer with `kubectl`) reaches in and changes it. Whoever holds the credentials can change anything, and nothing records what the cluster is supposed to look like.

GitOps **pulls**. A controller inside the cluster continuously compares reality against a Git repository and fixes any difference it finds:

```
        Git repository                     Your cluster
     (the desired state)                 (the actual state)
              |                                  |
              |   <-- ArgoCD reads both -->      |
              |                                  |
              |        different?                |
              |            |                     |
              |            +-- change the cluster to match Git
```

Two consequences follow, and both show up in Section 6:

1. **Deploying means committing.** There is no other way in. Every change to the cluster has an author, a timestamp, a diff, and a revert.
2. **Manual changes do not survive.** Run `kubectl scale` and the controller will quietly undo it within a few minutes, because Git did not say that. This feels wrong the first time you see it. It is the entire point.

---

## Table of Contents

- [How to Use This Guide](#how-to-use-this-guide)
- [What You Will Learn](#what-you-will-learn)
- [Decisions Locked](#decisions-locked)
- [Global Constraints](#global-constraints)
- [Repository and Directory Layout](#repository-and-directory-layout)
- [Access Model](#access-model)
- [Progress](#progress)
- [Section 1: Workstation and Repository Foundation](#section-1-workstation-and-repository-foundation)
- [Section 2: Local Cluster Infrastructure](#section-2-local-cluster-infrastructure)
- [Section 3: Application Services](#section-3-application-services)
- [Section 4: Data Layer](#section-4-data-layer)
- [Section 5: Kubernetes Manifests and Manual Deployment](#section-5-kubernetes-manifests-and-manual-deployment)
- [Section 6: GitOps Control Plane](#section-6-gitops-control-plane)
- [Section 7: Continuous Integration](#section-7-continuous-integration)
- [Section 8: Automated Promotion](#section-8-automated-promotion)
- [Section 9: Remote State and Resilience](#section-9-remote-state-and-resilience)
- [Appendix A: Private Repos and Private Packages](#appendix-a-private-repos-and-private-packages)
- [Appendix B: Troubleshooting](#appendix-b-troubleshooting)
- [Appendix C: Command Cheat Sheet](#appendix-c-command-cheat-sheet)
- [Appendix D: Glossary](#appendix-d-glossary)
- [Where to Go Next](#where-to-go-next)

---

## Decisions Locked

The source document left four things unspecified. They are settled here, and every task below assumes these answers.

| # | Decision | Choice | Why it matters |
|---|---|---|---|
| 1 | Application stack | **Python 3.12 + FastAPI** | The services are deliberately thin stubs. Python gets them written in minutes so the effort goes into the platform, which is the actual subject of this project. |
| 2 | Image tag promotion | **CI commits back to the GitOps repo** | Every deployment becomes a reviewable Git commit with a real author and timestamp. This is the canonical production pattern and it makes the CI/CD seam explicit rather than magic. |
| 3 | Terraform state | **Local first, migrate to S3 in Section 9** | Phase 1 is not blocked on AWS account setup. You get a working cluster first, then add remote state as a deliberate, isolated exercise. |
| 4 | Secret handling | **`.env` (gitignored) read by Terraform, which creates the Kubernetes Secret** | Git never contains a password, only a `secretKeyRef` pointing at a Secret by name. See the note below on why this needs care. |

### Note on decision 4

A plaintext Kubernetes Secret must never be committed, even to a private repo. Base64 is encoding, not encryption, and anyone with read access to the repo has the password forever, including in the history after you "remove" it.

The wrinkle with a gitignored `.env` is that ArgoCD runs **inside** the cluster and pulls from Git. It cannot see a file on your Mac. Something has to bridge that gap, and here that bridge is Terraform, which runs locally, can read `.env`, and talks to the cluster directly:

```
.env (your Mac, gitignored)
   |
   v
Terraform  (runs locally, reads TF_VAR_postgres_password)
   |
   v
Kubernetes Secret "postgres-credentials"  (lives only in the cluster)
   ^
   |
manifests in Git reference it by name via secretKeyRef, never by value
```

The tradeoff to be aware of: the cluster is no longer reproducible from Git alone, because the Secret comes from your laptop. That is an acceptable and common bootstrap pattern for a local platform. Section 9 includes a rebuild drill that proves the sequence still works. If you later want the cluster fully reproducible from Git, Sealed Secrets is the upgrade path, and it slots in without changing any application code.

---

## Global Constraints

Every task below implicitly inherits these. Values are exact.

| Constraint | Value |
|---|---|
| Cluster name | `platform` |
| Kube context | `k3d-platform` |
| Application namespace | `platform` |
| ArgoCD namespace | `argocd` |
| Host ingress port | `8080` (maps to Traefik on port 80 inside the cluster) |
| ArgoCD URL | `http://argocd.localhost:8080` via the Traefik ingress. No `kubectl port-forward`, see Task 6.1.5 |
| k3s image | `rancher/k3s:v1.36.4-k3s1` (ships Traefik v3, containerd v2. v1.31 is EOL as of February 2026) |
| k3d | `>= 5.9.0` |
| Postgres image | `postgres:16-alpine` |
| Python | `3.12` |
| Python package index | `https://pypi.org/simple` (public PyPI), pinned per-venv, never set globally |
| Container port for both services | `8000` |
| Terraform | `>= 1.9.0` (or OpenTofu `>= 1.8.0`) |
| GNU Make | `>= 4.0`, invoked as `gmake`. Apple's bundled `make` is 3.81 and will not work. |
| Kubernetes provider | `hashicorp/kubernetes ~> 2.35` |
| Helm provider | `hashicorp/helm ~> 2.17` (v3 changes the provider block syntax; do not use it with this plan) |
| argo-cd Helm chart | `10.4.2`, which deploys ArgoCD server `v3.5.2` (verified and pinned in Task 1.1.3) |
| argocd CLI | Must match the server's minor. Chart `10.4.2` pairs with CLI `v3.5.x`. |
| Image tag scheme | Git commit SHA, full 40 characters, never `latest` |
| Storage class | `local-path` (k3d default) |
| Secrets in Git | Never. Not plaintext, not base64. |

**Resource budget:** the whole stack should idle at roughly 1.5 GB to 2.5 GB RAM and 2 to 5 percent CPU. If you exceed that, Appendix B has the trim list.

---

## Repository and Directory Layout

Everything lives under one workspace directory. It holds the planning docs and the local dev compose file, and the three Git repositories sit inside it as subdirectories.

Throughout this guide that workspace is referred to as `$PLATFORM_HOME`, a shell variable you set in Task 1.2.1. On this machine it resolves to `~/Downloads/nextwork_projects/local-full-intrastructure`.

> **Repo naming.** The three repos are prefixed `lfi-` on this machine: `lfi-service-1-app`, `lfi-service-2-app`, and `lfi-infrastructure-gitops`. Every path and command below already uses those names, so they are safe to copy verbatim. If you read this guide against an earlier draft, the unprefixed names (`service-1-app`, `my-infrastructure-gitops`) were the originals.
>
> Note that the **Kubernetes** resource names stay unprefixed: `service-1`, `service-2`, the Deployments, the Services, the GHCR image paths, and the directories under `kubernetes/`. Only the three Git repositories carry the prefix. Renaming the in-cluster resources would mean rewriting the cluster DNS names the code depends on, and there is no reason to.

```text
$PLATFORM_HOME/                             # the workspace. NOT a Git repo itself.
│                                           # = ~/Downloads/nextwork_projects/local-full-intrastructure
├── docs/                                   # planning docs live here
│   ├── 1-local-full-infra-guide.md               # this guide, Sections 1 to 9
│   └── 2-multi-env-infra-guide.md           # the follow-on guide, Sections 10 to 13
├── docker-compose.dev.yaml                 # local dev loop, sees all three repos
│
├── lfi-service-1-app/                      # GitHub repo 1
│   ├── src/
│   │   ├── __init__.py
│   │   ├── config.py                       # env -> DSN, no secrets in code
│   │   └── main.py                         # FastAPI gateway
│   ├── tests/
│   │   ├── __init__.py
│   │   └── test_main.py
│   ├── .github/workflows/ci.yaml           # test -> build -> promote
│   ├── Dockerfile
│   ├── pyproject.toml
│   ├── requirements.txt
│   └── requirements-dev.txt
│
├── lfi-service-2-app/                      # GitHub repo 2
│   ├── src/
│   │   ├── __init__.py
│   │   └── main.py                         # FastAPI worker, stateless
│   ├── tests/
│   │   ├── __init__.py
│   │   └── test_main.py
│   ├── .github/workflows/ci.yaml
│   ├── Dockerfile
│   ├── pyproject.toml
│   ├── requirements.txt
│   └── requirements-dev.txt
│
└── lfi-infrastructure-gitops/              # GitHub repo 3. ArgoCD's source of truth.
    ├── .env                                # GITIGNORED. Passwords live here only.
    ├── .env.example                        # committed, no real values
    ├── .gitignore
    ├── Makefile                            # bridges .env into TF_VAR_* and runs Terraform
    │
    ├── terraform/
    │   ├── 01-cluster/                     # creates the k3d cluster
    │   │   ├── main.tf
    │   │   └── k3d-config.yaml
    │   └── 02-platform/                    # in-cluster resources: secret, ArgoCD, root app
    │       ├── main.tf
    │       ├── variables.tf
    │       ├── values/argocd.yaml
    │       └── bootstrap/root-app.yaml.tftpl
    │
    ├── kubernetes/                          # what ArgoCD deploys
    │   ├── postgres/
    │   │   ├── kustomization.yaml
    │   │   ├── service.yaml
    │   │   └── statefulset.yaml
    │   ├── service-1/
    │   │   ├── kustomization.yaml
    │   │   ├── deployment.yaml
    │   │   ├── service.yaml
    │   │   └── ingress.yaml
    │   └── service-2/
    │       ├── kustomization.yaml
    │       ├── deployment.yaml
    │       └── service.yaml
    │
    └── argocd/
        └── apps/                            # app-of-apps children
            ├── postgres.yaml
            ├── service-1.yaml
            └── service-2.yaml
```

### A note on nesting Git repos

The workspace holds three Git repositories but is **not** a repository itself, and it should stay that way. If you ever run `git init` here, Git will see three nested repos and behave confusingly: it will not track their contents, but it will offer to add them as broken submodule-like entries.

If you do want the workspace under version control (to track the guides in `docs/`), add the three repo directories to a workspace-level `.gitignore` first:

```gitignore
lfi-service-1-app/
lfi-service-2-app/
lfi-infrastructure-gitops/
```

That keeps the planning docs versioned while leaving the three repos to manage themselves.

### Why Terraform is split into two root modules

This is the single most important structural decision in the plan, so it is worth stating plainly.

Terraform's `kubernetes` and `helm` providers need a reachable cluster **at plan time**. If the same apply that creates the cluster also configures those providers, the first run fails because the cluster does not exist yet when the plan is built. This is a well-known Terraform limitation, not a bug in your config.

Splitting into `01-cluster` (creates infrastructure, uses only `null` and `local` providers) and `02-platform` (configures in-cluster resources, uses `kubernetes` and `helm`) sidesteps it entirely. Two applies, always in that order. The `Makefile` sequences them for you.

---

## Access Model

The baseline path assumes **public GitHub repos and public GHCR packages**. This removes two entire categories of credential plumbing (ArgoCD repo auth and Kubernetes image pull secrets) from the critical path, which matters when you are trying to get a first loop working.

The only credential you genuinely need is the `GITOPS_PAT`, because writing to a repo requires auth whether or not it is public.

If you want or need private repos and packages, everything still works. Appendix A gives the exact additional manifests and the two extra tasks, and flags where they insert.

---

## Progress

This guide is not a tracker and deliberately carries no status of its own. It stays
the source of truth for **what each task is**; tracking lives in a separate file so
the two can never disagree.

**Tick your progress in [`tracker_1_local_infra.md`](../tracker_1_local_infra.md)**, at the
workspace root. That file holds the phase summary with time estimates, a checkbox
per task, the milestone table, and a Notes and Deviations log for anything you did
differently from this plan.

---

## Section 1: Workstation and Repository Foundation

**Objective:** Every tool installed at a known version, three repos created, and the secret handling set up before a single line of infrastructure exists.

### Phase 1.1: Host toolchain

#### Task 1.1.1: Install OrbStack and the CLI toolchain

**Goal:** Every tool installed, Docker answering, and `gmake` resolving to GNU Make 4.x.

**Why:** One item on this list is not like the others. macOS ships GNU Make 3.81, which silently ignores the two directives the Makefile in Task 1.3.3 depends on. Installing `gmake` now prevents a confusing syntax error later, and a worse silent failure where Terraform runs in the repository root instead of the module directory.

OrbStack replaces Docker Desktop. It idles at a fraction of the RAM, which is the difference between this stack being comfortable and being painful on a laptop.

```bash
brew install orbstack
brew install k3d kubectl helm terraform kustomize yq
brew install argocd            # the ArgoCD CLI, used in Section 6
brew install make              # GNU Make 4.x, installed as 'gmake'. See below.
```

**Why GNU Make is not optional here.** macOS ships GNU Make 3.81, released in 2006, because 3.82 moved to GPLv3 and Apple will not distribute it. The `Makefile` in Task 1.3.3 depends on two special variables that were both introduced in 3.82:

- `.ONESHELL:` runs a whole recipe in a single shell, which is what lets `cd terraform/01-cluster` persist into the next line
- `.SHELLFLAGS := -eu -o pipefail -c` is what makes a failing command abort the target

Make 3.81 does not error on either. It **silently ignores** them, and that is what makes this worth pre-empting rather than debugging later. You get a confusing `syntax error: unexpected end of file` from the multi-line `if` in `check-env`, and if you worked around only that, `cd` would no longer persist and Terraform would quietly run in the repository root instead of the module directory.

Homebrew installs it as `gmake`, leaving Apple's `make` in place. **Every `gmake` command in this guide is deliberate.** Do not substitute `make`.

Resist the temptation to put Homebrew's `gnubin` directory on your `PATH` to make `make` resolve to 4.x. It works, but it silently changes `make` for every other project on the machine, which is exactly the kind of surprise this guide is trying to avoid.

Launch OrbStack once from Applications so it can install its Docker socket, then confirm the Docker CLI is wired up.

**Validate:**

```bash
docker info --format '{{.ServerVersion}}'
gmake --version | head -1
```

Expected: a Docker version string, then `GNU Make 4.x`. If you get `Cannot connect to the Docker daemon`, OrbStack is not running. If `gmake: command not found`, the `brew install make` did not complete.

#### Task 1.1.2: Record tool versions

**Goal:** A written record of every tool version, plus confirmation that the pinned k3s image tag exists.

**Why:** Version drift is the most common reason a plan like this stops working months later. Capturing what you actually have now is what makes a future failure diagnosable rather than mysterious.

Version drift is the most common reason a plan like this stops working months later. Capture what you actually have.

```bash
for tool in k3d kubectl helm terraform kustomize yq gmake; do
  printf '%-12s ' "$tool"
  case "$tool" in
    kubectl) kubectl version --client -o yaml | yq '.clientVersion.gitVersion' ;;
    yq)      yq --version ;;
    gmake)   gmake --version | head -1 ;;
    *)       $tool version | head -1 ;;
  esac
done
```

**Validate:** every line prints a version. Confirm `k3d` is `5.9.0` or newer, `terraform` is `1.9.0` or newer, and `gmake` is `4.0` or newer. Anything older and the k3d config `apiVersion`, the Terraform syntax, or the `Makefile`'s `.ONESHELL:` will not work as written.

The `k3d version` output also prints its default k3s version, which is `v1.35.5-k3s1` on k3d 5.9.0. This plan deliberately pins one minor higher, to `v1.36.4-k3s1`. Confirm that tag exists before depending on it, the same way you did for the ArgoCD chart:

```bash
docker manifest inspect rancher/k3s:v1.36.4-k3s1 >/dev/null && echo "tag exists"
```

Expected: `tag exists`. If it does not, pick the newest `v1.36.x-k3s1` on [Docker Hub](https://hub.docker.com/r/rancher/k3s/tags) and update the two places the version appears: Global Constraints and `k3d-config.yaml`.

#### Task 1.1.3: Verify and pin the ArgoCD chart version

**Goal:** A chart version you have confirmed exists, whose server version matches your `argocd` CLI's minor.

**Why:** Two separate failures avoided. A version that has been yanked fails during `terraform apply`, halfway through configuring a cluster. And a large gap between CLI and server breaks the `argocd` commands Section 6 depends on, which presents as a broken cluster rather than a version mismatch.

The plan pins chart `10.4.2`, which deploys ArgoCD server **v3.5.2**. Confirm it still exists before depending on it, rather than discovering it during a Terraform apply.

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
helm search repo argo/argo-cd --versions | head -20
```

**Validate:** `10.4.2` appears in the list, with `v3.5.2` in the APP VERSION column. If it does not, pick the newest `10.x` shown and replace every occurrence of `10.4.2` in this document and in `terraform/02-platform/variables.tf`.

**Why this version and not an older one.** The server version has to stay close to your `argocd` CLI, because the CLI talks to the server API and a large gap breaks commands you need in Section 6 (`argocd login`, `argocd app list`, `argocd app get`). Check yours:

```bash
argocd version --client
```

If it reports `v3.5.x`, chart `10.4.2` puts the two in lockstep. If it reports something else, find the chart whose APP VERSION matches your CLI's minor and pin that instead. The Argo project actively patches roughly the latest three minor lines, so anything much below that is receiving no fixes.

### Phase 1.2: Workspace variable and repositories

#### Task 1.2.1: Set the workspace variable

**Goal:** `PLATFORM_HOME` exported and persisted in `~/.zshrc`, surviving a new terminal.

**Why:** Every command in this guide is written relative to it, so they can be copied verbatim, and relocating the project later becomes a one-line change. Persisting it is the part that matters: you will open new terminals during this project, and a command that silently runs in the wrong directory is unpleasant to debug.

Every command in this guide is written relative to `$PLATFORM_HOME`. Set it once so the rest can be copied verbatim, and so you can relocate the whole project later by changing one line.

```bash
export PLATFORM_HOME="$HOME/Downloads/nextwork_projects/local-full-intrastructure"
```

Add that line to `~/.zshrc` now. You will open new terminals during this project, and a command that silently runs in the wrong directory is unpleasant to debug.

Note the directory name is spelled `local-full-intrastructure` on this machine, missing the `f` in "infrastructure". That is how it exists on disk, so the variable matches it. Rename the directory if it bothers you, and update this one line to match.

**Validate:**

```bash
ls "$PLATFORM_HOME/docs/1-local-full-infra-guide.md"
```

Expected: the path prints. An error means the variable is wrong or the directory has moved.

#### Task 1.2.2: Create the repos on GitHub

**Goal:** Three repositories on GitHub, cloned as siblings inside the workspace.

**Why:** Three repos rather than one is the architecture, not fussiness. The application repos must never be able to reach the cluster, and the GitOps repo is the only thing ArgoCD reads. That separation is what Section 8 depends on, and it is far harder to introduce later than to start with.

Using the `gh` CLI (`brew install gh` if needed, then `gh auth login`). All three are cloned into the workspace, so they end up as siblings of this guide.

```bash
cd "$PLATFORM_HOME"

gh repo create lfi-service-1-app         --public --clone
gh repo create lfi-service-2-app         --public --clone
gh repo create lfi-infrastructure-gitops --public --clone
```

If you prefer private repos, substitute `--private` and read Appendix A before starting Section 6.

**Validate:**

```bash
ls -d "$PLATFORM_HOME"/{lfi-service-1-app,lfi-service-2-app,lfi-infrastructure-gitops}
```

Expected: all three paths listed, no `No such file or directory`.

#### Task 1.2.3: Record your GitHub owner name

**Goal:** `GH_OWNER` exported and persisted, confirmed to survive a fresh terminal.

**Why:** Several committed files need your username. The convention worth internalising here is the one in the note below: `YOUR_GITHUB_USER` appearing inside a file's contents means substitute it by hand, because a committed file cannot read your shell.

Several files need your GitHub username or org. Set it in your shell alongside `PLATFORM_HOME`.

```bash
export GH_OWNER="$(gh api user --jq .login)"
echo "$GH_OWNER"
```

Add this `export` to `~/.zshrc` too. Throughout this guide, `YOUR_GITHUB_USER` appearing inside a file's contents means: substitute this value by hand, because it is going into a committed file rather than a shell command.

**Validate:**

```bash
echo "$GH_OWNER" && echo "$PLATFORM_HOME"
```

Expected: your GitHub username, then the workspace path. Open a fresh terminal and run it again to confirm both survived, which is the actual thing being tested here.

### Phase 1.3: Secrets and ignore rules

#### Task 1.3.1: Write the gitignore before writing any secrets

**Goal:** A `.gitignore` that provably matches `.env`, in place before any secret exists on disk.

**Why:** The ordering is the entire point of this task. Writing the rules first means there is no window in which a real password could be staged. Once a secret reaches Git history it is there permanently, and "removing" it in a later commit does not remove it from the history anyone can read.

Order matters. Create the ignore rules first so there is no window in which a `.env` could be accidentally staged.

**File:** `lfi-infrastructure-gitops/.gitignore`

```gitignore
# Secrets. Never commit.
.env
.env.local

# Terraform state and working dirs
*.tfstate
*.tfstate.*
.terraform/
crash.log
crash.*.log
override.tf
override.tf.json
*_override.tf
*_override.tf.json

# Generated manifests written by Terraform at apply time
terraform/**/.generated/

# Kubeconfigs
kubeconfig
kubeconfig-*

# macOS
.DS_Store
```

Note that `.terraform.lock.hcl` is deliberately **not** ignored. That file pins provider checksums and belongs in Git.

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
git check-ignore -v .env
```

Expected: output naming `.gitignore` and the `.env` rule. Silence means the rule is not matching and you must fix it before continuing.

#### Task 1.3.2: Create the committed example and the real .env

**Goal:** A committed `.env.example` holding placeholders, and a real gitignored `.env` holding a generated password.

**Why:** The example documents what a fresh clone needs without leaking anything, which is the only reason anyone else can use this repo. Generate the password rather than typing one: a password you invented on the spot is a password you or someone else can guess.

The example is committed so anyone cloning the repo knows what to supply. The real file never leaves your machine.

**File:** `lfi-infrastructure-gitops/.env.example` (committed)

```bash
# Copy to .env and fill in real values. .env is gitignored.

# Postgres credentials. Terraform reads these and creates the
# Kubernetes Secret "postgres-credentials" in the platform namespace.
POSTGRES_USER=platform
POSTGRES_PASSWORD=change-me
POSTGRES_DB=platform

# The GitOps repo ArgoCD watches. Public HTTPS URL.
GITOPS_REPO_URL=https://github.com/YOUR_GITHUB_USER/lfi-infrastructure-gitops.git

# Your GitHub owner, used to build GHCR image references.
GH_OWNER=YOUR_GITHUB_USER
```

**File:** `lfi-infrastructure-gitops/.env` (gitignored, real values)

```bash
POSTGRES_USER=platform
POSTGRES_PASSWORD=<generate one, see below>
POSTGRES_DB=platform
GITOPS_REPO_URL=https://github.com/YOUR_GITHUB_USER/lfi-infrastructure-gitops.git
GH_OWNER=YOUR_GITHUB_USER
```

Generate a real password rather than typing one:

```bash
openssl rand -base64 24
```

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
git status --porcelain | grep -c '\.env$'
```

Expected: `0`. The real `.env` must not appear as an untracked file Git is offering to add. If it shows up, Task 1.3.1 did not take effect.

#### Task 1.3.3: Write the Makefile that bridges .env into Terraform

**Goal:** A working `gmake check-env`, and the mechanism that turns `.env` keys into `TF_VAR_*` variables Terraform can read.

**Why:** Terraform does not read `.env` files, so something has to carry the values across. This Makefile is the concrete implementation of the arrow in the decision-4 diagram. The `check-env` guard exists because the failure it prevents is slow and confusing to diagnose: Terraform applying with an empty password, producing a Postgres instance nobody can log into.

Terraform does not read `.env` files. This Makefile sources `.env` and exports the values as `TF_VAR_*` environment variables, which Terraform does read. This is the concrete implementation of the arrow in the decision-4 diagram.

**Requires GNU Make 4.x, invoked as `gmake`.** The `.ONESHELL:` and `.SHELLFLAGS` lines below need Make 3.82 or newer, and macOS ships 3.81. Task 1.1.1 covers the install and explains what breaks otherwise. Recipe lines must be indented with **tabs**, not spaces; if your editor converts them you will get `missing separator`.

**File:** `lfi-infrastructure-gitops/Makefile`

```makefile
# ---------------------------------------------------------------------------
# Shell behaviour. All three lines are load-bearing.
# ---------------------------------------------------------------------------
# Use bash, not /bin/sh. The recipes below rely on [[ ]] and ${!var}.
SHELL := /bin/bash

# Run each recipe as ONE shell script instead of one shell per line.
# Without this, `cd terraform/01-cluster` would not survive into the next
# line and Terraform would run in the repo root. Needs GNU Make >= 3.82,
# so invoke this file with gmake, not Apple's make. See Task 1.1.1.
.ONESHELL:

# -e           abort the target on the first command that fails
# -u           treat an unset variable as an error, not an empty string
# -o pipefail  a pipeline fails if ANY stage fails, not just the last
# -c           required: this is how make hands the recipe text to the shell
.SHELLFLAGS := -eu -o pipefail -c

# ---------------------------------------------------------------------------
# Variables. := assigns once, immediately, as opposed to = which re-expands
# on every use.
# ---------------------------------------------------------------------------
CLUSTER  := platform

# Used by resume. Also here because ad-hoc kubectl commands want it.
CONTEXT  := k3d-$(CLUSTER)

# CURDIR is the directory make was invoked from, so ENV_FILE is absolute and
# stays correct after a recipe does `cd`.
#
# Do NOT put a trailing comment on this line. Make strips the comment but
# keeps the whitespace before it, so the path would gain trailing spaces and
# the -f test in check-env would fail on a file that exists.
ENV_FILE := $(CURDIR)/.env

# Declare targets that are names of actions, not files to be built. Without
# this, a file called `up` appearing in this directory would make `gmake up`
# say "nothing to be done".
.PHONY: help check-env cluster-up platform-up up pause resume down destroy

# ---------------------------------------------------------------------------
# help: self-documenting target list.
#
# Greps this file for lines of the form `target: ## description` and prints
# them in cyan. Adding `## something` to any target below is all it takes to
# get it listed. $$ is how you write a literal $ in a Makefile: make eats one.
# ---------------------------------------------------------------------------
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# check-env: the guard. Every apply target depends on this, so a bad .env
# stops you before Terraform touches anything.
#
# Note the comments inside this recipe are NOT tab-indented. That keeps them
# make comments, dropped before the shell ever sees them. Indent one with a
# tab and it becomes part of the script and gets echoed at runtime.
# ---------------------------------------------------------------------------
check-env: ## Fail fast if .env is missing or incomplete
# 1. The file has to exist at all.
	if [[ ! -f "$(ENV_FILE)" ]]; then
	  echo "ERROR: $(ENV_FILE) not found. Copy .env.example to .env and fill it in." >&2
	  exit 1
	fi
# 2. Load it. `set -a` makes every subsequent assignment an export, so sourcing
#    the file puts its keys in the environment rather than only in shell-local
#    variables. `set +a` turns that back off.
	set -a; source "$(ENV_FILE)"; set +a
# 3. Every required key must be non-empty. ${!var} is bash indirect expansion:
#    it reads the variable *named by* $var. The :- suffix stops `set -u` from
#    aborting before we can print a useful message.
	for var in POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB GITOPS_REPO_URL; do
	  if [[ -z "$${!var:-}" ]]; then
	    echo "ERROR: $$var is unset or empty in .env" >&2
	    exit 1
	  fi
	done
# 4. Reject the placeholder from .env.example. Copying the example and
#    forgetting to edit it is the single most likely mistake here.
	if [[ "$$POSTGRES_PASSWORD" == "change-me" ]]; then
	  echo "ERROR: POSTGRES_PASSWORD is still the placeholder value." >&2
	  exit 1
	fi
	echo "OK: .env looks complete."

# ---------------------------------------------------------------------------
# cluster-up: stage 1 of the two-stage split. Creates the k3d cluster using
# only the null provider, so nothing needs a reachable cluster at plan time.
# No TF_VAR_* exports here: this module takes no secrets.
# ---------------------------------------------------------------------------
cluster-up: check-env ## Stage 1: create the k3d cluster
	cd terraform/01-cluster
# -input=false makes Terraform fail rather than prompt, which is what you want
# in a scripted path. A prompt here would mean a variable is missing.
	terraform init -input=false
	terraform apply -auto-approve -input=false

# ---------------------------------------------------------------------------
# platform-up: stage 2. Configures resources *inside* the cluster, so its
# kubernetes and helm providers need stage 1 to have already run.
# This is where the .env -> Terraform bridge actually happens.
# ---------------------------------------------------------------------------
platform-up: check-env ## Stage 2: secret, ArgoCD, root application
	set -a; source "$(ENV_FILE)"; set +a
# Terraform reads variables from TF_VAR_<name>, never from .env directly.
# Renaming either side breaks the link to variables.tf, so keep them in step.
	export TF_VAR_postgres_user="$$POSTGRES_USER"
	export TF_VAR_postgres_password="$$POSTGRES_PASSWORD"
	export TF_VAR_postgres_db="$$POSTGRES_DB"
	export TF_VAR_gitops_repo_url="$$GITOPS_REPO_URL"
	cd terraform/02-platform
	terraform init -input=false
	terraform apply -auto-approve -input=false

# ---------------------------------------------------------------------------
# up: the only bring-up command you should need. Prerequisites run left to
# right, which is what enforces cluster-before-platform.
# ---------------------------------------------------------------------------
up: cluster-up platform-up ## Full bring-up, in the required order

# ---------------------------------------------------------------------------
# pause / resume: the cheapest lifecycle pair. Neither one touches Terraform,
# because nothing about the desired state changes: the node containers are
# simply stopped and started again.
#
# Reach for these when you are stepping away. `down` and `destroy` both throw
# work away and cost minutes to undo; pause costs seconds and keeps images,
# PVCs, and the kube context exactly as they were. Quitting OrbStack has the
# same effect implicitly, so a paused cluster is also what you get after a
# reboot.
# ---------------------------------------------------------------------------
pause: ## Stop the cluster containers, keeping all state
	k3d cluster stop $(CLUSTER)

resume: ## Start a paused cluster and wait for its nodes
	k3d cluster start $(CLUSTER)
# k3d returns as soon as the containers are running, which is well before k3s
# inside them is serving. Without this wait the next kubectl in your shell
# tends to fail with a connection refused, which looks like a broken cluster
# and is not. Pods need another moment beyond this to finish restarting.
	kubectl --context $(CONTEXT) wait --for=condition=Ready nodes --all --timeout=120s

# ---------------------------------------------------------------------------
# down: undo stage 2 only. The cluster survives, so this is the cheap way to
# reset ArgoCD without waiting on a k3s image pull again.
#
# This removes the postgres-credentials Secret. The PVC and its data are
# untouched, because ArgoCD created those, not Terraform.
# ---------------------------------------------------------------------------
down: ## Remove in-cluster platform resources, keep the cluster
	cd terraform/02-platform
	terraform destroy -auto-approve -input=false

# ---------------------------------------------------------------------------
# destroy: full teardown, in reverse order. Deletes the cluster and therefore
# the PVC and every row in the database.
# ---------------------------------------------------------------------------
destroy: ## Tear down everything including the cluster
# The leading - tells make to carry on even if this fails. Deliberate: if the
# cluster is already gone, stage 2's destroy cannot reach it, and that should
# not block deleting the cluster itself.
	-$(MAKE) down
	cd terraform/01-cluster
	terraform destroy -auto-approve -input=false
```

The `check-env` target exists because the failure mode it prevents (Terraform applying with an empty password, producing a Postgres instance nobody can log into) is slow and confusing to diagnose.

Note the three ways to stop, in ascending order of cost. `pause` stops the node containers and keeps everything, so `resume` takes seconds. `down` removes what Terraform put inside the cluster but leaves the cluster standing. `destroy` deletes the cluster, and with it every PVC, so the database goes too. When you are just closing the laptop, you want `pause`.

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
gmake check-env
```

Expected: `OK: .env looks complete.` Now prove the guard works:

```bash
mv .env .env.bak && gmake check-env; mv .env.bak .env
```

Expected: the missing-file error and a non-zero exit, then the file is restored.

#### Task 1.3.4: Commit Phase 1

**Goal:** The scaffolding committed, with `.env` provably absent from what you pushed.

**Why:** Phase boundary, and the first real test that Task 1.3.1 actually worked. The Validate here checks the thing that matters rather than that the commit succeeded.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
git add .gitignore .env.example Makefile
git commit -m "chore: repo scaffolding, env bridge, and ignore rules"
git push
```

**Validate:**

```bash
git log --oneline -1 && git status --porcelain
```

Expected: your commit on the first line, and no `.env` in the status output.

---

## Section 2: Local Cluster Infrastructure

**Objective:** A running k3d cluster, created by Terraform, with Traefik answering on `localhost:8080`. At the end of this section you have a real Kubernetes cluster you can `kubectl` against.

### Primer: what you are actually building

Three layers are stacked here, and they are easy to confuse.

- **k3s** is a full, certified Kubernetes distribution that Rancher stripped down to a single binary. It removes things a local or edge cluster does not need (cloud provider integrations, alpha features, legacy storage drivers) and bundles a few things it does need. It is not "Kubernetes lite" in the sense of being incomplete; your manifests are ordinary Kubernetes manifests.
- **k3d** runs k3s nodes as Docker containers. Each "node" in your cluster is a container on your Mac. That is what makes creating and destroying clusters take seconds instead of minutes.
- **OrbStack** is the Docker engine those containers run on.

So the full stack is: OrbStack runs containers, k3d makes some of those containers into k3s nodes, and k3s is Kubernetes.

**How traffic reaches your app.** This trips people up more than anything else in this section, so it is worth walking through the whole path:

```
  curl http://localhost:8080/
            |
            v
  [ Mac port 8080 ]                        <- k3d published this port
            |
            v
  [ k3d load balancer container ]          <- a small proxy k3d creates for you
            |
            v
  [ Traefik pod, port 80 ]                 <- the ingress controller, ships with k3s
            |
            v   (matches an Ingress rule)
  [ your Service ] -> [ your Pod ]
```

Two pieces of vocabulary that get used interchangeably but are not the same thing:

- An **Ingress** is a Kubernetes object. It is just a rule: "requests for this path go to that Service." On its own it does nothing at all.
- An **ingress controller** is the program that reads those rules and actually routes traffic. Here that is **Traefik**, which k3s installs by default.

An Ingress with no controller running is an inert piece of YAML. This is the single most common reason a local Kubernetes tutorial "doesn't work".

**One important constraint:** the `8080:80` port mapping is fixed when the cluster is created and cannot be added to a running cluster. If you get it wrong you have to destroy and recreate. That is cheap here, but it explains why Task 2.1.1 puts the port in a config file rather than leaving it to be added later.

### Phase 2.1: Terraform cluster module

#### Task 2.1.1: Write the k3d cluster config

**Goal:** A declarative description of the cluster's shape, including the `8080:80` port mapping.

**Why:** Keeping cluster shape in a file rather than a pile of CLI flags lets Terraform hash it and rebuild when it changes. The port mapping in particular has to live here rather than being added later, because it is fixed at creation time: getting it wrong means destroy and recreate.

Keeping cluster shape in a declarative YAML rather than a pile of CLI flags means Terraform can hash the file and recreate the cluster when it changes.

**File:** `lfi-infrastructure-gitops/terraform/01-cluster/k3d-config.yaml`

```yaml
# k3d's own config schema, not Kubernetes YAML. `kind: Simple` is k3d's
# single-cluster format.
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  # Becomes the kube context name, prefixed: k3d-platform.
  name: platform
# 1 server (control plane, also schedulable) + 1 agent (worker).
# agents: 0 works and is leaner; agents: 2 lets you watch pods spread.
servers: 1
agents: 1
# Pinned k3s version. Unpinned, a rebuild months from now would silently
# give you a different Kubernetes minor version.
#
# v1.36.x is the current supported line. v1.31 reached end of life in
# February 2026 and receives no security patches. This image ships Traefik v3
# and containerd v2; nothing in this plan depends on the older versions.
#
# Note k3d 5.9.0 defaults to v1.35.5-k3s1, so this pin is one minor ahead of
# what k3d ships. That is supported but not the combination k3d tests most.
# If cluster creation misbehaves, dropping to v1.35.5-k3s1 is the first thing
# to try.
image: rancher/k3s:v1.36.4-k3s1
ports:
  # Host 8080 -> the k3d load balancer -> Traefik on port 80 in-cluster.
  #
  # This mapping is fixed at CREATION time and cannot be added later. Getting
  # it wrong means destroy and recreate, which is why it lives in this file
  # rather than being passed as a flag.
  - port: 8080:80
    nodeFilters:
      # Attach to the load balancer container k3d creates, not to a node.
      - loadbalancer
options:
  k3d:
    # Do not return until the cluster is up, so Terraform's next step is safe.
    wait: true
    timeout: "180s"
  kubeconfig:
    # Merge into ~/.kube/config, or into $KUBECONFIG if you have set it.
    updateDefaultKubeconfig: true
    # Switches your active context to k3d-platform. Convenient here, and the
    # exact behaviour to be careful about if you also use kubectl for work.
    switchCurrentContext: true
```

Note there is no line disabling Traefik. k3s installs it by default and this plan wants exactly that. Many k3d guides disable it to install their own ingress controller, so do not copy that step from elsewhere.

Two things deliberately absent:

- **Traefik is not disabled.** k3s ships Traefik as its default ingress controller and the architecture calls for exactly that. Many k3d guides disable it to install their own; do not follow them here.
- **`agents: 1`** rather than 2. One server plus one agent is the sweet spot for the RAM budget. Set `agents: 0` to go leaner still (the k3s server node is schedulable by default), or `agents: 2` if you want to watch the scheduler spread pods.

#### Task 2.1.2: Write the cluster Terraform module

**Goal:** A module that passes `terraform validate`, declaring only the `null` provider.

**Why:** This is the two-module split in practice, and the reason for it is a real Terraform constraint rather than a style preference. The `kubernetes` and `helm` providers need a reachable cluster when the plan is built, and the cluster does not exist yet, so this module must not declare them. Collapse the two modules into one and the first apply can never succeed.

This module uses only the `null` and `local` providers, so it never needs to reach a cluster at plan time. That is the whole point of the two-module split.

**File:** `lfi-infrastructure-gitops/terraform/01-cluster/main.tf`

```hcl
# ---------------------------------------------------------------------------
# Stage 1 of the two-module split.
#
# The critical property of this file: it declares NO kubernetes or helm
# provider. Those need a reachable cluster when the plan is built, and the
# cluster does not exist yet. Only `null` is used, which needs nothing.
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

variable "cluster_name" {
  type        = string
  description = "Name of the k3d cluster. Kube context becomes k3d-<name>."
  default     = "platform"
}

# `locals` are computed values, not inputs. path.module is this directory, so
# the reference holds no matter where you invoke terraform from.
locals {
  config_path = "${path.module}/k3d-config.yaml"
}

# null_resource exists purely to hang provisioners off. There is no k3d
# Terraform provider, so the cluster is created by shelling out. That is a
# compromise: Terraform cannot see inside the cluster, only whether the
# triggers below changed.
resource "null_resource" "cluster" {
  # Recreate the cluster if its name or its shape changes.
  #
  # This map is the whole of Terraform's understanding of this resource. If a
  # value here is unchanged, the provisioner does not re-run, which is what
  # makes a second `gmake cluster-up` a genuine no-op (Task 2.1.4).
  # filesha256 hashes the config file, so editing ports or node counts
  # correctly forces a rebuild.
  triggers = {
    cluster_name  = var.cluster_name
    config_sha256 = filesha256(local.config_path)
  }

  provisioner "local-exec" {
    # Explicit bash, because the heredoc below uses pipefail.
    interpreter = ["/bin/bash", "-c"]
    # <<-EOT strips the leading indentation from the heredoc body.
    command     = <<-EOT
      set -euo pipefail

      # Adopt an existing cluster rather than failing on it. Makes the module
      # recoverable if state was lost but the cluster is still running.
      if k3d cluster list "${var.cluster_name}" >/dev/null 2>&1; then
        echo "Cluster '${var.cluster_name}' already exists, reusing it."
      else
        echo "Creating cluster '${var.cluster_name}'..."
        k3d cluster create --config "${local.config_path}"
      fi

      # Do not return until the API server will actually accept work. Without
      # this, stage 2 can start against a cluster whose nodes are NotReady.
      echo "Waiting for nodes to become Ready..."
      kubectl --context "k3d-${var.cluster_name}" \
        wait --for=condition=Ready nodes --all --timeout=180s
    EOT
  }

  # Runs on `terraform destroy` instead of on create.
  #
  # A destroy provisioner may only reference `self`, never `var` or `local`,
  # because the variables may be gone by the time it runs. That is the reason
  # cluster_name is stored in triggers above and read back from there.
  provisioner "local-exec" {
    when    = destroy
    command = "k3d cluster delete ${self.triggers.cluster_name}"
  }
}

# Outputs are this module's public interface. Nothing wires them into stage 2
# automatically here (no remote state data source yet), so they serve as
# documentation and as a check that the two modules agree on names.
output "cluster_name" {
  value       = var.cluster_name
  description = "Pass this to the 02-platform module."
}

output "kube_context" {
  value       = "k3d-${var.cluster_name}"
  description = "kubectl context name for the created cluster."
}
```

A destroy provisioner may only reference `self`, never `var`, which is why the cluster name is stored in `triggers` and read back as `self.triggers.cluster_name`. Terraform will reject the config otherwise.

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops/terraform/01-cluster
terraform init
terraform validate
```

Expected: `Success! The configuration is valid.`

#### Task 2.1.3: Create the cluster

**Goal:** Two `Ready` nodes, with your kube context switched to `k3d-platform`.

**Why:** The first point in this guide where you have real Kubernetes rather than files describing it.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
gmake cluster-up
```

This takes 30 to 90 seconds on a first run, most of it pulling the k3s image.

**Validate:**

```bash
kubectl config current-context
kubectl get nodes -o wide
```

Expected: context is `k3d-platform`, and two nodes (`k3d-platform-server-0` and `k3d-platform-agent-0`) in `Ready` status.

#### Task 2.1.4: Confirm idempotency

**Goal:** A second apply that reports no changes and does not re-run the provisioner.

**Why:** If the triggers are wrong you get surprise cluster rebuilds later, and a cluster rebuild destroys the database. Far better to find that out now, with nothing in the database, than during Section 8 when a rebuild would cost you the persistence proof from Section 4.

A second apply must be a no-op. If it is not, the triggers are wrong and you will get surprise cluster rebuilds later.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
gmake cluster-up
```

**Validate:** the output ends with `No changes. Your infrastructure matches the configuration.` and the log line `Cluster 'platform' already exists, reusing it.` does **not** appear, because Terraform should not re-run the provisioner at all.

### Phase 2.2: Cluster and ingress verification

#### Task 2.2.1: Confirm Traefik came up

**Goal:** Confirmation that an ingress controller is actually running, not merely installed.

**Why:** An Ingress with no controller reading it is inert YAML that produces no error. This is the single most common reason a local Kubernetes tutorial appears not to work, and checking here means you never spend time debugging a correct Ingress.

k3s v1.36 ships **Traefik v3**. Nothing in this plan depends on v2 behaviour: the Ingress below uses `networking.k8s.io/v1` and `ingressClassName`, both of which v3 handles identically. The one thing that changed is Traefik's own CRDs (`IngressRoute` and friends), which this project never uses.

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik
kubectl -n kube-system get svc traefik
```

**Validate:** the Traefik pod is `Running` with `1/1` ready, and the `traefik` service is type `LoadBalancer` with an assigned external IP.

If the label selector returns nothing, the chart's labels have moved rather than Traefik being absent. Fall back to `kubectl -n kube-system get pods | grep traefik` and carry on; the port test in Task 2.2.2 is the assertion that actually matters.

#### Task 2.2.2: Prove the host port mapping works end to end

**Goal:** A real HTTP response travelling the whole path from your Mac to a pod.

**Why:** Two reasons to do this with a throwaway workload now rather than with the real app later. If it fails once your app is deployed, a dozen things could be to blame and the port mapping is the least obvious. And because the fix is destroy and recreate, you want to discover it while the cluster contains nothing you care about.

Do not wait until the real app is deployed to discover the port mapping is wrong. Test it now with a throwaway workload.

```bash
kubectl create deployment ingress-probe --image=traefik/whoami --port=80
kubectl expose deployment ingress-probe --port=80 --target-port=80

kubectl create ingress ingress-probe \
  --class=traefik \
  --rule="/probe*=ingress-probe:80"

kubectl rollout status deployment/ingress-probe --timeout=60s
```

**Validate:**

```bash
curl -s http://localhost:8080/probe
```

Expected: a `whoami` response block containing `Hostname:`, `IP:`, and `RemoteAddr:` lines. If you get `curl: (52) Empty reply` or a connection refusal, the `8080:80@loadbalancer` mapping did not apply; see Appendix B.

#### Task 2.2.3: Clean up the probe

**Goal:** No probe resources left anywhere in the cluster.

**Why:** ArgoCD in Section 6 continuously compares the cluster against Git. Anything left here becomes drift it cannot explain, and you would be debugging a Section 2 leftover while trying to learn Section 6.

Leaving test resources behind will confuse ArgoCD later, since it will see workloads in the cluster that are not in Git.

```bash
kubectl delete ingress ingress-probe
kubectl delete service ingress-probe
kubectl delete deployment ingress-probe
```

**Validate:**

```bash
kubectl get deploy,svc,ingress -l app=ingress-probe
```

Expected: `No resources found in default namespace.`

#### Task 2.2.4: Commit Section 2

**Goal:** Section 2 committed, with the tracker rows updated in the same commit.

**Why:** Phase boundary. Updating the tracker in the same commit is what keeps it trustworthy across sessions.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
git add terraform/01-cluster
git commit -m "feat(infra): provision k3d cluster with Traefik ingress via Terraform"
git push
```

Update the tracker rows for Phases 2.1 and 2.2 to ☑ Done in the same commit.

**Validate:**

```bash
git status --porcelain
```

Expected: empty output. Note that `terraform.tfstate` is correctly absent because `.gitignore` covers it.

### What just happened

**Milestone 1.** You have a real Kubernetes cluster, and you did not create it by running `k3d cluster create` at a prompt. You described it in a file and asked Terraform to make reality match.

That distinction is the whole of Infrastructure as Code, and it is worth noticing what it bought you in Task 2.1.4: running apply a second time did nothing, because reality already matched. A shell script would have tried to create the cluster again and failed. Terraform compares desired state to recorded state and acts only on the difference. That property is called idempotency, and it is why `gmake up` will be safe to run at any time for the rest of this project.

You also hit the constraint that forced the two-module split. Worth re-reading that explanation now that you have seen the providers in action, because it is the kind of thing that reads as arbitrary until you have run into it.

---

## Section 3: Application Services

**Objective:** Two small FastAPI services that exercise the architectural boundaries the platform is meant to prove, plus a local development loop that runs them without Kubernetes.

**Design contract.** The services are stubs, but the boundaries are real and worth respecting exactly:

| | service-1 (gateway) | service-2 (worker) |
|---|---|---|
| Receives | external HTTP via Traefik | internal HTTP from service-1 only |
| Talks to | service-2 over cluster DNS, and Postgres | nothing |
| Database access | yes, exclusively | **none**, by design |
| State | none of its own | none |

service-2 having zero database access is the point of the split. If you find yourself wanting to give it a connection, that is the signal you have drifted from the architecture.

Build service-2 first: it has no dependencies, so it can be finished and tested in isolation.

### Primer: where packages come from

Many corporate machines configure pip to use an internal package mirror. If yours does, `~/.config/pip/pip.conf` will set something like `index-url = https://pypi.internal.example.com/simple`, and that becomes the default for every Python project on the machine. This project deliberately resolves from **public PyPI** instead, so that what you install locally is the same thing CI installs and the same thing that ends up inside the image.

The fix is one file per virtual environment, and it changes nothing outside that environment:

```bash
printf '[global]\nindex-url = https://pypi.org/simple\n' > .venv/pip.conf
```

pip reads three layers of configuration, in order: system-wide, then user, then the active virtual environment. The last one wins, so this overrides your user default for this venv and nothing else. `.venv/` is gitignored in both app repos (Tasks 3.1.4 and 3.2.5), so the file is never committed, and you rewrite it whenever you recreate the venv. To override a single command instead, `pip install --index-url https://pypi.org/simple ...` does the same job.

Confirm which index is actually in effect at any point:

```bash
pip config list     # the resolved value
pip config debug    # every layer, and which file each value came from
```

**Two places that need nothing.** A Docker build never sees your host's pip config, so it already resolves publicly. GitHub Actions runners carry no corporate pip configuration at all. That is precisely why the pinned versions have to exist on public PyPI: a version available only on the internal mirror would install cleanly on your Mac and then fail in CI, which is a slow and confusing way to find out.

Nothing else in this plan is affected. Homebrew, the Docker Hub images (`rancher/k3s`, `postgres`, `python:3.12-slim`, `traefik/whoami`), the argo Helm repository, and GHCR are all public and pulled directly.

If you ever swap pip for `uv`, note that `UV_INDEX_URL` and `UV_DEFAULT_INDEX` may be set in your environment, and environment variables take precedence over config files. Pass `--default-index https://pypi.org/simple` or unset them for that shell.

### Phase 3.1: service-2, the stateless worker

#### Task 3.1.1: Scaffold the package

**Goal:** A venv pointed at public PyPI, with dev dependencies installed and importable.

**Why:** The `pip.conf` step is the one that matters and the one easiest to skip. If this venv resolves against that internal mirror, a pinned version that exists only there will install cleanly on your Mac and then fail in CI, which is a slow and confusing way to discover the problem. Note there is no `[project]` table in `pyproject.toml` on purpose: these services ship as container images, not as Python packages.
mkdir -p src tests
touch src/__init__.py tests/__init__.py
```

**File:** `lfi-service-2-app/requirements.txt`

```text
fastapi==0.141.1
uvicorn[standard]==0.52.4
```

**File:** `lfi-service-2-app/requirements-dev.txt`

```text
-r requirements.txt
pytest==9.1.1
pytest-asyncio==1.4.0
httpx==0.28.1
ruff==0.16.5
```

**File:** `lfi-service-2-app/pyproject.toml`

```toml
# Configuration for this repo's dev tooling only. Nothing here describes the
# application: there is no [project] table and no build backend, because
# service-2 ships as a container image, not as a Python package. Runtime
# dependencies live in requirements.txt, dev ones in requirements-dev.txt.

# ---------------------------------------------------------------------------
# pytest. Picked up automatically by a bare `pytest` run from the repo root.
# ---------------------------------------------------------------------------
[tool.pytest.ini_options]
# Run async test functions without decorating each one with
# @pytest.mark.asyncio. Almost every test here is async, because the suite
# drives the app in-process through httpx.AsyncClient.
asyncio_mode = "auto"
# Required from pytest-asyncio 1.x. Leave it unset and every run prints a
# deprecation warning. "function" is the historical default, so setting it
# explicitly changes no behaviour, it just silences the warning.
asyncio_default_fixture_loop_scope = "function"
# Where to collect tests from. This narrows collection, nothing more. The
# separate reason `from src.main import ...` resolves is tests/__init__.py:
# it makes pytest walk up to the repo root and put that on sys.path.
testpaths = ["tests"]

# ---------------------------------------------------------------------------
# ruff: linter and import sorter, invoked as `ruff check src tests`.
# ---------------------------------------------------------------------------
[tool.ruff]
line-length = 100
# Tells ruff it may assume 3.12 syntax exists. This is what lets the UP rules
# below suggest modern replacements instead of staying silent.
target-version = "py312"

[tool.ruff.lint]
# E   pycodestyle errors: the formatting basics
# F   pyflakes: real problems, such as unused imports and undefined names
# I   isort: keeps import blocks ordered and grouped
# UP  pyupgrade: flags syntax that 3.12 has a cleaner form for
# B   bugbear: likely-bug patterns, such as mutable default arguments
select = ["E", "F", "I", "UP", "B"]

[tool.ruff.lint.flake8-bugbear]
# FastAPI's Depends/Query/Path in argument defaults is the framework's
# intended style, not the mutable-default bug B008 exists to catch.
extend-immutable-calls = [
  "fastapi.Depends", "fastapi.Query", "fastapi.Path", "fastapi.Body",
  "fastapi.Header", "fastapi.Cookie", "fastapi.File", "fastapi.Form",
  "fastapi.Security",
]
```

`asyncio_mode = "auto"` means async test functions run without needing a decorator on each one. It is still fully supported in pytest-asyncio 1.x; what 1.0 removed was the separate `event_loop` fixture, which this project never used.

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-service-2-app
python3.12 -m venv .venv && source .venv/bin/activate

# Point this venv, and only this venv, at public PyPI. See the primer above.
printf '[global]\nindex-url = https://pypi.org/simple\n' > .venv/pip.conf
pip config list

pip install -r requirements-dev.txt
python -c "import fastapi, httpx, pytest; print('deps ok')"
```

Expected: `pip config list` prints `global.index-url='https://pypi.org/simple'`, then the install runs and prints `deps ok`. If `pip config list` still shows `pypi.internal.example.com`, the `pip.conf` did not land where pip expects it; `pip config debug` will show which file won.

#### Task 3.1.2: Write the failing tests first

**Goal:** A test suite that fails with `ModuleNotFoundError`, because the module it imports does not exist yet.

**Why:** A test you have never seen fail is a test you cannot trust. Watching it fail for the right reason proves it is actually exercising the code rather than passing vacuously. The transform here is trivial, which is precisely why writing the test first costs nothing while still establishing the habit for Phase 3.2, where the tests are doing real work.

**File:** `lfi-service-2-app/tests/test_main.py`

```python
import httpx
import pytest

# Importing from src.main is what fails right now, and that is the point:
# the test file is written before the module exists.
from src.main import app, transform


# ---------------------------------------------------------------------------
# Pure-function tests. No app, no client, no I/O. These run in microseconds
# and are the reason `transform` was kept separate from the route handler.
# ---------------------------------------------------------------------------
def test_transform_doubles_its_input():
    assert transform(21) == 42


def test_transform_handles_zero():
    assert transform(0) == 0


def test_transform_handles_negatives():
    assert transform(-7) == -14


# ---------------------------------------------------------------------------
# HTTP-level tests. ASGITransport calls the app directly in-process: no
# socket, no port, no uvicorn. It also does NOT run lifespan events, which
# matters enormously for service-1 and not at all here.
#
# No @pytest.mark.asyncio decorator is needed because pyproject.toml sets
# asyncio_mode = "auto".
# ---------------------------------------------------------------------------
@pytest.fixture
async def client():
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as c:
        # yield, not return: everything after this runs as teardown, which is
        # what closes the client even if the test fails.
        yield c


async def test_healthz_returns_ok(client):
    response = await client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


async def test_process_returns_the_doubled_value(client):
    response = await client.post("/process", json={"value": 21})
    assert response.status_code == 200
    # Asserting the whole body, not just one field. That pins the response
    # shape, which the Kubernetes probes and service-1 both depend on.
    assert response.json() == {
        "service": "service-2",
        "input": 21,
        "result": 42,
    }


async def test_process_rejects_a_non_integer_value(client):
    response = await client.post("/process", json={"value": "not-a-number"})
    # 422, not 400 or 500. FastAPI validates against the Pydantic model before
    # the handler is ever called, so this is free rather than hand-written.
    assert response.status_code == 422
```

`httpx.ASGITransport` calls the app in-process without a network socket and, importantly, **without running lifespan events**. That matters much more for service-1 in Phase 3.2, where lifespan opens a real database connection.

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-service-2-app
pytest -v
```

Expected: collection fails with `ModuleNotFoundError: No module named 'src.main'`. That is the correct failure at this point.

#### Task 3.1.3: Implement service-2

**Goal:** The tests from Task 3.1.2 passing, with no code written beyond what they demanded.

**Why:** Two design choices in this file pay off much later. `transform` is a pure function separate from the route handler, which is what lets it be tested with no I/O at all. And `/process` echoes its own service name, which is what lets service-1's response in Phase 3.2 prove the internal DNS hop genuinely happened rather than being faked locally.

**File:** `lfi-service-2-app/src/main.py`

```python
from fastapi import FastAPI
from pydantic import BaseModel

# No lifespan handler, unlike service-1. This service opens no connections to
# anything, so there is nothing to set up or tear down.
app = FastAPI(title="service-2-worker", version="1.0.0")


# ---------------------------------------------------------------------------
# Request and response schemas. Declaring these buys three things at once:
# input validation, the 422 on bad input, and the OpenAPI docs at /docs.
# ---------------------------------------------------------------------------
class ProcessRequest(BaseModel):
    # `int`, not `str`. This single annotation is what rejects "not-a-number".
    value: int


class ProcessResponse(BaseModel):
    service: str
    input: int
    result: int


def transform(value: int) -> int:
    """The stub's entire business logic: deliberately trivial and pure.

    Pure so it is testable without any I/O, which is what lets service-2
    stay free of a database connection.
    """
    return value * 2


@app.get("/healthz")
def healthz() -> dict[str, str]:
    """Liveness. Has no dependencies, so it must never fail while the
    process is alive."""
    # No readiness endpoint here, deliberately. Readiness answers "can I reach
    # my dependencies", and this service has none, so it would duplicate
    # liveness. service-1 does need both.
    return {"status": "ok"}


# `def`, not `async def`. There is no await in the body, so FastAPI runs this
# in a threadpool and nothing blocks the event loop either way.
@app.post("/process", response_model=ProcessResponse)
def process(request: ProcessRequest) -> ProcessResponse:
    return ProcessResponse(
        # Echoing the service name is what lets service-1's response prove the
        # internal DNS hop actually happened rather than being faked locally.
        service="service-2",
        input=request.value,
        result=transform(request.value),
    )
```

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-service-2-app
pytest -v && ruff check src tests
```

Expected: `6 passed`, and ruff reports `All checks passed!`.

#### Task 3.1.4: Commit service-2's application code

**Goal:** service-2's code committed, with `.venv` untracked.

**Why:** Phase boundary. The `.venv` check is the part worth running: it holds the `pip.conf` from Task 3.1.1 plus a full dependency tree, and neither belongs in Git.

```bash
cd $PLATFORM_HOME/lfi-service-2-app
printf '.venv/\n__pycache__/\n*.pyc\n.pytest_cache/\n.ruff_cache/\n.DS_Store\n' > .gitignore
git add .
git commit -m "feat: stateless worker service with process endpoint"
git push
```

**Validate:** `git status --porcelain` is empty and `.venv` is not tracked.

### Phase 3.2: service-1, the gateway

#### Task 3.2.1: Scaffold the package

**Goal:** A second venv, also pinned to public PyPI, with `asyncpg` and `httpx` importable.

**Why:** pip config is per-venv, so this repo cannot inherit service-2's and needs its own `pip.conf`. The dependency list is the interesting difference between the two services: `httpx` and `asyncpg` appear here because service-1 is the only one that talks to anything else.

```bash
cd $PLATFORM_HOME/lfi-service-1-app
mkdir -p src tests
touch src/__init__.py tests/__init__.py
```

**File:** `lfi-service-1-app/requirements.txt`

```text
fastapi==0.141.1
uvicorn[standard]==0.52.4
httpx==0.28.1
asyncpg==0.31.0
```

**File:** `lfi-service-1-app/requirements-dev.txt`

```text
-r requirements.txt
pytest==9.1.1
pytest-asyncio==1.4.0
ruff==0.16.5
```

**File:** `lfi-service-1-app/pyproject.toml`

Same settings as service-2's, with the comments trimmed. The `flake8-bugbear` block at the bottom is the part that matters here, and Task 3.2.4 explains why:

```toml
[tool.pytest.ini_options]
asyncio_mode = "auto"
# Required from pytest-asyncio 1.x, see Task 3.1.1.
asyncio_default_fixture_loop_scope = "function"
testpaths = ["tests"]

[tool.ruff]
line-length = 100
target-version = "py312"

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B"]

[tool.ruff.lint.flake8-bugbear]
# FastAPI's Depends/Query/Path in argument defaults is the framework's
# intended style, not the mutable-default bug B008 exists to catch.
extend-immutable-calls = [
  "fastapi.Depends", "fastapi.Query", "fastapi.Path", "fastapi.Body",
  "fastapi.Header", "fastapi.Cookie", "fastapi.File", "fastapi.Form",
  "fastapi.Security",
]
```

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-service-1-app
python3.12 -m venv .venv && source .venv/bin/activate

# Same public-PyPI pin as service-2. One file per venv, so this repo needs
# its own. See the primer at the top of Section 3 for why.
printf '[global]\nindex-url = https://pypi.org/simple\n' > .venv/pip.conf
pip config list

pip install -r requirements-dev.txt
python -c "import asyncpg, httpx, fastapi; print('deps ok')"
```

Expected: `global.index-url='https://pypi.org/simple'`, then `deps ok`.

#### Task 3.2.2: Write the config module

**Goal:** One module that is the only place this service reads an environment variable.

**Why:** The four `POSTGRES_*` names in this file must match the keys in the Kubernetes Secret and the env vars in service-1's Deployment. Keeping the reads in one place means that contract has a single surface to agree on rather than being scattered through the codebase. Note the deliberate `os.environ[...]` rather than `.get`: a gateway with no database credentials should refuse to start rather than come up half-working, and in Kubernetes that surfaces as an obvious CrashLoopBackOff instead of mysterious runtime errors.

**File:** `lfi-service-1-app/src/config.py`

```python
import os


def database_url() -> str:
    """Assemble the Postgres DSN from discrete environment variables.

    The password arrives via a Kubernetes secretKeyRef, so it is never
    written into a manifest, an image, or this repository. The remaining
    parts are plain config.
    """
    # os.environ[...] raises KeyError when a variable is missing, which is
    # deliberate: a gateway with no database credentials should refuse to
    # start rather than come up half-working. In Kubernetes that surfaces as
    # CrashLoopBackOff, which is a clear signal.
    #
    # These four names must match the keys in the postgres-credentials Secret
    # and the plain env vars in service-1's Deployment. That agreement is the
    # one contract between the manifests and this code.
    user = os.environ["POSTGRES_USER"]
    password = os.environ["POSTGRES_PASSWORD"]
    host = os.environ["POSTGRES_HOST"]
    # .get with a default: port is the one value that has a sane fallback.
    port = os.environ.get("POSTGRES_PORT", "5432")
    database = os.environ["POSTGRES_DB"]
    # Built here rather than stored as a single DSN env var, so the password
    # stays a discrete Secret key instead of being embedded in a URL that
    # would then be logged wherever the URL is logged.
    return f"postgresql://{user}:{password}@{host}:{port}/{database}"


def service_2_url() -> str:
    """Cluster-internal DNS name for the worker.

    'service-2' resolves inside the platform namespace with no external
    DNS involved. This is the internal-DNS hop the architecture is
    meant to demonstrate.
    """
    # Defaulted rather than required, because the default is correct in the
    # cluster. Compose overrides it only to prove the override path works.
    return os.environ.get("SERVICE_2_URL", "http://service-2:8000")
```

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-service-1-app
POSTGRES_USER=u POSTGRES_PASSWORD=p POSTGRES_HOST=h POSTGRES_DB=d \
  python -c "from src.config import database_url; print(database_url())"
```

Expected: `postgresql://u:p@h:5432/d`.

#### Task 3.2.3: Write the failing tests

**Goal:** A suite that fails on the missing module, with fakes standing in for both the worker and the database.

**Why:** Testing an I/O-heavy service without doing any I/O is the skill this task exists to teach, and it is why `transform` and the connection pool were kept at arm's length. The 502 test is the one that earns its keep: it pins the ordering inside `compute()` so that a failed upstream call cannot leave a half-written row behind. No amount of manual testing would reliably catch that regression.

The interesting design question here is how to test a service whose startup opens a real database pool. Two mechanisms solve it together: `ASGITransport` skips lifespan entirely, and FastAPI's `dependency_overrides` swaps the pool and HTTP client for fakes.

**File:** `lfi-service-1-app/tests/test_main.py`

```python
import httpx
import pytest

# get_pool and get_worker are imported not to call them, but to use them as
# keys into app.dependency_overrides below.
from src.main import app, get_pool, get_worker


class FakePool:
    """Stands in for an asyncpg pool. Records what would have been written."""

    def __init__(self):
        # The assertion surface. Tests check these instead of querying a real
        # database, which is what keeps the suite runnable in CI with no
        # services at all.
        self.inserted: list[tuple] = []
        self.rows: list[dict] = []

    async def fetchval(self, query: str, *args):
        # Crude query sniffing, but enough: /readyz probes with SELECT 1 and
        # /compute inserts. A real fake would parse SQL; this is a stub.
        if query.strip().startswith("SELECT 1"):
            return 1
        self.inserted.append(args)
        # Stands in for the RETURNING id, hence persisted_id == 1 below.
        return 1

    async def fetch(self, query: str, *args):
        return self.rows


# ---------------------------------------------------------------------------
# Two canned service-2 responses. These are httpx handler functions: given a
# request, return a response, with no network involved.
# ---------------------------------------------------------------------------
def healthy_worker(request: httpx.Request) -> httpx.Response:
    return httpx.Response(200, json={"service": "service-2", "input": 21, "result": 42})


def broken_worker(request: httpx.Request) -> httpx.Response:
    # 503 rather than a connection error. Either would do; this proves
    # raise_for_status is what catches it.
    return httpx.Response(503, text="worker is down")


def build_client(worker_handler):
    """Wire up an app whose two external dependencies are fakes.

    Returns the test client and the FakePool, because tests need to assert
    against the pool after the request completes.
    """
    pool = FakePool()
    # MockTransport intercepts outbound requests from service-1 to service-2.
    worker = httpx.AsyncClient(
        transport=httpx.MockTransport(worker_handler),
        base_url="http://service-2:8000",
    )
    # This is the mechanism the whole test file rests on. FastAPI resolves
    # Depends(get_pool) by looking in this dict first, so the app under test
    # receives fakes without any change to production code.
    app.dependency_overrides[get_pool] = lambda: pool
    app.dependency_overrides[get_worker] = lambda: worker
    # ASGITransport skips lifespan, so connect_with_retry never runs and no
    # real database connection is ever attempted.
    transport = httpx.ASGITransport(app=app)
    return httpx.AsyncClient(transport=transport, base_url="http://test"), pool


@pytest.fixture(autouse=True)
def clear_overrides():
    # autouse means this wraps every test in the file without being requested.
    # The body before yield is setup (nothing), after yield is teardown.
    yield
    # dependency_overrides lives on the module-level `app`, so it leaks between
    # tests unless cleared. Skipping this makes tests pass or fail depending on
    # execution order, which is a miserable bug to chase.
    app.dependency_overrides.clear()


async def test_healthz_needs_no_dependencies():
    # Note: no build_client, so no overrides are installed. This proves
    # /healthz works with nothing wired up, which is exactly what a liveness
    # probe has to do.
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


async def test_readyz_touches_the_database():
    client, _ = build_client(healthy_worker)
    async with client:
        response = await client.get("/readyz")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


async def test_compute_calls_the_worker_and_persists_the_result():
    client, pool = build_client(healthy_worker)
    async with client:
        response = await client.post("/compute", json={"value": 21})

    assert response.status_code == 200
    body = response.json()
    assert body["gateway"] == "service-1"
    # "service-2" here came from the worker's response body, not from a
    # constant in service-1. That is what makes this an integration assertion.
    assert body["worker"] == "service-2"
    assert body["result"] == 42
    assert body["persisted_id"] == 1

    # The write actually happened, with the worker's result, not a local one.
    # (21, 42): the input and the worker's answer, in that column order.
    assert pool.inserted == [(21, 42)]


async def test_compute_returns_502_when_the_worker_is_unreachable():
    client, pool = build_client(broken_worker)
    async with client:
        response = await client.post("/compute", json={"value": 21})

    # 502 Bad Gateway, not 500. The gateway is fine; its upstream is not, and
    # the status code should say which.
    assert response.status_code == 502
    assert "service-2" in response.json()["detail"]

    # Nothing is persisted when the upstream call fails.
    # This is the assertion that actually earns its keep: it pins the ordering
    # in compute(), where the worker call must precede the insert.
    assert pool.inserted == []


async def test_history_returns_recent_rows():
    client, pool = build_client(healthy_worker)
    # Preload the fake so /history has something to return.
    pool.rows = [{"id": 2, "input_value": 5, "result": 10}]
    async with client:
        response = await client.get("/history")

    assert response.status_code == 200
    assert response.json() == [{"id": 2, "input_value": 5, "result": 10}]
```

The 502 test is the one that earns its keep. It pins the rule that a failed upstream call must not leave a half-written row behind.

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-service-1-app
pytest -v
```

Expected: `ModuleNotFoundError: No module named 'src.main'`.

#### Task 3.2.4: Implement service-1

**Goal:** All tests from Task 3.2.3 passing, with `/healthz` and `/readyz` doing genuinely different jobs.

**Why:** The probe split is the design decision to understand here, because Section 5's manifests depend on it and Section 12 of the follow-on guide depends on it again. `/healthz` touches nothing, so a database outage never causes Kubernetes to start killing otherwise-healthy pods. `/readyz` touches Postgres, so a pod that cannot reach the database is pulled from the Service endpoints and rejoins on its own once the database returns.

**File:** `lfi-service-1-app/src/main.py`

```python
import asyncio
import logging
from contextlib import asynccontextmanager

import asyncpg
import httpx
from fastapi import Depends, FastAPI, HTTPException, Request
from pydantic import BaseModel

from src.config import database_url, service_2_url

# Log to stdout at INFO. In Kubernetes stdout IS the log: kubectl logs reads
# it, so writing to a file would only hide it inside the container.
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("service-1")

# IF NOT EXISTS makes this safe to run on every startup, which it is, since
# lifespan applies it each time. See the note below the code block about why
# this belongs in a migration tool in a real service.
SCHEMA = """
CREATE TABLE IF NOT EXISTS computations (
    id          SERIAL       PRIMARY KEY,
    input_value INTEGER      NOT NULL,
    result      INTEGER      NOT NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
)
"""


async def connect_with_retry(
    dsn: str, attempts: int = 30, delay: float = 2.0
) -> asyncpg.Pool:
    """Postgres is frequently still starting when this pod is scheduled.

    Kubernetes would eventually fix that for us by restarting a crashed
    pod, but retrying in-process turns a noisy CrashLoopBackOff into a
    quiet 60-second startup.
    """
    # 30 attempts x 2s = up to a minute of patience, which comfortably covers
    # a cold Postgres initialising its data directory on first boot.
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            # min_size=1 so the pool is usable immediately; max_size=5 because
            # two replicas x 5 is well within Postgres' default 100 limit.
            pool = await asyncpg.create_pool(dsn, min_size=1, max_size=5)
            logger.info("Connected to Postgres on attempt %s.", attempt)
            return pool
        # OSError covers DNS and TCP failures (Postgres not up yet);
        # PostgresError covers it being up but not accepting this database.
        # Deliberately narrow: a wrong password should not be retried 30 times.
        except (OSError, asyncpg.PostgresError) as error:
            last_error = error
            logger.warning(
                "Database not ready (attempt %s/%s): %s", attempt, attempts, error
            )
            await asyncio.sleep(delay)
    # `from last_error` preserves the original traceback, so the logs show what
    # actually went wrong rather than just "could not reach".
    raise RuntimeError(
        f"Could not reach the database after {attempts} attempts."
    ) from last_error


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup before the yield, shutdown after it.

    Connections are opened once here rather than per request. Opening a pool
    per request would work and would also be catastrophically slow.
    """
    app.state.pool = await connect_with_retry(database_url())
    async with app.state.pool.acquire() as connection:
        await connection.execute(SCHEMA)
    # One shared client, reused across requests, so connections to service-2
    # are pooled and kept alive. The 5s timeout is what turns a hung worker
    # into a 502 rather than a request that never returns.
    app.state.http = httpx.AsyncClient(base_url=service_2_url(), timeout=5.0)
    logger.info("Startup complete.")
    yield
    # Ordered teardown. Skipping these leaks sockets on every pod restart.
    await app.state.http.aclose()
    await app.state.pool.close()


app = FastAPI(title="service-1-gateway", version="1.0.0", lifespan=lifespan)


# These two exist as dependencies rather than direct app.state reads so
# that tests can override them. See tests/test_main.py.
#
# Reading request.app.state instead of the module-level `app` is what makes the
# override work: the test swaps the function, and nothing here needs to change.
def get_pool(request: Request) -> asyncpg.Pool:
    return request.app.state.pool


def get_worker(request: Request) -> httpx.AsyncClient:
    return request.app.state.http


class ComputeRequest(BaseModel):
    value: int


class ComputeResponse(BaseModel):
    # Both service names are in the response on purpose: it is the evidence
    # that the request really traversed two pods, not one.
    gateway: str
    worker: str
    input: int
    result: int
    persisted_id: int


class HistoryEntry(BaseModel):
    id: int
    input_value: int
    result: int


@app.get("/healthz")
def healthz() -> dict[str, str]:
    """Liveness. Deliberately dependency-free: a database blip should not
    cause Kubernetes to kill an otherwise healthy pod."""
    return {"status": "ok"}


@app.get("/readyz")
async def readyz(pool: asyncpg.Pool = Depends(get_pool)) -> dict[str, str]:
    """Readiness. Does touch the database, because a pod that cannot reach
    Postgres should be pulled out of the Service's endpoint list."""
    # The cheapest possible round trip that proves the connection is live.
    # If this raises, FastAPI returns 500 and the readiness probe fails, which
    # is the intended behaviour: remove this pod from the Service endpoints
    # without restarting it.
    await pool.fetchval("SELECT 1")
    return {"status": "ready"}


@app.post("/compute", response_model=ComputeResponse)
async def compute(
    body: ComputeRequest,
    worker: httpx.AsyncClient = Depends(get_worker),
    pool: asyncpg.Pool = Depends(get_pool),
) -> ComputeResponse:
    """The full path the architecture exists to demonstrate:
    ingress -> service-1 -> service-2 over cluster DNS -> Postgres.
    """
    # Call the worker FIRST, persist second. The ordering is the contract:
    # a failed worker call must leave no row behind. The 502 test pins it.
    try:
        response = await worker.post("/process", json={"value": body.value})
        # httpx does not raise on 4xx/5xx by default, so this line is what
        # turns the broken_worker fixture's 503 into an exception.
        response.raise_for_status()
    # httpx.HTTPError is the base class, so this covers timeouts, connection
    # failures, and the status error above in one handler.
    except httpx.HTTPError as error:
        raise HTTPException(
            status_code=502, detail=f"service-2 unreachable: {error}"
        ) from error

    payload = response.json()

    # $1/$2 are asyncpg's placeholders. Values are passed separately, so the
    # driver parameterises the query and string formatting never touches SQL.
    # RETURNING id hands back the new primary key in the same round trip.
    persisted_id = await pool.fetchval(
        "INSERT INTO computations (input_value, result) VALUES ($1, $2) RETURNING id",
        body.value,
        payload["result"],
    )

    return ComputeResponse(
        gateway="service-1",
        # Read from the worker's response rather than hardcoded, so this field
        # is meaningful evidence about who actually answered.
        worker=payload["service"],
        input=body.value,
        result=payload["result"],
        persisted_id=persisted_id,
    )


@app.get("/history", response_model=list[HistoryEntry])
async def history(pool: asyncpg.Pool = Depends(get_pool)) -> list[HistoryEntry]:
    # DESC + LIMIT 10: newest first, bounded. An unbounded SELECT would be a
    # slow surprise the first time the table is large.
    rows = await pool.fetch(
        "SELECT id, input_value, result FROM computations ORDER BY id DESC LIMIT 10"
    )
    # asyncpg returns Record objects, not dicts. dict(row) converts, then **
    # unpacks into the model, which validates the shape on the way out.
    return [HistoryEntry(**dict(row)) for row in rows]
```

**A note on lint and `Depends`.** ruff's bugbear rules include B008, "do not perform function call in argument defaults". The four `Depends(...)` defaults above trip it, so `ruff check` reports four errors here while the tests pass cleanly. B008 exists to catch defaults evaluated once at import time, such as a mutable list, and in FastAPI that single evaluation is exactly the intent: `Depends` builds a marker object the framework resolves per request. This is a false positive, which is why `pyproject.toml` lists the FastAPI callables under `extend-immutable-calls`. If you skipped that block, add it now and re-run. The other way out is `Annotated[asyncpg.Pool, Depends(get_pool)]`, which has no default at all and so never triggers the rule; this plan keeps the plain default form because it reads more simply.

**A note on the schema.** Creating the table in `lifespan` is fine for a stub and keeps the plan focused on the platform. It is not how you would run a real service: concurrent replicas racing on DDL and no version history are both real problems. The production answer is a migration tool (Alembic) run as an init container or a Kubernetes Job. Treat this as a deliberate, documented shortcut rather than a pattern to copy.

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-service-1-app
pytest -v && ruff check src tests
```

Expected: `5 passed`, and `All checks passed!`.

#### Task 3.2.5: Commit service-1's application code

**Goal:** service-1 committed with tests green and lint clean.

**Why:** Phase boundary. One specific failure to watch for: if `pytest` passes but `ruff` reports four B008 errors, the `flake8-bugbear` block from Task 3.2.1 is missing. Green tests with red lint is the signature of exactly that, and nothing else.

```bash
cd $PLATFORM_HOME/lfi-service-1-app
printf '.venv/\n__pycache__/\n*.pyc\n.pytest_cache/\n.ruff_cache/\n.DS_Store\n' > .gitignore
git add .
git commit -m "feat: gateway service calling the worker and persisting results"
git push
```

**Validate:** `git status --porcelain` is empty.

### Phase 3.3: Containerization

#### Task 3.3.1: Write both Dockerfiles

**Goal:** Two images that build and run, each as a non-root user with no test dependencies inside.

**Why:** Four choices in this file are load-bearing, and each one prevents a specific problem. `-slim` over `-alpine` avoids musl forcing Python wheels to compile from source. Copying `requirements.txt` before `src/` is what keeps the dependency layer cached across source edits, and reversing them is the most common slow-Dockerfile mistake there is. The exec-form `CMD` is what lets SIGTERM reach uvicorn, so pods stop cleanly instead of waiting out the full termination grace period on every delete. And `.dockerignore` is what guarantees a stray `.env` can never be copied into an image.

The two files are identical apart from the title in the comment. Write them separately rather than sharing one, because the repos are independent by design.

**File:** `lfi-service-1-app/Dockerfile` and `lfi-service-2-app/Dockerfile`

```dockerfile
# -slim, not -alpine. Alpine uses musl instead of glibc, which means many
# Python wheels have no prebuilt binary and get compiled from source instead.
# Slim is slightly larger and vastly less annoying.
FROM python:3.12-slim

# PYTHONDONTWRITEBYTECODE  no .pyc files; the container is disposable
# PYTHONUNBUFFERED         flush stdout immediately, so `kubectl logs` is live
#                          rather than showing nothing until the buffer fills
# PIP_NO_CACHE_DIR         do not keep a pip cache in the image layer
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Dependencies first so this layer caches across source-only changes.
# Reversing these two COPYs would reinstall every dependency on every source
# edit, which is the single most common slow-Dockerfile mistake.
COPY requirements.txt .
# --index-url is belt and braces. A container never sees your host's
# ~/.config/pip/pip.conf, so this already resolved from public PyPI, but
# saying so means a stray PIP_INDEX_URL in the build environment cannot
# quietly redirect it. See the primer at the top of Section 3.
RUN pip install --no-cache-dir --index-url https://pypi.org/simple -r requirements.txt

# requirements.txt, not requirements-dev.txt: pytest and ruff have no business
# in a production image. .dockerignore also excludes tests/.
COPY src/ ./src/

# Run as a non-root user. A container that does not need root should
# not have it, and some clusters refuse to schedule ones that do.
#
# A high, explicit uid rather than a name, because Kubernetes securityContext
# checks work on numeric ids. Task 3.3.2 asserts this is 10001, not 0.
# chown after COPY, because files copied earlier are owned by root.
RUN useradd --create-home --uid 10001 appuser \
 && chown -R appuser:appuser /app
USER appuser

# Documentation only. It publishes nothing; the Deployment's containerPort
# and the Service are what actually route traffic.
EXPOSE 8000

# Exec form (a JSON array), not shell form. Shell form wraps the process in
# /bin/sh, which swallows SIGTERM, so Kubernetes would wait out the full
# termination grace period on every pod delete instead of stopping cleanly.
#
# --host 0.0.0.0, not 127.0.0.1: bind on all interfaces or nothing outside
# the container can reach it.
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

Also add a `.dockerignore` to each repo, so the build context stays small and a stray `.env` can never be copied into an image:

**File:** `lfi-service-1-app/.dockerignore` and `lfi-service-2-app/.dockerignore`

```text
.venv/
__pycache__/
*.pyc
.pytest_cache/
.ruff_cache/
.git/
.github/
tests/
.env
.DS_Store
```

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-service-2-app
docker build -t service-2:dev .
docker run --rm -d --name s2-probe -p 8002:8000 service-2:dev
sleep 3
curl -s -X POST http://localhost:8002/process \
  -H 'Content-Type: application/json' -d '{"value": 21}'
docker rm -f s2-probe
```

Expected: `{"service":"service-2","input":21,"result":42}`.

#### Task 3.3.2: Confirm the image runs as non-root

**Goal:** Proof the container runs as uid 10001 rather than 0.

**Why:** A container that does not need root should not have it, and some clusters refuse to schedule ones that do. Checking the numeric id rather than trusting the `USER` line matters because Kubernetes `securityContext` policies evaluate numeric ids, so this is the exact value a cluster would judge you on.

```bash
docker run --rm service-2:dev id -u
```

Expected: `10001`. If it prints `0`, the `USER` directive is missing or placed before the `useradd`.

### Phase 3.4: Local dev loop with compose

#### Task 3.4.1: Write the compose file

**Goal:** A compose file at the workspace root that builds both app repos and stands up Postgres beside them.

**Why:** It exists so you can iterate on application code in seconds without waiting on a cluster, and it lives at the workspace root because that is the only place able to see all three repos. The detail worth noticing: `SERVICE_2_URL` and `POSTGRES_HOST` hold the *same values* here as they will in Kubernetes, because compose gives each service a DNS name matching its key. Same values, different resolver, and therefore no code change between local and cluster.

The build contexts are `./lfi-service-1-app` and `./lfi-service-2-app`, which resolve because the repos are subdirectories of the workspace.

**File:** `$PLATFORM_HOME/docker-compose.dev.yaml`

```yaml
# Local development only. Not deployed, not part of the GitOps repo.
# Usage:  docker compose -f docker-compose.dev.yaml up --build
#
# This file lives at the workspace root because it is the only place that can
# see all three repos. Compose gives each service a DNS name matching its key
# below, which is why the same SERVICE_2_URL and POSTGRES_HOST values work here
# and in Kubernetes without any code change.

services:
  postgres:
    image: postgres:16-alpine
    environment:
      # Plain values, not a Secret. Throwaway credentials for a throwaway
      # database. The cluster's real password comes from .env via Terraform.
      POSTGRES_USER: platform
      POSTGRES_PASSWORD: localdev
      POSTGRES_DB: platform
    ports:
      # Published to the host so you can psql into it directly while debugging.
      - "5432:5432"
    healthcheck:
      # pg_isready, not a TCP check. Postgres accepts connections several
      # seconds before it will accept queries, and this distinguishes them.
      # That is what makes the `service_healthy` condition below meaningful.
      test: ["CMD-SHELL", "pg_isready -U platform -d platform"]
      interval: 3s
      timeout: 3s
      retries: 10

  service-2:
    # Relative to this file, hence the requirement to run compose from
    # $PLATFORM_HOME. Running it elsewhere gives "path not found".
    build: ./lfi-service-2-app
    ports:
      # host 8002 -> container 8000. Different host ports so both services can
      # be reached at once; both listen on 8000 internally, as in the cluster.
      - "8002:8000"

  service-1:
    build: ./lfi-service-1-app
    environment:
      # These names match compose's service keys above, and in the cluster they
      # match Kubernetes Service names. Same values, different resolver.
      SERVICE_2_URL: http://service-2:8000
      POSTGRES_HOST: postgres
      POSTGRES_PORT: "5432"
      POSTGRES_USER: platform
      POSTGRES_PASSWORD: localdev
      POSTGRES_DB: platform
    ports:
      - "8001:8000"
    depends_on:
      postgres:
        # Waits for the healthcheck to pass, not merely for the container to
        # start. Without this, service-1 would burn several retries from
        # connect_with_retry on every `up`.
        condition: service_healthy
      service-2:
        # Started is enough: service-2 has no dependencies of its own, and
        # service-1 only calls it when a request arrives.
        condition: service_started
```

The password here is a throwaway that never leaves your machine and never reaches the cluster. The cluster's password comes from `.env` via Terraform, as set out in decision 4.

#### Task 3.4.2: Run the full stack locally and exercise every hop

**Goal:** Four hops confirmed separately: gateway alive, gateway to database, gateway to worker to database, and the write actually landing.

**Why:** Four checks rather than one end-to-end call, so a failure names the broken hop instead of just reporting that something is wrong. This is also the last point where you can find an application bug in seconds rather than through `kubectl logs` and pod restarts, so thoroughness here saves disproportionate time in Section 5.

```bash
cd $PLATFORM_HOME
docker compose -f docker-compose.dev.yaml up --build -d
sleep 10
```

**Validate:** run all four and check each expectation.

```bash
# 1. Gateway is alive
curl -s http://localhost:8001/healthz
# Expected: {"status":"ok"}

# 2. Gateway can reach the database
curl -s http://localhost:8001/readyz
# Expected: {"status":"ready"}

# 3. The full chain: gateway -> worker -> database
curl -s -X POST http://localhost:8001/compute \
  -H 'Content-Type: application/json' -d '{"value": 21}'
# Expected: {"gateway":"service-1","worker":"service-2","input":21,
#            "result":42,"persisted_id":1}

# 4. The write really landed
curl -s http://localhost:8001/history
# Expected: [{"id":1,"input_value":21,"result":42}]
```

If step 3 returns a 502, service-1 cannot resolve `service-2`. Check `docker compose logs service-2`.

#### Task 3.4.3: Tear down and commit

**Goal:** Compose stopped with its volume removed, and the Dockerfiles committed in both app repos.

**Why:** The `-v` is the part that matters. Leaving the volume behind means the next `up` starts with rows already in the table, so the `persisted_id: 1` expectation in Task 3.4.2 would fail on a re-run and send you looking for a bug that is not there.

```bash
cd $PLATFORM_HOME
docker compose -f docker-compose.dev.yaml down -v
```

Commit the Dockerfiles and dockerignores in each app repo:

```bash
cd $PLATFORM_HOME/lfi-service-1-app
git add Dockerfile .dockerignore && git commit -m "build: containerize the gateway" && git push

cd $PLATFORM_HOME/lfi-service-2-app
git add Dockerfile .dockerignore && git commit -m "build: containerize the worker" && git push
```

Update the tracker rows for Phases 3.1 through 3.4 to ☑ Done.

**Validate:**

```bash
docker compose -f $PLATFORM_HOME/docker-compose.dev.yaml ps
```

Expected: no running services listed.

---

## Section 4: Data Layer

**Objective:** A PostgreSQL StatefulSet backed by a PersistentVolumeClaim, with its password delivered from your gitignored `.env` through Terraform, never through Git. By the end of this section you will have proven that data survives a pod deletion.

This section also creates the `02-platform` Terraform module. It starts small (a namespace and a Secret) and Section 6 extends the same module with ArgoCD.

### Primer: how Kubernetes handles things that cannot be thrown away

Kubernetes is built around the assumption that pods are disposable. Any pod can be killed, rescheduled onto another node, or replaced at any moment, and for stateless services that is a feature. A database breaks that assumption, and Kubernetes has two specific objects for dealing with it.

**Deployment against StatefulSet.**

| | Deployment | StatefulSet |
|---|---|---|
| Pod names | random suffix (`service-1-7d4b9c-x2j8k`) | stable ordinal (`postgres-0`) |
| Identity across restarts | none, a replacement is a different pod | preserved, `postgres-0` is always `postgres-0` |
| Storage | shared or none | one PersistentVolumeClaim per pod, created automatically |
| Startup and shutdown | all at once | ordered, one at a time |
| Right for | your two services | your database |

The property that matters most here is the third one. A StatefulSet's `volumeClaimTemplates` block creates a separate PVC for each replica and **binds it to that replica's identity**. When `postgres-0` dies and is recreated, it gets the same volume back. That is the entire reason a database can live in Kubernetes at all.

**The three storage objects, and how they relate.**

```
  PersistentVolumeClaim (PVC)     "I need 2Gi of ReadWriteOnce storage"
             |                     a request, written by you
             v
  StorageClass                    "here is how to satisfy that"
             |                     the provisioner; k3d gives you 'local-path'
             v
  PersistentVolume (PV)           the actual storage that got created
                                  bound 1:1 to the claim
```

You write the PVC. The StorageClass provisioner creates the PV and binds them. You rarely touch PVs directly.

**The lifecycle detail that makes Phase 4.3 work:** deleting a pod does **not** delete its PVC. Deleting the StatefulSet does not either. This is deliberate, and it is why "I deleted the deployment to restart it" is a much more dangerous habit with stateful workloads than stateless ones. You have to delete a PVC explicitly, which is exactly the friction you want in front of destroying data.

**What this does not give you.** The `local-path` provisioner writes to a directory on the k3d node, which is a container on your Mac. Destroy the cluster and the data goes with it. A PVC protects against pod failure, not cluster deletion, and it is not a backup. Section 9.3 states this plainly again before you destroy anything.

### Phase 4.1: Secret plumbing via Terraform

#### Task 4.1.1: Write the platform module's variables

**Goal:** Inputs declared, with secrets marked `sensitive` and given no defaults.

**Why:** The presence or absence of a default is the quickest way to read this file: no default means a secret or something environment-specific that must be supplied, a default means a decision already made. `sensitive = true` redacts the value from plan and apply output. Note what it does not do: it does not encrypt the value in `terraform.tfstate`, which is exactly why the state file is gitignored.

**File:** `lfi-infrastructure-gitops/terraform/02-platform/variables.tf`

```hcl
# ---------------------------------------------------------------------------
# Inputs for the platform module.
#
# Anything WITHOUT a default is required, and the Makefile supplies it as
# TF_VAR_<name>. Anything WITH a default is ordinary config you can override
# but rarely need to. That split is the quickest way to read this file:
# defaults are decisions, no-defaults are secrets or environment.
# ---------------------------------------------------------------------------

variable "kube_context" {
  type        = string
  # Must match `kube_context` output by 01-cluster. Nothing enforces that
  # automatically, so a mismatch here is silently applying to another cluster.
  description = "kubectl context to target. Must match the 01-cluster output."
  default     = "k3d-platform"
}

variable "namespace" {
  type        = string
  description = "Namespace for application workloads."
  default     = "platform"
}

# --- Supplied from .env by the Makefile. No defaults on purpose. ------------

variable "postgres_user" {
  type        = string
  description = "Supplied from .env via TF_VAR_postgres_user."
}

variable "postgres_db" {
  type        = string
  description = "Supplied from .env via TF_VAR_postgres_db."
}

variable "postgres_password" {
  type        = string
  description = "Supplied from .env via TF_VAR_postgres_password. Never defaulted."
  # Redacts the value from plan and apply output. Note this does NOT encrypt
  # it in terraform.tfstate, which is why the state file is gitignored.
  sensitive   = true
}

variable "gitops_repo_url" {
  type        = string
  # Not a secret, just environment-specific. Required rather than defaulted
  # because guessing a repo URL wrong is a confusing failure in Section 6.
  description = "HTTPS URL of the GitOps repo ArgoCD watches. Used in Section 6."
}

variable "argocd_chart_version" {
  type        = string
  # Pinned, not "latest". An unpinned chart means a reinstall months from now
  # silently upgrades ArgoCD and may rename the keys in values/argocd.yaml.
  #
  # 10.4.2 deploys ArgoCD server v3.5.2. Keep this in step with your argocd
  # CLI version: a large client/server gap breaks the CLI commands used in
  # Section 6. See Task 1.1.3.
  description = "Pinned argo-cd Helm chart version. Verified in Task 1.1.3."
  default     = "10.4.2"
}

variable "argocd_host" {
  type        = string
  # Resolves to 127.0.0.1 on macOS with no /etc/hosts entry, and any *.localhost
  # name behaves the same way. Host-based routing keeps ArgoCD served from "/",
  # so no server.rootpath configuration is needed.
  description = "Hostname Traefik routes to ArgoCD, reachable on port 8080."
  default     = "argocd.localhost"
}
```

`postgres_password` has no default on purpose. A default would let a broken `.env` silently produce a cluster with a password you did not choose.

#### Task 4.1.2: Write the platform module, namespace and Secret only

**Goal:** A namespace and a `postgres-credentials` Secret in the cluster, built from values in `.env`.

**Why:** This is decision 4's bridge made real. Terraform runs on your Mac so it can read `.env`; ArgoCD runs inside the cluster and cannot see your filesystem at all. Something has to carry the value across, and this is it. Git only ever holds a `secretKeyRef` naming the Secret. ArgoCD is deliberately absent for now: Section 6 extends this same module, and building it in two passes keeps each pass independently verifiable.

**File:** `lfi-infrastructure-gitops/terraform/02-platform/main.tf`

```hcl
# ---------------------------------------------------------------------------
# Stage 2 of the two-module split.
#
# Unlike 01-cluster, this file DOES declare kubernetes and helm providers, and
# they need a reachable cluster when the plan is built. That is precisely why
# it is a separate root module: applying it before stage 1 fails at plan time.
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      # ~> 2.17 means >= 2.17.0 and < 3.0.0. The upper bound is deliberate,
      # not lazy: v3 changed the provider block syntax below.
      version = "~> 2.17"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# Authenticate by reading your existing kubeconfig rather than by embedding
# credentials. config_context pins WHICH cluster, so a stray `kubectl config
# use-context` cannot redirect an apply at your work cluster.
provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = var.kube_context
}

# Same target, separate provider. Helm needs its own connection block.
# Under helm provider v3 this becomes `kubernetes = { ... }` with an equals
# sign; the nested-block form below is v2 syntax.
provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = var.kube_context
  }
}

# Created by Terraform rather than by ArgoCD, because the Secret below has to
# land in it and Terraform runs first.
resource "kubernetes_namespace" "platform" {
  metadata {
    name = var.namespace
    labels = {
      # Documents ownership for anyone reading `kubectl get ns -o yaml` and
      # wondering why this namespace is not in the GitOps repo.
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# The bridge described in decision 4: values arrive from the gitignored
# .env as TF_VAR_* and land directly in the cluster. Git only ever holds
# a secretKeyRef naming this Secret.
resource "kubernetes_secret" "postgres" {
  metadata {
    name      = "postgres-credentials"
    # Referencing the resource, not var.namespace, creates an explicit
    # dependency so Terraform orders the namespace first. metadata[0] is
    # needed because metadata is a block, which HCL models as a list.
    namespace = kubernetes_namespace.platform.metadata[0].name
  }

  # Keys match what the postgres image and service-1 both expect,
  # so both can consume this Secret with a single envFrom.
  #
  # Terraform base64-encodes these for you. Do not pre-encode them.
  data = {
    POSTGRES_USER     = var.postgres_user
    POSTGRES_PASSWORD = var.postgres_password
    POSTGRES_DB       = var.postgres_db
  }

  # Opaque = arbitrary key/value. The other types (kubernetes.io/tls,
  # dockerconfigjson) enforce specific keys, which is not what is wanted here.
  type = "Opaque"
}
```

The pinned `helm ~> 2.17` matters. Provider v3 replaced the nested `kubernetes { }` block with a `kubernetes = { }` attribute, and this config will not parse under it.

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
gmake platform-up
```

Expected: Terraform creates two resources. Then confirm the Secret exists and holds the value from `.env`:

```bash
kubectl -n platform get secret postgres-credentials
kubectl -n platform get secret postgres-credentials \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo
```

Expected: the Secret is listed with 3 data keys, and the decoded password matches `POSTGRES_PASSWORD` in your `.env`.

#### Task 4.1.3: Prove the secret is not in Git

**Goal:** Confirmation your password appears in no tracked file and in no commit in the history.

**Why:** This is the assertion the whole secret-handling decision rests on, so verify it rather than assuming it. The history check matters as much as the working-tree one: a password committed once and removed in a later commit is still readable by anyone who clones the repository, and no amount of subsequent tidying changes that.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
source .env
git grep -I "$POSTGRES_PASSWORD" -- . && echo "LEAK FOUND" || echo "clean: password absent from tracked files"
```

Expected: `clean: password absent from tracked files`. Also check history, in case of an earlier mistake:

```bash
git log -p --all -S "$POSTGRES_PASSWORD" | head -5
```

Expected: no output.

### Phase 4.2: Postgres StatefulSet and PVC

#### Task 4.2.1: Write the headless Service

**Goal:** One Service doing two jobs: governing the StatefulSet, and giving clients a stable `postgres:5432` address.

**Why:** A StatefulSet requires a governing Service named in `serviceName`, and that Service must already exist or the pods get no stable DNS. `clusterIP: None` is what makes it headless, so DNS resolves straight to the pod rather than through a load balancer. That is the correct choice for a single-writer database, where you always want to reach the same instance rather than whichever one a balancer picks.

**File:** `lfi-infrastructure-gitops/kubernetes/postgres/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  labels:
    app: postgres
spec:
  # Headless: no cluster IP, DNS resolves straight to the pod.
  clusterIP: None
  selector:
    app: postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: postgres
```

#### Task 4.2.2: Write the StatefulSet

**Goal:** Postgres running with a PVC bound to its pod identity.

**Why:** Three settings in this file each prevent a specific crash loop, and all three are easy to omit. `fsGroup: 999` makes the mounted volume writable by the uid the postgres image runs as; without it the container starts and immediately dies on its own data directory. `PGDATA` points at a subdirectory because Postgres refuses to initialise into a mount root that already contains anything, and some volumes arrive carrying `lost+found`. And the probes shell out to `pg_isready` rather than using `httpGet`, because Postgres speaks its own wire protocol and would never answer an HTTP check.

**File:** `lfi-infrastructure-gitops/kubernetes/postgres/statefulset.yaml`

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  labels:
    app: postgres
spec:
  # Names the governing headless Service. A StatefulSet requires this, and the
  # Service must already exist or pods get no stable DNS. It is what gives
  # each pod a name like postgres-0.postgres.platform.svc.cluster.local.
  serviceName: postgres
  # One replica. Postgres does not replicate by simply raising this number:
  # you would get two independent databases, not a cluster. Real HA needs an
  # operator (CloudNativePG, Zalando) that handles primary election.
  replicas: 1
  selector:
    # Must match the pod template labels below, or the API server rejects it.
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      securityContext:
        # The postgres image runs as uid/gid 999. fsGroup makes the
        # mounted volume group-writable by that user.
        #
        # Omit this and the container starts, fails to write to its data
        # directory, and crash-loops with a permissions error.
        fsGroup: 999
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - name: postgres
              containerPort: 5432
          envFrom:
            # POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB, created
            # by Terraform from .env. No values appear in this file.
            #
            # envFrom imports every key in the Secret as an env var of the same
            # name, which is why the Terraform key names had to match exactly.
            - secretRef:
                name: postgres-credentials
          env:
            # Point PGDATA at a subdirectory. Postgres refuses to
            # initialise into a mount root that already contains
            # anything, and some volumes arrive with lost+found.
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            # `name: data` ties back to the volumeClaimTemplate at the bottom.
            - name: data
              mountPath: /var/lib/postgresql/data
          readinessProbe:
            # exec, not httpGet: Postgres speaks its own wire protocol, not
            # HTTP. pg_isready is the shipped tool for exactly this.
            # `exec` in front of pg_isready replaces the shell process rather
            # than forking, so no stray sh lingers per probe.
            exec:
              command:
                - sh
                - -c
                - exec pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" -h 127.0.0.1
            # Fails fast (5s in) so traffic is not sent to a database that is
            # still starting. Failing readiness only removes it from endpoints.
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 6
          livenessProbe:
            # Same check, different consequence: failing THIS one restarts the
            # container. Hence the far more patient initialDelaySeconds, so a
            # slow first-time initdb is never mistaken for a hang.
            exec:
              command:
                - sh
                - -c
                - exec pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" -h 127.0.0.1
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          resources:
            # requests = what the scheduler reserves. limits = the hard cap.
            # No CPU limit on purpose: CPU is throttled when exceeded, which
            # just makes startup slow, whereas exceeding a memory limit is an
            # instant OOM kill.
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi
  # The clause that makes this a StatefulSet rather than a Deployment with a
  # volume. Kubernetes creates one PVC per replica, named
  # <template>-<statefulset>-<ordinal>, so `data-postgres-0`, and rebinds it to
  # the same pod identity after a restart.
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        # ReadWriteOnce: mountable by one node at a time. Correct for a
        # single-writer database, and all local-path supports anyway.
        accessModes: ["ReadWriteOnce"]
        # k3d's built-in provisioner. It writes to a directory on the node,
        # which is a container on your Mac, so this survives pod deletion but
        # NOT cluster deletion.
        storageClassName: local-path
        resources:
          requests:
            storage: 2Gi
```

`volumeClaimTemplates` is what makes this a StatefulSet rather than a Deployment with a volume: each replica gets its own PVC, and that PVC is deliberately **not** deleted when the pod is. That is the property Phase 4.3 tests.

#### Task 4.2.3: Write the Kustomization

**Goal:** A single entry point, so `kubectl apply -k kubernetes/postgres` deploys the whole directory.

**Why:** Kustomize reads only what `resources` lists, so a stray YAML file in this directory is ignored rather than silently applied, which is a useful property when you are experimenting. Note that the labels land on the objects and the pod template but deliberately **not** on the selector: a StatefulSet's selector is immutable once created, so a label that reaches it can only be changed by deleting the StatefulSet.

**File:** `lfi-infrastructure-gitops/kubernetes/postgres/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: platform

resources:
  - service.yaml
  - statefulset.yaml

# Stamped on both resources and on the pod template, but deliberately NOT on
# selectors. The older `commonLabels` field did write to selectors and is now
# deprecated; a StatefulSet's selector is immutable once created, so anything
# that lands there can only be changed by deleting the StatefulSet.
labels:
  - pairs:
      app.kubernetes.io/part-of: local-platform
    includeTemplates: true
```

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
kustomize build kubernetes/postgres
```

Expected: rendered YAML for both resources, each with `namespace: platform` applied. No errors.

#### Task 4.2.4: Deploy Postgres

**Goal:** `postgres-0` running and ready, with PVC `data-postgres-0` bound.

**Why:** The PVC name is worth reading rather than glancing past. The pattern `<volumeClaimTemplate>-<statefulset>-<ordinal>` is how a StatefulSet ties a volume to a pod *identity* rather than to a pod, and it is the reason the same storage comes back to the same pod after a restart. That property is what Phase 4.3 goes on to prove.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
kubectl apply -k kubernetes/postgres
kubectl -n platform rollout status statefulset/postgres --timeout=180s
```

**Validate:**

```bash
kubectl -n platform get pods,pvc,statefulset
```

Expected: pod `postgres-0` is `Running` and `1/1`, and PVC `data-postgres-0` is `Bound`. The PVC name pattern `<volumeClaimTemplate>-<statefulset>-<ordinal>` is how StatefulSets tie storage to identity.

#### Task 4.2.5: Confirm the credentials actually work

**Goal:** A successful `psql` login from inside the pod.

**Why:** The Secret existing is a different claim from Postgres accepting it, and only the second one matters. If this fails with an authentication error, the Secret and the StatefulSet disagree about key names, which is a mistake that produces a perfectly healthy-looking pod and no error anywhere until an application tries to connect.

```bash
kubectl -n platform exec -it postgres-0 -- \
  sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT version();"'
```

Expected: a `PostgreSQL 16.x ... on aarch64` version line. An authentication failure here means the Secret and the StatefulSet disagree about key names.

### Phase 4.3: Persistence proof

This phase writes no new files. It exists because "the PVC is Bound" and "my data actually survives" are different claims, and only the second one matters.

#### Task 4.3.1: Write a row

**Goal:** One row in a throwaway table, so there is something to lose.

**Why:** The dollar-quoting is worth understanding rather than copying blindly. Ordinary single quotes would collide with the shell's own quoting, and double quotes in SQL mean an identifier rather than a string, so the obvious alternatives both produce confusing errors rather than working.

```bash
kubectl -n platform exec -it postgres-0 -- \
  sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
    CREATE TABLE IF NOT EXISTS persistence_check (id SERIAL PRIMARY KEY, note TEXT);
    INSERT INTO persistence_check (note) VALUES (\$\$written before pod deletion\$\$);
    SELECT * FROM persistence_check;"'
```

The `$$...$$` is Postgres dollar-quoting. Ordinary single quotes would collide with the shell's, and double quotes in SQL mean an identifier rather than a string, which is a genuinely confusing error to hit.

**Validate:** one row is returned, with `id` of `1`.

#### Task 4.3.2: Delete the pod and let the StatefulSet rebuild it

**Goal:** A freshly created pod, alongside a PVC that is visibly older than it.

**Why:** The age difference between pod and PVC is the visible proof that storage outlived the pod, which is the entire property a StatefulSet exists to provide. Deleting the pod on purpose is also the cheapest possible rehearsal of the thing that will eventually happen to you unplanned.

```bash
kubectl -n platform delete pod postgres-0
kubectl -n platform wait --for=condition=Ready pod/postgres-0 --timeout=180s
```

**Validate:**

```bash
kubectl -n platform get pvc data-postgres-0
```

Expected: still `Bound`, and the `AGE` column is older than the newly recreated pod. That age difference is the visible proof that storage outlived the pod.

#### Task 4.3.3: Confirm the row survived

**Goal:** The same row still readable after the pod that wrote it was destroyed.

**Why:** This is the claim the whole phase exists for. "The PVC is Bound" and "my data actually survives" are different statements, and only the second is worth anything. If the table is missing, the PVC is not mounted where Postgres is actually writing, and `PGDATA` is the first thing to check.

```bash
kubectl -n platform exec -it postgres-0 -- \
  sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT * FROM persistence_check;"'
```

Expected: the same row, `written before pod deletion`, still present. If the table is missing, the PVC is not actually mounted where Postgres is writing, and `PGDATA` is the first thing to check.

#### Task 4.3.4: Clean up the check table and commit Section 4

**Goal:** The throwaway table dropped, and Section 4 committed.

**Why:** Phase boundary. Run the Validate properly here rather than trusting the commit: `git show --stat HEAD` tells you exactly what you pushed, and confirms no `.env` travelled along with the five expected files. That is the check Task 4.1.3 was rehearsing.

```bash
kubectl -n platform exec -it postgres-0 -- \
  sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP TABLE persistence_check;"'

cd $PLATFORM_HOME/lfi-infrastructure-gitops
git add terraform/02-platform kubernetes/postgres
git commit -m "feat(data): postgres statefulset with PVC and terraform-managed credentials"
git push
```

Update the tracker rows for Phases 4.1 through 4.3 to ☑ Done.

**Validate:** `git status --porcelain` is empty, and `git show --stat HEAD` lists five files with no `.env` among them.

---

## Section 5: Kubernetes Manifests and Manual Deployment

**Objective:** Get the entire stack running in the cluster by hand, using `kubectl apply -k`. ArgoCD comes in Section 6.

**Why deploy manually first.** If you introduce ArgoCD at the same time as the workloads, then when something breaks you cannot tell whether the manifests are wrong or the GitOps wiring is wrong. Proving the manifests work under `kubectl` first means that when Section 6 hands the same manifests to ArgoCD, any new failure is unambiguously a GitOps problem.

### Primer: Kustomize, and why not Helm

You have already used Helm once, to install ArgoCD's chart. So why use a different tool for your own manifests?

**Helm templates.** A chart is YAML with `{{ }}` placeholders, rendered by substituting values. It is powerful, and it is how you consume third-party software, because the chart author cannot know your environment.

**Kustomize overlays.** There are no placeholders. You write plain, valid Kubernetes YAML that you could `kubectl apply` directly, and then declare transformations on top of it: change this image tag, add this label, set this namespace.

The practical difference:

```yaml
# Helm: not a valid Kubernetes manifest. You cannot apply this,
# cannot lint it as Kubernetes YAML, cannot read it without
# mentally rendering it first.
image: {{ .Values.image.repository }}:{{ .Values.image.tag }}

# Kustomize: a real manifest. Applies as-is.
image: service-1
```

```yaml
# ...and the transformation lives separately, in kustomization.yaml
images:
  - name: service-1
    newName: ghcr.io/YOUR_GITHUB_USER/service-1
    newTag: a1b2c3d
```

Kustomize is the better fit here for one concrete reason that pays off in Section 8: **CI has to rewrite the image tag automatically.** With Kustomize that is one deterministic field at a known path, and a one-line `yq` command updates it. With Helm you would be templating a values file, and the tag would be one interpolation away from the manifest rather than declared in it.

The rule of thumb this reflects: **Helm for software you consume, Kustomize for software you own.**

**Two commands to keep straight:**

```bash
kustomize build kubernetes/service-1     # render to stdout, change nothing
kubectl apply -k kubernetes/service-1    # render and apply (-k, not -f)
```

Get in the habit of running `kustomize build` and reading the output before you apply. It is the fastest way to catch a transformation that silently did not match anything, which is the most common Kustomize mistake and produces no error at all.

### Phase 5.1: Kustomize bases

Images have not been built by CI yet, so this phase uses locally built images imported straight into the k3d nodes. The image **names** are already the final GHCR paths, so Section 8 only ever has to change a tag.

#### Task 5.1.1: Write the service-2 manifests

**Goal:** A Deployment, Service, and Kustomization for the worker, with the image reference rewritten by Kustomize.

**Why:** The bare `image: service-2` in the Deployment is deliberate rather than lazy: it gives the `images:` transformer an obvious key to match, so if `kustomize build` shows it unchanged you know immediately that the block did not apply. That `newTag` field is also the single field CI will rewrite in Section 8, and keeping the seam exactly one field wide is the whole reason this project uses Kustomize rather than Helm.

**File:** `lfi-infrastructure-gitops/kubernetes/service-2/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: service-2
  labels:
    app: service-2
spec:
  # Deployment, not StatefulSet: these pods are interchangeable and own no
  # storage. Any one can be killed and replaced with no consequence.
  replicas: 2
  selector:
    matchLabels:
      app: service-2
  template:
    metadata:
      labels:
        # This label is what the Service's selector matches on. Change it here
        # without changing service.yaml and the Service silently has zero
        # endpoints: no error, just nothing answering.
        app: service-2
    spec:
      containers:
        - name: service-2
          # Rewritten by the kustomization's images: block.
          # Left as a bare name on purpose, so the transformation has an
          # obvious key to match. If `kustomize build` shows this unchanged,
          # the images: block did not match.
          image: service-2
          # Required for images side-loaded with 'k3d image import',
          # which are present on the node but not in any registry.
          # Once CI publishes to GHCR in Section 7 this stops mattering,
          # because SHA tags are immutable and never need re-pulling.
          imagePullPolicy: IfNotPresent
          ports:
            # Naming the port lets the probes below say `port: http` instead
            # of repeating 8000, so there is one place to change it.
            - name: http
              containerPort: 8000
          livenessProbe:
            # Failing this RESTARTS the container.
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            # Failing this only removes the pod from the Service endpoints.
            # Same endpoint here because service-2 has no dependencies; for
            # service-1 the two probes deliberately differ.
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            # Tiny, because it is a stub. requests are what the scheduler
            # reserves, so setting them honestly is what lets the whole stack
            # fit in the 1.5-2.5 GB budget.
            requests:
              cpu: 25m
              memory: 64Mi
            limits:
              memory: 192Mi
```

Two replicas, because the worker is genuinely stateless and this is the cheapest way to make rolling updates visible later.

**File:** `lfi-infrastructure-gitops/kubernetes/service-2/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: service-2
  labels:
    app: service-2
spec:
  # Deliberately ClusterIP: service-2 is never reachable from outside
  # the cluster. There is no Ingress for it, and there should not be.
  type: ClusterIP
  selector:
    app: service-2
  ports:
    - name: http
      port: 8000
      targetPort: http
```

**File:** `lfi-infrastructure-gitops/kubernetes/service-2/kustomization.yaml`

Substitute your GitHub username for `YOUR_GITHUB_USER`.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Injected into every resource below, so none of them declare a namespace of
# their own. One place to change if you ever rename the namespace.
namespace: platform

# The files to include. Kustomize reads only what is listed here, so a stray
# YAML file in this directory is ignored rather than silently applied.
resources:
  - deployment.yaml
  - service.yaml

# Stamped on every resource here and on the pod template, but deliberately NOT
# on the Deployment's selector. `commonLabels`, which this replaces, did write
# to selectors and is now deprecated. Selectors are immutable, so a label that
# lands there can only be changed by recreating the Deployment.
labels:
  - pairs:
      app.kubernetes.io/part-of: local-platform
    includeTemplates: true

# The image transformation. `name` is what to match in the manifests (the bare
# `image: service-2` in deployment.yaml); newName and newTag are what to
# substitute.
images:
  - name: service-2
    newName: ghcr.io/YOUR_GITHUB_USER/service-2
    # `dev` until CI takes over. From Section 8 this is a 40-character SHA,
    # rewritten by one yq command. It is the only field CI ever touches, which
    # is the whole reason this project uses Kustomize rather than Helm.
    newTag: dev
```

`newTag` is the single field CI rewrites in Section 8.

#### Task 5.1.2: Write the service-1 manifests

**Goal:** A Deployment, Service, Ingress, and Kustomization for the gateway.

**Why:** Two things differ from service-2 and both are deliberate. The Ingress sets **no host**, so it matches any Host header and plain `http://localhost:8080/` works with no `/etc/hosts` entry or local DNS setup. And the two probes differ from each other rather than pointing at the same endpoint: `/healthz` touches nothing while `/readyz` touches Postgres, which is what lets a pod that has lost its database drop out of service without being killed and restarted.

**File:** `lfi-infrastructure-gitops/kubernetes/service-1/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: service-1
  labels:
    app: service-1
spec:
  # Two replicas is also what makes the zero-downtime check in Task 8.3.4
  # meaningful: with one, a rolling update always has a gap.
  replicas: 2
  selector:
    matchLabels:
      app: service-1
  template:
    metadata:
      labels:
        app: service-1
    spec:
      containers:
        - name: service-1
          # Bare name, rewritten by kustomization.yaml's images: block.
          image: service-1
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8000
          env:
            # Cluster-internal DNS. No external resolution involved.
            #
            # `service-2` is a short name: Kubernetes appends the search
            # domain, so it resolves within the platform namespace. Note there
            # is no `lfi-` prefix here; these are Kubernetes Service names,
            # not repo names.
            - name: SERVICE_2_URL
              value: http://service-2:8000
            # Resolves to the headless Service, which points straight at
            # postgres-0.
            - name: POSTGRES_HOST
              value: postgres
            # Quoted, because unquoted 5432 is a YAML integer and every
            # env var value must be a string. Kubernetes rejects the manifest
            # otherwise.
            - name: POSTGRES_PORT
              value: "5432"
          envFrom:
            # Supplies POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB.
            # The password never appears in this file.
            #
            # Split deliberately: non-secret config sits in `env` above where
            # you can read it, secrets come from `envFrom` by reference. Both
            # end up as env vars that config.py reads identically.
            - secretRef:
                name: postgres-credentials
          livenessProbe:
            # /healthz, which touches nothing. A database outage must not
            # cause Kubernetes to start killing otherwise-healthy pods.
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            # readyz touches Postgres, so a pod that cannot reach the
            # database is pulled from the Service's endpoints.
            #
            # This is the one place the liveness/readiness distinction earns
            # its keep: unready pods stop receiving traffic but keep running,
            # and recover on their own once Postgres returns.
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
            # 6 x 5s = 30s of grace, which covers connect_with_retry working
            # through a slow Postgres start.
            failureThreshold: 6
          resources:
            # Higher than service-2: this one holds a connection pool.
            requests:
              cpu: 50m
              memory: 96Mi
            limits:
              memory: 256Mi
```

**File:** `lfi-infrastructure-gitops/kubernetes/service-1/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: service-1
  labels:
    app: service-1
spec:
  type: ClusterIP
  selector:
    app: service-1
  ports:
    - name: http
      port: 8000
      targetPort: http
```

**File:** `lfi-infrastructure-gitops/kubernetes/service-1/ingress.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: service-1
  labels:
    app: service-1
spec:
  # Which ingress controller should act on this rule. An Ingress is inert
  # YAML on its own; Traefik is the program that reads it and routes traffic.
  # Wrong or missing class here and nothing happens, with no error.
  ingressClassName: traefik
  rules:
    # No host is set on purpose. That makes the rule match any Host
    # header, so plain http://localhost:8080/ works with no /etc/hosts
    # entry and no local DNS setup.
    - http:
        paths:
          - path: /
            # Prefix, so / matches every path below it. `Exact` would match
            # only the bare / and nothing else.
            pathType: Prefix
            backend:
              service:
                # Points at the Service, never at pods directly. The Service
                # is what load-balances across the two replicas.
                name: service-1
                port:
                  # The Service's port, not the container's. They are both
                  # 8000 here, which hides the distinction until they differ.
                  number: 8000
```

There is deliberately no Ingress for service-2. It is reachable only from inside the cluster, and adding one would break the architectural boundary this project exists to demonstrate.

**File:** `lfi-infrastructure-gitops/kubernetes/service-1/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: platform

resources:
  # Three files here, against two for service-2: this is the only service
  # exposed through the ingress.
  - deployment.yaml
  - service.yaml
  - ingress.yaml

# Same form as service-2's, and for the same reason: labels on the objects and
# the pod template, never on the selector.
labels:
  - pairs:
      app.kubernetes.io/part-of: local-platform
    includeTemplates: true

images:
  - name: service-1
    newName: ghcr.io/YOUR_GITHUB_USER/service-1
    # Rewritten by service-1's promote job in Section 8.
    newTag: dev
```

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
kustomize build kubernetes/service-1 | grep 'image:'
kustomize build kubernetes/service-2 | grep 'image:'
```

Expected: `image: ghcr.io/<your-user>/service-1:dev` and `image: ghcr.io/<your-user>/service-2:dev`. If you see the bare names, the `images:` block did not match the container image name.

### Phase 5.2: Manual apply and end-to-end smoke test

#### Task 5.2.1: Build and import the images into k3d

**Goal:** Both images present in the cluster's own image store, not just on your Mac.

**Why:** k3d nodes are containers with their own image store, so an image you built locally is invisible to them until it is imported. Worth knowing that this step is temporary scaffolding: from Section 7, CI publishes to GHCR and the cluster pulls for itself, and `k3d image import` disappears from the loop entirely.

```bash
cd $PLATFORM_HOME
source lfi-infrastructure-gitops/.env

docker build -t "ghcr.io/$GH_OWNER/service-1:dev" lfi-service-1-app
docker build -t "ghcr.io/$GH_OWNER/service-2:dev" lfi-service-2-app

k3d image import "ghcr.io/$GH_OWNER/service-1:dev" -c platform
k3d image import "ghcr.io/$GH_OWNER/service-2:dev" -c platform
```

**Validate:**

```bash
docker exec k3d-platform-server-0 crictl images | grep service-
```

Expected: both images listed with tag `dev`.

#### Task 5.2.2: Deploy both services

**Goal:** Five pods running: one Postgres, two of each service.

**Why:** service-1 takes noticeably longer on a first run because its readiness probe waits on the database. That is the probe design from Task 3.2.4 working as intended rather than a problem, and recognising the difference saves you from debugging a healthy system.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
kubectl apply -k kubernetes/service-2
kubectl apply -k kubernetes/service-1

kubectl -n platform rollout status deployment/service-2 --timeout=120s
kubectl -n platform rollout status deployment/service-1 --timeout=180s
```

service-1 takes longer on a first run because its readiness probe waits on the database.

**Validate:**

```bash
kubectl -n platform get pods
```

Expected: `postgres-0` plus two `service-1-*` and two `service-2-*` pods, all `Running` and fully ready. `ImagePullBackOff` on a service pod means the import did not land or `imagePullPolicy` is not `IfNotPresent`.

#### Task 5.2.3: Exercise the whole architecture through the ingress

**Goal:** Four calls, each covering one hop in the architecture diagram.

**Why:** This is the milestone test for Section 5, and it is four calls rather than one because each isolates a different hop. A failure then tells you *which* layer broke: Traefik, the database connection, cluster DNS, or persistence. A single end-to-end call would only tell you that something is wrong.

```bash
# Hop 1: Mac -> Traefik -> service-1
curl -s http://localhost:8080/healthz
# Expected: {"status":"ok"}

# Hop 2: service-1 -> Postgres
curl -s http://localhost:8080/readyz
# Expected: {"status":"ready"}

# Hop 3: the full chain, including service-1 -> service-2 over cluster DNS
curl -s -X POST http://localhost:8080/compute \
  -H 'Content-Type: application/json' -d '{"value": 21}'
# Expected: {"gateway":"service-1","worker":"service-2","input":21,
#            "result":42,"persisted_id":1}

# Hop 4: the write is durable and readable back
curl -s http://localhost:8080/history
# Expected: [{"id":1,"input_value":21,"result":42}]
```

**Validate:** all four produce the expected output. A 502 on the third call means service-1 cannot resolve `service-2`; check `kubectl -n platform logs -l app=service-1 --tail=50`.

#### Task 5.2.4: Confirm the boundary that service-2 has no database access

**Goal:** Proof that service-2's Deployment carries no database configuration whatsoever.

**Why:** This is the architecture's main constraint, and a constraint nobody tests quietly stops being true. Catching a stray `secretRef` now is far easier than noticing it three sections later, by which time you would have to work out when it appeared.

```bash
kubectl -n platform get deployment service-2 -o yaml | grep -i -E 'postgres|secret' || \
  echo "confirmed: service-2 has no database configuration"
```

Expected: `confirmed: service-2 has no database configuration`.

#### Task 5.2.5: Commit Section 5

**Goal:** The manifests committed, and the second milestone reached.

**Why:** Phase boundary, and worth pausing on. Everything up to this point you applied by hand with `kubectl`. Section 6 takes that ability away, so this is the last commit where the cluster does what you tell it directly.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
git add kubernetes/service-1 kubernetes/service-2
git commit -m "feat(k8s): manifests for gateway, worker, and traefik ingress"
git push
```

Update the tracker rows for Phases 5.1 and 5.2 to ☑ Done. You have now hit the second milestone: the full stack is running in Kubernetes.

**Validate:** `git status --porcelain` is empty.

### What just happened

**Milestone 2.** Every hop in the original architecture diagram now exists and carries real traffic. When you ran the four curls in Task 5.2.3, this is the path each request took:

```
  your Mac  ->  Traefik  ->  service-1  ->  service-2   (cluster DNS, no external network)
                                |
                                +--------->  Postgres   (through a Secret you never committed)
```

Three things are worth pausing on:

**Cluster DNS did real work.** `http://service-2:8000` resolved with no configuration from you, because Kubernetes runs an internal DNS server that gives every Service a name inside its namespace. Your app has no idea what IP it talked to, and the pods behind that name can be replaced without anything noticing.

**The Secret stayed out of Git.** Task 4.1.3 proved the password is not in the repository, and yet service-1 authenticated to Postgres. `envFrom.secretRef` is the mechanism, and the pattern generalises: config in Git, credentials injected at runtime.

**You deployed imperatively, on purpose.** You typed `kubectl apply`. That is exactly what Section 6 takes away from you. Notice what is unsatisfying about the current state: nothing records that you ran those commands, nothing would stop a colleague from changing the cluster differently, and if you deleted a Deployment right now, nothing would bring it back. Those three gaps are what GitOps closes.

---

## Section 6: GitOps Control Plane

**Objective:** Install ArgoCD via Terraform and hand it ownership of everything in `kubernetes/`. After this section, nobody runs `kubectl apply` again. Git is the source of truth and the cluster pulls from it.

**The shift in ownership.** Up to now you have been pushing state into the cluster. From here the cluster pulls its own state and continuously corrects anything that does not match Git, including your own manual changes. Phase 6.3 proves that by deliberately breaking something and watching it heal.

### Primer: ArgoCD's vocabulary

ArgoCD has a small number of concepts, and everything in this section is built from them. Learning them now will save you guessing at the UI later.

**Application** is the core object. Despite the name it is not your app; it is a *mapping*, and it says exactly one thing:

> take the manifests at **this path** in **this Git repo** and make **this namespace** in **this cluster** match them.

That is it. An Application is a CRD, so it lives in the cluster as YAML like anything else, which is what makes the app-of-apps trick below possible.

**Two independent status fields**, and conflating them is the most common source of confusion:

| Field | Question it answers | Values |
|---|---|---|
| **Sync status** | Does the cluster match Git? | `Synced` / `OutOfSync` |
| **Health status** | Are the running workloads actually okay? | `Healthy` / `Progressing` / `Degraded` |

They are genuinely orthogonal. `Synced` + `Degraded` means ArgoCD faithfully deployed exactly what Git said, and what Git said is broken. That is not an ArgoCD failure; it is ArgoCD telling you your manifest is wrong.

**Three sync policy settings** you will configure in Phase 6.2:

- **`automated`** sync without waiting for a human to click. Turn this off and ArgoCD will detect drift and simply report it.
- **`selfHeal: true`** also revert changes made *in the cluster*, not just apply changes made in Git. This is what undoes your `kubectl scale` in Phase 6.3.
- **`prune: true`** delete cluster resources that no longer appear in Git. Powerful and appropriate for stateless workloads. You will deliberately set it to `false` for Postgres, because "someone deleted a file" should never mean "the database is gone."

**The reconciliation loop**, which runs every 3 minutes by default:

```
  read Git  ->  read cluster  ->  diff  ->  different?  ->  apply  ->  wait  ->  repeat
```

Nothing more sophisticated than that. Polling is why your changes take up to 3 minutes to appear, and why `argocd app get <name> --refresh` (a forced poll) is a command you will use constantly while learning. Production setups replace polling with a Git webhook.

### Primer: the app-of-apps pattern

There is a bootstrap problem hiding in GitOps. If everything is deployed by committing to Git, how does the *first* thing get deployed? Something has to be applied by hand.

The trick is to make that hand-applied thing as small as possible: **one** Application whose Git path contains nothing but *other* Application manifests.

```
  Terraform applies ONE manifest, once:
  
     root (Application)
        |  watches  argocd/apps/  in the GitOps repo
        |
        +---> postgres  (Application)  -> watches kubernetes/postgres/
        +---> service-1 (Application)  -> watches kubernetes/service-1/
        +---> service-2 (Application)  -> watches kubernetes/service-2/
```

Because `root` watches a directory of Application manifests, adding a fourth service later means committing one new file to `argocd/apps/`. `root` notices it and creates the Application, which deploys the workload. You never touch Terraform or run `kubectl` again.

That is the payoff: exactly one imperative action in the entire system, performed once at bootstrap, and everything downstream is declarative.

### Phase 6.1: ArgoCD via Terraform and Helm

#### Task 6.1.1: Write the ArgoCD Helm values

**Goal:** A values file that keeps the install minimal and serves ArgoCD over plain HTTP.

**Why:** `server.insecure` is the setting to understand rather than copy. It makes ArgoCD serve HTTP instead of terminating TLS itself, which is correct here because Traefik fronts it. Get this wrong in combination with Task 6.1.3's ingress (pointing it at port 443 with `insecure` set) and Traefik speaks TLS to a plaintext backend, which resets the connection and looks like a broken install.

The defaults assume a multi-tenant production install. Trimming them is what keeps the RAM budget intact.

**File:** `lfi-infrastructure-gitops/terraform/02-platform/values/argocd.yaml`

```yaml
# Trimmed for a single-user local cluster. Each disabled component
# below is a real feature you are choosing not to run, not dead weight.

# SSO / OIDC broker. Local admin login only, so it is not needed.
dex:
  enabled: false

# Slack / email alerting on sync events.
notifications:
  enabled: false

# Templated generation of Applications across many clusters.
# The app-of-apps pattern in Phase 6.2 covers this project's needs.
#
# WARNING: this key does nothing. The argo-cd chart has no
# `applicationSet.enabled` value, in 7.x or in 10.x, and its deployment
# template carries no conditional. Helm ignores unrecognised values silently,
# so the ApplicationSet controller IS deployed regardless of what you write
# here. It is kept only to document the intent.
#
# To actually remove it, set the replica count to zero instead:
#   applicationSet:
#     replicas: 0
# Budget roughly 50-100 MB if you leave it running, which is what the resource
# figures below assume.
applicationSet:
  enabled: false

configs:
  params:
    # Terminate TLS at Traefik or at kubectl port-forward instead of
    # inside argocd-server. Avoids the self-signed certificate dance
    # for a cluster reachable only from localhost.
    server.insecure: true
    # Poll Git every 3 minutes. Lower it if you dislike waiting during
    # Section 8; a webhook would be the production answer.
    #
    # This interval is also what bounds the drift-correction demo in Phase
    # 6.3: a manual `kubectl scale` survives at most this long.
    timeout.reconciliation: 180s

# --- Resource budgets for ArgoCD's four components. -------------------------
# Without these the chart requests far more than a laptop wants to give.
# Memory limits only, no CPU limits: throttling is recoverable, an OOM kill
# mid-sync is not.

# The reconciliation engine. Does the actual diffing and applying, so it is
# the component that most needs headroom.
controller:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 768Mi

# Clones Git and renders manifests (runs kustomize build for you).
repoServer:
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      memory: 512Mi

# The API and web UI. Idle most of the time.
server:
  resources:
    requests:
      cpu: 50m
      memory: 96Mi
    limits:
      memory: 256Mi

# Manifest cache. Losing it costs a re-render, not data.
redis:
  resources:
    requests:
      cpu: 25m
      memory: 64Mi
    limits:
      memory: 192Mi
```

#### Task 6.1.2: Write the root Application template

**Goal:** One Application manifest that will go on to discover all the others.

**Why:** This is the app-of-apps pattern in a single file. Terraform applies exactly one manifest, and everything else the platform runs is found in Git by ArgoCD itself, which is what keeps the bootstrap small. The `.tftpl` extension is what lets `templatefile()` substitute your repo URL from `.env`, so a value you never commit still reaches a manifest.

**File:** `lfi-infrastructure-gitops/terraform/02-platform/bootstrap/root-app.yaml.tftpl`

```yaml
# The app-of-apps root. Terraform applies this one manifest; everything
# else the platform runs is discovered from Git by ArgoCD itself.
#
# The .tftpl extension marks it as a Terraform template: ${gitops_repo_url}
# below is substituted by templatefile() at apply time, which is how a value
# from your .env reaches a manifest without ever being committed.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  # Applications live in the argocd namespace even when the workloads they
  # manage live elsewhere.
  namespace: argocd
  finalizers:
    # Deleting this Application cascades to its children rather than
    # orphaning them in the cluster.
    - resources-finalizer.argocd.argoproj.io
spec:
  # `default` is the AppProject ArgoCD ships with, which permits any repo and
  # any destination. A real multi-tenant setup would define a narrower one.
  project: default
  source:
    repoURL: ${gitops_repo_url}
    # HEAD tracks the default branch. Pin to a tag or SHA if you ever want
    # deliberate, reviewed promotion instead of continuous tracking.
    targetRevision: HEAD
    # Contains only child Application manifests, never workloads.
    path: argocd/apps
  destination:
    # The in-cluster API server, addressed from inside the cluster. ArgoCD can
    # target remote clusters too; this says "the one I am running in".
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      # prune: delete resources removed from Git. Without it, deleting a file
      # leaves the object running forever and Git stops being the truth.
      prune: true
      # selfHeal: revert manual changes made with kubectl. This is the single
      # setting that makes Phase 6.3's drift demo work.
      selfHeal: true
    syncOptions:
      # false because the argocd namespace already exists, created by Helm.
      # The child Applications set this to true for the platform namespace.
      - CreateNamespace=false
```

#### Task 6.1.3: Extend the platform module with ArgoCD

**Goal:** ArgoCD installed via Helm, reachable through Traefik, with the root Application applied.

**Why:** One deliberate inconsistency in this file is worth understanding rather than tidying away. The root Application is applied with `kubectl` inside a `null_resource`, not with a `kubernetes_manifest` resource. That is because `kubernetes_manifest` validates against the API server at **plan** time, and the Application CRD does not exist until the Helm release has already run. No `depends_on` can express that ordering, so this is a genuine workaround for a Terraform limitation rather than sloppiness.

Append this to the existing `terraform/02-platform/main.tf`. Do not replace the file; the namespace and Secret from Phase 4.1 stay exactly as they are.

```hcl
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  # Pinned via a variable so there is exactly one place to change it.
  version          = var.argocd_chart_version
  namespace        = "argocd"
  # Helm creates this namespace; the platform namespace above is Terraform's.
  create_namespace = true

  # Block until the release is actually healthy, so the root
  # Application below never races ahead of a half-started ArgoCD.
  wait    = true
  # 600s, because a first run pulls several ArgoCD images.
  timeout = 600

  # file() reads the values file verbatim, no templating. Keeping it as a real
  # YAML file means you can lint it and diff it like any other manifest.
  values = [file("${path.module}/values/argocd.yaml")]
}

# Reach ArgoCD through the Traefik ingress that already fronts the cluster on
# localhost:8080, instead of through `kubectl port-forward`.
#
# Why this exists rather than a port-forward. A port-forward is a single
# process holding one stream, and kubectl tears the whole thing down on the
# first stream error, taking the listener with it. `argocd login` reliably
# triggers exactly that here: the connection is reset before the RPC reaches
# the server, the forward dies, and the CLI then reports the retry's
# "connection refused" rather than the original fault. Routing through Traefik
# removes the tunnel from the picture entirely, and the session survives
# across terminals and reboots.
#
# Host-based routing, not a path prefix, so ArgoCD is served from "/" and
# needs no server.rootpath setting.
resource "kubernetes_ingress_v1" "argocd_server" {
  metadata {
    name      = "argocd-server"
    namespace = "argocd"
  }

  spec {
    ingress_class_name = "traefik"

    rule {
      host = var.argocd_host

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "argocd-server"

              # Port 80, plain HTTP, because values/argocd.yaml sets
              # server.insecure. Pointing this at 443 would have Traefik
              # speak TLS to a plaintext backend, which resets the connection.
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  # Both the namespace and the argocd-server Service come from the chart.
  depends_on = [helm_release.argocd]
}

# Rendered to disk rather than piped inline, so the manifest is easy to
# inspect and 'kubectl apply -f' stays a plain, debuggable command.
#
# .generated/ is gitignored: it is Terraform output, not source.
resource "local_file" "root_app" {
  filename = "${path.module}/.generated/root-app.yaml"
  # templatefile() substitutes ${gitops_repo_url} in the .tftpl.
  content = templatefile("${path.module}/bootstrap/root-app.yaml.tftpl", {
    gitops_repo_url = var.gitops_repo_url
  })
  file_permission = "0644"
}

# Applied with kubectl rather than the kubernetes_manifest resource on
# purpose: kubernetes_manifest validates against the API server at PLAN
# time, and the Application CRD does not exist until the Helm release
# above has run. That ordering cannot be expressed with depends_on.
resource "null_resource" "root_application" {
  # Explicit, because Terraform cannot infer a dependency from a provisioner's
  # shell command the way it can from a resource attribute reference.
  depends_on = [helm_release.argocd, local_file.root_app]

  # Re-apply only when the rendered manifest or the target cluster changes.
  # Hashing the content rather than the filename is what makes an edit to the
  # template actually trigger a re-apply.
  triggers = {
    manifest_sha  = sha256(local_file.root_app.content)
    kube_context  = var.kube_context
    manifest_path = local_file.root_app.filename
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      # helm_release returning does not guarantee the CRDs are registered and
      # accepted by the API server. Applying an Application a moment too early
      # fails with "no matches for kind", so wait for the CRD explicitly.
      echo "Waiting for the Application CRD to be established..."
      kubectl --context "${var.kube_context}" wait \
        --for condition=established --timeout=120s \
        crd/applications.argoproj.io

      # The last imperative step in the whole project. From here on, ArgoCD
      # pulls from Git and nothing outside the cluster applies anything.
      kubectl --context "${var.kube_context}" apply \
        -f "${local_file.root_app.filename}"
    EOT
  }
}

# The chart generates a random admin password into a Secret. Printing the
# command rather than the password keeps the secret out of terraform output
# and out of the state file.
output "argocd_admin_password_command" {
  value = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
```

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops/terraform/02-platform
terraform init -upgrade
terraform validate
```

Expected: `Success! The configuration is valid.`

#### Task 6.1.4: Install ArgoCD

**Goal:** ArgoCD pods running, and the root Application accepted by the API server.

**Why:** A first run pulls several images, which is why the timeout is 600 seconds rather than the default. `wait = true` on the Helm release is what stops the root Application racing ahead of a half-started ArgoCD, and the explicit CRD wait in the provisioner covers the gap between Helm returning and the API server actually accepting the new kind.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
gmake platform-up
```

First run takes 3 to 6 minutes: chart pull, four images, and the `wait = true` gate.

**Validate:**

```bash
kubectl -n argocd get pods
```

Expected: `argocd-server`, `argocd-repo-server`, `argocd-application-controller`, and `argocd-redis` all `Running` and ready. No `dex` or `notifications` pods, confirming the values file applied.

Note that `argocd-applicationset-controller` **will** be present. That is expected: as `values/argocd.yaml` explains in its own comment, the chart has no `applicationSet.enabled` key, so Helm ignores that setting silently. Use `applicationSet: replicas: 0` if you want it gone.

#### Task 6.1.5: Reach ArgoCD and log in

**Goal:** A working `argocd` CLI session, established over the Traefik ingress.

**Why:** Log in through the ingress rather than `kubectl port-forward`, and the reason is specific enough to be worth stating. A port-forward is one process holding a single stream, and kubectl tears the whole thing down on the first stream error. `argocd login` reliably triggers exactly that: the connection resets, the forward dies, and the CLI then reports its retry's "connection refused" rather than the original fault. You end up debugging a phantom. Routing through Traefik removes the tunnel from the picture and the session survives across terminals and reboots.

ArgoCD is served through the Traefik ingress created in Task 6.1.3, on the port your cluster already publishes. No `kubectl port-forward` is involved.

```bash
ARGOCD_PASSWORD="$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)"

argocd login argocd.localhost:8080 --username admin \
  --password "$ARGOCD_PASSWORD" --plaintext --grpc-web
```

You will be prompted once with `server certificate had error ... Proceed insecurely (y/n)?`. Answer `y`. The CLI probes for TLS before honouring `--plaintext`, and there is no certificate to find. Add `--insecure` if you want the command non-interactive for scripting.

The UI is at `http://argocd.localhost:8080`, username `admin`, same password. Plain http, not https.

**Why an ingress instead of a port-forward.** Most ArgoCD guides tell you to run `kubectl port-forward svc/argocd-server 8081:80` and log in against `localhost:8081`. That works until it doesn't, and the way it fails is genuinely confusing, so it is worth knowing what you are avoiding.

A port-forward is one process holding one stream. kubectl treats any stream error as fatal and exits, taking the listener with it. On this stack, `argocd login` reliably triggers one: the connection is reset before the RPC ever reaches the server, so `kubectl logs deploy/argocd-server` shows nothing at all, the forward dies, and the CLI's automatic retry then hits a closed port and reports `connection refused`. You end up chasing a message that describes the retry rather than the fault, on a pod that never restarted and a server that was healthy the whole time.

The ingress removes the tunnel from the picture. It also survives closing your terminal, which the forward never did.

Two flags worth understanding, since both are load-bearing:

- **`--plaintext`, not `--insecure`.** They sound interchangeable and are not. `--insecure` still speaks TLS and merely skips certificate verification. `--plaintext` disables TLS altogether, which is what `server.insecure: true` in `values/argocd.yaml` requires.
- **`--grpc-web`** wraps gRPC in ordinary HTTP/1.1 requests, which is what lets it pass through an ingress controller cleanly.

**Validate:**

```bash
curl -s http://argocd.localhost:8080/api/version
argocd app list
```

Expected: `{"Version":"v3.5.2"}`, then a header row and the `root` application. It will show `Unknown` with a `ComparisonError` condition because `argocd/apps/` does not exist in Git yet. That is the correct state before Phase 6.2.

If `curl` fails, the ingress is the thing to check, not the CLI: `kubectl -n argocd get ingress` should list `argocd-server` with host `argocd.localhost`.

### Phase 6.2: App-of-apps

#### Task 6.2.1: Write the three child Applications

**Goal:** Three Application manifests in `argocd/apps/`, each pointing at one workload directory.

**Why:** Committing these files **is** the deployment; nothing applies them by hand. Two per-service differences are deliberate and both concern Postgres. It gets `prune: false`, so an accidental deletion in Git cannot take the database with it, while the stateless services enable pruning because there is nothing to lose. And it gets an `ignoreDifferences` entry, because `volumeClaimTemplates` are immutable after creation and come back from the API server with defaulted fields ArgoCD would otherwise report as permanent drift. Without that entry the app sits `OutOfSync` forever and you learn to ignore the status, which defeats the point of having one.

Each points at a directory you already proved works under `kubectl apply -k`.

**File:** `lfi-infrastructure-gitops/argocd/apps/postgres.yaml`

Substitute your GitHub username in `repoURL` in all three files.

```yaml
# A child Application, discovered by `root` because it sits in argocd/apps/.
# Committing this file IS the deployment: nothing applies it by hand.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: postgres
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_GITHUB_USER/lfi-infrastructure-gitops.git
    targetRevision: HEAD
    # ArgoCD detects the kustomization.yaml here and runs kustomize build
    # itself. No tool declaration is needed.
    path: kubernetes/postgres
  destination:
    server: https://kubernetes.default.svc
    # The workload namespace, not argocd. The Application object lives in
    # argocd; what it deploys lands in platform.
    namespace: platform
  syncPolicy:
    automated:
      # prune is deliberately FALSE for the data layer. An accidental
      # deletion in Git must not take the database with it. The
      # stateless services below do enable it.
      prune: false
      selfHeal: true
  ignoreDifferences:
    # StatefulSet volumeClaimTemplates are immutable after creation and
    # the API server returns them with defaulted fields, which ArgoCD
    # would otherwise report as permanent drift.
    #
    # Without this the app sits at OutOfSync forever and you learn to ignore
    # the status, which defeats the point of having one.
    - group: apps
      kind: StatefulSet
      jsonPointers:
        - /spec/volumeClaimTemplates
```

**File:** `lfi-infrastructure-gitops/argocd/apps/service-2.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: service-2
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_GITHUB_USER/lfi-infrastructure-gitops.git
    targetRevision: HEAD
    # The directory CI rewrites in Section 8. A commit to the newTag field
    # inside it is what triggers everything below.
    path: kubernetes/service-2
  destination:
    server: https://kubernetes.default.svc
    namespace: platform
  syncPolicy:
    automated:
      # TRUE here, unlike postgres. Deleting a stateless Deployment from Git
      # should remove it from the cluster; there is nothing to lose.
      prune: true
      selfHeal: true
    # Retries a failed sync instead of leaving the app in Degraded. Useful
    # when a promote commit lands microseconds before GHCR finishes serving
    # the new tag.
    retry:
      limit: 3
      backoff:
        # 10s, then 20s, then 40s, capped at 2m.
        duration: 10s
        factor: 2
        maxDuration: 2m
```

**File:** `lfi-infrastructure-gitops/argocd/apps/service-1.yaml`

```yaml
# Identical to service-2's apart from the name and path. Notably there is no
# ordering declared between the three child Applications: ArgoCD syncs them
# concurrently, and service-1's connect_with_retry is what absorbs Postgres
# not being ready yet. Sync waves exist if you ever need real ordering.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: service-1
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_GITHUB_USER/lfi-infrastructure-gitops.git
    targetRevision: HEAD
    path: kubernetes/service-1
  destination:
    server: https://kubernetes.default.svc
    namespace: platform
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

The `prune: false` on postgres against `prune: true` on the services is the one asymmetry in this file set, and it is intentional: pruning is a good default for stateless workloads and a bad one for anything holding data.

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
for f in argocd/apps/*.yaml; do
  echo "== $f"
  kubectl apply --dry-run=client -f "$f" >/dev/null && echo "valid"
done
```

Expected: `valid` under each of the three filenames.

#### Task 6.2.2: Push, which is how you deploy from now on

**Goal:** Four Applications, all Synced and Healthy, produced by a `git push` alone.

**Why:** This is the first deployment performed purely by pushing to Git, and from here there is no other way in. The title is the lesson.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
git add argocd terraform/02-platform
git commit -m "feat(gitops): argocd install and app-of-apps for all three workloads"
git push
```

**Validate:** this is the first deployment performed purely by pushing to Git. Force a poll instead of waiting up to 3 minutes:

```bash
argocd app get root --refresh
argocd app list
```

Expected: four applications (`root`, `postgres`, `service-1`, `service-2`). Within a minute or two all four should read `Synced` and `Healthy`.

#### Task 6.2.3: Confirm ArgoCD adopted the existing resources rather than duplicating them

**Goal:** Still two pods per service, not four.

**Why:** The workloads were applied by hand in Section 5, and ArgoCD should recognise them by name and namespace and take ownership rather than creating a second copy. Doubled pod counts mean your manifest names diverged from what you actually applied, and that is the one way this handover goes quietly wrong: nothing errors, you simply end up with twice the workload.

```bash
kubectl -n platform get pods
argocd app resources service-1
```

**Validate:** still two `service-1` pods and two `service-2` pods, not four. `argocd app resources service-1` lists the Deployment, Service, and Ingress. If pod counts doubled, the manifest names diverged from what you applied in Section 5.

### Phase 6.3: Handover and drift correction

This phase writes no files. It proves the property that makes GitOps worth the setup: the cluster actively defends its declared state.

#### Task 6.3.1: Scale a Deployment by hand and watch it revert

**Goal:** Five replicas becoming two again, with you doing nothing to cause it.

**Why:** This is the property that makes the entire setup worth the effort, and watching it happen is genuinely different from reading about it. It is also the concrete reason nobody runs `kubectl scale` against a GitOps-managed cluster: the change is silently undone within a reconciliation window, with no error to tell you it was ignored.

```bash
kubectl -n platform scale deployment/service-2 --replicas=5
kubectl -n platform get pods -l app=service-2
```

You will briefly see five pods. Now wait for `selfHeal` to notice:

```bash
sleep 30
kubectl -n platform get deployment service-2
```

**Validate:** replicas are back to `2/2`. Git says two, so the cluster is two. Confirm ArgoCD is the one that did it:

```bash
argocd app history service-2 | tail -3
```

Expected: a recent sync entry. This is why nobody runs `kubectl scale` against a GitOps-managed cluster: the change is silently undone within a reconciliation window.

#### Task 6.3.2: Delete a resource entirely and watch it come back

**Goal:** A deleted Service reappearing on its own.

**Why:** Deletion is drift like any other. Worth doing separately from the scale test because "corrects a wrong number" and "recreates something that is gone" feel like two different capabilities, and seeing that they are the same loop is the point.

```bash
kubectl -n platform delete service service-2
sleep 30
kubectl -n platform get service service-2
```

**Validate:** the Service exists again. Deletion is drift like any other and `selfHeal` repairs it.

#### Task 6.3.3: Confirm the app still works after all that

**Goal:** A working request after two deliberate acts of vandalism.

**Why:** The incrementing `persisted_id` is the quiet part worth noticing. It confirms the database kept its data through everything this section did to the cluster, which ties Phase 4.3's persistence proof to Phase 6.3's reconciliation proof.

```bash
curl -s -X POST http://localhost:8080/compute \
  -H 'Content-Type: application/json' -d '{"value": 50}'
```

Expected: a `200` with `"result":100`. The `persisted_id` will have incremented, which also confirms the database kept its data across the whole section.

#### Task 6.3.4: Update the tracker and confirm the end state

**Goal:** Exactly four Applications, all Synced and Healthy, and the tracker updated.

**Why:** This is the natural stopping point of the guide. Sections 7 through 9 add cloud CI, automated promotion, and remote state; what you have right now is a complete local GitOps platform that works. Stopping here is a coherent outcome, not an abandoned project.

Mark Phases 6.1 through 6.3 as ☑ Done in the tracker at the top of this document. The tracker lives in `$PLATFORM_HOME/docs/`, not in the GitOps repo, so there is nothing to commit here unless you version the workspace separately.

Third milestone reached: ArgoCD owns the cluster.

**Validate:**

```bash
argocd app list -o name
```

Expected: exactly four applications, all `Synced` and `Healthy`.

### What just happened

**Milestone 3, and the conceptual centre of this guide.** In Phase 6.3 you scaled a Deployment to five replicas and the cluster put it back to two. You deleted a Service and it came back. Nobody did that; a controller noticed a difference and closed it.

Sit with how strange that is compared to how you worked in Section 5. Your `kubectl` access has not been revoked. You still have full admin rights. But changes you make by hand no longer *persist*, because the cluster's opinion of what it should look like now comes from somewhere else.

**What you actually gained:**

- **Every change is reviewable.** Deployments are commits, so they have an author, a diff, a timestamp, and a revert. `argocd app history` and `git log` tell the same story.
- **Drift cannot accumulate.** The gap between "what we think is deployed" and "what is deployed" is the thing that makes long-lived environments frightening. A reconciliation loop keeps it at zero by construction rather than by discipline.
- **Recovery is a rebuild, not an archaeology project.** Because the desired state is a repo, a destroyed cluster is a re-clone. Section 9.3 tests exactly this.

**What you gave up**, because it is a real trade and worth naming: fast manual intervention. During an incident, `kubectl edit` is no longer a fix, it is a change that will be reverted within three minutes. The escape hatch is to disable auto-sync on one Application, do what you need, then re-enable it and reconcile the change back into Git. Teams adopting GitOps usually discover this at the worst possible moment.

**A good thing to try before moving on.** Open the UI at `http://localhost:8081` and click into `service-1`. The resource tree shows the Deployment, its ReplicaSet, and each Pod, with sync and health state on every node. It is the clearest available picture of what "the cluster matches Git" actually means.

---

## Section 7: Continuous Integration

**Objective:** Both app repos build, test, lint, and publish multi-architecture images to GHCR tagged with the Git commit SHA. This section stops at publishing. Section 8 connects it to the cluster.

**Why the SHA and never `latest`.** A tag like `latest` is a moving pointer, which means the image running in your cluster is not identifiable from Git, rollbacks have nothing to roll back to, and Kubernetes cannot tell that anything changed. A commit SHA is immutable and traces a running pod back to an exact line of source.

**Why multi-arch.** You are on Apple Silicon (`arm64`) and GitHub's hosted runners are `amd64`. An image built only on the runner will not run on your Mac. Building both and publishing a manifest list means the same tag works in both places.

### Phase 7.1: CI for service-2

Build service-2's pipeline first: it has no cross-repo concerns, so any problem you hit is a pure CI problem.

#### Task 7.1.1: Write the workflow

**Goal:** A workflow that tests, then builds and pushes a multi-arch image tagged with the commit SHA.

**Why:** Tagging by SHA rather than by a moving tag like `latest` is what makes deployments traceable and immutable: every image maps to exactly one commit, and nothing can be rebuilt under you later. The `if:` guard on the build job is what stops a pull request publishing an image, and Task 7.3.3 tests that guard rather than trusting it.

**File:** `lfi-service-2-app/.github/workflows/ci.yaml`

```yaml
name: ci

# Run on every push to main, and on every PR targeting main. The PR trigger
# is what gives you a red X before a merge rather than after one.
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

# Least privilege for the automatic GITHUB_TOKEN. Default is broader; naming
# scopes explicitly means a compromised action cannot rewrite this repo.
#   contents: read   -> clone the source
#   packages: write  -> push to GHCR
# Note this token is scoped to THIS repo, which is exactly why Section 8
# needs a separate PAT to write to the GitOps repo.
permissions:
  contents: read
  packages: write

# The image name, deliberately without the `lfi-` repo prefix. It has to match
# the `newName` in the GitOps repo's kustomization.yaml or the promote step in
# Section 8 will update a tag nothing is using.
env:
  IMAGE_NAME: service-2

jobs:
  test:
    name: lint and test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: actions/setup-python@v7
        with:
          python-version: "3.12"
          # Caches the pip download directory, keyed on the hash of the file
          # below. Change a pinned version and the cache correctly misses.
          cache: pip
          cache-dependency-path: requirements-dev.txt

      - name: Install dependencies
        # No index override here. Runners carry no corporate pip config, so this
        # already resolves from public PyPI. It is also the reason every pin
        # in requirements-dev.txt must exist there: a version present only on
        # an internal mirror installs on your Mac and fails on this line.
        run: pip install -r requirements-dev.txt

      - name: Lint
        run: ruff check src tests

      - name: Test
        run: pytest -v

  build:
    name: build and push
    # `needs` is the gate: no image is built unless lint and tests passed.
    needs: test
    # Pull requests get tested but never publish an image. Only a
    # merged commit on main produces something deployable.
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      # QEMU lets an amd64 runner emulate arm64 for the second build.
      - uses: docker/setup-qemu-action@v4

      # Buildx is the builder that can produce a multi-arch manifest list.
      # Plain `docker build` cannot.
      - uses: docker/setup-buildx-action@v4

      - name: Log in to GHCR
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          # Automatically provided. No secret to create for this step.
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v7
        with:
          context: .
          # Two architectures: amd64 for CI and most cloud, arm64 for your Mac.
          platforms: linux/amd64,linux/arm64
          push: true
          # Tagged with the full commit SHA, never `latest`. This is what makes
          # a running pod traceable to exactly one commit, and what lets
          # Kubernetes tell that the image genuinely changed.
          tags: ghcr.io/${{ github.repository_owner }}/${{ env.IMAGE_NAME }}:${{ github.sha }}
          # Layer cache in GitHub Actions storage. The arm64 build is
          # slow under emulation and this is what makes it bearable.
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-service-2-app
git add .github/workflows/ci.yaml
git commit -m "ci: lint, test, and publish multi-arch images to ghcr"
git push
gh run watch
```

Expected: both jobs succeed. The `build` job typically takes 3 to 5 minutes on a cold cache, mostly the emulated arm64 layer.

#### Task 7.1.2: Make the package public

**Goal:** The GHCR package pullable with no credentials at all.

**Why:** Public packages remove Kubernetes image pull secrets from the critical path entirely, which is one fewer thing to debug while getting the first loop working. Appendix A has the extra manifests if you need private packages later; the point of doing it this way now is to keep the number of moving parts down while the loop is unproven.

A newly published GHCR package inherits the repo's visibility settings but must be confirmed public, otherwise the cluster cannot pull it without a secret.

Go to `https://github.com/users/YOUR_GITHUB_USER/packages/container/service-2/settings`, then **Danger Zone**, then **Change visibility**, then **Public**.

**Validate:** pull the image with no credentials at all.

```bash
docker logout ghcr.io
SHA="$(git -C $PLATFORM_HOME/lfi-service-2-app rev-parse HEAD)"
docker pull "ghcr.io/$GH_OWNER/service-2:$SHA"
```

Expected: the pull succeeds. `denied` or `unauthorized` means the package is still private; either fix the visibility or switch to Appendix A.

### Phase 7.2: CI for service-1

#### Task 7.2.1: Write the workflow

**Goal:** The same test, build, and push pipeline for the gateway.

**Why:** Written separately rather than shared through a reusable workflow, because the repos are independent by design and that independence is the architecture. The duplication is the price of the boundary, and it is a deliberate trade rather than an oversight.

**File:** `lfi-service-1-app/.github/workflows/ci.yaml`

Identical to service-2's apart from `IMAGE_NAME`. Reproduced in full rather than referenced, because these are separate repositories with no shared code.

Comments are kept light here to avoid duplicating them. The fully annotated version of this workflow is in Task 7.1.1 above; read that one if any step is unclear.

```yaml
name: ci

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read
  packages: write

env:
  # The ONLY difference from service-2's workflow. Must match the `newName`
  # in kubernetes/service-1/kustomization.yaml, minus the registry and owner.
  IMAGE_NAME: service-1

jobs:
  test:
    name: lint and test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: actions/setup-python@v7
        with:
          python-version: "3.12"
          cache: pip
          cache-dependency-path: requirements-dev.txt

      - name: Install dependencies
        # No index override here. Runners carry no corporate pip config, so this
        # already resolves from public PyPI. It is also the reason every pin
        # in requirements-dev.txt must exist there: a version present only on
        # an internal mirror installs on your Mac and fails on this line.
        run: pip install -r requirements-dev.txt

      - name: Lint
        run: ruff check src tests

      # Runs without a database or a service-2. The tests use dependency
      # overrides and a mock transport, which is why Phase 3.2 bothered
      # with them: CI needs no infrastructure at all.
      - name: Test
        run: pytest -v

  build:
    name: build and push
    needs: test
    # No image is published from a pull request. Merged commits only.
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      # QEMU for arm64 emulation, buildx for the multi-arch manifest.
      - uses: docker/setup-qemu-action@v4
      - uses: docker/setup-buildx-action@v4

      - name: Log in to GHCR
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v7
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: true
          # Full commit SHA as the tag. Never `latest`.
          tags: ghcr.io/${{ github.repository_owner }}/${{ env.IMAGE_NAME }}:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

Note that service-1's tests never touch a real database, which is exactly why they run in CI with no Postgres service container. That was the payoff of the dependency-override design in Task 3.2.3.

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-service-1-app
git add .github/workflows/ci.yaml
git commit -m "ci: lint, test, and publish multi-arch images to ghcr"
git push
gh run watch
```

Expected: both jobs green.

#### Task 7.2.2: Make the service-1 package public

**Goal:** The second package pullable without credentials.

**Why:** Same reasoning as Task 7.1.2, and both must be done. One public and one private gives you a cluster where one service starts and the other sits in `ErrImagePull`, which reads as a broken deployment rather than a permissions setting.

Same procedure as Task 7.1.2, at `https://github.com/users/YOUR_GITHUB_USER/packages/container/service-1/settings`.

**Validate:**

```bash
docker logout ghcr.io
SHA="$(git -C $PLATFORM_HOME/lfi-service-1-app rev-parse HEAD)"
docker pull "ghcr.io/$GH_OWNER/service-1:$SHA"
```

Expected: pull succeeds without credentials.

### Phase 7.3: Multi-arch and GHCR verification

#### Task 7.3.1: Confirm both architectures are actually present

**Goal:** A manifest list containing both `linux/amd64` and `linux/arm64`.

**Why:** A successful push does not guarantee a manifest list, so inspect it rather than assuming. If only one architecture made it, the image fails to start on the other side, and on an Apple Silicon Mac that surfaces as `exec format error`, which mentions nothing about architecture and sends you looking in the wrong place.

```bash
SHA="$(git -C $PLATFORM_HOME/lfi-service-1-app rev-parse HEAD)"
docker buildx imagetools inspect "ghcr.io/$GH_OWNER/service-1:$SHA"
```

**Validate:** the output lists two manifests, `linux/amd64` and `linux/arm64`. Only one means `platforms:` did not apply and the image will fail to start on one side or the other.

#### Task 7.3.2: Confirm the arm64 image runs on your Mac

**Goal:** The GHCR image answering locally, with no emulation warning.

**Why:** Task 7.3.1 proved the manifest claims two architectures. This proves the arm64 half actually works, which is the half you depend on. The absence of an emulation warning is the specific thing to notice: it means you are running native rather than under qemu.

```bash
SHA="$(git -C $PLATFORM_HOME/lfi-service-2-app rev-parse HEAD)"
docker run --rm -d --name s2-ghcr -p 8003:8000 "ghcr.io/$GH_OWNER/service-2:$SHA"
sleep 3
curl -s -X POST http://localhost:8003/process \
  -H 'Content-Type: application/json' -d '{"value": 4}'
docker rm -f s2-ghcr
```

Expected: `{"service":"service-2","input":4,"result":8}`, with no `exec format error` and no emulation warning.

#### Task 7.3.3: Confirm PRs do not publish

**Goal:** A pull request where the `test` job runs and the `build` job is skipped.

**Why:** The `if:` guard is a real safety property, not decoration: without it every pull request would publish an image, and anything in a PR could be deployed. Guards that are never tested are assumptions, so cause the case on purpose and watch it hold.

```bash
cd $PLATFORM_HOME/lfi-service-2-app
git checkout -b ci-guard-check
printf '\n# ci guard check\n' >> README.md 2>/dev/null || echo "# service-2" > README.md
git add README.md && git commit -m "test: confirm PRs do not publish images"
git push -u origin ci-guard-check
gh pr create --title "CI guard check" --body "Verifying the build job is skipped on PRs." --fill
gh run watch
```

**Validate:** the `test` job runs and the `build` job is skipped. Then clean up:

```bash
gh pr close ci-guard-check --delete-branch
git checkout main && git pull
```

Mark Phases 7.1 through 7.3 as ☑ Done.

---

## Section 8: Automated Promotion

**Objective:** Close the loop. A push to an app repo builds an image and commits the new tag to the GitOps repo, which ArgoCD reconciles into a rolling update. This is decision 2 made real.

**The seam.** CI and CD are separate systems that meet at exactly one place: a single `newTag` field in a `kustomization.yaml`. Keeping that seam narrow is what lets app teams ship without touching cluster config, and lets you change deployment mechanics without touching app repos.

```
push to lfi-service-1-app
        |
        v
  test -> build -> push image to ghcr.io/OWNER/service-1:<sha>
        |
        v
  promote:  clone gitops repo
            yq -i '.images[0].newTag = "<sha>"'  kubernetes/service-1/kustomization.yaml
            commit + push
        |
        v
  ArgoCD polls, sees the commit, syncs, rolling update
```

### Phase 8.1: Cross-repo token

#### Task 8.1.1: Create a fine-grained PAT

**Goal:** One token that can write to the GitOps repo and nothing else.

**Why:** `GITHUB_TOKEN` is automatically scoped to the repository running the workflow, so it cannot push to a different repo. That gap needs exactly one credential. Worth noticing how small the credential footprint is: this is the only secret the entire cross-repo design requires, because everything else runs on public access.

At `https://github.com/settings/personal-access-tokens/new`:

| Field | Value |
|---|---|
| Token name | `gitops-promote` |
| Expiration | 90 days |
| Repository access | Only select repositories, then `lfi-infrastructure-gitops` |
| Repository permissions | **Contents: Read and write**. Nothing else. |

Grant only Contents. A promote job that can rewrite workflows or read secrets is a much larger blast radius than one that can only commit a tag.

Note the expiry in your calendar. A silently expired token produces a green `build` job and a `promote` job that fails on push, which is a confusing failure to debug months later.

#### Task 8.1.2: Add the token to both app repos

**Goal:** The secret available to both workflows.

**Why:** Both repos need it because both promote. Storing it as a repository secret rather than anywhere in the workflow file is decision 4's principle applied to CI: the reference is committed, the value never is.

```bash
read -rs -p "Paste the PAT: " GITOPS_PAT; echo

gh secret set GITOPS_PAT --repo "$GH_OWNER/lfi-service-1-app" --body "$GITOPS_PAT"
gh secret set GITOPS_PAT --repo "$GH_OWNER/lfi-service-2-app" --body "$GITOPS_PAT"

unset GITOPS_PAT
```

**Validate:**

```bash
gh secret list --repo "$GH_OWNER/lfi-service-1-app"
gh secret list --repo "$GH_OWNER/lfi-service-2-app"
```

Expected: `GITOPS_PAT` appears in both. Note that the value is write-only; you cannot read it back, which is why it was never echoed above.

### Phase 8.2: Promote job

#### Task 8.2.1: Add the promote job to service-1

**Goal:** A job that clones the GitOps repo, rewrites one field, and pushes.

**Why:** This is the seam between CI and CD, and it is deliberately one field wide. The retry loop matters far more than it looks: two app repos can promote at the same moment, and without rebase-and-retry the second push is rejected and that deployment is silently lost. Task 8.3.5 forces exactly that race to prove the loop earns its place.

Append this job to `lfi-service-1-app/.github/workflows/ci.yaml`. Also add the `concurrency` block at the top level of the file, just under the `env:` block.

```yaml
# Add at the top level of the workflow, alongside 'on:' and 'env:'.
# Serialises promotions from THIS repo. Cross-repo races are handled
# by the rebase retry loop in the job below.
concurrency:
  group: promote-${{ github.repository }}
  cancel-in-progress: false
```

```yaml
  promote:
    name: promote to gitops
    # Only runs if `build` succeeded, so a tag is never written for an image
    # that does not exist in GHCR. This ordering is the whole CI/CD seam.
    needs: build
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
      - name: Check out the GitOps repo
        uses: actions/checkout@v7
        with:
          # Note this checks out a DIFFERENT repo from the one running the
          # workflow. That is why the automatic GITHUB_TOKEN is not enough:
          # it is scoped to this repo only.
          repository: ${{ github.repository_owner }}/lfi-infrastructure-gitops
          token: ${{ secrets.GITOPS_PAT }}
          # Into a subdirectory, so it cannot collide with this repo's files.
          path: gitops

      - name: Update the image tag and push
        working-directory: gitops
        # Passed as env vars rather than interpolated into the script with
        # ${{ }}. Interpolation splices text into the shell before it runs,
        # which is a script-injection route; env vars are just data.
        env:
          SHA: ${{ github.sha }}
          SERVICE: service-1
        run: |
          set -euo pipefail

          # Commit as the Actions bot. This exact address is what makes the
          # bot avatar render on the commit in the GitHub UI.
          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

          MANIFEST="kubernetes/${SERVICE}/kustomization.yaml"

          # The one-field edit that is the entire deployment. strenv(SHA) reads
          # the env var as a string, so a numeric-looking SHA is not coerced.
          # yq is preinstalled on ubuntu-latest runners.
          yq -i '.images[0].newTag = strenv(SHA)' "$MANIFEST"

          # Re-running the same commit is not an error. Without this guard,
          # `git commit` would fail on an empty diff and fail the pipeline.
          if git diff --quiet; then
            echo "Tag already at ${SHA}. Nothing to promote."
            exit 0
          fi

          git add "$MANIFEST"
          git commit -m "deploy(${SERVICE}): ${SHA}"

          # Both app repos push to this one repo, so a race is normal
          # rather than exceptional. Rebase and retry instead of failing.
          #
          # Rebase, not merge: it replays our single one-line commit on top of
          # theirs, so history stays linear and the two edits touch different
          # files anyway. --autostash covers any stray working-tree change.
          for attempt in 1 2 3 4 5; do
            if git push; then
              echo "Promoted ${SERVICE} to ${SHA} on attempt ${attempt}."
              exit 0
            fi
            echo "Push rejected (attempt ${attempt}). Rebasing and retrying..."
            git pull --rebase --autostash
            # Back off a little further each time: 3s, 6s, 9s, 12s.
            sleep $(( attempt * 3 ))
          done

          echo "Could not push after 5 attempts." >&2
          exit 1
```

The retry loop is not defensive padding. Two app repos writing to one GitOps repo will collide the first time you push both at once, and without the loop that surfaces as a red pipeline for a deployment that was otherwise fine.

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-service-1-app
yq '.jobs | keys' .github/workflows/ci.yaml
yq '.concurrency.group' .github/workflows/ci.yaml
```

Expected: three jobs (`test`, `build`, `promote`) and a concurrency group. Do not push yet; wire up service-2 first so the loop test in Phase 8.3 exercises both.

#### Task 8.2.2: Add the promote job to service-2

**Goal:** The same job in the second repo, with `SERVICE` set to `service-2`.

**Why:** `SERVICE` is the one field that must differ between the two, which makes it the one field a copy-paste will get wrong. Leaving it as `service-1` means service-2's pipeline overwrites service-1's tag: the wrong service redeploys, the right one silently does not, and nothing anywhere reports an error.

Identical, with `SERVICE: service-2`. Append to `lfi-service-2-app/.github/workflows/ci.yaml`, plus the same top-level `concurrency` block.

Comments are kept light here. Task 8.2.1 above has the annotated version.

```yaml
  promote:
    name: promote to gitops
    needs: build
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
      - name: Check out the GitOps repo
        uses: actions/checkout@v7
        with:
          # A different repo from the one running this workflow, hence the PAT.
          repository: ${{ github.repository_owner }}/lfi-infrastructure-gitops
          token: ${{ secrets.GITOPS_PAT }}
          path: gitops

      - name: Update the image tag and push
        working-directory: gitops
        env:
          SHA: ${{ github.sha }}
          # The ONLY line that differs from service-1's promote job. Getting
          # this wrong means this pipeline overwrites service-1's tag, which
          # Task 8.2.3 exists to catch.
          SERVICE: service-2
        run: |
          set -euo pipefail

          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

          MANIFEST="kubernetes/${SERVICE}/kustomization.yaml"

          # The one-field edit that constitutes the deployment.
          yq -i '.images[0].newTag = strenv(SHA)' "$MANIFEST"

          # A re-run of the same commit is a no-op, not a failure.
          if git diff --quiet; then
            echo "Tag already at ${SHA}. Nothing to promote."
            exit 0
          fi

          git add "$MANIFEST"
          git commit -m "deploy(${SERVICE}): ${SHA}"

          # Rebase-and-retry, because service-1 may be pushing to this same
          # repo right now. See Task 8.2.1 for why this is expected.
          for attempt in 1 2 3 4 5; do
            if git push; then
              echo "Promoted ${SERVICE} to ${SHA} on attempt ${attempt}."
              exit 0
            fi
            echo "Push rejected (attempt ${attempt}). Rebasing and retrying..."
            git pull --rebase --autostash
            sleep $(( attempt * 3 ))
          done

          echo "Could not push after 5 attempts." >&2
          exit 1
```

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-service-2-app
yq '.jobs.promote.steps[1].env.SERVICE' .github/workflows/ci.yaml
```

Expected: `service-2`. Getting `service-1` here means a copy-paste slip that would make service-2's pipeline overwrite service-1's tag, which is a genuinely confusing bug.

#### Task 8.2.3: Verify the yq expression against the real file before trusting CI

**Goal:** Proof the rewrite changes `newTag` and leaves the rest of the file intact.

**Why:** Test it locally so a failure in CI is not your first data point. The specific hazard is that a `yq` expression matching nothing exits zero and changes nothing, so the failure mode is a completely green pipeline that deploys absolutely nothing, which is the hardest kind of failure to notice.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
cp kubernetes/service-1/kustomization.yaml /tmp/kust-backup.yaml

SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
  yq -i '.images[0].newTag = strenv(SHA)' kubernetes/service-1/kustomization.yaml

grep newTag kubernetes/service-1/kustomization.yaml
```

Expected: `newTag: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef`. Confirm the rest of the file is intact, then restore it:

```bash
cp /tmp/kust-backup.yaml kubernetes/service-1/kustomization.yaml
git diff --quiet kubernetes/service-1/kustomization.yaml && echo "restored cleanly"
```

Expected: `restored cleanly`.

### Phase 8.3: Full loop test

#### Task 8.3.1: Push the promote jobs

**Goal:** A `deploy(service-2)` commit in the GitOps repo, authored by `github-actions[bot]`.

**Why:** First time a workflow in one repository writes to another. Check the author as well as the message: it is what proves the PAT was used rather than something cached on your machine.

```bash
cd $PLATFORM_HOME/lfi-service-2-app
git add .github/workflows/ci.yaml
git commit -m "ci: promote new image tags to the gitops repo"
git push
gh run watch
```

**Validate:** all three jobs green. Then confirm the commit actually landed in the other repo:

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
git pull
git log --oneline -1
grep newTag kubernetes/service-2/kustomization.yaml
```

Expected: a `deploy(service-2): <sha>` commit authored by `github-actions[bot]`, and `newTag` holding that same SHA rather than `dev`.

#### Task 8.3.2: Watch ArgoCD roll it out

**Goal:** The running Deployment's image matching the SHA from the promote commit.

**Why:** This is the moment CI and CD are actually joined. That image reference travelled from a `git push` in one repository to a running pod without anyone touching the cluster, and reading it off the live Deployment is what confirms the whole chain rather than any single link.

```bash
argocd app get service-2 --refresh
argocd app wait service-2 --health --timeout 300
```

**Validate:**

```bash
kubectl -n platform get deployment service-2 \
  -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

Expected: `ghcr.io/<your-user>/service-2:<the sha from the commit>`. That image reference travelled from a `git push` in one repo to a running pod without anyone touching the cluster.

#### Task 8.3.3: Do the same for service-1 with a real code change

**Goal:** A version string you edited in Python, read back off the running service.

**Why:** A tag changing proves the plumbing works. A *behaviour* changing proves the deployment works, and those are different claims. Making the change visible in the response is what turns this from "the pipeline ran" into "the new code is serving traffic", which is the only version that matters.

```bash
cd $PLATFORM_HOME/lfi-service-1-app
```

In `src/main.py`, change the `FastAPI(...)` version argument:

```python
app = FastAPI(title="service-1-gateway", version="1.1.0", lifespan=lifespan)
```

Then:

```bash
git commit -am "feat: bump gateway version to 1.1.0"
git push
gh run watch
```

**Validate:** wait for the sync, then read the version straight off the running service.

```bash
argocd app wait service-1 --health --timeout 300
curl -s http://localhost:8080/openapi.json | yq -p json '.info.version'
```

Expected: `1.1.0`. You edited Python in one repository and a pod in your local cluster is serving it, with no manual step anywhere in between.

#### Task 8.3.4: Confirm the rollout was zero-downtime

**Goal:** At least two revisions in the rollout history.

**Why:** Two replicas plus the default `RollingUpdate` strategy means one pod was always serving. The optional polling loop is worth running during your next deploy, because a continuous stream of `200`s is the difference between believing the property holds and having watched it hold.

```bash
kubectl -n platform rollout history deployment/service-1
```

**Validate:** at least two revisions listed. A Deployment's default `RollingUpdate` strategy with two replicas means one pod was always serving. Optionally prove it during the next deploy by running `while true; do curl -s -o /dev/null -w '%{http_code} ' http://localhost:8080/healthz; sleep 0.5; done` and watching for a continuous stream of `200`s.

#### Task 8.3.5: Test the cross-repo race

**Goal:** Two distinct `deploy(...)` commits, one per service, with neither tag lost.

**Why:** This is the test the retry loop in Task 8.2.1 exists for, and the only way to know it works is to cause the collision deliberately. Seeing `Push rejected (attempt 1). Rebasing and retrying...` in a job log followed by success is the evidence. Without the loop, one of these two deployments would vanish with a green pipeline.

```bash
cd $PLATFORM_HOME/lfi-service-1-app && git commit --allow-empty -m "test: concurrent promotion" && git push
cd $PLATFORM_HOME/lfi-service-2-app && git commit --allow-empty -m "test: concurrent promotion" && git push
```

**Validate:** both pipelines finish green. Then check the GitOps repo:

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops && git pull
git log --oneline -3
```

Expected: two distinct `deploy(...)` commits, one per service, with neither tag lost. If one job's logs show `Push rejected (attempt 1). Rebasing and retrying...` followed by success, the loop did exactly what it was written for.

Mark Phases 8.1 through 8.3 as ☑ Done. Fourth milestone reached: the loop is closed.

### What just happened

**Milestone 4.** In Task 8.3.3 you changed a version string in Python, committed, and pushed. Some minutes later a pod in your local cluster was serving the new code. Between those two events, no human did anything.

Trace the chain, because every link is something you built:

```
  git push                          you
  -> tests + lint                   GitHub Actions
  -> multi-arch image built         Buildx + QEMU
  -> pushed to ghcr.io:<sha>        immutable, traceable to a commit
  -> tag committed to GitOps repo   the promote job
  -> ArgoCD notices the commit      reconciliation loop
  -> rolling update                 Kubernetes
  -> new code serving traffic       zero downtime
```

**The property worth internalising: every artifact is traceable in both directions.** Given a running pod you can read its image SHA, find the commit, and read the source. Given a commit you can find the image and see whether it is deployed. That two-way traceability is what `latest` destroys and what makes incident response tractable. It is not extra rigour for its own sake; it is the difference between "when did this change?" being a five-second query and an afternoon.

**Notice also what the app repos do not know.** Neither `lfi-service-1-app` nor `lfi-service-2-app` contains a single Kubernetes manifest, a cluster credential, or any knowledge of how or where it is deployed. They build an image and write one string to a file. That narrowness is the point of decision 2: you could replace the entire cluster, or move to a different one, without touching either application repository.

**Something to try.** Roll back without rebuilding anything:

```bash
argocd app history service-1          # find an earlier revision number
argocd app rollback service-1 <N>
```

Then look at the GitOps repo. ArgoCD has rolled the *cluster* back, but Git still says the newer tag, so it now reports `OutOfSync` and self-heal will pull it forward again. That tension is instructive: a durable rollback is a Git revert, not a cluster operation. In GitOps, if you did not change Git, you did not really change anything.

---

## Section 9: Remote State and Resilience

**Objective:** Move Terraform state off your laptop into S3 with locking, then prove the whole platform can be destroyed and rebuilt from Git plus `.env`.

**Why bother for a local cluster.** State locking matters less when you are the only operator, but three things make this worth doing: state on a single laptop is one disk failure from unrecoverable, remote state is the pattern every real team uses, and the rebuild drill in Phase 9.3 is what converts "I think this is reproducible" into a fact.

> **On locking.** The original design specified S3 plus a DynamoDB lock table, which was the only option for years because S3 had no atomic create-if-absent operation. It does now, so Terraform 1.10 introduced native S3 state locking via `use_lockfile = true` and 1.11 deprecated the `dynamodb_table` argument. OpenTofu has an equivalent from 1.11. This section uses the native lock file throughout: same mutual exclusion, one less AWS resource to create, pay for, and remember to delete. If you are pinned below Terraform 1.10, you need the DynamoDB variant instead; see the Terraform S3 backend docs.

### Phase 9.1: S3 backend

#### Task 9.1.1: Set up AWS credentials

**Goal:** A working `aws` CLI that can identify itself.

**Why:** Everything in this section fits comfortably in the free tier: the state file is a few kilobytes and lock writes are a handful per apply. Confirming credentials first means a later failure is about the backend rather than about authentication, which are easy to confuse when both present as an access error.

```bash
brew install awscli
aws configure
```

Supply an access key for an IAM user, your preferred region (`ap-southeast-2` below), and `json` as the output format.

**Validate:**

```bash
aws sts get-caller-identity
```

Expected: JSON with your `Account`, `UserId`, and `Arn`. An error here means credentials are not configured and nothing further in this section will work.

#### Task 9.1.2: Create the state bucket

**Goal:** A versioned, encrypted, private bucket, with its name recorded in `.env`.

**Why:** The bucket is created outside Terraform on purpose, because a backend cannot bootstrap itself: Terraform needs the bucket to exist before it can store state in it. The three follow-up calls are not optional extras. Versioning is your only recovery path if a bad apply corrupts state, and encryption matters because **state files contain secrets in plaintext**, including the Postgres password Terraform manages.

This task assumes nothing from earlier terminals, so it sets every variable it uses.

```bash
export PLATFORM_HOME="$HOME/Downloads/nextwork_projects/local-full-intrastructure"
export GH_OWNER="$(gh api user --jq .login)"
export AWS_REGION="ap-southeast-2"

# Bucket names are globally unique across all of AWS, so include something
# distinctive. They are also DNS-style, so they must be lowercase: a GitHub
# username with capitals in it will be rejected without the tr.
export TF_BUCKET="tfstate-$(echo "$GH_OWNER" | tr '[:upper:]' '[:lower:]')-local-platform"

echo "$TF_BUCKET in $AWS_REGION"
```

Now create the bucket. The `--create-bucket-configuration` flag is required in every region except `us-east-1`; omit it here and the call fails with `IllegalLocationConstraintException`, which reads like a permissions problem but is not one.

```bash
aws s3api create-bucket \
  --bucket "$TF_BUCKET" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

# Versioning is the safety net. If a bad apply corrupts state, you can
# restore the previous object version.
aws s3api put-bucket-versioning \
  --bucket "$TF_BUCKET" \
  --versioning-configuration Status=Enabled

# State files contain secrets in plaintext, including the Postgres
# password Terraform manages. Encryption at rest is not optional.
aws s3api put-bucket-encryption \
  --bucket "$TF_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Block all public access.
aws s3api put-public-access-block \
  --bucket "$TF_BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

Nothing else to create. Locking uses a `.tflock` object written into this same bucket, so versioning and encryption cover it too.

Record the bucket name and region in your `.env` so they are not lost:

```bash
cat >> $PLATFORM_HOME/lfi-infrastructure-gitops/.env <<EOF
TF_STATE_BUCKET=$TF_BUCKET
AWS_REGION=$AWS_REGION
EOF
```

**Validate:**

```bash
aws s3api head-bucket --bucket "$TF_BUCKET" --region "$AWS_REGION" && echo "bucket ok"
```

Expected: `bucket ok`. Keep the printed `$TF_BUCKET` value to hand; Task 9.1.3 needs it typed literally into a file.

#### Task 9.1.3: Add the backend blocks

**Goal:** Two backend blocks, one per module, sharing a bucket but not a state key.

**Why:** Each module needs its own key because state is per-module: sharing one key would have the two modules overwrite each other's state, destroying both. Note that backend blocks cannot use variables or interpolation, so the bucket name must be typed literally. That is a Terraform restriction rather than an oversight, and it is why Task 9.1.2 told you to keep the name to hand.

**File:** `lfi-infrastructure-gitops/terraform/01-cluster/backend.tf`

Substitute your real bucket name; backend blocks cannot use variables or interpolation, which is a Terraform restriction, not an oversight.

```hcl
terraform {
  backend "s3" {
    bucket       = "tfstate-YOUR_GITHUB_USER-local-platform"
    key          = "local-platform/01-cluster/terraform.tfstate"
    region       = "ap-southeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
```

**File:** `lfi-infrastructure-gitops/terraform/02-platform/backend.tf`

```hcl
terraform {
  backend "s3" {
    bucket       = "tfstate-YOUR_GITHUB_USER-local-platform"
    key          = "local-platform/02-platform/terraform.tfstate"
    region       = "ap-southeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
```

`use_lockfile = true` is S3-native locking: before any state write Terraform creates `<key>.tflock` with a conditional put, so exactly one run can hold it and the second gets "Error acquiring the state lock". If a run dies mid-apply the object is orphaned and blocks everyone, so `terraform force-unlock <lock-id>` is the escape hatch.

Distinct `key` values are what keep the two modules independently lockable, so a long `02-platform` apply never blocks a `01-cluster` operation.

**Validate:**

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops/terraform/01-cluster
terraform validate
```

Expected: `Success! The configuration is valid.` and nothing else. `validate` only checks configuration, it never touches the backend, so there is no warning here even though the backend just changed. That prompt appears on the next `init` or `plan`, which is Phase 9.2.

### Phase 9.2: State migration

#### Task 9.2.1: Back up local state first

**Goal:** Two non-zero backup copies of your local state files.

**Why:** Migration is the one operation in this guide that can genuinely lose work. State is Terraform's only record of what already exists; lose it and Terraform no longer knows about your running cluster, so the next apply tries to create a second one on top of it.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops/terraform
cp 01-cluster/terraform.tfstate  /tmp/01-cluster.tfstate.bak
cp 02-platform/terraform.tfstate /tmp/02-platform.tfstate.bak
ls -la /tmp/*.tfstate.bak
```

**Validate:** both backup files exist and are non-zero in size.

#### Task 9.2.2: Migrate the cluster module

**Goal:** `null_resource.cluster` listed from the new backend, and the state object present in S3.

**Why:** `-migrate-state` copies the state rather than recreating resources, so the running cluster is untouched. Checking both the state list *and* S3 is deliberate: it confirms the copy actually landed, rather than the backend being silently initialised empty, which looks identical until the next apply.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops/terraform/01-cluster
terraform init -migrate-state
```

Terraform will show the old and new backends and ask for confirmation. Type `yes`.

**Validate:**

```bash
terraform state list
aws s3 ls "s3://$TF_BUCKET/local-platform/01-cluster/"
```

Expected: `null_resource.cluster` in the state list, and `terraform.tfstate` present in S3.

#### Task 9.2.3: Migrate the platform module

**Goal:** Five resources listed from the migrated backend.

**Why:** Same operation, second module. Counting the resources is the actual check: an empty list means Terraform started fresh instead of migrating, and the next apply would try to install ArgoCD on top of the ArgoCD already running.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops/terraform/02-platform
terraform init -migrate-state
```

**Validate:**

```bash
terraform state list
```

Expected: five resources listed, including `kubernetes_secret.postgres` and `helm_release.argocd`.

#### Task 9.2.4: Confirm no drift was introduced

**Goal:** Exit code `0` from both plans.

**Why:** Migration moves where state lives and must not change what state says. `-detailed-exitcode` is what turns this from a glance into an assertion: `0` means no changes needed and `2` means Terraform wants to change something, and those two are easy to confuse when skim-reading ordinary plan output.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
source .env
export TF_VAR_postgres_user="$POSTGRES_USER" \
       TF_VAR_postgres_password="$POSTGRES_PASSWORD" \
       TF_VAR_postgres_db="$POSTGRES_DB" \
       TF_VAR_gitops_repo_url="$GITOPS_REPO_URL"

cd terraform/01-cluster  && terraform plan -detailed-exitcode; echo "01-cluster exit: $?"
cd ../02-platform && terraform plan -detailed-exitcode; echo "02-platform exit: $?"
```

**Validate:** both report exit `0`, which specifically means "succeeded, no changes needed". Exit `2` means Terraform wants to change something and you should read the plan before proceeding.

#### Task 9.2.5: Verify locking actually works

**Goal:** A second concurrent command that fails with `Error acquiring the state lock`.

**Why:** An untested lock is not a lock. Note that this is the one task in the guide where an error message **is** the success condition, so do not go debugging it when it appears.

In one terminal, start a long apply:

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops/terraform/02-platform
terraform apply -auto-approve
```

In a second terminal, immediately try another:

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops/terraform/02-platform
terraform plan
```

**Validate:** the second command reports `Error acquiring the state lock` with a lock ID and the holder's details. That message is the success condition here.

#### Task 9.2.6: Remove the local state files and commit

**Goal:** No local state files on disk, and the backend configuration committed.

**Why:** Leaving them behind means a future `init` could pick up a stale local copy and quietly diverge from S3, which produces two competing views of reality. Keep `/tmp/*.tfstate.bak` for now though: it is your last fallback if the rebuild drill in Phase 9.3 goes wrong.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops/terraform
rm -f 01-cluster/terraform.tfstate  01-cluster/terraform.tfstate.backup
rm -f 02-platform/terraform.tfstate 02-platform/terraform.tfstate.backup

cd $PLATFORM_HOME/lfi-infrastructure-gitops
git add terraform/01-cluster/backend.tf terraform/02-platform/backend.tf
git add terraform/*/.terraform.lock.hcl
git commit -m "feat(infra): migrate terraform state to s3 with locking"
git push
```

Keep `/tmp/*.tfstate.bak` until Phase 9.3 passes.

**Validate:**

```bash
git status --porcelain
ls terraform/01-cluster/*.tfstate 2>/dev/null || echo "no local state, as intended"
```

Expected: clean status, and `no local state, as intended`.

### Phase 9.3: Destroy and rebuild drill

This is the section's real payoff. It answers the question the whole project implies: if this machine died, could you rebuild the platform?

#### Task 9.3.1: Record what should come back

**Goal:** A written record of the current history rows and the running image tag.

**Why:** You need something to compare against, or "it came back" is a feeling rather than a finding. This task also sets an honest expectation: the **platform** is reproducible, the **data** is not. The PVC is local-path storage on a k3d node, so destroying the cluster destroys the database. Naming that plainly now is better than discovering it in the next task.

```bash
curl -s http://localhost:8080/history
kubectl -n platform get deployment service-1 \
  -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

Write both down. Note the honest expectation: the **platform** is reproducible, the **data** is not. The PVC is local-path storage on a k3d node, so destroying the cluster destroys the database. That is correct for a local development platform, and naming it explicitly is better than being surprised by it. A real environment would add backups; that is out of scope here.

#### Task 9.3.2: Destroy everything

**Goal:** No cluster, and no `k3d-platform` context.

**Why:** The whole section is only worth something if you actually do this. A disaster-recovery plan you have written but never executed tells you nothing about whether it works, which is the same reason the parent guide's own DR policy would demand a real traffic shift rather than a tabletop exercise.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
gmake destroy
```

**Validate:**

```bash
k3d cluster list
kubectl config get-contexts | grep k3d-platform || echo "context gone"
```

Expected: no `platform` cluster listed.

#### Task 9.3.3: Rebuild from Git and .env alone

**Goal:** A working platform, reconstructed from nothing but the repository and `.env`.

**Why:** This is the claim the guide has been making since decision 4, now tested rather than asserted. Note the `time` on the command: the number you get is your actual recovery time, and knowing it is considerably more useful than assuming it.

```bash
cd $PLATFORM_HOME/lfi-infrastructure-gitops
time gmake up
```

**Validate:** the command completes. Then wait for ArgoCD to reconcile everything from Git:

```bash
ARGOCD_PASSWORD="$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)"
argocd login argocd.localhost:8080 --username admin \
  --password "$ARGOCD_PASSWORD" --plaintext --grpc-web --insecure

argocd app wait root service-1 service-2 postgres --health --timeout 600
```

Expected: all four healthy. Total rebuild time is typically 8 to 12 minutes, most of it image pulls.

#### Task 9.3.4: Confirm the rebuilt platform is the one Git describes

**Goal:** The image tags Git specifies, confirmed to be the ones actually serving traffic.

**Why:** "Something came up" and "the thing Git describes came up" are different claims, and only the second one means the platform is reproducible. Comparing against what you wrote down in Task 9.3.1 is what distinguishes them.

```bash
# The app answers on the ingress again.
curl -s http://localhost:8080/healthz
# Expected: {"status":"ok"}

# The full chain works.
curl -s -X POST http://localhost:8080/compute \
  -H 'Content-Type: application/json' -d '{"value": 21}'
# Expected: 200 with "result":42 and "persisted_id":1

# The running image matches the tag currently committed in Git,
# NOT the tag that happened to be running before the destroy.
kubectl -n platform get deployment service-1 \
  -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
grep newTag kubernetes/service-1/kustomization.yaml
```

**Validate:** the running image and the `newTag` in Git are the same SHA. `persisted_id` is `1` again, which is the expected and previously stated consequence of the PVC being destroyed with the cluster.

#### Task 9.3.5: Clean up and close out

**Goal:** The state backups deleted, and the tracker complete.

**Why:** Deleting `/tmp/*.tfstate.bak` is deliberately the last step in the guide, because it is the moment you admit you no longer need them. You only earn that by having Phase 9.3 actually pass.

```bash
rm -f /tmp/01-cluster.tfstate.bak /tmp/02-platform.tfstate.bak
```

Mark Phases 9.1 through 9.3 as ☑ Done, and set every remaining tracker row to ☑.

**Validate:** the tracker at the top of this document has no ☐ left, and a final health check passes:

```bash
argocd app list
kubectl -n platform get pods
curl -s http://localhost:8080/healthz
```

Expected: four `Synced` and `Healthy` applications, all pods `Running`, and `{"status":"ok"}`.

---

## Appendix A: Private Repos and Private Packages

The main path assumes public repos and public GHCR packages. If you need private, everything still works with two additions.

### A.1: Let ArgoCD read a private GitOps repo

ArgoCD needs credentials to clone. Add this to `terraform/02-platform/main.tf` and put a read-only PAT in `.env` as `ARGOCD_REPO_PAT`.

```hcl
variable "argocd_repo_pat" {
  type        = string
  sensitive   = true
  description = "Fine-grained PAT with Contents: Read on the GitOps repo."
}

# ArgoCD does not read credentials from a config file. It scans Secrets in its
# own namespace and picks up any carrying the label below, which is why this
# is an ordinary Secret rather than something ArgoCD-specific.
resource "kubernetes_secret" "argocd_repo" {
  metadata {
    name      = "gitops-repo"
    # argocd, not platform: this is ArgoCD's own configuration.
    namespace = "argocd"
    labels = {
      # This label is how ArgoCD discovers repository credentials.
      # Omit it and the Secret is simply ignored, with no error anywhere.
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type = "git"
    # Must match the repoURL in the Applications character for character.
    # ArgoCD matches credentials to repos by URL prefix, so a trailing .git
    # mismatch means it silently tries an anonymous clone.
    url      = var.gitops_repo_url
    # For a GitHub PAT the username is ignored; the token is the password.
    username = "git"
    password = var.argocd_repo_pat
  }

  # ArgoCD's namespace has to exist first, and Helm creates it.
  depends_on = [helm_release.argocd]
}
```

Add `export TF_VAR_argocd_repo_pat="$ARGOCD_REPO_PAT"` to the `platform-up` target in the `Makefile`.

**Validate:** `argocd repo list` shows the repo with connection status `Successful`.

### A.2: Let the cluster pull private images

```hcl
variable "ghcr_pat" {
  type        = string
  sensitive   = true
  description = "PAT with read:packages."
}

variable "gh_owner" {
  type = string
}

# An image pull secret. Kubelet uses this to authenticate to GHCR; it is
# unrelated to the repository Secret above, which is for ArgoCD cloning Git.
resource "kubernetes_secret" "ghcr" {
  metadata {
    name = "ghcr-pull"
    # Must live in the SAME namespace as the pods that use it. Secrets do not
    # cross namespaces, so a second namespace needs its own copy.
    namespace = kubernetes_namespace.platform.metadata[0].name
  }

  # A typed Secret, not Opaque. This type requires the exact key below, and
  # kubelet only looks at Secrets of this type.
  type = "kubernetes.io/dockerconfigjson"

  data = {
    # Hand-building the file Docker would normally write to ~/.docker/config.json.
    # jsonencode keeps it valid rather than relying on a heredoc.
    ".dockerconfigjson" = jsonencode({
      auths = {
        "ghcr.io" = {
          username = var.gh_owner
          password = var.ghcr_pat
          # Redundant with username/password above, but some clients read only
          # this field. Cheap to include, annoying to debug when missing.
          auth = base64encode("${var.gh_owner}:${var.ghcr_pat}")
        }
      }
    })
  }
}
```

Then reference it from each pod spec with `imagePullSecrets: [{name: ghcr-pull}]`, or attach it to the namespace's `default` ServiceAccount so every pod picks it up automatically.

Then add to both `deployment.yaml` files, as a sibling of `containers:`:

```yaml
      imagePullSecrets:
        - name: ghcr-pull
```

**Validate:** delete a service pod and confirm the replacement reaches `Running` rather than `ImagePullBackOff`.

---

## Appendix B: Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `/bin/bash: -c: line 1: syntax error: unexpected end of file` from any `gmake` target | You ran Apple's `make` (3.81), which silently ignores `.ONESHELL:`, so each recipe line runs in its own shell and the multi-line `if` is incomplete | `brew install make`, then use `gmake`, not `make`. Confirm with `gmake --version` showing 4.x. Task 1.1.1 explains why. |
| `Makefile:12: *** missing separator.  Stop.` | Recipe lines indented with spaces instead of tabs | Makefiles require literal tabs. Check your editor is not expanding them for this file. |
| Terraform runs but reports it is in the repository root, or `terraform init` cannot find the module | Same 3.81 cause as above: `cd` did not persist to the next recipe line | Use `gmake`. This one produces no error, which is why it is worse than the syntax error. |
| `cd: no such file or directory` on a `$PLATFORM_HOME` path, or a command running in the wrong directory | `PLATFORM_HOME` is unset in this shell | `echo $PLATFORM_HOME`. If empty, re-export it (Task 1.2.1) and add it to `~/.zshrc`. Most likely you opened a new terminal. |
| `docker build` fails with `path "lfi-service-1-app" not found` | Running from the wrong directory | These build contexts are relative to the workspace root. `cd $PLATFORM_HOME` first. |
| `pip install` fails with `No matching distribution found` for a pinned version, but the Docker build of the same repo succeeds | The venv is resolving from the internal mirror (`pypi.internal.example.com`), which does not carry that version. The container never sees your host pip config, which is why it differs | Write `.venv/pip.conf` with the public index and reinstall. See the primer at the top of Section 3. |
| `pip config list` still shows `pypi.internal.example.com` inside an activated venv | Either `.venv/pip.conf` was not written (or the venv was recreated, deleting it), or `PIP_INDEX_URL` is set in the environment, and environment variables beat config files | `pip config debug` prints every layer and which file each value came from. Fix whichever layer is winning. |
| `curl: (7) Failed to connect to localhost:8080` | Port mapping absent from the cluster | `k3d cluster list` and check the PORTS column. If missing, `gmake destroy && gmake up`: k3d port mappings cannot be added to a running cluster. |
| `curl: (52) Empty reply from server` | Traefik is up but no Ingress matches | `kubectl -n platform get ingress` and confirm `ingressClassName: traefik`. |
| Terraform: `context "k3d-platform" does not exist` | Kubeconfig not updated, or `02-platform` run before `01-cluster` | `k3d kubeconfig merge platform --kubeconfig-merge-default`, then re-run in order. |
| Terraform: `Provider configuration ... cannot be evaluated` | The two-module split was collapsed into one | Keep `01-cluster` and `02-platform` separate. See the explanation under Repository and Directory Layout. |
| `ImagePullBackOff` on a service pod | Image not imported, or wrong pull policy | `k3d image import <ref> -c platform`, and confirm `imagePullPolicy: IfNotPresent`. |
| `ErrImagePull` with `denied` from ghcr.io | Package is still private | Make it public (Task 7.1.2) or apply Appendix A.2. |
| Postgres pod `CrashLoopBackOff`, log says `directory not empty` | `PGDATA` points at the mount root | Confirm `PGDATA=/var/lib/postgresql/data/pgdata`. If the volume is already dirty: `kubectl -n platform delete pvc data-postgres-0` and let the StatefulSet recreate it. Destroys data. |
| service-1 `CrashLoopBackOff` on first deploy | Postgres not ready yet | Expected briefly. `connect_with_retry` allows 60 seconds. Persisting past that means credentials are wrong: check `kubectl -n platform logs -l app=service-1`. |
| `ruff check` reports B008 `Do not perform function call Depends in argument defaults`, four times, while `pytest` passes | The `[tool.ruff.lint.flake8-bugbear]` block is missing from that repo's `pyproject.toml` | Add the `extend-immutable-calls` list from Task 3.2.1. Tests green and lint red is the signature of this one. |
| service-1 returns 502 on `/compute` | Cannot resolve or reach `service-2` | `kubectl -n platform get endpoints service-2`. Empty endpoints means the pod selector does not match. |
| ArgoCD app stuck `OutOfSync` with no visible diff | Cluster-defaulted fields the manifest omits | Add an `ignoreDifferences` entry, as done for `volumeClaimTemplates` in Task 6.2.1. |
| `argocd login` fails with `error: lost connection to pod`, then `connection refused`. The UI worked seconds earlier, and the pod never restarted | You are logging in over `kubectl port-forward`. kubectl kills the whole forward on the first stream error, and the CLI then reports its retry's failure rather than the original reset | Use the ingress instead: `argocd login argocd.localhost:8080 --plaintext --grpc-web`. Task 6.1.5 explains why the port-forward path is not worth debugging. |
| `curl http://argocd.localhost:8080/api/version` returns 404 | Traefik has no route for that host | `kubectl -n argocd get ingress` should show `argocd-server` with host `argocd.localhost`. If it is missing, re-run `gmake platform-up`. A 404 from Traefik means the request arrived but matched no rule, so the port mapping itself is fine. |
| `argocd` commands fail with `Argo CD server address unspecified` | No context in `~/.config/argocd/config`, usually because a previous login failed | Re-run the login from Task 6.1.5. The message means the CLI never stored a server, not that the server is down. |
| ArgoCD `Unknown` with `repository not found` | Wrong `repoURL`, or private repo without credentials | Check the URL in `argocd/apps/*.yaml`, then apply Appendix A.1. |
| Promote job fails with `403` on push | `GITOPS_PAT` missing, expired, or lacking Contents: Write | Reissue the token per Task 8.1.1 and re-run `gh secret set`. |
| Promote job fails with `non-fast-forward` after 5 retries | Sustained contention, or a divergent history | Pull the GitOps repo locally, resolve, push, then re-run the job. |
| Terraform: `Error acquiring the state lock` | A previous apply was interrupted | Confirm nothing is genuinely running, then `terraform force-unlock <LOCK_ID>`. Use with care. |
| RAM above the 2.5 GB budget | ArgoCD default footprint, or too many nodes | Set `agents: 0` in `k3d-config.yaml`, drop each service to `replicas: 1`, and confirm `dex` and `notifications` are disabled. Note `applicationSet: enabled: false` does NOT work; use `applicationSet: replicas: 0` instead. |

### Useful diagnostic commands

```bash
# What is actually consuming resources
kubectl top pods -A --sort-by=memory

# Why a pod will not start: read Events at the bottom
kubectl -n platform describe pod <pod-name>

# Cluster-wide recent events, newest last
kubectl get events -A --sort-by=.lastTimestamp | tail -30

# Exactly what ArgoCD thinks is different
argocd app diff service-1

# Reconciliation errors
kubectl -n argocd logs -l app.kubernetes.io/name=argocd-application-controller --tail=100
```

---

## Appendix C: Command Cheat Sheet

Two shell variables make the rest of this work. If a command fails with a path error, check these first:

```bash
export PLATFORM_HOME="$HOME/Downloads/nextwork_projects/local-full-intrastructure"
export GH_OWNER="$(gh api user --jq .login)"
```

```bash
# --- Getting around ----------------------------------------------
cd $PLATFORM_HOME                        # the workspace root
cd $PLATFORM_HOME/lfi-infrastructure-gitops
cd $PLATFORM_HOME/lfi-service-1-app

# --- Python venv for either app repo -----------------------------
# The pip.conf line pins THIS venv to public PyPI, overriding the machine
# default (pypi.internal.example.com) without changing it. Rewrite it whenever you
# recreate the venv. See the primer at the top of Section 3.
python3.12 -m venv .venv && source .venv/bin/activate
printf '[global]\nindex-url = https://pypi.org/simple\n' > .venv/pip.conf
pip config list           # resolved index
pip config debug          # every layer, and which file each value came from
pip install -r requirements-dev.txt
pytest -v && ruff check src tests

# --- Lifecycle (run from the gitops repo) ------------------------
# Note: gmake, not make. Apple's make is 3.81 and cannot run this Makefile.
gmake help                # list every target with its description
gmake up                  # full bring-up, correct order
gmake down                # remove platform resources, keep the cluster
gmake destroy             # tear down everything
gmake check-env           # validate .env before applying

# --- Cluster -----------------------------------------------------
k3d cluster list
kubectl config use-context k3d-platform
kubectl -n platform get pods,svc,ingress,pvc

# --- ArgoCD ------------------------------------------------------
# No port-forward: ArgoCD is behind the Traefik ingress. UI at
# http://argocd.localhost:8080
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# --plaintext because the server runs without TLS, --grpc-web to pass through
# the ingress cleanly, --insecure to skip the certificate prompt. Task 6.1.5.
argocd login argocd.localhost:8080 --username admin --plaintext --grpc-web --insecure

argocd app list
argocd app get service-1 --refresh      # force a poll
argocd app diff service-1
argocd app sync service-1               # manual sync
argocd app wait service-1 --health
argocd app history service-1
argocd app rollback service-1 <REVISION>

# --- Smoke test the whole architecture ---------------------------
curl -s http://localhost:8080/healthz
curl -s http://localhost:8080/readyz
curl -s -X POST http://localhost:8080/compute \
  -H 'Content-Type: application/json' -d '{"value": 21}'
curl -s http://localhost:8080/history

# --- Database ----------------------------------------------------
kubectl -n platform exec -it postgres-0 -- \
  sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

# --- Local image workflow (pre-CI, or offline) -------------------
# Run from $PLATFORM_HOME: the build contexts are relative to it.
cd $PLATFORM_HOME
docker build -t "ghcr.io/$GH_OWNER/service-1:dev" lfi-service-1-app
k3d image import "ghcr.io/$GH_OWNER/service-1:dev" -c platform

# --- Local dev without Kubernetes --------------------------------
cd $PLATFORM_HOME
docker compose -f docker-compose.dev.yaml up --build
docker compose -f docker-compose.dev.yaml down -v
```

---

## Appendix D: Glossary

Terms as they are used in this guide. Where a definition is commonly muddled, the confusion is named directly.

### Kubernetes objects

| Term | Meaning |
|---|---|
| **Pod** | The smallest deployable unit: one or more containers sharing a network address. You rarely create one directly; something else manages them for you. |
| **Deployment** | Manages a set of identical, interchangeable pods. Handles rolling updates and replacement. Right for stateless services. |
| **ReplicaSet** | Created by a Deployment to hold one specific version of a pod template. A rolling update is one ReplicaSet scaling up while another scales down. |
| **StatefulSet** | Like a Deployment, but pods get stable names (`postgres-0`), stable storage, and ordered startup. Right for databases. |
| **Service** | A stable name and virtual IP in front of a changing set of pods. Pods come and go; the Service name does not. |
| **ClusterIP** | The default Service type. Reachable only from inside the cluster, which is what `service-2` uses. |
| **Headless Service** | A Service with `clusterIP: None`. DNS resolves straight to pod IPs instead of a load-balanced virtual IP. Required to govern a StatefulSet. |
| **Ingress** | A *rule* saying which hostnames and paths route to which Service. Inert on its own. |
| **Ingress controller** | The *program* that reads Ingress rules and actually routes traffic. Here, Traefik. An Ingress without a controller does nothing, which is a very common source of confusion. |
| **Namespace** | A logical partition of a cluster. This project uses `platform` for workloads and `argocd` for the control plane. |
| **Secret** | An object holding sensitive values. Base64-encoded, **not encrypted**. This is precisely why one must never be committed to Git. |
| **secretKeyRef / envFrom** | The two ways a pod reads a Secret into environment variables: one key at a time, or all keys at once. |
| **PersistentVolumeClaim (PVC)** | A request for storage: how much, and with what access mode. Written by you. |
| **PersistentVolume (PV)** | The storage that actually got provisioned to satisfy a claim. Usually created for you. |
| **StorageClass** | The provisioner that turns a PVC into a PV. k3d ships `local-path`, which writes to a directory on the node. |
| **Liveness probe** | "Is this process wedged?" Failing it **restarts** the container. Keep it dependency-free, or a database blip will kill healthy pods. |
| **Readiness probe** | "Should this pod receive traffic right now?" Failing it removes the pod from its Service without restarting it. |
| **CRD** | Custom Resource Definition. How a tool adds its own object types to the Kubernetes API. ArgoCD's `Application` is a CRD. |
| **Finalizer** | A marker that blocks deletion until cleanup runs. Used on ArgoCD Applications so deleting one removes its children rather than orphaning them. |

### The local cluster stack

| Term | Meaning |
|---|---|
| **k3s** | A complete, certified Kubernetes distribution packaged as a single binary, with cloud-provider and legacy components stripped out. Not a partial implementation. |
| **k3d** | Runs k3s nodes as Docker containers. Each "node" in your cluster is a container on your Mac. |
| **OrbStack** | The container engine underneath, replacing Docker Desktop at a fraction of the memory cost. |
| **Traefik** | The ingress controller k3s installs by default. Your entry point on `localhost:8080`. |
| **Cluster DNS** | The internal resolver that makes `http://service-2:8000` work with no configuration from you. |

### Configuration and packaging

| Term | Meaning |
|---|---|
| **Manifest** | A YAML file describing a Kubernetes object. |
| **Declarative** | You describe the desired end state and the system works out the steps. The opposite of imperative, where you specify the steps yourself. |
| **Kustomize** | Transforms plain, valid manifests through overlays. No templating language. Built into `kubectl` as `-k`. |
| **Helm** | Templates manifests from a chart plus values. The right tool for consuming third-party software. |
| **Chart** | A packaged Helm application, such as `argo-cd`. |
| **Rule of thumb** | Helm for software you consume, Kustomize for software you own. |

### GitOps

| Term | Meaning |
|---|---|
| **GitOps** | Git holds the desired state and a controller *inside* the cluster continuously pulls and reconciles toward it. Contrast with push-based CD, where an external system reaches in. |
| **ArgoCD** | The GitOps controller used here. |
| **Application** | ArgoCD's core object: a mapping from a Git repo path to a cluster namespace. Not your application. |
| **App-of-apps** | One hand-applied Application whose Git path contains only other Application manifests. Solves the bootstrap problem with a single imperative step. |
| **Reconciliation** | The loop: read Git, read cluster, diff, apply. Every 3 minutes by default. |
| **Sync status** | Does the cluster match Git? `Synced` or `OutOfSync`. |
| **Health status** | Are the workloads actually functioning? `Healthy`, `Progressing`, or `Degraded`. Independent of sync status: `Synced` plus `Degraded` means Git faithfully describes something broken. |
| **Drift** | Any difference between Git and the cluster, whether from a manual change or a failure. |
| **Self-heal** | Revert changes made in the cluster, not just apply changes made in Git. |
| **Prune** | Delete cluster resources no longer present in Git. Deliberately disabled for Postgres in this project. |

### Infrastructure as Code

| Term | Meaning |
|---|---|
| **IaC** | Infrastructure described in version-controlled files rather than created by hand. |
| **Terraform / OpenTofu** | The IaC tool used here. OpenTofu is the open-source fork; either works. |
| **Provider** | A plugin that lets Terraform manage one kind of thing (`kubernetes`, `helm`, `aws`). |
| **State** | Terraform's record of what it has created and how that maps to your config. Losing it means Terraform no longer knows it owns anything. |
| **Backend** | Where state is stored. A local file by default, S3 from Section 9. |
| **State locking** | Prevents two applies running at once and corrupting state. A `.tflock` object written into the state bucket with a conditional put. |
| **Idempotency** | Running the same operation twice produces the same result as running it once. Why `gmake up` is always safe. |
| **`local-exec` provisioner** | Runs a local shell command from Terraform. Used here for `k3d` and one `kubectl apply`, both cases where no good provider exists. |

### CI/CD and registries

| Term | Meaning |
|---|---|
| **GHCR** | GitHub Container Registry, `ghcr.io`. Free for public images. |
| **Image tag** | A label on an image. This project always uses the full Git commit SHA, never `latest`, so a running pod traces back to exact source. |
| **Manifest list** | One tag pointing at several architecture-specific images. What makes a single tag work on both `arm64` and `amd64`. |
| **Buildx / QEMU** | Docker's multi-platform builder, and the emulation that lets an `amd64` runner produce `arm64` images. |
| **`GITHUB_TOKEN`** | A token GitHub Actions provides automatically, scoped to the current repo only. It cannot push to a different repo, which is why `GITOPS_PAT` exists. |
| **PAT** | Personal Access Token. The fine-grained one here has Contents: Write on exactly one repository and nothing else. |
| **Rolling update** | Replacing pods gradually so some are always serving. The default Deployment strategy, and why Task 8.3.4 sees no downtime. |

---

## Where to Go Next

The platform is finished, but it is deliberately a baseline. These are the natural extensions, roughly ordered by how much you learn per hour spent.

**Replace polling with a webhook.** ArgoCD's 3-minute poll is the slowest link in the whole loop. Point a GitHub webhook at `argocd-server` and deployments start within seconds. Small change, immediately satisfying.

**Add observability.** Install `kube-prometheus-stack` as a new Application. You already have the app-of-apps pattern, so this is one new file in `argocd/apps/`. Then instrument the services with `prometheus-fastapi-instrumentator` and build a dashboard. This is the largest genuine gap in the platform as built.

**Do schema migrations properly.** Replace the `CREATE TABLE IF NOT EXISTS` in service-1's startup with Alembic, run as an init container or a Kubernetes Job. This fixes the shortcut flagged in Task 3.2.4 and teaches you how schema changes and rolling deployments interact, which is genuinely subtle.

**Make the cluster reproducible from Git alone.** Adopt Sealed Secrets so the Postgres credential lives encrypted in the repo rather than in your local `.env`. This closes the gap named in decision 4, and afterwards a rebuild needs nothing from your laptop.

**Add environments.** Introduce `overlays/dev` and `overlays/staging` in the GitOps repo, layered over the bases you already wrote. This is where Kustomize starts genuinely earning its place over plain YAML, and it is the structure most real GitOps repos converge on.

**Add progressive delivery.** Argo Rollouts replaces the Deployment with canary or blue-green strategies, so a bad image reaches 10 percent of traffic rather than all of it. A natural follow-on once you have metrics to base the promotion decision on.

**Enforce policy.** Kyverno or OPA Gatekeeper reject manifests that violate rules you set, such as running as root or omitting resource limits. Teaches you the admission controller layer, which stays invisible until the day you need it.

### Two things this guide deliberately did not do

Both were flagged where they arose. Worth remembering as known debt rather than oversights:

1. **The database schema is created in application startup**, not by a migration tool. Fine for a single-replica stub, wrong the moment two replicas race on DDL or you need to alter a column.
2. **The cluster is reproducible from Git plus a local `.env`**, not from Git alone. Reasonable for a local platform, and the reason the rebuild drill in Section 9.3 still needs your laptop.

Neither is hidden anywhere in the build. Both have a named upgrade path above.
