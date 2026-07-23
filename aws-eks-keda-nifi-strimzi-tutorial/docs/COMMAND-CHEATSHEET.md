# Command Cheat Sheet

```bash
export KUBECONFIG="$PWD/.kube/config"

kubectl get nodes -o wide
kubectl get pods -A
kubectl get services -A
kubectl get pvc -A
kubectl top nodes
kubectl top pods -A
kubectl get events -A --sort-by=.lastTimestamp

helm list -A
helm status metrics-server -n kube-system
helm status keda -n keda
helm status strimzi-cluster-operator -n strimzi-system

kubectl get scaledobject,hpa -n web
kubectl get kafka,kafkanodepool,kafkatopic -n kafka
kubectl get statefulset,pods,lease -n nifi
```
