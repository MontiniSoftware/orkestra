#!/bin/sh
# MCP Demo — Scaffold a complete Inventory bounded context via orkestra-mcp
#
# Run inside the Docker container:
#   docker compose exec app sh priv/mcp_demo.sh
#
# Or locally (from examples/order_system/):
#   sh priv/mcp_demo.sh
#
# This script sends JSON-RPC requests to the orkestra-mcp escript via stdin,
# demonstrating the full code generation pipeline.

set -e

MCP_BIN="${MCP_BIN:-/app/orkestra_mcp/orkestra_mcp}"
PROJECT_DIR="${PROJECT_DIR:-.}"

# Helper: send a JSON-RPC request and extract the result text
mcp_call() {
  local id="$1"
  local method="$2"
  local params="$3"

  printf '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"0.1"}}}\n{"jsonrpc":"2.0","method":"notifications/initialized"}\n{"jsonrpc":"2.0","id":%s,"method":"%s","params":%s}\n' \
    "$id" "$method" "$params" \
  | timeout 15 "$MCP_BIN" --project-dir "$PROJECT_DIR" 2>/dev/null \
  | tail -1 \
  | python3 -c "
import sys, json
line = sys.stdin.readline().strip()
if line:
    d = json.loads(line)
    r = d.get('result', {})
    # Tool results
    for c in r.get('content', []):
        print(c.get('text', ''))
    # Resource results
    for c in r.get('contents', []):
        print(c.get('text', ''))
" 2>/dev/null
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Orkestra MCP Demo — Scaffolding an Inventory Context"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. Generate AddStock command
echo "1. Generating command: OrderSystem.Inventory.Commands.AddStock"
mcp_call 1 "tools/call" '{"name":"gen_command","arguments":{"module_name":"OrderSystem.Inventory.Commands.AddStock","params":"[{\"name\":\"sku\",\"type\":\"string\",\"required\":true},{\"name\":\"product_name\",\"type\":\"string\",\"required\":true},{\"name\":\"quantity\",\"type\":\"integer\",\"required\":true},{\"name\":\"warehouse\",\"type\":\"string\",\"required\":true}]"}}'
echo ""

# 2. Generate StockAdded event
echo "2. Generating event: OrderSystem.Inventory.Events.StockAdded"
mcp_call 2 "tools/call" '{"name":"gen_event","arguments":{"module_name":"OrderSystem.Inventory.Events.StockAdded","fields":"[{\"name\":\"sku\",\"type\":\"string\",\"required\":true},{\"name\":\"product_name\",\"type\":\"string\",\"required\":true},{\"name\":\"quantity\",\"type\":\"integer\",\"required\":true},{\"name\":\"warehouse\",\"type\":\"string\",\"required\":true}]"}}'
echo ""

# 3. Generate aggregate
echo "3. Generating aggregate: OrderSystem.Inventory.StockAggregate"
mcp_call 3 "tools/call" '{"name":"gen_aggregate","arguments":{"module_name":"OrderSystem.Inventory.StockAggregate","stream_id_field":"sku","commands":"[\"OrderSystem.Inventory.Commands.AddStock\"]","events":"[\"OrderSystem.Inventory.Events.StockAdded\"]"}}'
echo ""

# 4. Generate command handler
echo "4. Generating handler: OrderSystem.Inventory.Handlers.AddStockHandler"
mcp_call 4 "tools/call" '{"name":"gen_command_handler","arguments":{"module_name":"OrderSystem.Inventory.Handlers.AddStockHandler","command_module":"OrderSystem.Inventory.Commands.AddStock"}}'
echo ""

# 5. Generate event handler
echo "5. Generating event handler: OrderSystem.Inventory.Handlers.StockNotifier"
mcp_call 5 "tools/call" '{"name":"gen_event_handler","arguments":{"module_name":"OrderSystem.Inventory.Handlers.StockNotifier","opts":"{\"mode\":\"single\",\"event\":\"OrderSystem.Inventory.Events.StockAdded\"}"}}'
echo ""

# 6. Generate ES projector
echo "6. Generating ES projector: OrderSystem.Inventory.Projectors.StockESProjector"
mcp_call 6 "tools/call" '{"name":"gen_es_projection","arguments":{"module_name":"OrderSystem.Inventory.Projectors.StockESProjector","repo_module":"OrderSystem.Repo","cluster_module":"OrderSystem.ESCluster","index":"inventory","events":"[\"OrderSystem.Inventory.Events.StockAdded\"]"}}'
echo ""

# 7. Generate ES queries
echo "7. Generating ES queries: OrderSystem.Inventory.ES.Queries"
mcp_call 7 "tools/call" '{"name":"gen_es_queries","arguments":{"module_name":"OrderSystem.Inventory.ES.Queries","projector_module":"OrderSystem.Inventory.Projectors.StockESProjector"}}'
echo ""

# 8. Show the domain map
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Domain Map (introspection)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
mcp_call 8 "resources/read" '{"uri":"orkestra://domain-map"}'
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Done! Check lib/order_system/inventory/ for generated files."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
