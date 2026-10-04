# Tracker 3: EKS Counterpart

Plan: [docs/3-eks-counterpart-guide.md](docs/3-eks-counterpart-guide.md)

**Status:** In progress, executed by hand. The checked items below are what has been done and validated.

| Section | Phase | Status | Estimate |
|---------|-------|--------|----------|
| 14 Restructure | 14.1 Preflight | ☐ Not started | 20 min |
| | 14.2 Build new paths beside old | ☐ Not started | 45 min |
| | 14.3 Cutover | ☐ Not started | 60 min |
| | 14.4 Remove old paths | ☐ Not started | 20 min |
| | 14.5 Move the local Terraform | ☐ Not started | 30 min |
| 15 EKS infrastructure | 15.1 Prerequisites and guardrails | ☐ Not started | 45 min |
| | 15.2 Network and cluster | ☐ Not started | 90 min |
| | 15.3 Storage | ☐ Not started | 30 min |
| 16 EKS platform | 16.1 Platform module | ☐ Not started | 60 min |
| | 16.2 Ingress | ☐ Not started | 30 min |
| | 16.3 Apply and hand over to GitOps | ☐ Not started | 45 min |
| 17 Overlays and apps | 17.1 Overlays | ☐ Not started | 60 min |
| | 17.2 Applications | ☐ Not started | 30 min |
| | 17.3 First sync | ☐ Not started | 45 min |
| | 17.4 Releases | ☐ Not started | 75 min |
| 18 Operating both | 18.1 Makefile | ☐ Not started | 45 min |
| | 18.2 Independence drills | ☐ Not started | 90 min |
| | 18.3 Teardown and cost | ☐ Not started | 45 min |

**Commit rule:** commit this tracker with the related changes only when a whole Section completes.

## Section 14: Restructure for two targets
- [x] 14.1.1 Prove the local cluster is healthy
- [x] 14.1.2 Snapshot the rendered manifests
- [x] 14.1.3 Work on a branch
- [x] 14.2.1 Copy overlays to `overlays/local`
- [x] 14.2.2 Create `argocd/apps-local`
- [x] 14.3.1 Commit and merge the additive change
- [x] 14.3.2 Repoint the root Application
- [x] 14.3.3 Repoint the writers (CI in both service repos, release.sh, CODEOWNERS)
- [x] 14.4.1 Delete the old paths
- [x] 14.4.2 Re-run the release path end to end
- [x] 14.5.1 Move the local Terraform under `terraform/local`

## Section 15: EKS infrastructure
- [x] 15.1.1 AWS access
- [x] 15.1.2 Verify module, chart and Kubernetes versions, and prices
- [x] 15.1.3 Budget alarm
- [x] 15.1.4 Confirm images are pullable from AWS
- [x] 15.2.1 Provider, backend and VPC
- [x] 15.2.2 EKS cluster and managed node group
- [x] 15.2.3 State in S3
- [x] 15.3.1 EBS CSI driver

## Section 16: EKS platform bootstrap
- [x] 16.1.1 Copy the local module and remove the k3d pieces
- [x] 16.1.2 Guard the context
- [x] 16.1.3 gp3 StorageClass
- [x] 16.2.1 Traefik via Helm
- [x] 16.3.1 Apply the platform stage
- [x] 16.3.2 Confirm the root Application watches `apps-eks`
- [x] 16.3.3 Reach the ArgoCD UI

## Section 17: EKS overlays and apps
- [x] 17.1.1 `overlays/eks/{dev,prod}/<svc>`
- [x] 17.1.2 Gate the EKS prod path
- [x] 17.2.1 `argocd/apps-eks/{dev,prod}`
- [x] 17.3.1 Merge and watch it converge
- [x] 17.3.2 Hit it through the load balancer
- [x] 17.4.1 CI and `release.sh` write every overlay
- [x] 17.4.2 Canary on EKS

## Section 18: Operating both
- [ ] 18.1.1 Replace the per-cluster commands with commands that ask
- [ ] 18.2.1 Drill: local only
- [ ] 18.2.2 Drill: EKS only
- [ ] 18.2.3 Drill: both
- [ ] 18.3.1 Full EKS teardown leaves nothing billing
- [ ] 18.3.2 Update the published docs
