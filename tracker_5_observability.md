# Tracker 5: Observability Setup

Progress tracking for [5-observability-setup-guide.md](docs/5-observability-setup-guide.md). **Tick here, not in the plan.**

The plan stays the source of truth for what each task actually is. This file is the source of truth for what is done.

Companion to [tracker_1_local_infra.md](tracker_1_local_infra.md), [tracker_2_multi_env.md](tracker_2_multi_env.md), [tracker_3_eks.md](tracker_3_eks.md) and [tracker_4_pluggable.md](tracker_4_pluggable.md). This one covers Sections 22 to 25.

**Status:** Not started. The guide is a draft: nothing in it has been run against a cluster. The time estimates below are the author's guesses, not measurements from a run; replace them with your own.

**Rule:** tick a task when its **Validate** block passes, not when you have typed the code. When every task in a phase is ticked, flip that phase's row in the summary table below.

**Commit rule:** commit this tracker with the related changes only when a whole Section completes.

**Prerequisite:** Sections 1 to 21 complete, so both clusters run from the pluggable layout, the services, data and add-ons ApplicationSets work, and `kubectl top` answers on both clusters.

**EKS bills while it exists** (about 0.23 USD an hour). Phases 22.4, 23.3 and 24.4 are the only ones that need it in Sections 22 to 24. Each ends with a choice to destroy it.

---

## Phase Summary

| Section | Est. | Phase | Status |
|---|---|---|---|
| **22. Metrics platform** | 3.75 hrs | 22.1 Preflight and Prometheus (1 hr) | ☐ Not started |
|  |  | 22.2 Grafana (45 min) | ☐ Not started |
|  |  | 22.3 Postgres, Traefik and the cluster itself (1 hr) | ☐ Not started |
|  |  | 22.4 Prove it on EKS (1 hr) | ☐ Not started |
| **23. Instrumenting the stubs** | 4.25 hrs | 23.1 Metrics in the services (2 hrs) | ☐ Not started |
|  |  | 23.2 A dashboard, and a canary to watch on it (1.5 hrs) | ☐ Not started |
|  |  | 23.3 Confirm on EKS (45 min) | ☐ Not started |
| **24. Traces and logs** | 4.5 hrs | 24.1 The stores and the agent (1.5 hrs) | ☐ Not started |
|  |  | 24.2 OpenTelemetry in the services (1.5 hrs) | ☐ Not started |
|  |  | 24.3 Follow one request (30 min) | ☐ Not started |
|  |  | 24.4 Confirm on EKS, and the knobs (1 hr) | ☐ Not started |
| **25. Analysis, budget and operation** | 4 hrs | 25.1 Automated analysis (2.5 hrs) | ☐ Not started |
|  |  | 25.2 The budget, measured (45 min) | ☐ Not started |
|  |  | 25.3 Operating it (45 min) | ☐ Not started |

### Milestones

| After | You have | Good stopping point? |
|---|---|---|
| Section 22 | Prometheus and Grafana as add-ons on both clusters, scraping the platform, Postgres and Traefik | Yes, if metrics were the goal |
| Section 23 | RED metrics on both services, a dashboard separating canary from stable, and a real canary watched on it | **Yes.** The core of the guide |
| Section 24 | One request traced across both services, its logs found by trace id, and Grafana jumping between them | Yes |
| Section 25 | A canary that aborts itself on errors, an honest note on what it cannot see, and measured budgets | **Yes.** Ready for the marketplace project |

---

## Section 22: Metrics platform

### [Phase 22.1: Preflight and Prometheus](docs/5-observability-setup-guide.md#phase-221-preflight-and-prometheus)

- [ ] 22.1.1 Verify chart versions, value keys and the scrape model
- [ ] 22.1.2 Confirm the starting point and branch
- [ ] 22.1.3 The Prometheus add-on
- [ ] 22.1.4 Merge and watch it converge

### [Phase 22.2: Grafana](docs/5-observability-setup-guide.md#phase-222-grafana)

- [ ] 22.2.1 The Grafana add-on with Prometheus as a datasource
- [ ] 22.2.2 Commands that ask: `gmake grafana`, `gmake prometheus`, `gmake traffic`

### [Phase 22.3: Postgres, Traefik and the cluster itself](docs/5-observability-setup-guide.md#phase-223-postgres-traefik-and-the-cluster-itself)

- [ ] 22.3.1 The Postgres exporter sidecar
- [ ] 22.3.2 Traefik metrics
- [ ] 22.3.3 Decide on kube-state-metrics, and prove the cluster's own metrics are there

### [Phase 22.4: Prove it on EKS](docs/5-observability-setup-guide.md#phase-224-prove-it-on-eks)

- [ ] 22.4.1 Enable the same add-ons on EKS
- [ ] 22.4.2 Measure, then decide whether to leave it up

---

## Section 23: Instrumenting the stubs

### [Phase 23.1: Metrics in the services](docs/5-observability-setup-guide.md#phase-231-metrics-in-the-services)

- [ ] 23.1.1 service-2 exposes RED metrics
- [ ] 23.1.2 service-1 exposes RED metrics, plus outbound and database timings
- [ ] 23.1.3 Scrapeable canary and stable Services
- [ ] 23.1.4 Ship it to dev

### [Phase 23.2: A dashboard, and a canary to watch on it](docs/5-observability-setup-guide.md#phase-232-a-dashboard-and-a-canary-to-watch-on-it)

- [ ] 23.2.1 The RED dashboard
- [ ] 23.2.2 Watch traffic on the dashboard
- [ ] 23.2.3 Release to prod, then watch a canary on the dashboard

### [Phase 23.3: Confirm on EKS](docs/5-observability-setup-guide.md#phase-233-confirm-on-eks)

- [ ] 23.3.1 Dashboard and a canary on EKS

---

## Section 24: Traces and logs

### [Phase 24.1: The stores and the agent](docs/5-observability-setup-guide.md#phase-241-the-stores-and-the-agent)

- [ ] 24.1.1 Tempo
- [ ] 24.1.2 Loki
- [ ] 24.1.3 Alloy
- [ ] 24.1.4 Grafana learns about Tempo and Loki, and links them

### [Phase 24.2: OpenTelemetry in the services](docs/5-observability-setup-guide.md#phase-242-opentelemetry-in-the-services)

- [ ] 24.2.1 service-2 traces and logs with trace ids
- [ ] 24.2.2 service-1 traces its outbound call and its queries
- [ ] 24.2.3 Point the pods at Alloy
- [ ] 24.2.4 Ship it

### [Phase 24.3: Follow one request](docs/5-observability-setup-guide.md#phase-243-follow-one-request)

- [ ] 24.3.1 One trace, three spans and a query
- [ ] 24.3.2 The log lines of that trace
- [ ] 24.3.3 Jump between them

### [Phase 24.4: Confirm on EKS, and the knobs](docs/5-observability-setup-guide.md#phase-244-confirm-on-eks-and-the-knobs)

- [ ] 24.4.1 The same stack on EKS
- [ ] 24.4.2 Sampling and retention

---

## Section 25: Analysis, budget and operation

### [Phase 25.1: Automated analysis](docs/5-observability-setup-guide.md#phase-251-automated-analysis)

- [ ] 25.1.1 An AnalysisTemplate per service, wired into prod only
- [ ] 25.1.2 A way to make service-2 misbehave on purpose
- [ ] 25.1.3 Rehearse a bad canary, and a wrong one
- [ ] 25.1.4 Write down the finding

### [Phase 25.2: The budget, measured](docs/5-observability-setup-guide.md#phase-252-the-budget-measured)

- [ ] 25.2.1 Replace the estimates with measurements
- [ ] 25.2.2 Set the requests to what you measured
- [ ] 25.2.3 Headroom on the one EKS node

### [Phase 25.3: Operating it](docs/5-observability-setup-guide.md#phase-253-operating-it)

- [ ] 25.3.1 The commands, and how to read a canary
- [ ] 25.3.2 Teardown, the stamp checklist, and the docs

---

## Notes and Deviations

Log anything you changed relative to the plan, so a later you (or a rebuild) is not surprised. A chart value key that moved is the most likely entry (Task 22.1.1).

| Task | What changed | Why |
|---|---|---|
| | | |

## Measurements

Filled in by Tasks 22.4.2, 24.4.1 and 25.2.1. The estimates are from the guide; the rest are yours.

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

**Headroom conclusion (Task 25.2.3):** 

**Finding on error-rate analysis (Task 25.1.4):** 

