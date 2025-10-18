#!/bin/bash
###############################################################################
# run-autobahn-docker.sh
# Runs Autobahn Test Suite using Docker or Podman
###############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔══════════════════════════════╗${NC}"
echo -e "${BLUE}║   CLWS Autobahn Test Suite   ║${NC}"
echo -e "${BLUE}╚══════════════════════════════╝${NC}"
echo

(cd ../; sbcl --eval "(asdf:load-system :clws)" --quit)
(cd ../; sbcl --eval "(asdf:load-system :clws)" --quit)

# Detect container runtime (Docker or Podman)
CONTAINER_CMD=""
if command -v podman &> /dev/null; then
    CONTAINER_CMD="podman"
    echo -e "${GREEN}✓ Using Podman${NC}"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
    echo -e "${GREEN}✓ Using Docker${NC}"
else
    echo -e "${RED}Error: Neither Docker nor Podman found${NC}"
    echo
    echo "Install Podman (recommended for Fedora):"
    echo "  sudo dnf install podman"
    echo
    echo "Or install Docker:"
    echo "  https://docs.docker.com/get-docker/"
    echo 
    exit 1
fi
echo

# Pull Autobahn container image if needed
echo -e "${BLUE}Checking for Autobahn container image...${NC}"
if ! $CONTAINER_CMD image inspect docker.io/crossbario/autobahn-testsuite &> /dev/null; then
    echo "Pulling docker.io/crossbario/autobahn-testsuite..."
    $CONTAINER_CMD pull docker.io/crossbario/autobahn-testsuite
else
    echo -e "${GREEN}✓ Image already present${NC}"
fi
echo

# Start CLWS server in background
echo -e "${BLUE}Starting CLWS server...${NC}"
sbcl --noinform --load run-autobahn-server.lisp > server.log 2>&1 &
SERVER_PID=$!

echo "Server PID: $SERVER_PID"

# Function to cleanup on exit
cleanup() {
    echo
    echo -e "${YELLOW}Stopping CLWS server (PID: $SERVER_PID)...${NC}"
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    echo -e "${GREEN}✓ Server stopped${NC}"
}

trap cleanup EXIT INT TERM

# Wait for server to start
echo "Waiting for server to start..."
sleep 3

# Check if server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo -e "${RED}Error: Server failed to start${NC}"
    echo "Server log:"
    cat server.log
    exit 1
fi

echo -e "${GREEN}✓ Server started${NC}"
echo

# Create reports directory
mkdir -p reports

# Run Autobahn test suite via container
echo -e "${BLUE}===========================================
Running Autobahn Test Suite via $CONTAINER_CMD
===========================================${NC}"
echo
echo "This will run 500+ protocol conformance tests..."
echo "This may take several minutes..."
echo

if $CONTAINER_CMD run -it --rm \
    -v "${PWD}/fuzzingclient.json:/config/fuzzingclient.json:Z" \
    -v "${PWD}/reports:/reports:Z" \
    --network="host" \
    docker.io/crossbario/autobahn-testsuite \
    wstest -m fuzzingclient -s /config/fuzzingclient.json; then

    echo
    echo -e "${BLUE}===========================================
Autobahn Test Results
===========================================${NC}"
    echo -e "${GREEN}✓ Test suite completed${NC}"
    echo
    echo "View detailed results:"
    echo "  Open: $(pwd)/reports/clients/index.html"
    echo

    # Try to display summary if index.html exists
    if [ -f "reports/clients/index.html" ]; then
        echo "Summary:"
        # Extract test results from HTML (basic parsing)
        if command -v grep &> /dev/null && command -v wc &> /dev/null; then
            TOTAL=$(grep -o 'case_count">[0-9]*' reports/clients/index.html 2>/dev/null | sed 's/case_count">//' | head -1 || echo "?")
            echo "  Total test cases: $TOTAL"
        fi
    fi

    EXIT_CODE=0
else
    echo
    echo -e "${RED}✗ Autobahn test suite failed${NC}"
    echo "Check reports/clients/index.html for details"
    EXIT_CODE=1
fi

exit $EXIT_CODE
