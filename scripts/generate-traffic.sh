#!/bin/bash
# =============================================================================
# TRAFFIC GENERATOR — Simulates Real User Checkout Flow
# =============================================================================
# PURPOSE:
#   Generates realistic HTTP traffic through the Online Boutique application
#   to produce observable data in Elasticsearch/Kibana. Without traffic,
#   dashboards would be empty and traces wouldn't exist.
#
# HOW IT WORKS:
#   Simulates a complete e-commerce user journey:
#   1. Visit homepage (GET /)
#   2. Browse a product (GET /product/<id>)
#   3. Add item to cart (POST /cart)
#   4. View cart (GET /cart)
#   5. Complete checkout (POST /cart/checkout)
#
#   Each step generates:
#   - HTTP requests logged by NGINX Ingress
#   - Backend traces through the microservice chain
#   - Business metrics (cart operations, payment attempts)
#
# USAGE:
#   bash scripts/generate-traffic.sh           # 50 requests (default)
#   bash scripts/generate-traffic.sh 200       # 200 requests
#   bash scripts/generate-traffic.sh continuous # Run forever
#
# NOTE:
#   The built-in loadgenerator pod in Online Boutique also generates traffic.
#   This script is for manual/additional traffic generation.
# =============================================================================

set -euo pipefail

# Number of shopping sessions to simulate
MODE="${1:-50}"

# Auto-detect the frontend URL from the Ingress IP
INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

if [ -z "$INGRESS_IP" ]; then
  echo "ERROR: Could not detect Ingress IP. Is the cluster running?"
  echo "Try: kubectl get svc ingress-nginx-controller -n ingress-nginx"
  exit 1
fi

FRONTEND_URL="http://$INGRESS_IP.nip.io"
echo "Frontend URL: $FRONTEND_URL"
echo "Mode: $MODE"
echo ""

# Product IDs from the Online Boutique catalog
PRODUCTS=(
  "OLJCESPC7Z"   # Vintage Typewriter
  "66VCHSJNUP"   # Vintage Camera Lens
  "1YMWWN1N4O"   # Home Barista Kit
  "L9ECAV7KIM"   # Terrarium
  "2ZYFJ3GM2N"   # Film Camera
  "0PUK6V6EV0"   # Vintage Record Player
  "LS4PSXUNUM"   # Metal Camping Mug
  "9SIQT8TOJO"   # City Bike
  "6E92ZMYYFZ"   # Air Plant
)

CURRENCIES=("USD" "EUR" "GBP" "JPY" "CAD")
SUCCESS=0
ERRORS=0

# Simulate one shopping session
simulate_session() {
  local session_id="sess-$(date +%s)-$RANDOM"
  
  # Step 1: Visit homepage
  curl -s -o /dev/null -w "%{http_code}" \
    -H "Cookie: shop_session-id=$session_id" \
    "$FRONTEND_URL/" > /dev/null 2>&1 || true

  # Step 2: Browse a random product
  local product=${PRODUCTS[$((RANDOM % ${#PRODUCTS[@]}))]}
  curl -s -o /dev/null \
    -H "Cookie: shop_session-id=$session_id" \
    "$FRONTEND_URL/product/$product" > /dev/null 2>&1 || true

  # Step 3: Add to cart
  local quantity=$((RANDOM % 5 + 1))
  curl -s -o /dev/null -X POST \
    -H "Cookie: shop_session-id=$session_id" \
    -d "product_id=$product&quantity=$quantity" \
    "$FRONTEND_URL/cart" > /dev/null 2>&1 || true

  # Step 4: View cart
  curl -s -o /dev/null \
    -H "Cookie: shop_session-id=$session_id" \
    "$FRONTEND_URL/cart" > /dev/null 2>&1 || true

  # Step 5: Checkout (70% of the time — simulates cart abandonment)
  if [ $((RANDOM % 10)) -lt 7 ]; then
    local currency=${CURRENCIES[$((RANDOM % ${#CURRENCIES[@]}))]}
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      -H "Cookie: shop_session-id=$session_id" \
      -d "email=user-$RANDOM@test.example&street_address=123+Test+St&zip_code=10001&city=New+York&state=NY&country=US&credit_card_number=4432801561520454&credit_card_expiration_month=01&credit_card_expiration_year=2030&credit_card_cvv=672&currency_code=$currency" \
      "$FRONTEND_URL/cart/checkout" 2>/dev/null || echo "000")
    
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
      ((SUCCESS++)) || true
    else
      ((ERRORS++)) || true
    fi
  fi
}

# Main loop
run_traffic() {
  local count=$1
  echo "Generating $count shopping sessions..."
  echo ""
  
  for i in $(seq 1 "$count"); do
    simulate_session
    
    # Progress update every 10 sessions
    if [ $((i % 10)) -eq 0 ]; then
      echo "  Progress: $i/$count sessions (✅ $SUCCESS checkouts, ❌ $ERRORS errors)"
    fi
    
    # Small delay between sessions
    sleep 0.5
  done
}

if [ "$MODE" = "continuous" ]; then
  echo "Running continuously (Ctrl+C to stop)..."
  while true; do
    simulate_session
    ((SUCCESS + ERRORS)) && echo "Sessions: $((SUCCESS + ERRORS)) (✅ $SUCCESS, ❌ $ERRORS)" || true
    sleep 1
  done
else
  run_traffic "$MODE"
fi

echo ""
echo "============================================"
echo "  Traffic Generation Complete"
echo "============================================"
echo "  Total sessions: $((SUCCESS + ERRORS))"
echo "  Successful checkouts: $SUCCESS"
echo "  Errors: $ERRORS"
echo ""
echo "  View traces in Kibana: Observability → APM → Services"
echo "  View dashboards: Kibana → Dashboards"
echo "============================================"
