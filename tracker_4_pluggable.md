# Tracker 4: Pluggable Structure

Plan: [docs/4-pluggable-structure-guide.md](docs/4-pluggable-structure-guide.md)

**Status:** Not started. Tick a task when its Validate passes, not when you have typed the code.

| Section | Phase | Status | Estimate |
|---------|-------|--------|----------|
| 19 Baseline and contract | 19.1 Preflight | ☐ Not started | 25 min |
| | 19.2 The contract | ☐ Not started | 30 min |
| 20 Pluggable services | 20.1 Components and slimmer overlays | ☐ Not started | 45 min |
| | 20.2 Stage the ApplicationSets | ☐ Not started | 40 min |
| | 20.3 Cutover on the local cluster | ☐ Not started | 60 min |
| | 20.4 Scripts read the registry | ☐ Not started | 40 min |
| | 20.5 The scaffolder | ☐ Not started | 45 min |
| | 20.6 Plug-in drill (local) | ☐ Not started | 30 min |
| 21 Add-ons and multi-cluster | 21.1 The add-on layer | ☐ Not started | 40 min |
| | 21.2 One source of truth for cluster identity | ☐ Not started | 60 min |
| | 21.3 EKS prefix delegation | ☐ Not started | 25 min |
| | 21.4 A template others can stamp | ☐ Not started | 45 min |
| | 21.5 Prove it on EKS (billed: about 0.23 USD an hour) | ☐ Not started | 120 min |
| | 21.6 Close | ☐ Not started | 15 min |

About 10 hours in total, of which about 2 bill.

**Commit rule:** commit this tracker with the related changes only when a whole Section completes.

## Section 19: Baseline and contract
- [ ] 19.1.1 Bring up the local cluster and prove it healthy
- [ ] 19.1.2 Sync main and tag the end of guide 3
- [ ] 19.1.3 Snapshot what exists today
- [ ] 19.1.4 Work on a branch
- [ ] 19.2.1 Write the registry
- [ ] 19.2.2 A contract check that fails loudly

## Section 20: Pluggable services
- [ ] 20.1.1 Create the four components
- [ ] 20.1.2 Slim the service overlays
- [ ] 20.1.3 Prove the render did not change
- [ ] 20.1.4 Widen the code owners
- [ ] 20.2.1 Correct the ArgoCD values and confirm the controller
- [ ] 20.2.2 Write the ApplicationSets outside the watched directory
- [ ] 20.3.1 Confirm the preconditions and record pod identity
- [ ] 20.3.2 Move 1: ship the restructure
- [ ] 20.3.3 Move 2: remove the finalizers
- [ ] 20.3.4 Move 3: delete the six Application files
- [ ] 20.3.5 Move 4: add the ApplicationSets
- [ ] 20.4.1 Replace the hard-coded service and cluster lists
- [ ] 20.5.1 The service template
- [ ] 20.5.2 The scaffold script
- [ ] 20.6.1 Plug a service in
- [ ] 20.6.2 Plug it out

## Section 21: Add-ons and multi-cluster
- [ ] 21.1.1 The add-ons ApplicationSets
- [ ] 21.1.2 The proof add-on: metrics-server on EKS
- [ ] 21.2.1 The Makefile reads the registry
- [ ] 21.2.2 Terraform stops naming the cluster
- [ ] 21.2.3 Prove no state moved (local)
- [ ] 21.3.1 Verify the setting exists for your add-on version
- [ ] 21.3.2 Turn it on
- [ ] 21.4.1 The stamp script
- [ ] 21.4.2 Document it and mark the repo as a template
- [ ] 21.5.1 Confirm the guardrails, then bring EKS up
- [ ] 21.5.2 Terraform agrees with itself on a real cluster
- [ ] 21.5.3 The pod limit went up
- [ ] 21.5.4 metrics-server works
- [ ] 21.5.5 Plug a service in and out on both clusters
- [ ] 21.5.6 Decide what to do with EKS
- [ ] 21.6.1 Tag and confirm

## Milestones

| Milestone | Reached when | Done |
|-----------|--------------|------|
| Baseline tagged | 19.1.2 | ☐ |
| Refactor proven inert | 20.1.3 prints IDENTICAL | ☐ |
| Local cutover complete | 20.3.5: NOTHING RECREATED | ☐ |
| Services plug in and out | 20.6.2: BACK TO THE START | ☐ |
| Registry drives Terraform | 21.2.3: exit code 0 on both stages | ☐ |
| Pod limit raised | 21.5.3: 110 | ☐ |
| Guide 4 complete | 21.6.1 | ☐ |

## Notes and deviations

Record anything that differed from the guide here, with the date: a command that needed changing, a version that moved, a step that failed and how it was fixed. Feed anything reusable back into the guide or its Appendix I.
