locals {
  servers = {
    a = {
      name    = "hello-server-a"
      heading = "Hello from micro server A"
      detail  = "KEDA can add more copies of server A when CPU rises."
    }
    b = {
      name    = "hello-server-b"
      heading = "Hello from micro server B"
      detail  = "The Kubernetes Service balances traffic across A and B."
    }
  }
}
