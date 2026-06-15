# Amazon ECS Configuration Best Practices Guide

**AWS-only. Current as of June 2026.** Covers load balancers, containers, services, and dependencies — with each pattern shown in **CloudFormation**, **Terraform**, **raw JSON**, and **manual CLI**.

-----

## What changed recently (read this first)

A few shifts matter for how you configure ECS today versus older tutorials:

- **AWS App Mesh is being retired on September 30, 2026.** New accounts have been blocked since Sept 2024. Do **not** build new sidecar-Envoy meshes. For ECS service-to-service communication, use **ECS Service Connect** (native, no sidecar management). For cross-VPC/cross-account, look at **VPC Lattice**.
- **Native blue/green deployments** shipped in July 2025. ECS now provisions the new version alongside the old, supports **deployment lifecycle hooks** for validation, a configurable **bake time**, and one-click rollback — all without CodeDeploy glue. Works with ALB, NLB, and Service Connect.
- **Software version consistency** is enforced by default: ECS resolves image tags to a SHA256 **digest** at deploy time and launches every task in the deployment from that digest, so a mutable tag like `latest` won’t drift mid-scale-out. You can opt a specific container out via `versionConsistency` (useful for third-party telemetry sidecars).
- **1-click rollback** (May 2025) and **deployment circuit breaker** improvements mean rollback should be configured on every service.

-----

## Core principles

1. **Two health checks, both required.** The ALB target-group health check decides whether the LB routes traffic; the container `healthCheck` (HEALTHCHECK) decides whether ECS considers the task healthy. Configure both — they answer different questions.
1. **Three IAM roles, never merged.** *Execution role* (ECS pulls images, fetches secrets, writes logs), *task role* (your app’s runtime permissions), and on EC2 the *instance role* (agent registers with the cluster). Scope each to least privilege.
1. **Secrets via `secrets`, never `environment`.** Pull from Secrets Manager or SSM Parameter Store at launch. Plaintext env vars leak in `describe-tasks` and console.
1. **Pin images, scan images.** Immutable ECR tags + scan-on-push + lifecycle policies. Let version consistency do the digest pinning.
1. **Make deploys safe by default.** Circuit breaker + rollback + CloudWatch alarms on every service. Use blue/green for anything customer-facing.
1. **Private subnets + VPC endpoints.** Tasks run in private subnets; reach ECR/S3/Secrets/Logs over interface & gateway endpoints to cut NAT cost and keep traffic off the internet.

-----

# 1. Load Balancer Configuration

## Best practices

- **ALB for HTTP/HTTPS**, NLB for raw TCP/UDP or ultra-low latency. Most container web workloads want ALB.
- **`target_type = ip`** when using `awsvpc` networking (each task gets its own ENI). Use `instance` only for the legacy `bridge` mode with dynamic ports.
- **Terminate TLS at the ALB** with an ACM cert. Redirect HTTP→HTTPS. Use a modern policy: `ELBSecurityPolicy-TLS13-1-2-2021-06`.
- **Tune the health check**: a real health endpoint (`/healthz`, not `/`), `interval` 15–30s, `timeout` < interval, healthy threshold 2–3, unhealthy 2–3, matcher `200`.
- **Lower the deregistration delay** (connection draining) from the 300s default to ~30s for faster rolling deploys — but keep it long enough to drain in-flight requests.
- **Attach WAF** to public ALBs; **enable access logs** to S3; tune **idle timeout** to sit above your longest backend response.
- Use **stickiness only when you actually need session affinity** — it undermines even load distribution.

## CloudFormation

```yaml
TargetGroup:
  Type: AWS::ElasticLoadBalancingV2::TargetGroup
  Properties:
    VpcId: !Ref Vpc
    Port: 8080
    Protocol: HTTP
    TargetType: ip                 # awsvpc networking
    HealthCheckPath: /healthz
    HealthCheckIntervalSeconds: 15
    HealthCheckTimeoutSeconds: 5
    HealthyThresholdCount: 2
    UnhealthyThresholdCount: 3
    Matcher: { HttpCode: '200' }
    TargetGroupAttributes:
      - { Key: deregistration_delay.timeout_seconds, Value: '30' }

HttpsListener:
  Type: AWS::ElasticLoadBalancingV2::Listener
  Properties:
    LoadBalancerArn: !Ref LoadBalancer
    Port: 443
    Protocol: HTTPS
    SslPolicy: ELBSecurityPolicy-TLS13-1-2-2021-06
    Certificates: [{ CertificateArn: !Ref AcmCertArn }]
    DefaultActions: [{ Type: forward, TargetGroupArn: !Ref TargetGroup }]

HttpRedirect:
  Type: AWS::ElasticLoadBalancingV2::Listener
  Properties:
    LoadBalancerArn: !Ref LoadBalancer
    Port: 80
    Protocol: HTTP
    DefaultActions:
      - Type: redirect
        RedirectConfig: { Protocol: HTTPS, Port: '443', StatusCode: HTTP_301 }
```

## Terraform

```hcl
resource "aws_lb_target_group" "app" {
  vpc_id      = aws_vpc.this.id
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  deregistration_delay = 30

  health_check {
    path                = "/healthz"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_cert_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect { protocol = "HTTPS"  port = "443"  status_code = "HTTP_301" }
  }
}
```

## Manual CLI

```bash
# Target group
aws elbv2 create-target-group \
  --name app-tg --vpc-id "$VPC_ID" \
  --protocol HTTP --port 8080 --target-type ip \
  --health-check-path /healthz \
  --health-check-interval-seconds 15 --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
  --matcher HttpCode=200

aws elbv2 modify-target-group-attributes \
  --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30

# HTTPS listener + HTTP redirect
aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
  --protocol HTTPS --port 443 \
  --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
  --certificates CertificateArn="$ACM_ARN" \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN"

aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions \
  'Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}'
```

-----

# 2. Container / Task Definition Configuration

## Best practices

- **Set CPU/memory at the task level** (the scheduler uses it) **and per container** (`memory` = hard cap, `memoryReservation` = soft floor). Hard limit prevents one container starving the host; soft reservation lets it burst.
- **Define a container `healthCheck`** (the in-task HEALTHCHECK) with sensible `interval`, `timeout`, `retries`, `startPeriod`.
- **Logging**: `awslogs` driver to a CloudWatch log group with a finite `retentionInDays`, or `awsfirelens` → FireLens/Fluent Bit for routing to S3/OpenSearch/third parties.
- **Secrets via `secrets`** referencing Secrets Manager ARNs or SSM parameters — not `environment`.
- **Harden the container**: `readonlyRootFilesystem: true`, a non-root `user`, drop Linux capabilities, set `ulimits`. Mount a writable `tmpfs`/volume only where the app genuinely needs to write.
- **Container ordering** with `dependsOn` (`START`, `HEALTHY`, `COMPLETE`, `SUCCESS`) so an app waits for its sidecar/init container.
- **`stopTimeout`** so SIGTERM-then-SIGKILL gives the app time to drain.
- **Image references**: immutable tags or digests. Leave version consistency on; only set `versionConsistency: disabled` for sidecars you intentionally float (e.g., a vendor agent on `latest`).
- **`essential`**: mark the main container essential; non-essential sidecars shouldn’t kill the task when they exit.

## Raw JSON (`taskdef.json` for `register-task-definition`)

This is the one artifact ECS genuinely consumes as a standalone JSON file.

```json
{
  "family": "app-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["EC2"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "arn:aws:iam::<ACCOUNT_ID>:role/app-execution-role",
  "taskRoleArn": "arn:aws:iam::<ACCOUNT_ID>:role/app-task-role",
  "containerDefinitions": [
    {
      "name": "app",
      "image": "<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/app:1.4.2",
      "essential": true,
      "cpu": 512,
      "memory": 1024,
      "memoryReservation": 768,
      "user": "1000:1000",
      "readonlyRootFilesystem": true,
      "linuxParameters": {
        "capabilities": { "drop": ["ALL"] },
        "initProcessEnabled": true
      },
      "portMappings": [
        { "containerPort": 8080, "protocol": "tcp", "name": "app-8080" }
      ],
      "environment": [
        { "name": "LOG_LEVEL", "value": "info" }
      ],
      "secrets": [
        {
          "name": "DB_PASSWORD",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:prod/db-AbCdEf:password::"
        }
      ],
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:8080/healthz || exit 1"],
        "interval": 15,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 30
      },
      "stopTimeout": 30,
      "ulimits": [
        { "name": "nofile", "softLimit": 65536, "hardLimit": 65536 }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/app",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "app"
        }
      }
    }
  ]
}
```

```bash
aws ecs register-task-definition --cli-input-json file://taskdef.json
```

## CloudFormation (same task definition)

```yaml
TaskDefinition:
  Type: AWS::ECS::TaskDefinition
  Properties:
    Family: app-task
    NetworkMode: awsvpc
    RequiresCompatibilities: [EC2]
    Cpu: '512'
    Memory: '1024'
    ExecutionRoleArn: !GetAtt ExecutionRole.Arn
    TaskRoleArn: !GetAtt TaskRole.Arn
    ContainerDefinitions:
      - Name: app
        Image: !Sub '${AWS::AccountId}.dkr.ecr.${AWS::Region}.amazonaws.com/app:1.4.2'
        Essential: true
        MemoryReservation: 768
        User: '1000:1000'
        ReadonlyRootFilesystem: true
        LinuxParameters:
          Capabilities: { Drop: [ALL] }
          InitProcessEnabled: true
        PortMappings:
          - { ContainerPort: 8080, Protocol: tcp, Name: app-8080 }
        Secrets:
          - Name: DB_PASSWORD
            ValueFrom: !Sub 'arn:aws:secretsmanager:${AWS::Region}:${AWS::AccountId}:secret:prod/db-AbCdEf:password::'
        HealthCheck:
          Command: ["CMD-SHELL", "curl -f http://localhost:8080/healthz || exit 1"]
          Interval: 15
          Timeout: 5
          Retries: 3
          StartPeriod: 30
        StopTimeout: 30
        LogConfiguration:
          LogDriver: awslogs
          Options:
            awslogs-group: /ecs/app
            awslogs-region: !Ref AWS::Region
            awslogs-stream-prefix: app
```

## Terraform (same task definition)

```hcl
resource "aws_ecs_task_definition" "app" {
  family                   = "app-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name              = "app"
    image             = "${data.aws_caller_identity.me.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com/app:1.4.2"
    essential         = true
    memoryReservation = 768
    user              = "1000:1000"
    readonlyRootFilesystem = true
    linuxParameters = {
      capabilities       = { drop = ["ALL"] }
      initProcessEnabled = true
    }
    portMappings = [{ containerPort = 8080, protocol = "tcp", name = "app-8080" }]
    secrets = [{
      name      = "DB_PASSWORD"
      valueFrom = aws_secretsmanager_secret.db.arn
    }]
    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:8080/healthz || exit 1"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }
    stopTimeout = 30
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = "/ecs/app"
        awslogs-region        = data.aws_region.current.name
        awslogs-stream-prefix = "app"
      }
    }
  }])
}
```

-----

# 3. Service Configuration (deployments, scaling, capacity)

## Best practices

- **Deployment safety**: enable the **circuit breaker with rollback**, attach **CloudWatch alarms**, and use **blue/green** for customer-facing services with a bake period and lifecycle-hook validation.
- **Rolling-update knobs**: `minimumHealthyPercent` (e.g. 100 to never drop below desired) and `maximumPercent` (e.g. 200 to spin up replacements before draining).
- **`healthCheckGracePeriodSeconds`**: give slow-starting apps time before the LB starts failing them (e.g. 60–120s).
- **Service autoscaling** via Application Auto Scaling: target-tracking on **`ALBRequestCountPerTarget`** (best for web), CPU, or memory. Set sensible min/max.
- **Capacity providers** (EC2): attach the ASG with `managedScaling` ENABLED and `managedTerminationProtection` ENABLED so ECS scales instances to task demand and won’t kill instances running tasks.
- **Placement** (EC2): `spread` across AZs for availability, `binpack` for cost density; add `placement constraints` for instance attributes.
- **Enable ECS Exec** (`enableExecuteCommand`) for break-glass debugging into running containers.
- **Service Connect** for service-to-service discovery + TLS instead of App Mesh.

## CloudFormation

```yaml
Service:
  Type: AWS::ECS::Service
  DependsOn: HttpsListener
  Properties:
    Cluster: !Ref Cluster
    TaskDefinition: !Ref TaskDefinition
    DesiredCount: 3
    HealthCheckGracePeriodSeconds: 90
    EnableExecuteCommand: true
    CapacityProviderStrategy:
      - { CapacityProvider: !Ref CapacityProvider, Weight: 1 }
    DeploymentConfiguration:
      MinimumHealthyPercent: 100
      MaximumPercent: 200
      DeploymentCircuitBreaker: { Enable: true, Rollback: true }
      Alarms:
        Enable: true
        Rollback: true
        AlarmNames: [!Ref HighErrorRateAlarm]
    NetworkConfiguration:
      AwsvpcConfiguration:
        Subnets: [!Ref PrivateSubnet1, !Ref PrivateSubnet2]
        SecurityGroups: [!Ref TaskSecurityGroup]
    PlacementStrategies:
      - { Type: spread, Field: 'attribute:ecs.availability-zone' }
      - { Type: binpack, Field: memory }
    LoadBalancers:
      - { ContainerName: app, ContainerPort: 8080, TargetGroupArn: !Ref TargetGroup }

# Target-tracking autoscaling
ScalableTarget:
  Type: AWS::ApplicationAutoScaling::ScalableTarget
  Properties:
    ServiceNamespace: ecs
    ResourceId: !Sub 'service/${Cluster}/${Service.Name}'
    ScalableDimension: ecs:service:DesiredCount
    MinCapacity: 3
    MaxCapacity: 20
    RoleARN: !Sub 'arn:aws:iam::${AWS::AccountId}:role/aws-service-role/ecs.application-autoscaling.amazonaws.com/AWSServiceRoleForApplicationAutoScaling_ECSService'
ScalingPolicy:
  Type: AWS::ApplicationAutoScaling::ScalingPolicy
  Properties:
    PolicyName: cpu-target
    PolicyType: TargetTrackingScaling
    ScalingTargetId: !Ref ScalableTarget
    TargetTrackingScalingPolicyConfiguration:
      TargetValue: 60.0
      PredefinedMetricSpecification:
        PredefinedMetricType: ECSServiceAverageCPUUtilization
```

## Terraform

```hcl
resource "aws_ecs_service" "app" {
  name            = "app-svc"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 3
  health_check_grace_period_seconds = 90
  enable_execute_command            = true

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.this.name
    weight            = 1
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  deployment_circuit_breaker { enable = true  rollback = true }

  network_configuration {
    subnets         = aws_subnet.private[*].id
    security_groups = [aws_security_group.task.id]
  }

  ordered_placement_strategy { type = "spread"  field = "attribute:ecs.availability-zone" }
  ordered_placement_strategy { type = "binpack" field = "memory" }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 8080
  }
  depends_on = [aws_lb_listener.https]
}

resource "aws_appautoscaling_target" "app" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 3
  max_capacity       = 20
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "cpu-target"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.app.service_namespace
  resource_id        = aws_appautoscaling_target.app.resource_id
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension
  target_tracking_scaling_policy_configuration {
    target_value = 60.0
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
```

## Manual CLI

```bash
# Service with circuit breaker + rollback
aws ecs create-service \
  --cluster prod \
  --service-name app-svc \
  --task-definition app-task \
  --desired-count 3 \
  --health-check-grace-period-seconds 90 \
  --enable-execute-command \
  --capacity-provider-strategy capacityProvider=prod-cp,weight=1 \
  --deployment-configuration \
  'minimumHealthyPercent=100,maximumPercent=200,deploymentCircuitBreaker={enable=true,rollback=true}' \
  --network-configuration \
  'awsvpcConfiguration={subnets=[subnet-aaa,subnet-bbb],securityGroups=[sg-ccc]}' \
  --placement-strategy type=spread,field=attribute:ecs.availability-zone type=binpack,field=memory \
  --load-balancers targetGroupArn="$TG_ARN",containerName=app,containerPort=8080

# Autoscaling: register target, then attach policy
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/prod/app-svc \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 3 --max-capacity 20

aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --resource-id service/prod/app-svc \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name cpu-target --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration \
  'TargetValue=60.0,PredefinedMetricSpecification={PredefinedMetricType=ECSServiceAverageCPUUtilization}'
```

-----

# 4. Dependencies

## ECR (image registry)

**Best practices:** enable **scan-on-push**, set **tag immutability**, and add a **lifecycle policy** to expire old/untagged images.

```bash
aws ecr create-repository --repository-name app \
  --image-scanning-configuration scanOnPush=true \
  --image-tag-mutability IMMUTABLE
```

```hcl
resource "aws_ecr_repository" "app" {
  name                 = "app"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
}
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({ rules = [{
    rulePriority = 1, description = "expire untagged after 14d"
    selection = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 14 }
    action = { type = "expire" }
  }]})
}
```

## Secrets (Secrets Manager / SSM)

Reference them from the task definition’s `secrets` block (shown in §2). The **execution role** needs `secretsmanager:GetSecretValue` (or `ssm:GetParameters`) and `kms:Decrypt` for the secret’s KMS key — scoped to the specific secret ARNs.

## IAM roles

```jsonc
// Execution role trust + minimal inline policy beyond AmazonECSTaskExecutionRolePolicy
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["secretsmanager:GetSecretValue"],
      "Resource": "arn:aws:secretsmanager:us-east-1:<ACCT>:secret:prod/db-*" },
    { "Effect": "Allow", "Action": ["kms:Decrypt"],
      "Resource": "arn:aws:kms:us-east-1:<ACCT>:key/<KEY_ID>" }
  ]
}
```

The **task role** carries only what your app calls at runtime (e.g. a specific S3 bucket, a DynamoDB table) — never the execution role’s permissions.

## Networking: private subnets + VPC endpoints

Run tasks in **private subnets**. Instead of routing image pulls and API calls through a NAT gateway, add VPC endpoints (cheaper, more secure):

- **Gateway endpoints** (free): S3, DynamoDB.
- **Interface endpoints**: `ecr.api`, `ecr.dkr`, `logs`, `secretsmanager`, `ssm`, `ecs`, `ecs-agent`, `ecs-telemetry`.

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

resource "aws_vpc_endpoint" "interfaces" {
  for_each            = toset(["ecr.api","ecr.dkr","logs","secretsmanager","ssm"])
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
}
```

## Observability

- **Container Insights (enhanced)** on the cluster for task/service/instance metrics.
- **ADOT or the CloudWatch agent** as a sidecar for OpenTelemetry traces/metrics.
- **Structured JSON logging** so CloudWatch Logs Insights / OpenSearch can query fields.

```bash
aws ecs create-cluster --cluster-name prod \
  --settings name=containerInsights,value=enhanced
```

-----

## Service-to-service communication (post–App Mesh)

Since App Mesh ends Sept 30, 2026, use **ECS Service Connect**: a namespace + per-service `serviceConnectConfiguration` gives you DNS-based discovery, retries, outlier detection, and CloudWatch networking metrics with no sidecar fleet to manage.

```bash
# 1. Namespace (Cloud Map HTTP namespace)
aws servicediscovery create-http-namespace --name internal.local

# 2. Reference it on the cluster default, and add serviceConnectConfiguration
#    per service so clients reach it at  http://app:8080  inside the namespace.
```

```hcl
service_connect_configuration {
  enabled   = true
  namespace = aws_service_discovery_http_namespace.internal.arn
  service {
    port_name      = "app-8080"          # matches the portMapping "name"
    discovery_name = "app"
    client_alias { port = 8080  dns_name = "app" }
  }
}
```

-----

## Deployment-strategy quick reference

|Need                                                      |Use                                                                |
|----------------------------------------------------------|-------------------------------------------------------------------|
|Simple, in-place updates                                  |Rolling update + circuit breaker + rollback                        |
|Validate in prod before shifting traffic, instant rollback|**Native blue/green** + lifecycle hooks + bake time                |
|Service discovery / mTLS between services                 |**ECS Service Connect** (not App Mesh)                             |
|Cross-VPC / cross-account networking                      |**VPC Lattice**                                                    |
|EC2 capacity tracking task demand                         |**Capacity provider** with managed scaling + termination protection|

## Tooling quick reference

|You want                                      |Pick                                              |
|----------------------------------------------|--------------------------------------------------|
|AWS-native single-file stack + Service Catalog|**CloudFormation** (YAML or JSON)                 |
|Strong module reuse, multi-environment        |**Terraform** modules                             |
|Register/version just a task                  |**Raw task-def JSON** + `register-task-definition`|
|Imperative, scripting, break-glass            |**Manual CLI**                                    |
|CFN power with real programming languages     |**AWS CDK** (synthesizes to CFN)                  |

-----

*Hardening checklist before production: HTTPS-only listeners with a modern TLS policy, WAF on public ALBs, private subnets + VPC endpoints, secrets via Secrets Manager, non-root + read-only-root-filesystem containers, scan-on-push immutable ECR images, circuit breaker + alarms + rollback on every service, Container Insights enabled, and least-privilege execution/task/instance roles.*