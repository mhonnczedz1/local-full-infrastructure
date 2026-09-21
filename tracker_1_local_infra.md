# Tracker Ticker

Progress tracking for [1-local-full-infra-guide.md](docs/1-local-full-infra-guide.md). **Tick here, not in the plan.**

The plan stays the source of truth for what each task actually is. This file is the source of truth for what is done.

**Rule:** tick a task when its **Validate** block passes, not when you have typed the code. When every task in a phase is ticked, flip that phase's row in the summary table below.

---

## Phase Summary

| Section | Est. | Phase | Status |
|---|---|---|---|
| **1. Workstation and Repository Foundation** | 45 min | 1.1 Host toolchain | ☑ Done |
| | | 1.2 Workspace variable and repositories | ☑ Done |
| | | 1.3 Secrets and ignore rules | ☑ Done |
| **2. Local Cluster Infrastructure** | 30 min | 2.1 Terraform cluster module | ☑ Done |
| | | 2.2 Cluster and ingress verification | ☑ Done |
| **3. Application Services** | 2 hrs | 3.1 service-2 (stateless worker) | ☑ Done |
| | | 3.2 service-1 (gateway) | ☑ Done |
| | | 3.3 Containerization | ☑ Done |
| | | 3.4 Local dev loop with compose | ☑ Done |
| **4. Data Layer** | 45 min | 4.1 Secret plumbing via Terraform | ☑ Done |
| | | 4.2 Postgres StatefulSet and PVC | ☑ Done |
| | | 4.3 Persistence proof | ☑ Done |
| **5. Manifests and Manual Deployment** | 1 hr | 5.1 Kustomize bases | ☑ Done |
| | | 5.2 Manual apply and end-to-end smoke test | ☑ Done |
| **6. GitOps Control Plane** | 1.5 hrs | 6.1 ArgoCD via Terraform and Helm | ☑ Done |
| | | 6.2 App-of-apps | ☑ Done |
| | | 6.3 Handover and drift correction | ☑ Done |
| **7. Continuous Integration** | 1 hr | 7.1 CI for service-2 | ☑ Done |
| | | 7.2 CI for service-1 | ☑ Done |
| | | 7.3 Multi-arch and GHCR verification | ☑ Done |
| **8. Automated Promotion** | 45 min | 8.1 Cross-repo token | ☑ Done |
| | | 8.2 Promote job | ☑ Done |
| | | 8.3 Full loop test | ☑ Done |
| **9. Remote State and Resilience** | 1.5 hrs | 9.1 S3 backend | ☑ Done |
| | | 9.2 State migration | ☑ Done |
| | | 9.3 Destroy and rebuild drill | ☑ Done |

### Milestones

| After | You have | Good stopping point? |
|---|---|---|
| Section 2 | A running Kubernetes cluster answering on `localhost:8080` | Yes, if you only wanted local Kubernetes |
| Section 5 | The full 2-tier app plus Postgres running in the cluster | Not really, you have automated nothing yet |
| Section 6 | ArgoCD owning the cluster and correcting manual drift | **Yes.** A complete local GitOps platform. |
| Section 8 | `git push` in an app repo automatically rolls out to the cluster | Yes, the loop is closed |

---

## Section 1: Workstation and Repository Foundation

### [Phase 1.1: Host toolchain](docs/1-local-full-infra-guide.md#phase-11-host-toolchain)

- [x] 1.1.1 Install OrbStack and the CLI toolchain
- [x] 1.1.2 Record tool versions
- [x] 1.1.3 Verify and pin the ArgoCD chart version

### [Phase 1.2: Workspace variable and repositories](docs/1-local-full-infra-guide.md#phase-12-workspace-variable-and-repositories)

- [x] 1.2.1 Set the workspace variable
- [x] 1.2.2 Create the repos on GitHub
- [x] 1.2.3 Record your GitHub owner name

### [Phase 1.3: Secrets and ignore rules](docs/1-local-full-infra-guide.md#phase-13-secrets-and-ignore-rules)

- [x] 1.3.1 Write the gitignore before writing any secrets
- [x] 1.3.2 Create the committed example and the real .env
- [x] 1.3.3 Write the Makefile that bridges .env into Terraform
- [x] 1.3.4 Commit Phase 1

---

## Section 2: Local Cluster Infrastructure

### [Phase 2.1: Terraform cluster module](docs/1-local-full-infra-guide.md#phase-21-terraform-cluster-module)

- [x] 2.1.1 Write the k3d cluster config
- [x] 2.1.2 Write the cluster Terraform module
- [x] 2.1.3 Create the cluster
- [x] 2.1.4 Confirm idempotency

### [Phase 2.2: Cluster and ingress verification](docs/1-local-full-infra-guide.md#phase-22-cluster-and-ingress-verification)

- [x] 2.2.1 Confirm Traefik came up
- [x] 2.2.2 Prove the host port mapping works end to end
- [x] 2.2.3 Clean up the probe
- [x] 2.2.4 Commit Section 2

**Milestone 1** after this section: a real Kubernetes cluster, created declaratively.

---

## Section 3: Application Services

### [Phase 3.1: service-2, the stateless worker](docs/1-local-full-infra-guide.md#phase-31-service-2-the-stateless-worker)

- [x] 3.1.1 Scaffold the package
- [x] 3.1.2 Write the failing tests first
- [x] 3.1.3 Implement service-2
- [x] 3.1.4 Commit service-2's application code

### [Phase 3.2: service-1, the gateway](docs/1-local-full-infra-guide.md#phase-32-service-1-the-gateway)

- [x] 3.2.1 Scaffold the package
- [x] 3.2.2 Write the config module
- [x] 3.2.3 Write the failing tests
- [x] 3.2.4 Implement service-1
- [x] 3.2.5 Commit service-1's application code

### [Phase 3.3: Containerization](docs/1-local-full-infra-guide.md#phase-33-containerization)

- [x] 3.3.1 Write both Dockerfiles
- [x] 3.3.2 Confirm the image runs as non-root

### [Phase 3.4: Local dev loop with compose](docs/1-local-full-infra-guide.md#phase-34-local-dev-loop-with-compose)

- [x] 3.4.1 Write the compose file
- [x] 3.4.2 Run the full stack locally and exercise every hop
- [x] 3.4.3 Tear down and commit

---

## Section 4: Data Layer

### [Phase 4.1: Secret plumbing via Terraform](docs/1-local-full-infra-guide.md#phase-41-secret-plumbing-via-terraform)

- [x] 4.1.1 Write the platform module's variables
- [x] 4.1.2 Write the platform module, namespace and Secret only
- [x] 4.1.3 Prove the secret is not in Git

### [Phase 4.2: Postgres StatefulSet and PVC](docs/1-local-full-infra-guide.md#phase-42-postgres-statefulset-and-pvc)

- [x] 4.2.1 Write the headless Service
- [x] 4.2.2 Write the StatefulSet
- [x] 4.2.3 Write the Kustomization
- [x] 4.2.4 Deploy Postgres
- [x] 4.2.5 Confirm the credentials actually work

### [Phase 4.3: Persistence proof](docs/1-local-full-infra-guide.md#phase-43-persistence-proof)

- [x] 4.3.1 Write a row
- [x] 4.3.2 Delete the pod and let the StatefulSet rebuild it
- [x] 4.3.3 Confirm the row survived
- [x] 4.3.4 Clean up the check table and commit Section 4

---

## Section 5: Kubernetes Manifests and Manual Deployment

### [Phase 5.1: Kustomize bases](docs/1-local-full-infra-guide.md#phase-51-kustomize-bases)

- [x] 5.1.1 Write the service-2 manifests
- [x] 5.1.2 Write the service-1 manifests

### [Phase 5.2: Manual apply and end-to-end smoke test](docs/1-local-full-infra-guide.md#phase-52-manual-apply-and-end-to-end-smoke-test)

- [x] 5.2.1 Build and import the images into k3d
- [x] 5.2.2 Deploy both services
- [x] 5.2.3 Exercise the whole architecture through the ingress
- [x] 5.2.4 Confirm the boundary that service-2 has no database access
- [x] 5.2.5 Commit Section 5

**Milestone 2** after this section: full 2-tier app plus Postgres, deployed by hand.

---

## Section 6: GitOps Control Plane

### [Phase 6.1: ArgoCD via Terraform and Helm](docs/1-local-full-infra-guide.md#phase-61-argocd-via-terraform-and-helm)

- [x] 6.1.1 Write the ArgoCD Helm values
- [x] 6.1.2 Write the root Application template
- [x] 6.1.3 Extend the platform module with ArgoCD
- [x] 6.1.4 Install ArgoCD
- [x] 6.1.5 Log in to ArgoCD

### [Phase 6.2: App-of-apps](docs/1-local-full-infra-guide.md#phase-62-app-of-apps)

- [x] 6.2.1 Write the three child Applications
- [x] 6.2.2 Push, which is how you deploy from now on
- [x] 6.2.3 Confirm ArgoCD adopted the existing resources rather than duplicating them

### [Phase 6.3: Handover and drift correction](docs/1-local-full-infra-guide.md#phase-63-handover-and-drift-correction)

- [x] 6.3.1 Scale a Deployment by hand and watch it revert
- [x] 6.3.2 Delete a resource entirely and watch it come back
- [x] 6.3.3 Confirm the app still works after all that
- [x] 6.3.4 Update the tracker and confirm the end state

**Milestone 3** after this section: a complete local GitOps platform. A coherent place to stop.

---

## Section 7: Continuous Integration

### [Phase 7.1: CI for service-2](docs/1-local-full-infra-guide.md#phase-71-ci-for-service-2)

- [x] 7.1.1 Write the workflow
- [x] 7.1.2 Make the package public

### [Phase 7.2: CI for service-1](docs/1-local-full-infra-guide.md#phase-72-ci-for-service-1)

- [x] 7.2.1 Write the workflow
- [x] 7.2.2 Make the service-1 package public

### [Phase 7.3: Multi-arch and GHCR verification](docs/1-local-full-infra-guide.md#phase-73-multi-arch-and-ghcr-verification)

- [x] 7.3.1 Confirm both architectures are actually present
- [x] 7.3.2 Confirm the arm64 image runs on your Mac
- [x] 7.3.3 Confirm PRs do not publish

---

## Section 8: Automated Promotion

### [Phase 8.1: Cross-repo token](docs/1-local-full-infra-guide.md#phase-81-cross-repo-token)

- [x] 8.1.1 Create a fine-grained PAT
- [x] 8.1.2 Add the token to both app repos

### [Phase 8.2: Promote job](docs/1-local-full-infra-guide.md#phase-82-promote-job)

- [x] 8.2.1 Add the promote job to service-1
- [x] 8.2.2 Add the promote job to service-2
- [x] 8.2.3 Verify the yq expression against the real file before trusting CI

### [Phase 8.3: Full loop test](docs/1-local-full-infra-guide.md#phase-83-full-loop-test)

- [x] 8.3.1 Push the promote jobs
- [x] 8.3.2 Watch ArgoCD roll it out
- [x] 8.3.3 Do the same for service-1 with a real code change
- [x] 8.3.4 Confirm the rollout was zero-downtime
- [x] 8.3.5 Test the cross-repo race

**Milestone 4** after this section: the loop is closed. `git push` deploys.

---

## Section 9: Remote State and Resilience

### [Phase 9.1: S3 backend](docs/1-local-full-infra-guide.md#phase-91-s3-backend)

- [x] 9.1.1 Set up AWS credentials
- [x] 9.1.2 Create the state bucket
- [x] 9.1.3 Add the backend blocks

### [Phase 9.2: State migration](docs/1-local-full-infra-guide.md#phase-92-state-migration)

- [x] 9.2.1 Back up local state first
- [x] 9.2.2 Migrate the cluster module
- [x] 9.2.3 Migrate the platform module
- [x] 9.2.4 Confirm no drift was introduced
- [x] 9.2.5 Verify locking actually works
- [x] 9.2.6 Remove the local state files and commit

### [Phase 9.3: Destroy and rebuild drill](docs/1-local-full-infra-guide.md#phase-93-destroy-and-rebuild-drill)

- [x] 9.3.1 Record what should come back
- [x] 9.3.2 Destroy everything
- [x] 9.3.3 Rebuild from Git and .env alone
- [x] 9.3.4 Confirm the rebuilt platform is the one Git describes
- [x] 9.3.5 Clean up and close out

---

## Notes and Deviations

Log anything you changed relative to the plan, so a later you (or a rebuild) is not surprised.

| Task | What changed | Why |
|---|---|---|
| 1.1.3 | Kept the `7.7.11` chart pin | Chart line has moved to 10.x, but `7.7.11` is still published and the `values/argocd.yaml` in Task 6.1.2 is written against 7.x value keys |
| 1.2.2 | Repos prefixed `lfi-`: `lfi-service-1-app`, `lfi-service-2-app`, `lfi-infrastructure-gitops` | Naming preference. The plan has been updated throughout, so its commands stay copy-pasteable. Kubernetes resource names and GHCR image paths are deliberately left unprefixed. |
| 1.1.1, 1.3.3 | Added `brew install make` and switched every lifecycle command to `gmake` | Apple ships GNU Make 3.81, which silently ignores `.ONESHELL:` and `.SHELLFLAGS`. Symptom was `syntax error: unexpected end of file` on `check-env`. Always `gmake`, never `make`. |
| 2.1.1 | k3s image bumped from `v1.31.4-k3s1` to `v1.36.4-k3s1`, k3d floor raised to 5.9.0 | v1.31 hit end of life in February 2026 and gets no security patches. v1.36 brings Traefik v3 and containerd v2, neither of which this plan depends on. Note k3d 5.9.0 defaults to v1.35.5, so the pin runs one minor ahead. |
| 7.1.1, 7.2.1, 8.2.1, 8.2.2 | All six GitHub Actions bumped to current majors: checkout v7, setup-python v7, setup-qemu v4, setup-buildx v4, login v4, build-push v7 | Every one was behind, several by multiple majors. Action majors move when the Node runtime is retired, so stale ones warn and then stop working. Verified against the GitHub releases API. |
| 1.1.3, 4.1.1, 6.1.1 | ArgoCD chart `7.7.11` to `10.4.2` (server v2.13.2 to v3.5.2) | The old chart deployed an unsupported server two majors behind the local `argocd` CLI, which would break the CLI calls in Section 6. The expected `values/argocd.yaml` rewrite proved unnecessary: no top-level keys were removed between the charts. |
| 6.1.1 | Corrected the `applicationSet: enabled: false` comment | Pre-existing bug, unrelated to the upgrade. That key exists in neither chart 7.x nor 10.x and the deployment template has no conditional, so the setting never did anything. Use `applicationSet: replicas: 0` instead. |
| 1.3.3 | Added `pause` and `resume` targets to the Makefile | Neither `down` nor `destroy` fits stepping away for a while: both discard work and cost minutes to undo. `k3d cluster stop/start` keeps images, PVCs, and context, and returns in seconds. `resume` waits on node readiness because k3d returns before k3s is serving. |
| 3.1.1, 3.2.1 | Python pins refreshed and `asyncio_default_fixture_loop_scope = "function"` added to both `pyproject.toml` | Pins were ~20 months old. pytest and pytest-asyncio had to move together: 1.4.0 declares `pytest<10,>=8.4`. The new loop-scope setting silences a pytest-asyncio 1.x warning without changing behaviour. Not yet exercised: no tests have been run against the new versions. |
