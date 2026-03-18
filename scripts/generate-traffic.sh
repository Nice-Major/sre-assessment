#!/bin/bash
# =============================================================================
# Traffic Generator — Full Checkout Flow
# Exercises the complete user journey: browse → add to cart → checkout
# Generates enough traffic to produce meaningful traces and metrics.
#
# Usage:
#   bash scripts/generate-traffic.sh                 # 50 iterations
#   bash scripts/generate-traffic.sh 200             # 200 iterations
#   bash scripts/generate-traffic.sh continuous      # runs indefinitely
# =============================================================================
set -euo pipefail

FRONTEND_URL="${FRONTEND_URL:-http://localhost:8080}"
ITERATIONS="${1:-50}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-1}"

# Product IDs from Online Boutique catalog
PRODUCTS=(
  "OLJCESPC7Z"   # Sunglasses
  "66VCHSJNUP"   # Tank Top
  "1YMWWN1N4O"   # Watch
  "L9ECAV7KIM"   # Loafers
  "2ZYFJ3GM2N"   # Hairdryer
  "0PUK6V6EV0"   # Candle Holder
  "LS4PSXUNUM"   # Salt & Pepper Shakers
  "9SIQT8TOJO"   # Bamboo Glass Jar
  "6E92ZMYYFZ"   # Mug
)

EMAILS=("test@example.com" "user@assessment.dev" "checkout@demo.io")

success_count=0
error_count=0
total=0

generate_one_flow() {
  local product_idx=$((RANDOM % ${#PRODUCTS[@]}))
  local product_id="${PRODUCTS[$product_idx]}"
  local email="${EMAILS[$((RANDOM % ${#EMAILS[@]}))]}"
  local quantity=$((RANDOM % 3 + 1))

  # Step 1: Browse homepage
  curl -s -o /dev/null -w "" "${FRONTEND_URL}/" || true

  # Step 2: View a product
  curl -s -o /dev/null -w "" "${FRONTEND_URL}/product/${product_id}" || true

  # Step 3: Add to cart
  curl -s -o /dev/null -w "" -X POST "${FRONTEND_URL}/cart" \
    -d "product_id=${product_id}&quantity=${quantity}" || true

  # Step 4: View cart
  curl -s -o /dev/null -w "" "${FRONTEND_URL}/cart" || true

  # Step 5: Checkout
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${FRONTEND_URL}/cart/checkout" \
    -d "email=${email}&street_address=123+Main+St&zip_code=10001&city=Lagos&state=LA&country=NG&credit_card_number=4111111111111111&credit_card_expiration_month=12&credit_card_expiration_year=2028&credit_card_cvv=123" || echo "000")

  total=$((total + 1))
  if [[ "$http_code" =~ ^2 ]] || [[ "$http_code" =~ ^3 ]]; then
    success_count=$((success_count + 1))
  else
    error_count=$((error_count + 1))
  fi
}

echo "=== Traffic Generator ==="
echo "  Target: ${FRONTEND_URL}"
echo "  Mode: ${ITERATIONS}"
echo ""

if [[ "$ITERATIONS" == "continuous" ]]; then
  echo "  Running continuously (Ctrl+C to stop)..."
  while true; do
    generate_one_flow
    printf "\r  Flows: %d | Success: %d | Errors: %d" "$total" "$success_count" "$error_count"
    sleep "$SLEEP_BETWEEN"
  done
else
  for i in $(seq 1 "$ITERATIONS"); do
    generate_one_flow
    printf "\r  Progress: %d/%s | Success: %d | Errors: %d" "$i" "$ITERATIONS" "$success_count" "$error_count"
    sleep "$SLEEP_BETWEEN"
  done
fi

echo ""
echo ""
echo "=== Traffic Generation Complete ==="
echo "  Total flows: ${total}"
echo "  Successful:  ${success_count}"
echo "  Errors:      ${error_count}"
echo ""
echo "  Next: Check Kibana → Observability → APM → Traces"
echo "        Check Kibana → Observability → APM → Service Map"
