resource "kubernetes_manifest" "scaled_object" {
  for_each = local.servers

  manifest = {
    apiVersion = "keda.sh/v1alpha1"
    kind       = "ScaledObject"

    metadata = {
      name      = each.value.name
      namespace = kubernetes_namespace_v1.web.metadata[0].name
    }

    spec = {
      scaleTargetRef = {
        name = kubernetes_deployment_v1.server[each.key].metadata[0].name
      }

      pollingInterval = 15
      cooldownPeriod  = 60
      minReplicaCount = 1
      maxReplicaCount = 5

      advanced = {
        horizontalPodAutoscalerConfig = {
          behavior = {
            scaleUp = {
              stabilizationWindowSeconds = 0
              policies = [
                {
                  type          = "Percent"
                  value         = 100
                  periodSeconds = 30
                }
              ]
            }
            scaleDown = {
              stabilizationWindowSeconds = 60
            }
          }
        }
      }

      triggers = [
        {
          type       = "cpu"
          metricType = "Utilization"
          metadata = {
            value = "50"
          }
        }
      ]
    }
  }

  depends_on = [kubernetes_deployment_v1.server]
}
