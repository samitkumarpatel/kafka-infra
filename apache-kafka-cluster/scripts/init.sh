#!/bin/bash
# ============================================================
#  Topic + ACL init — single-broker KRaft
#  Runs as topic-acl-init one-shot container.
#  kafka-connect and kafka-ui depend on this completing (exit 0).
# ============================================================

# Do NOT use set -e here — we want the retry loop to work
# and we want to see all errors before deciding to fail.
set -uo pipefail

export PATH="/opt/kafka/bin:$PATH"
BS="${BOOTSTRAP_SERVERS:-broker:9092}"
CFG="/etc/kafka/secrets/admin.properties"

# ── Wait until broker accepts admin connections ──────────────
# Retries indefinitely — Docker will kill us if we hang too long.
# Using kafka-broker-api-versions.sh which does a real Kafka handshake.
echo "⏳ Waiting for broker at $BS ..."
RETRIES=0
until kafka-broker-api-versions.sh \
        --bootstrap-server "$BS" \
        --command-config "$CFG" > /dev/null 2>&1; do
  RETRIES=$((RETRIES + 1))
  echo "   attempt $RETRIES — broker not ready yet, waiting 3s..."
  sleep 3
  if [ "$RETRIES" -ge 40 ]; then
    echo "❌ Broker did not become ready after $RETRIES attempts. Exiting."
    exit 1
  fi
done
echo "✅ Broker ready after $RETRIES retries."

# Short extra wait for ACL publisher to fully initialise on first boot
sleep 3

KT="kafka-topics.sh --bootstrap-server $BS --command-config $CFG"
KA="kafka-acls.sh --bootstrap-server $BS --command-config $CFG"

# ── Helpers ──────────────────────────────────────────────────

create_topic() {
  local name="$1" parts="${2:-3}" ret="${3:-604800000}" clean="${4:-delete}"
  if $KT --describe --topic "$name" > /dev/null 2>&1; then
    echo "  ⏭  topic '$name' already exists"
    return 0
  fi
  $KT --create --topic "$name" \
    --partitions "$parts" \
    --replication-factor 3 \
    --config "retention.ms=$ret" \
    --config "cleanup.policy=$clean" \
    --config "min.insync.replicas=2" \
    --config "compression.type=lz4"
  echo "  ✅ created topic '$name'"
}

# Grant operations on a literal topic name
acl_topic() {
  local user="$1" topic="$2"; shift 2
  local ops=("$@")
  for op in "${ops[@]}"; do
    $KA --add \
      --allow-principal "User:$user" \
      --topic "$topic" \
      --operation "$op" \
      --allow-host "*"
  done
  echo "  🔐 Topic:$topic [${ops[*]}] → User:$user"
}

# Grant Read + Describe on a specific consumer group.
# Together with acl_topic Read, this LOCKS the user to only this
# named group — any other group name will be denied by the broker.
acl_group() {
  local user="$1" group="$2"
  $KA --add \
    --allow-principal "User:$user" \
    --group "$group" \
    --operation Read \
    --operation Describe \
    --allow-host "*"
  echo "  🔐 Group:$group [Read,Describe] → User:$user"
}

# ── Application topics ────────────────────────────────────────
echo ""
echo "📂 Creating topics..."
create_topic "orders"          3  604800000  delete
create_topic "payments"        3  604800000  delete
create_topic "orders-events"   3  604800000  delete
create_topic "payments-events" 3  604800000  delete
create_topic "dead-letter"     1  -1         delete

# ── connect-worker ACLs ───────────────────────────────────────
echo ""
echo "🔐 connect-worker ACLs..."

# Prefix ACL on _connect-* — covers all three internal topics.
# Create is required: Connect creates these topics itself on first boot.
$KA --add \
  --allow-principal "User:connect-worker" \
  --topic "_connect-" \
  --resource-pattern-type prefixed \
  --operation Read \
  --operation Write \
  --operation Create \
  --operation Describe \
  --operation DescribeConfigs \
  --allow-host "*"
echo "  🔐 Topic:_connect-* [Read,Write,Create,Describe,DescribeConfigs] → User:connect-worker"

# Worker consumer group
acl_group "connect-worker" "kafka-connect-cluster"

# Cluster-level describe for metadata
$KA --add \
  --allow-principal "User:connect-worker" \
  --cluster \
  --operation Describe \
  --operation DescribeConfigs \
  --allow-host "*"
echo "  🔐 Cluster [Describe,DescribeConfigs] → User:connect-worker"

# Source connector targets (write into Kafka)
acl_topic "connect-worker" "orders"          Write Create Describe
acl_topic "connect-worker" "orders-events"   Write Create Describe
acl_topic "connect-worker" "payments-events" Write Create Describe
acl_topic "connect-worker" "dead-letter"     Write Describe

# Sink connector sources (read from Kafka)
acl_topic "connect-worker" "orders"   Read Describe
acl_topic "connect-worker" "payments" Read Describe

# Prefix ACL for sink connector consumer groups (auto-named connect-<name>)
$KA --add \
  --allow-principal "User:connect-worker" \
  --group "connect-" \
  --resource-pattern-type prefixed \
  --operation Read \
  --allow-host "*"
echo "  🔐 Group:connect-* [Read] → User:connect-worker"

# ── Application service accounts ─────────────────────────────
echo ""
echo "🔐 Application ACLs..."

# orders-producer: write-only, no group ACL → can never consume
acl_topic "orders-producer" "orders"       Write Describe
acl_topic "orders-producer" "dead-letter"  Write

# payments-consumer: can read "orders" ONLY with group "payments-cg"
# Any other group name → broker denies at the group ACL check.
acl_topic "payments-consumer" "orders"       Read Describe
acl_group "payments-consumer" "payments-cg"
acl_topic "payments-consumer" "payments"     Write Describe
acl_topic "payments-consumer" "dead-letter"  Write

# analytics-reader: can read events ONLY with group "analytics-cg"
acl_topic "analytics-reader" "orders-events"   Read Describe
acl_topic "analytics-reader" "payments-events" Read Describe
acl_group "analytics-reader" "analytics-cg"

# ── kafka-ui — describe + read (required to browse messages) ──
echo ""
echo "🔐 kafka-ui ACLs..."
for t in orders payments orders-events payments-events dead-letter; do
  $KA --add \
    --allow-principal "User:kafka-ui" \
    --topic "$t" \
    --operation Describe \
    --operation Read \
    --allow-host "*"
done
# Prefix ACL so kafka-ui can see and read _connect-* topics too
$KA --add \
  --allow-principal "User:kafka-ui" \
  --topic "_connect-" \
  --resource-pattern-type prefixed \
  --operation Describe \
  --operation Read \
  --allow-host "*"
# kafka-ui creates transient consumer groups to fetch messages;
# Read is required in addition to Describe.
$KA --add \
  --allow-principal "User:kafka-ui" \
  --group "*" \
  --operation Describe \
  --operation Read \
  --allow-host "*"
echo "  🔐 Topics + Group:* [Describe,Read] → User:kafka-ui"

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "📋 Topics:"
$KT --list

echo ""
echo "📋 ACLs:"
$KA --list

echo ""
echo "🎉 Init complete — kafka-connect and kafka-ui can now start."