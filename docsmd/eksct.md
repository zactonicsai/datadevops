# EKS + NiFi + Kafka — Cheat Sheet
### Tape this to your monitor. Companion to the full training guide.

---

## 🧭 The 10 commands you'll type every single day

```bash
aws eks update-kubeconfig --name dp-dev --region us-east-1   # 1. connect to a cluster
kubectl get pods -A                                          # 2. what's running everywhere
kubectl get pods -n kafka -o wide                            # 3. pods in one namespace (+node/IP)
kubectl describe pod <pod> -n <ns>                           # 4. WHY is this pod unhappy (read Events!)
kubectl logs <pod> -n <ns> -f --tail=100                     # 5. live logs
kubectl logs <pod> -n <ns> --previous                        # 6. logs from BEFORE the crash
kubectl get events -n <ns> --sort-by=.lastTimestamp          # 7. recent drama in a namespace
kubectl exec -it <pod> -n <ns> -- sh                         # 8. shell inside a pod
kubectl get nodes && kubectl top nodes                       # 9. node health + resource usage
kubectl rollout restart statefulset/<name> -n <ns>           # 10. safe rolling restart
```

---

## ☸️ kubectl quick table

| Want to… | Command |
|---|---|
| Switch cluster | `kubectl config use-context <ctx>` (list: `kubectl config get-contexts`) |
| All resources in ns | `kubectl get all -n nifi` |
| YAML of live object | `kubectl get svc kafka -n kafka -o yaml` |
| Edit live (dev only!) | `kubectl edit deploy <d> -n <ns>` |
| Apply a folder | `kubectl apply -f tenants/dev/` |
| Diff before apply | `kubectl diff -f file.yaml` |
| Port-forward UI locally | `kubectl port-forward svc/nifi 8443:8443 -n nifi` |
| Pod using disk/CPU | `kubectl top pods -n kafka` |
| PVCs (the data disks!) | `kubectl get pvc -n kafka` |
| Who can do X? | `kubectl auth can-i delete pods -n kafka --as=<user>` |
| Decode a secret | `kubectl get secret <s> -n <ns> -o jsonpath='{.data.password}' \| base64 -d` |
| Drain node for maintenance | `kubectl cordon <node>` then `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` |

---

## 🏗️ eksctl / aws eks

| Task | Command |
|---|---|
| List clusters | `aws eks list-clusters` |
| Cluster details (version, endpoint, logging) | `aws eks describe-cluster --name dp-prod` |
| Create cluster from config | `eksctl create cluster -f cluster.yaml` |
| List / scale nodegroups | `eksctl get nodegroup --cluster dp-dev` / `eksctl scale nodegroup --cluster dp-dev --name apps --nodes 5` |
| Upgrade control plane | `eksctl upgrade cluster --name dp-dev --version 1.33 --approve` |
| Add-on versions | `aws eks list-addons --cluster-name dp-dev` |
| Who has cluster access | `aws eks list-access-entries --cluster-name dp-prod` |
| Grant access | `aws eks create-access-entry --cluster-name dp-dev --principal-arn <role-arn> --kubernetes-groups <group>` |
| Pod ↔ IAM role mapping | `aws eks list-pod-identity-associations --cluster-name dp-prod` |

---

## ⎈ Helm

| Task | Command |
|---|---|
| What's installed | `helm list -A` |
| Install/upgrade | `helm upgrade --install nifi ./charts/nifi -n nifi -f values/dev/nifi.yaml --wait` |
| What values are live | `helm get values nifi -n nifi` |
| History / rollback | `helm history nifi -n nifi` → `helm rollback nifi 3 -n nifi` |
| Render without applying | `helm template ./charts/nifi -f values/dev/nifi.yaml` |

---

## 🧱 Terraform (audit-safe = read-only)

| Task | Command |
|---|---|
| Connect to state | `terraform init` |
| **Everything it owns** | `terraform state list` |
| One resource's detail | `terraform state show 'module.eks.aws_eks_cluster.this'` |
| **Drift check** ★ | `terraform plan` → "No changes" = clean |
| Exported values | `terraform output` |
| Format / sanity | `terraform fmt -check -recursive` / `terraform validate` |
| Adopt a hand-made resource | `terraform import <address> <aws-id>` |
| ⚠️ Changes reality | `terraform apply` / `terraform destroy` — **pipeline only!** |

**File map:** `main.tf` resources · `variables.tf` knobs · `terraform.tfvars` knob settings · `outputs.tf` exports · `backend.tf` where state lives · `modules/` recipes

---

## 🕵️ AWS Console — audit click-map

| Question | Go to |
|---|---|
| What servers exist / tags | EC2 → Instances → Tags tab (`aws:cloudformation:stack-name` = owner clue) |
| Orphan disks ($ leak) | EC2 → Volumes → state "available" |
| Public or private subnet? | VPC → Route tables → `0.0.0.0/0 → igw-` = public |
| Open-to-world ports 🚨 | EC2 → Security Groups → inbound `0.0.0.0/0` |
| Load balancers + health | EC2 → Load Balancers / Target groups |
| Cluster version / access / logging | EKS → Clusters → (Compute, Networking, Access, Logging tabs) |
| IaC blueprints (AWS-native) | CloudFormation → Stacks → Resources/Template/Outputs tabs |
| Did someone click? (CFN) | Stack → Stack actions → **Detect drift** |
| Who did what, when | CloudTrail → Event history (90 days free search) |
| Resource change timeline | Config → Resources |
| Cost by env/service | Billing → Cost Explorer → group by Tag |
| Untagged mystery spend | Resource Groups → Tag Editor |
| Free risk scan | Trusted Advisor |
| Logs + retention | CloudWatch → Log groups |

---

## 🌐 Networking crib notes

**Subnet tags EKS needs (or LBs won't spawn):**

| Tag | Value | On |
|---|---|---|
| `kubernetes.io/role/elb` | `1` | Public subnets |
| `kubernetes.io/role/internal-elb` | `1` | Private subnets |
| `kubernetes.io/cluster/<name>` | `shared` | All cluster subnets |

**Which load balancer / which scheme:**

| Traffic | LB | Key annotation |
|---|---|---|
| NiFi UI, HTTP APIs | **ALB** (via Ingress) | `alb.ingress.kubernetes.io/scheme: internet-facing` or `internal` |
| Kafka, raw TCP | **NLB** (via Service) | `service.beta.kubernetes.io/aws-load-balancer-scheme: internal` + `-nlb-target-type: ip` |
| NiFi UI stickiness | ALB | `target-group-attributes: stickiness.enabled=true` |
| Restrict who reaches ALB | ALB | `alb.ingress.kubernetes.io/inbound-cidrs: <vpn-cidr>` |

**Mental model:** public subnet = front yard (doors only: ALB, NAT) · private subnet = backyard (nodes, pods, data) · IGW = front gate (two-way) · NAT = exit-only revolving door · Security group = bouncer per resource · NetworkPolicy = bouncer between pods.

**Golden rules:** nothing but doors in public subnets · sources = other SGs, not IPs · `0.0.0.0/0` only on a public LB's 443 · prod EKS API endpoint = private.

---

## 🔌 Ports you'll memorize eventually

| Port | What |
|---|---|
| 9092 | Kafka plaintext (internal/dev only) |
| 9093 | Kafka TLS (in-cluster clients w/ Strimzi) |
| 9094 | Kafka external listener (via internal NLB) |
| 8443 | NiFi UI + API (HTTPS) |
| 18443 | NiFi Registry UI (common default) |
| 2181 | ZooKeeper (legacy Kafka/NiFi 1.x — a migration smell) |
| 443  | EKS API server / ALB HTTPS |

---

## 🧯 Troubleshooting — first moves

| Symptom | First commands / look |
|---|---|
| Pod `Pending` | `kubectl describe pod` → Events: no room (autoscaler/quota?), unbound PVC, or taint w/o toleration |
| `CrashLoopBackOff` | `kubectl logs --previous` → app error; check config/secret mounts |
| `ImagePullBackOff` | Typo in image tag? ECR permissions? `describe pod` says exactly |
| LB never gets address | AWS LB Controller logs (`-n kube-system`); subnet tags missing (above) |
| Can't reach service | Right port? `kubectl get endpoints <svc>` empty = selector mismatch; then NetworkPolicy; then SG |
| Kafka under-replicated > 0 | A broker down/slow: `kubectl get pods -n kafka`, broker logs, disk % |
| Consumer lag climbing | Consumer app logs; scale consumers ≤ partition count |
| NiFi queue stuck/red | Canvas: back-pressure on connection; downstream processor's error bulletin (top-right of box) |
| NiFi UI logging you out | ALB stickiness off, or OIDC clock/redirect misconfig |
| Disk filling on broker/NiFi | `kubectl exec ... df -h`; lower retention or grow PVC (gp3 can expand live) |
| `kubectl` = Unauthorized | Wrong AWS profile/role → `aws sts get-caller-identity`; access entry exists? |
| Terraform plan shows surprise changes | Someone clicked. CloudTrail who → adopt (`import`) or revert |

---

## 🚀 Promotion flow (how changes ship)

```
MR (plan/tests shown) → merge to main → AUTO deploy DEV → smoke tests
        → ▶ manual STAGE (protected) → full tests
        → ▶ manual PROD (protected + approver)
```

- Humans in prod = **read-only**. The pipeline's role deploys.
- NiFi flows promote via **NiFi Registry versions**, params via per-env **Parameter Contexts**.
- Secrets: **AWS Secrets Manager → External Secrets Operator**. Never in Git, never in canvas.
- GitLab→AWS auth: **OIDC assume-role**, no stored keys.

## 🧳 Migration order (the two mantras)

- **Kafka:** MM2 replicates → verify → move **consumers** → move **producers** → soak → retire.
- **NiFi:** flows to Registry → import on EKS → parallel test → **stop old sources → drain old queues → start new sources** → flip DNS → soak → retire.
- Rollback = point clients back at old. Old cluster stays intact for the soak window.

## ✅ New-environment go-live checklist

```
□ 3 AZs; private subnets /19+; subnet tags present
□ Prod API endpoint private; SGs: no 0.0.0.0/0 except public ALB:443
□ Control-plane logs (all 5) on; CloudWatch add-on installed; retention set
□ Karpenter/autoscaler working (scale test); dedicated tainted nodes for kafka/nifi
□ gp3 StorageClass; Kafka deleteClaim=false; Velero/snapshot backups scheduled
□ Access entries mapped to SSO roles; humans read-only in prod
□ Quotas + LimitRanges + default-deny NetworkPolicy per tenant ns
□ Kafka: RF=3, min.insync=2, rack awareness, auto-create topics OFF
□ NiFi: Registry connected, OIDC login, sticky ALB, params per env
□ Alarms: URP>0, consumer lag, disk>75%, CrashLoop, cert expiry
□ Pipeline can deploy end-to-end; rollback rehearsed once on purpose
```
