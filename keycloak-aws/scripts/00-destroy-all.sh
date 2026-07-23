#!/usr/bin/env bash
###############################################################################
# 00-destroy-all.sh
#
# Convenience wrapper: runs all three destroy scripts in the correct order.
# This is the "get me back to zero dollars" button.
#
# Usage:  ./00-destroy-all.sh
#         FORCE=yes ./00-destroy-all.sh     (no prompts at all)
###############################################################################

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "################################################################"
echo "#  FULL TEARDOWN                                               #"
echo "#                                                              #"
echo "#  Order matters. Compute must die before the network it       #"
echo "#  lives in can be deleted, and the database must die before   #"
echo "#  its subnets can be removed. This wrapper enforces that.     #"
echo "#                                                              #"
echo "#    1. 93-destroy-keycloak.sh   (EC2 + Elastic IP)            #"
echo "#    2. 92-destroy-database.sh   (RDS + parameter group)       #"
echo "#    3. 91-destroy-network.sh    (VPC + IAM)                   #"
echo "#                                                              #"
echo "#  Expect 10-20 minutes, mostly waiting on RDS.                #"
echo "################################################################"
echo ""

if [[ "${FORCE:-no}" != "yes" ]]; then
  read -r -p "Type 'DESTROY EVERYTHING' to proceed: " CONFIRM
  [[ "$CONFIRM" == "DESTROY EVERYTHING" ]] || { echo "Cancelled."; exit 0; }
fi

export FORCE=yes   # child scripts already confirmed via this prompt

bash "$SCRIPT_DIR/93-destroy-keycloak.sh"
bash "$SCRIPT_DIR/92-destroy-database.sh"
bash "$SCRIPT_DIR/91-destroy-network.sh"

echo ""
echo "################################################################"
echo "#  ALL LAYERS PROCESSED                                        #"
echo "#  Scroll up for any [!] warnings and clean those by hand.     #"
echo "################################################################"
