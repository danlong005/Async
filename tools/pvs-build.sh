#!/bin/bash
# ------------------------------------------------------------------
# pvs-build.sh - build and test the working tree on the pvs IBM i
#
#   tools/pvs-build.sh               build, unit tests
#   tools/pvs-build.sh it [SCEN...]  also the integration tests and examples
#
# Copies the working tree to IFS directory DIR on ssh host HOST, then
# runs tools/build.sh there, which builds ASYNC into LIB and runs the
# iRPGUnit tests. Only ASYNC* objects in LIB are replaced; nothing is
# cleared.
#
# HOST is an entry in ~/.ssh/config (default pvs). Override the
# defaults with environment variables HOST, LIB and DIR.
# ------------------------------------------------------------------
set -euo pipefail

HOST=${HOST:-pvs}
LIB=${LIB:-ASYNC}
DIR=${DIR:-/home/dlong/async}

cd "$(dirname "$0")/.."

echo "== copying the working tree to $HOST:$DIR"
rsync -az --delete --exclude .git \
  -e "ssh -o BatchMode=yes" \
  --rsync-path=/QOpenSys/pkgs/bin/rsync \
  ./ "$HOST:$DIR/"

# Run from a file: fed through stdin, the commands it runs would
# read the rest of the script as their input
ssh -o BatchMode=yes "$HOST" "bash $DIR/tools/build.sh $LIB $DIR </dev/null"

if [ "${1:-}" = it ]; then
  shift
  ssh -o BatchMode=yes "$HOST" \
      "rc=0
       bash $DIR/tools/integration.sh $LIB $DIR $* </dev/null || rc=1
       bash $DIR/tools/examples.sh $LIB </dev/null || rc=1
       exit \$rc"
fi
