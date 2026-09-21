# Tracker Ticker: Multi-Environment

Progress tracking for [2-multi-env-infra-guide.md](docs/2-multi-env-infra-guide.md). **Tick here, not in the plan.**

The plan stays the source of truth for what each task actually is. This file is the source of truth for what is done.

Companion to [tracker_1_local_infra.md](tracker_1_local_infra.md), which covers Sections 1 to 9. This one covers Sections 10 to 13.

**Rule:** tick a task when its **Validate** block passes, not when you have typed the code. When every task in a phase is ticked, flip that phase's row in the summary table below.

**Prerequisite:** Sections 1 to 9 complete, so `gmake up` gives a working single-environment platform with Terraform state in S3.

---

## Phase Summary

| Section | Est. | Phase | Status |
|---|---|---|---|
| **10. Two Environments** | 2 hrs | 10.1 Preparation and teardown | ☐ Not started |
| | | 10.2 Restructure the manifests | ☑ Done |
| | | 10.3 Terraform and the Makefile | ☐ Not started |
| | | 10.4 Bring up and verify | ☐ Not started |
| **11. The Weekly Release** | 1 hr | 11.1 The promotion script | ☐ Not started |
| | | 11.2 The gate | ☐ Not started |
| **12. Canary With a Human in the Loop** | 2 hrs | 12.1 The canary strategy | ☐ Not started |
| | | 12.2 Learn to judge | ☐ Not started |
| | | 12.3 Write down what you learned | ☐ Not started |
| **13. Observability** | deferred | 13.1 Metrics and dashboards | ☐ Deferred |
| | | 13.2 Automated analysis | ☐ Deferred |

### Milestones

| After | You have | Good stopping point? |
|---|---|---|
| Section 10 | Two real environments, separate namespaces, separate databases, separate credentials | Yes, if environment separation was the goal |
| Section 11 | Prod that changes only through a reviewed weekly PR, with named releases and revert as rollback | **Yes.** A complete release process. |
| Section 12 | Prod releases that reach half the fleet and wait for your judgment | Yes, the loop is closed |

---

## Section 10: Two Environments

### [Phase 10.1: Preparation and teardown](docs/2-multi-env-infra-guide.md#phase-101-preparation-and-teardown)

- [x] 10.1.1 Confirm the starting state and record the current image tags
- [x] 10.1.2 Install the Argo Rollouts kubectl plugin
- [x] 10.1.3 Verify the argo-rollouts chart version
- [x] 10.1.4 Tear down the cluster

> **Destroys the database.** Task 10.1.4 deletes the cluster and its PVC. Record the two image tags in 10.1.1 first; after teardown they are only recoverable from Git history.

### [Phase 10.2: Restructure the manifests](docs/2-multi-env-infra-guide.md#phase-102-restructure-the-manifests)

- [x] 10.2.1 Move the three service directories into base/
- [x] 10.2.2 Strip environment-specific fields from the base kustomizations
- [x] 10.2.3 Convert both services from Deployment to Rollout
- [x] 10.2.4 Write the dev overlay
- [x] 10.2.5 Write the prod overlay
- [x] 10.2.6 Prove all six overlays before ArgoCD sees any of them

> **Do not skip 10.2.6.** It is the only thing that catches the silent failure in 10.2.4: kustomize's `replicas:` field does nothing to a Rollout, with no error, so dev would quietly run prod's replica count.

### [Phase 10.3: Terraform and the Makefile](docs/2-multi-env-infra-guide.md#phase-103-terraform-and-the-makefile)

- [x] 10.3.1 Two namespaces and two Secrets, with for_each
- [x] 10.3.2 Add the Argo Rollouts controller
- [x] 10.3.3 Teach the root Application to recurse
- [x] 10.3.4 Per-environment passwords in .env and the guard
- [x] 10.3.5 (Optional) Honest node memory limits

### [Phase 10.4: Bring up and verify](docs/2-multi-env-infra-guide.md#phase-104-bring-up-and-verify)

- [ ] 10.4.1 Six ArgoCD child Applications
- [ ] 10.4.2 Bring the platform up
- [ ] 10.4.3 Verify the two environments are genuinely independent
- [x] 10.4.4 Write and test the build tag calculator
- [x] 10.4.5 Switch service-1's CI to build tags and the dev overlay path
- [x] 10.4.6 Mirror both changes into service-2
- [ ] 10.4.7 Verify the tagging end to end
- [ ] 10.4.8 Commit Section 10

> **10.4.5 is cross-repo and fails silently.** Until the promote path is fixed in `lfi-service-1-app` and `lfi-service-2-app`, CI keeps passing and dev quietly stops receiving builds. Tasks 10.4.4 to 10.4.6 are file edits only and need no cluster; 10.4.7 is the one that does.

**Milestone** after this section: two real environments on one cluster.

---

## Section 11: The Weekly Release

### [Phase 11.1: The promotion script](docs/2-multi-env-infra-guide.md#phase-111-the-promotion-script)

- [ ] 11.1.1 Create the deny list
- [ ] 11.1.2 Write scripts/release.sh
- [ ] 11.1.3 Wire it into the Makefile
- [ ] 11.1.4 Dry run the release
- [ ] 11.1.5 Verify a denial actually blocks

### [Phase 11.2: The gate](docs/2-multi-env-infra-guide.md#phase-112-the-gate)

- [ ] 11.2.1 CODEOWNERS
- [ ] 11.2.2 Branch protection
- [ ] 11.2.3 Tag each release
- [ ] 11.2.4 Practise the rollback before you need it
- [ ] 11.2.5 Commit Section 11

> **11.2.2 is a manual GitHub UI step.** Without it, CODEOWNERS is advisory and the gate does not exist. The task ends by trying to break its own gate; do that part.

**Milestone** after this section: prod changes only through a reviewed weekly PR. A coherent place to stop.

Rollback time measured in 11.2.4: `________`

---

## Section 12: Canary With a Human in the Loop

### [Phase 12.1: The canary strategy](docs/2-multi-env-infra-guide.md#phase-121-the-canary-strategy)

- [ ] 12.1.1 Add canary steps to the prod overlay
- [ ] 12.1.2 Verify ArgoCD does not fight the pause
- [ ] 12.1.3 Makefile helpers

### [Phase 12.2: Learn to judge](docs/2-multi-env-infra-guide.md#phase-122-learn-to-judge)

- [ ] 12.2.1 Answer two questions about service-1's client behaviour
- [ ] 12.2.2 Rehearse a bad service-1 release
- [ ] 12.2.3 Rehearse a bad service-2 release
- [ ] 12.2.4 Release both services at once

> **12.2.3 has an unusual success condition.** If you break service-2 and cannot detect it, that is the finding, not a failure. Write down what you were missing; that list is the specification for Section 13.

Answers from 12.2.1, needed while judging a live canary:

| Question | Answer |
|---|---|
| Does service-1 retry its calls to service-2? | |
| Retry count and timeout, if it does | |
| Does `readyz` check service-2, or only Postgres? | |

### [Phase 12.3: Write down what you learned](docs/2-multi-env-infra-guide.md#phase-123-write-down-what-you-learned)

- [ ] 12.3.1 The bake runbook
- [ ] 12.3.2 Commit Section 12

**Milestone** after this section: the loop is closed. A prod release reaches half the fleet and waits for you.

---

## Section 13: Observability and Automated Analysis

Deferred by design. Do not start until Section 12's rehearsals are done, because those rehearsals define what these metrics have to answer.

### [Phase 13.1: Metrics and dashboards](docs/2-multi-env-infra-guide.md#phase-131-metrics-and-dashboards)

- [ ] 13.1.1 Prometheus and Grafana via Terraform
- [ ] 13.1.2 Expose /metrics from both services
- [ ] 13.1.3 Dashboards separating canary from stable

### [Phase 13.2: Automated analysis](docs/2-multi-env-infra-guide.md#phase-132-automated-analysis)

- [ ] 13.2.1 An AnalysisTemplate comparing canary to stable error rate
- [ ] 13.2.2 Wire the analysis into the prod strategy
- [ ] 13.2.3 Confirm the metrics answer the service-2 question

---

## Notes and Deviations

Log anything you changed relative to the plan, so a later you (or a rebuild) is not surprised.

| Task | What changed | Why |
|---|---|---|
| | | |
