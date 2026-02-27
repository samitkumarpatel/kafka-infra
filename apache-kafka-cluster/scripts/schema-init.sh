#!/bin/sh
# ============================================================
#  Schema Registry init — registers Avro key + value schemas
#  for every application topic.
#
#  Runs as schema-init one-shot container.
#  kafka-connect and kafka-ui depend on this completing (exit 0).
#
#  Idempotent: re-registering an identical schema returns the
#  existing schema ID — safe to run on every stack restart.
# ============================================================

set -eu

SR="${SCHEMA_REGISTRY_URL:-http://schema-registry:8081}"

# ── Wait until Schema Registry is ready ─────────────────────
echo "⏳ Waiting for Schema Registry at $SR ..."
RETRIES=0
until curl -sf "$SR/subjects" > /dev/null 2>&1; do
  RETRIES=$((RETRIES + 1))
  echo "   attempt $RETRIES — not ready yet, waiting 3s..."
  sleep 3
  if [ "$RETRIES" -ge 40 ]; then
    echo "❌ Schema Registry did not become ready after $RETRIES attempts. Exiting."
    exit 1
  fi
done
echo "✅ Schema Registry ready after $RETRIES retries."

# ── Helper ───────────────────────────────────────────────────
# register_schema <subject> <schema-type> <schema-json>
# Schema type: AVRO | JSON | PROTOBUF
register_schema() {
  SUBJECT="$1"
  SCHEMA_TYPE="$2"
  SCHEMA="$3"

  PAYLOAD=$(printf '{"schemaType":"%s","schema":"%s"}' \
    "$SCHEMA_TYPE" \
    "$(echo "$SCHEMA" | sed 's/\\/\\\\/g; s/"/\\"/g; s/    //g; s/\n//g')")

  HTTP_CODE=$(curl -s -o /tmp/sr_resp.json -w "%{http_code}" \
    -X POST "$SR/subjects/$SUBJECT/versions" \
    -H "Content-Type: application/vnd.schemaregistry.v1+json" \
    -d "$PAYLOAD")

  if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 409 ]; then
    ID=$(grep -o '"id":[0-9]*' /tmp/sr_resp.json | head -1 || echo "id:existing")
    echo "  ✅ $SUBJECT ($ID)"
  else
    echo "  ❌ $SUBJECT — HTTP $HTTP_CODE: $(cat /tmp/sr_resp.json)"
    exit 1
  fi
}

# ── All topics: plain string key + string value ───────────────
echo ""
echo "📐 Registering schemas..."

for TOPIC in orders payments orders-events payments-events dead-letter; do
  register_schema "${TOPIC}-key"   "AVRO" '{"type":"string"}'
  register_schema "${TOPIC}-value" "AVRO" '{"type":"string"}'
done

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "📋 Registered subjects:"
curl -s "$SR/subjects" | tr ',' '\n' | tr -d '[]"' | sort | sed 's/^/  - /'

echo ""
echo "🎉 Schema init complete."
