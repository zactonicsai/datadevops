# Shell script version — command reference

Every script sources `00-config.sh` and writes what it created into
`.lab-state`. Run them in numeric order.

## Order of operations

| # | Script | Creates | Time | Reversed by |
|---|---|---|---|---|
| 00 | `00-config.sh` | (sourced, not run) | — | — |
| 01 | `01-create-vpc.sh` | VPC | 10s | `d6` |
| 02 | `02-create-networking.sh` | Subnets, IGW, NAT, routes, S3 endpoint | ~3m | `d5` |
| 03 | `03-create-iam.sh` | Cluster role, node role | 10s | `d4` |
| 04 | `04-create-security-groups.sh` | Node SG, ALB SG | 10s | `d4` |
| 05 | `05-create-cluster.sh` | EKS control plane, OIDC provider | ~13m | `d3` |
| 06 | `06-create-launch-template.sh` | EC2 launch template | 5s | `d2` |
| 07 | `07-create-nodegroup.sh` | Managed node group | ~5m | `d2` |
| 08 | `08-create-s3-and-irsa.sh` | S3 bucket, NiFi IAM role, service account | 20s | `d4` |
| 09 | `09-install-addons.sh` | EBS CSI, metrics-server, StorageClass | ~3m | `d1` |
| 10 | `10-launch-keycloak.sh` | Keycloak | ~1m | `d1` |
| 11 | `11-launch-kafka.sh` | Kafka + topic | ~2m | `d1` |
| 12 | `12-launch-nifi.sh` | NiFi | ~3m | `d1` |
| 13 | `13-launch-webapp.sh` | Web app | ~1m | `d1` |
| 14 | `14-launch-grafana.sh` | Prometheus + Grafana | ~4m | `d1` |
| 15 | `15-create-nifi-flow.sh` | (prints instructions) | — | — |
| 16 | `16-verify.sh` | (checks everything) | — | — |

## Changing the size or cost

Set these before running, or edit `00-config.sh`:

```bash
export USE_NAT=false                 # save ~$33/month, nodes go public
export NODE_INSTANCE_TYPE=t3.xlarge  # if pods stay Pending
export NODE_DESIRED=3                # needed if you install Grafana
export NODE_CAPACITY_TYPE=ON_DEMAND  # if spot reclaims annoy you
export MY_IP=$(curl -s https://checkip.amazonaws.com)   # lock the ALB to you
```

## Useful commands while it runs

```bash
# --- see everything ---
kubectl get nodes -o wide
kubectl -n lab get all
kubectl -n lab get pvc
kubectl top nodes                       # after metrics-server is up

# --- open each app (each needs its own terminal) ---
kubectl -n lab port-forward svc/webapp   8000:80     # http://localhost:8000
kubectl -n lab port-forward svc/nifi     8443:8443   # https://localhost:8443/nifi
kubectl -n lab port-forward svc/keycloak 8080:8080   # http://localhost:8080
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80

# --- passwords ---
kubectl -n lab get secret keycloak-admin   -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n lab get secret nifi-single-user -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo

# --- Kafka ---
kubectl -n lab exec kafka-0 -- /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --list
kubectl -n lab exec -it kafka-0 -- /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic messages --from-beginning

# --- S3 ---
source ./00-config.sh
aws s3 ls "s3://${S3_BUCKET}/" --recursive
aws s3 cp "s3://${S3_BUCKET}/<key>" - | cat

# --- get a shell on a node, with NO ssh ---
aws ssm start-session --target $(aws ec2 describe-instances \
  --filters "Name=tag:Lab,Values=ekslab" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

# --- AWS-side inspection ---
aws eks describe-cluster --name ekslab-eks --query 'cluster.{Status:status,Version:version}'
aws eks list-nodegroups --cluster-name ekslab-eks
aws ec2 describe-vpcs --filters Name=tag:Lab,Values=ekslab --output table
aws ec2 describe-security-groups --filters Name=tag:Lab,Values=ekslab \
  --query 'SecurityGroups[].{Name:GroupName,Id:GroupId}' --output table
aws iam list-roles --query "Roles[?starts_with(RoleName,'ekslab')].RoleName" --output table
```

## Cost check at any time

```bash
./16-verify.sh          # prints a rough hourly estimate at the end

# what is actually running and billable right now
aws ec2 describe-instances --filters "Name=tag:Lab,Values=ekslab" \
  "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,Life:InstanceLifecycle}' --output table
aws ec2 describe-nat-gateways --filter Name=tag:Lab,Values=ekslab \
  --query 'NatGateways[?State==`available`].NatGatewayId' --output table
aws ec2 describe-addresses --query 'Addresses[?!AssociationId].PublicIp' --output table
```

That last one lists **unattached Elastic IPs**, which are billed hourly and are
the classic thing people leave behind after a failed teardown.
