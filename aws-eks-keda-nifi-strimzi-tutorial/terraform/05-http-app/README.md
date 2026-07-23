# 05 - Two HTTP Micro Servers

This folder creates two NGINX Deployments. Each starts with one pod. A shared
ClusterIP Service balances requests across both Deployments. KEDA can scale each
Deployment from one to five pods using CPU utilization.
