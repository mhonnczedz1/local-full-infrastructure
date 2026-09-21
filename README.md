# Local Full Infrastructure

A build guide for a fully automated, GitOps-driven Kubernetes platform that runs
entirely on a Mac, using cloud services only for source control, CI, image
storage, and Terraform state. Compute cost: $0.

This is not a reference manual and not a repo you clone and run. It is a guide
you work through in order, building the three companion repositories yourself as
you go. Roughly 8 to 10 hours for the base platform, plus 4 to 5 more for the
multi-environment follow-on.

## What you build

A k3d cluster (k3s inside Docker, hosted by OrbStack) runs a two-tier
microservice stub backed by a PostgreSQL StatefulSet. Terraform provisions the
cluster and bootstraps ArgoCD. ArgoCD then owns everything else, pulling desired
state from a dedicated GitOps repository. The application repos never touch the
cluster: their CI builds an image, pushes it to GHCR, and commits the new tag to
the GitOps repo, which ArgoCD reconciles.

By the end of the second guide, that single environment is split into `dev` and
`prod`. Dev deploys continuously. Prod changes only through a reviewed weekly
release, and each prod release reaches half the fleet and waits for your
judgment before completing.

**Tech stack:** OrbStack, k3d, k3s, Traefik, Terraform (or OpenTofu), Helm,
ArgoCD, Argo Rollouts, Kustomize, PostgreSQL 16, Python 3.12, FastAPI, GitHub
Actions, GHCR, AWS S3.

## Start here

| | |
|---|---|
| **1.** | [`docs/1-local-full-infra-guide.md`](docs/1-local-full-infra-guide.md) builds the platform, Sections 1 to 9. |
| **2.** | [`docs/2-multi-env-infra-guide.md`](docs/2-multi-env-infra-guide.md) splits it into two environments with gated releases and canary, Sections 10 to 13. |

Read guide 1's "How to Use This Guide" section before starting. It explains the
structure and, more importantly, what the Validate blocks are for.

### Sections

| | Guide 1 | | Guide 2 |
|---|---|---|---|
| 1 | Workstation and Repository Foundation | 10 | Two Environments |
| 2 | Local Cluster Infrastructure | 11 | The Weekly Release |
| 3 | Application Services | 12 | Canary With a Human in the Loop |
| 4 | Data Layer | 13 | Observability (scoped, deliberately unbuilt) |
| 5 | Kubernetes Manifests and Manual Deployment | | |
| 6 | GitOps Control Plane | | |
| 7 | Continuous Integration | | |
| 8 | Automated Promotion | | |
| 9 | Remote State and Resilience | | |

Guide 1 carries Appendices A to D (private repos, troubleshooting, a command
cheat sheet, and a glossary). Guide 2 adds E and F.

### Where you can stop

Section 6 is a complete and genuinely useful local platform. Section 9 adds
cloud CI, automated deployment, and remote state. Section 11 is a complete
release process. Each of those is a coherent outcome rather than an abandoned
project, and the guides say so where you reach them.

## How the guides are structured

Three levels: **Sections** are one part of the system, **Phases** are
milestone-sized chunks, and **Tasks** are single concrete actions.

Every task opens with a **Goal** (the concrete state that exists once it is
done, so you can tell whether you actually finished rather than merely typed the
code) and a **Why** (usually by naming what breaks without it). Every task
closes with a **Validate** block giving the exact command and the output you
should see.

Take the Validate blocks seriously. They exist so that when something breaks
three sections later, you know with certainty which steps were genuinely
working. Debugging one broken layer is straightforward; debugging four stacked
broken layers is not.

## Tracking progress

Not in the guides. The guides stay the source of truth for *what each task is*;
the trackers are the source of truth for *what is done*, so the two can never
disagree and the guides never go stale.

| Tracker | Covers |
|---|---|
| [`tracker_1_local_infra.md`](tracker_1_local_infra.md) | Sections 1 to 9 |
| [`tracker_2_multi_env.md`](tracker_2_multi_env.md) | Sections 10 to 13 |

Each holds a phase summary with time estimates, a checkbox per task, a milestone
table, and a Notes and Deviations log. Tick a task when its Validate passes, not
when you have typed the code.

The checkboxes in this repo reflect the author's own run. Reset them for yours.

## Companion repositories

You create these three yourself during Section 1. These are the reference
versions, public, for comparison when something does not match.

| Repo | What it holds |
|---|---|
| [lfi-infrastructure-gitops](https://github.com/mhonnczedz1/lfi-infrastructure-gitops) | ArgoCD's source of truth. Terraform (`01-cluster`, `02-platform`), the Kubernetes manifests, the app-of-apps children, and the Makefile. |
| [lfi-service-1-app](https://github.com/mhonnczedz1/lfi-service-1-app) | The gateway service. FastAPI, talks to Postgres and to service-2. |
| [lfi-service-2-app](https://github.com/mhonnczedz1/lfi-service-2-app) | The stateless worker. FastAPI. |

## Prerequisites

- A Mac with Homebrew.
- A GitHub account (the baseline path uses public repos and public GHCR
  packages, which removes two entire categories of credential plumbing from the
  critical path).
- An AWS account, for the S3 Terraform backend in Section 9. Free tier is ample.
- GNU Make 4.x installed as `gmake`. macOS ships 3.81, which **silently
  ignores** two directives the Makefile depends on. Task 1.1.1 explains why this
  is not optional.

Comfort in a terminal and a rough idea of what a container is. You do not need
prior Kubernetes, Terraform, or GitOps experience; where a concept is
load-bearing there is a primer before you use it, and where a choice could
reasonably have gone another way the reasoning is spelled out.

## A note on this repo's layout

The guides describe a workspace that holds the three repositories above and is
deliberately not a repository itself. This repo *is* that workspace root, with
the three directories listed in `.gitignore` exactly as guide 1's "A note on
nesting Git repos" prescribes. That keeps the guides and trackers versioned
while leaving the three repos to manage themselves.

So where the guides say the workspace is not a Git repository, they mean yours
will not be until you choose otherwise. This one took the option they describe.

Placeholders in the guides (`YOUR_GITHUB_USER`, `$GH_OWNER`, `/Users/<you>`)
are yours to substitute. Nothing is meant to be pasted unchanged.

## License

[MIT](LICENSE).
