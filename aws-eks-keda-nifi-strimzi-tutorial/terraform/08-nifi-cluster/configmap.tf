resource "kubernetes_config_map_v1" "configure" {
  metadata {
    name      = "nifi-configure"
    namespace = kubernetes_namespace_v1.nifi.metadata[0].name
  }

  data = {
    "configure-nifi.sh" = <<-SCRIPT
      #!/usr/bin/env bash
      set -Eeuo pipefail

      SOURCE_CONF="/opt/nifi/nifi-current/conf"
      TARGET_CONF="/work/conf"

      cp -R "$${SOURCE_CONF}/." "$${TARGET_CONF}/"

      set_property() {
        local key="$1"
        local value="$2"
        local file="$${TARGET_CONF}/nifi.properties"

        if grep -q "^$${key}=" "$${file}"; then
          sed -i "s|^$${key}=.*|$${key}=$${value}|" "$${file}"
        else
          printf '%s=%s\n' "$${key}" "$${value}" >> "$${file}"
        fi
      }

      NODE_FQDN="$${HOSTNAME}.nifi-headless.nifi.svc.cluster.local"

      set_property "nifi.web.http.host" "0.0.0.0"
      set_property "nifi.web.http.port" "8080"
      set_property "nifi.web.https.host" ""
      set_property "nifi.web.https.port" ""
      set_property "nifi.sensitive.props.key" "$${NIFI_SENSITIVE_PROPS_KEY}"

      set_property "nifi.cluster.is.node" "true"
      set_property "nifi.cluster.node.address" "$${NODE_FQDN}"
      set_property "nifi.cluster.node.protocol.port" "11443"
      set_property "nifi.cluster.load.balance.host" "$${NODE_FQDN}"
      set_property "nifi.cluster.load.balance.port" "6342"
      set_property "nifi.cluster.leader.election.implementation" "KubernetesLeaderElectionManager"
      set_property "nifi.cluster.leader.election.kubernetes.lease.prefix" "tutorial-nifi-"
      set_property "nifi.cluster.flow.election.max.candidates" "2"
      set_property "nifi.cluster.flow.election.max.wait.time" "2 mins"

      set_property "nifi.flowfile.repository.directory" "/opt/nifi/data/flowfile_repository"
      set_property "nifi.content.repository.directory.default" "/opt/nifi/data/content_repository"
      set_property "nifi.provenance.repository.directory.default" "/opt/nifi/data/provenance_repository"
      set_property "nifi.database.directory" "/opt/nifi/data/database_repository"
      set_property "nifi.state.management.embedded.zookeeper.start" "false"

      mkdir -p \
        /opt/nifi/data/flowfile_repository \
        /opt/nifi/data/content_repository \
        /opt/nifi/data/provenance_repository \
        /opt/nifi/data/database_repository

      echo "Generated NiFi configuration for $${NODE_FQDN}."
    SCRIPT
  }
}
