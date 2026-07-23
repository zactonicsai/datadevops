# Troubleshooting

## Terraform says a state file is missing

Run the folders in numeric order. `02-eks` needs `01-network/terraform.tfstate`.
The application folders need the kubeconfig created after EKS is ready.

## kubectl tries localhost:8080

Your kubeconfig is missing or the wrong file is selected:

```bash
export KUBECONFIG="$PWD/.kube/config"
kubectl config current-context
kubectl get nodes
```

## Nodes stay NotReady

Check the managed node group and EKS add-ons:

```bash
aws eks describe-nodegroup --cluster-name CLUSTER --nodegroup-name general
kubectl get pods -n kube-system
kubectl describe node NODE_NAME
```

Common causes are missing NAT egress, IAM permissions, subnet tags, or a failed
VPC CNI add-on.

## Pods are Pending

```bash
kubectl describe pod POD_NAME -n NAMESPACE
kubectl get events -n NAMESPACE --sort-by=.lastTimestamp
kubectl get nodes
kubectl top nodes
```

Look for not enough CPU, not enough memory, an unbound PVC, or node limits.

## EBS PVC stays Pending

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
kubectl describe pvc PVC_NAME -n NAMESPACE
kubectl get storageclass
```

Verify the EBS CSI add-on is Active and the IAM role was created.

## KEDA does not scale

```bash
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top pods -n web
kubectl describe scaledobject hello-server-a -n web
kubectl get hpa -n web
kubectl logs -n keda deployment/keda-operator
```

The CPU scaler requires CPU requests on the target containers. This project
includes them.

## Kafka is not Ready

```bash
kubectl get kafka,kafkanodepool -n kafka -o yaml
kubectl get pods -n kafka
kubectl logs -n strimzi-system deployment/strimzi-cluster-operator
kubectl get pvc -n kafka
```

Kafka can take several minutes because the operator creates certificates,
services, pods, and EBS volumes.

## NiFi pods restart or never become Ready

```bash
kubectl get pods,pvc,lease -n nifi
kubectl logs -n nifi nifi-0 -c configure
kubectl logs -n nifi nifi-0 -c nifi
kubectl describe pod -n nifi nifi-0
```

NiFi startup can be slow. Check memory, disk binding, configuration generation,
and Lease RBAC.

## Session Manager cannot connect to the test runner

```bash
aws ssm describe-instance-information
aws ec2 describe-instances --filters Name=tag:Role,Values=eks-test-runner
```

The instance needs outbound internet access, the SSM IAM policy, and a running
SSM agent. Amazon Linux 2023 normally includes the agent.
