A few quick ways depending on what you’re trying to check:

1 — Check the CSI driver’s IAM role annotation

kubectl get sa ebs-csi-controller-sa -n kube-system -o yaml | grep role-arn


2 — Check what IAM policies are attached to the role

aws iam list-attached-role-policies \
  --role-name AmazonEKS_EBS_CSI_DriverRole


3 — Check if the EBS CSI add-on has a role configured

aws eks describe-addon \
  --cluster-name <YOUR_CLUSTER> \
  --addon-name aws-ebs-csi-driver \
  --query "addon.serviceAccountRoleArn"


4 — Check if a PVC is stuck (and why)

kubectl describe pvc <pvc-name>


Look for ProvisioningFailed events — they’ll show the exact permission error.

5 — Check CSI controller pod logs directly

kubectl logs -n kube-system \
  -l app=ebs-csi-controller \
  -c csi-provisioner --tail=50


This is the most detailed — it shows the actual AWS API error (e.g. UnauthorizedOperation, AccessDenied).

Start with #4 and #5 — they’ll tell you exactly which permission is missing. What error are you seeing right now?