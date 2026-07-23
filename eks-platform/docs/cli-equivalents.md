# Doing It All By Hand: `aws`, `kubectl` and `helm`

This document shows the command-line equivalent of everything Terraform does in
this project. It exists for three reasons:

1. **Understanding.** Terraform hides a lot. Seeing the raw commands makes it
   obvious what is actually happening.
2. **Debugging.** When a Terraform apply fails, you fix it with these commands.
3. **Judgement.** Knowing both approaches lets you choose the right one, rather
   than reaching for Terraform reflexively.

---

## When to use which tool

| Situation | Use | Why |
|---|---|---|
| Building infrastructure you will keep | Terraform | Reproducible, reviewable, one `destroy` cleans up |
| Trying something out for ten minutes | `kubectl`/`helm` | No state file to manage or corrupt |
| Investigating why something is broken | `kubectl` | Terraform cannot tell you why a pod is crash-looping |
| Rolling back a bad chart upgrade | `helm rollback` | Terraform has no direct equivalent |
| Seeing exactly what a chart will create | `helm template` | Renders the YAML without installing |
| Anything a colleague must reproduce | Terraform | "It works on my laptop" is not a deployment strategy |

The honest summary: **Terraform for the durable, kubectl for the immediate.**

---

## 1. Prerequisites

```bash
# Verify your tools exist and you are authenticated.
terraform version          # need >= 1.9
aws --version              # need v2
kubectl version --client
helm version

# Confirm AWS credentials work. This is a read-only call.
aws sts get-caller-identity
```

If that last command fails, nothing else in this document will work. Fix it
first with `aws configure` or by setting `AWS_PROFILE`.

---

## 2. Creating the cluster with `eksctl` instead of Terraform

`eksctl` is the AWS-endorsed CLI for EKS. It is much faster to type than
Terraform is to write, and much worse at managing change over time.

```bash
eksctl create cluster \
  --name eksdemo-cluster \
  --region us-east-1 \
  --version 1.34 \
  --nodegroup-name general \
  --node-type m6i.large \
  --nodes 3 \
  --nodes-min 3 \
  --nodes-max 6 \
  --node-volume-size 50 \
  --managed \
  --with-oidc
```

**Pros:** one command, sensible defaults, roughly 15 minutes to a working
cluster.

**Cons:** it builds a CloudFormation stack you did not write and do not
control. Changing anything later means either another `eksctl` command that may
not do what you expect, or editing CloudFormation by hand. There is no plan
step, so you cannot preview a change before making it.

Use `eksctl` to learn or to spin up a throwaway. Use Terraform for anything
that will still exist next month.

---

## 3. Connecting `kubectl` to the cluster

```bash
# Writes a context into ~/.kube/config. Safe to re-run.
aws eks update-kubeconfig --region us-east-1 --name eksdemo-cluster

# Verify
kubectl get nodes
kubectl cluster-info
```

If `kubectl get nodes` says "Unauthorized", your IAM identity has no access
entry on the cluster. That is what `enable_cluster_creator_admin_permissions`
handles in layer 01. To grant someone else access:

```bash
aws eks create-access-entry \
  --cluster-name eksdemo-cluster \
  --principal-arn arn:aws:iam::123456789012:role/SomeRole \
  --region us-east-1

aws eks associate-access-policy \
  --cluster-name eksdemo-cluster \
  --principal-arn arn:aws:iam::123456789012:role/SomeRole \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster \
  --region us-east-1
```

---

## 4. metrics-server

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update

helm install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --version 3.13.0 \
  --set replicas=2 \
  --set 'args[0]=--kubelet-insecure-tls' \
  --wait

# Verify. Numbers may take ~60s to appear after install.
kubectl top nodes
kubectl top pods -A
```

`--kubelet-insecure-tls` is required on EKS because kubelets present
self-signed certificates. Traffic is still encrypted; only identity
verification is skipped. Without it, metrics-server crash-loops with an x509
error and **all CPU-based autoscaling silently stops working**.

---

## 5. KEDA

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

# See every value you could set before you set any of them.
helm show values kedacore/keda --version 2.20.1 > /tmp/keda-values.yaml

helm install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --version 2.20.1 \
  --wait \
  --timeout 15m

# Verify the CRDs registered
kubectl get crd | grep keda.sh
kubectl api-resources --api-group=keda.sh
kubectl get pods -n keda
```

You should see three deployments: the operator, the metrics apiserver, and the
admission webhooks.

Then apply a ScaledObject:

```bash
kubectl apply -f docs/keda-scaledobject.yaml

kubectl get scaledobject -n hello-web
kubectl get hpa -n hello-web          # KEDA created this for you
kubectl describe scaledobject hello-web-scaler -n hello-web
```

**Reading the HPA output is the key debugging skill here.** The `TARGETS`
column shows `current/target`, e.g. `12%/50%`. If it shows `<unknown>/50%`,
metrics-server is not working — go back to section 4.

---

## 6. Strimzi and Kafka

```bash
helm repo add strimzi https://strimzi.io/charts/
helm repo update

helm install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
  --namespace kafka \
  --create-namespace \
  --version 1.0.0 \
  --wait \
  --timeout 15m

kubectl get pods -n kafka
kubectl get crd | grep strimzi
```

Then create the cluster:

```bash
kubectl apply -f docs/kafka-cluster.yaml

# Watch it come up. This takes 3-5 minutes.
kubectl get kafka -n kafka -w

# Expect 5 pods: 3 controllers + 2 brokers
kubectl get pods -n kafka
```

### When Kafka will not become Ready

In order of usefulness:

```bash
# 1. The status conditions usually name the problem outright.
kubectl describe kafka demo-kafka -n kafka

# 2. The operator log explains its reasoning step by step.
kubectl logs -n kafka -l name=strimzi-cluster-operator --tail=100

# 3. Events catch scheduling and storage failures.
kubectl get events -n kafka --sort-by=.lastTimestamp | tail -30

# 4. If pods are Pending, the cluster is out of room.
kubectl describe pod demo-kafka-broker-0 -n kafka | grep -A10 Events
```

### Producing and consuming

```bash
# Produce (type lines, Ctrl-D to finish)
kubectl run kafka-producer -n kafka -ti --rm --restart=Never \
  --image=quay.io/strimzi/kafka:latest-kafka-4.2.0 \
  -- bin/kafka-console-producer.sh \
     --bootstrap-server demo-kafka-kafka-bootstrap:9092 \
     --topic demo-topic

# Consume from the beginning
kubectl run kafka-consumer -n kafka -ti --rm --restart=Never \
  --image=quay.io/strimzi/kafka:latest-kafka-4.2.0 \
  -- bin/kafka-console-consumer.sh \
     --bootstrap-server demo-kafka-kafka-bootstrap:9092 \
     --topic demo-topic --from-beginning

# Inspect topics
kubectl run kafka-admin -n kafka -ti --rm --restart=Never \
  --image=quay.io/strimzi/kafka:latest-kafka-4.2.0 \
  -- bin/kafka-topics.sh \
     --bootstrap-server demo-kafka-kafka-bootstrap:9092 --describe
```

---

## 7. NiFi

There is no official Apache NiFi Helm chart, which is why layer 07 writes a
StatefulSet by hand. To reach the UI:

```bash
kubectl port-forward -n nifi svc/nifi 8443:8443

# Then open https://localhost:8443/nifi
# Your browser will warn about the self-signed certificate. That is expected.

# Get the generated password
cd 07-nifi && terraform output -raw nifi_password

# Or read it straight from the Secret
kubectl get secret nifi-credentials -n nifi \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

If you get **"Invalid host header"**, the hostname you used is not in
`NIFI_WEB_PROXY_HOST`. That variable is set in `07-nifi/main.tf`.

---

## 8. The toolbox, and testing from inside the cluster

```bash
# Open a shell inside the cluster
kubectl exec -it -n toolbox deploy/toolbox -- /bin/bash

# Load the addresses of everything
. /etc/toolbox/cluster-env.sh
echo $KAFKA_BOOTSTRAP
```

Inside that shell:

```bash
# DNS resolution
dig +short hello-web.hello-web.svc.cluster.local
nslookup demo-kafka-kafka-bootstrap.kafka.svc.cluster.local

# HTTP
curl -s http://hello-web.hello-web.svc.cluster.local/ | grep Pod

# Raw TCP — the fastest way to distinguish "DNS broken" from "port closed"
nc -zv demo-kafka-kafka-bootstrap.kafka.svc.cluster.local 9092
nc -zv nifi.nifi.svc.cluster.local 8443

# Address one specific StatefulSet pod
nc -zv nifi-0.nifi-headless.nifi.svc.cluster.local 8443

# TLS inspection
openssl s_client -connect nifi.nifi.svc.cluster.local:8443 </dev/null
```

### The debugging order that actually works

When something cannot reach something else, check in this order. Each step
rules out a whole category of cause:

1. **Does the name resolve?** `dig +short <name>` — if not, the Service does
   not exist or you have the namespace wrong.
2. **Does the Service have endpoints?** `kubectl get endpoints <svc> -n <ns>` —
   an empty list means the label selector matches nothing, or no pod is passing
   its readiness probe. This is the single most common cause.
3. **Is the port open?** `nc -zv <name> <port>` — if DNS works but TCP does
   not, check `targetPort` against what the container actually listens on.
4. **Does the application respond?** `curl` — TCP open but no HTTP response
   means the app is still starting or is wedged.
5. **Only now read logs.** `kubectl logs <pod> -n <ns>`

Skipping to step 5 first is the most common time-waster in Kubernetes
debugging.

---

## 9. Cleaning up

```bash
# Helm releases
helm uninstall keda -n keda
helm uninstall strimzi-kafka-operator -n kafka
helm uninstall metrics-server -n kube-system

# Custom resources first, so operators can clean up properly
kubectl delete kafka demo-kafka -n kafka
kubectl delete kafkanodepool --all -n kafka

# Namespaces
kubectl delete namespace hello-web kafka nifi keda toolbox

# The cluster itself
eksctl delete cluster --name eksdemo-cluster --region us-east-1
```

### Things that survive deletion and keep billing you

This is the part people miss:

```bash
# PVCs from StatefulSets are deliberately kept by Kubernetes
kubectl get pvc -A

# Unattached EBS volumes
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size,CreateTime]' --output table

# Load balancers orphaned by a deleted Service
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'

# NAT gateways (~$32/month each)
aws ec2 describe-nat-gateways --filter Name=state,Values=available

# CloudWatch log groups (small but they accumulate)
aws logs describe-log-groups --log-group-name-prefix /aws/eks
```

`scripts/destroy-all.sh` runs the EBS check automatically. The rest are worth
a manual look after any teardown.
