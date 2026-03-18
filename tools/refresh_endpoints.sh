#!/usr/bin/env bash
# refresh_endpoints.sh — Extract current X GraphQL endpoint IDs from X's client JS bundle.
#
# Usage:
#   bash tools/refresh_endpoints.sh
#
# What it does:
#   1. Fetches X's main page to find the JS bundle URL containing GraphQL endpoint definitions
#   2. Downloads and searches the bundle for list mutation operation IDs
#   3. Prints the found IDs so you can update src/consts.nim
#
# Requirements: curl, grep, sed

set -euo pipefail

echo "=== X GraphQL Endpoint ID Extractor ==="
echo ""

# Step 1: Get the main page and find client JS bundle URLs
echo "[1/3] Fetching x.com main page..."
MAIN_HTML=$(curl -sL "https://x.com" \
  -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36" \
  2>/dev/null || true)

if [ -z "$MAIN_HTML" ]; then
  echo "ERROR: Could not fetch x.com. Check your network connection."
  exit 1
fi

# Extract JS bundle URLs
JS_URLS=$(echo "$MAIN_HTML" | grep -oE 'https://abs\.twimg\.com/responsive-web/client-web[^"]+\.js' | head -20)

if [ -z "$JS_URLS" ]; then
  echo "WARNING: Could not find client-web JS bundles from x.com HTML."
  echo ""
  echo "=== Manual Instructions ==="
  echo "1. Open x.com in Chrome, press F12 → Network tab"
  echo "2. Filter by 'graphql'"
  echo "3. Create a list → copy the hash from the POST URL (the part before /CreateList)"
  echo "4. Add a member → copy the hash from /ListAddMember"
  echo "5. Remove a member → copy the hash from /ListRemoveMember"
  echo "6. Delete a list → copy the hash from /DeleteList"
  echo "7. Update src/consts.nim with the hashes"
  exit 0
fi

echo "[2/3] Searching ${#JS_URLS[@]} JS bundles for GraphQL endpoints..."
echo ""

# Operations we're looking for
OPERATIONS=("CreateList" "DeleteList" "ListAddMember" "ListRemoveMember" "SearchTimeline" "ListTimeline" "ListMembers" "UserByScreenName" "TweetDetail")

FOUND=0
for url in $JS_URLS; do
  BUNDLE=$(curl -sL "$url" 2>/dev/null || true)
  if [ -z "$BUNDLE" ]; then
    continue
  fi

  for op in "${OPERATIONS[@]}"; do
    # Look for patterns like: queryId:"HASH",operationName:"CreateList" or {queryId:"HASH",...operationName:"CreateList"}
    MATCHES=$(echo "$BUNDLE" | grep -oE '[A-Za-z0-9_-]{20,30}/'"$op" || true)
    if [ -n "$MATCHES" ]; then
      echo "  ✅ $op: $MATCHES"
      FOUND=$((FOUND + 1))
    fi
  done
done

echo ""
if [ $FOUND -eq 0 ]; then
  echo "No endpoint IDs found in JS bundles (X may have changed their bundling strategy)."
  echo ""
  echo "=== Manual Instructions ==="
  echo "1. Open x.com in Chrome, press F12 → Network tab"
  echo "2. Filter by 'graphql'"
  echo "3. Perform each action and copy the hash from the request URL."
  echo "   The URL format is: /i/api/graphql/{HASH}/{OperationName}"
  echo ""
  echo "Operations to capture:"
  echo "  - CreateList (create a new list)"
  echo "  - DeleteList (delete a list)"
  echo "  - ListAddMember (add someone to a list)"
  echo "  - ListRemoveMember (remove someone from a list)"
  echo ""
  echo "Then update src/consts.nim lines for graphCreateList, graphDeleteList, etc."
else
  echo "[3/3] Found $FOUND endpoint(s). Update src/consts.nim with the hashes above."
  echo ""
  echo "Example: if SearchTimeline shows 'bshMIjqDk8LTXTq4w91WKw/SearchTimeline', then set:"
  echo '  graphSearchTimeline* = "bshMIjqDk8LTXTq4w91WKw/SearchTimeline"'
fi
