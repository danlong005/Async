#!/bin/bash
# ------------------------------------------------------------------
# pub400-build.sh - build and test the working tree on pub400
#
#   tools/pub400-build.sh               build, unit tests
#   tools/pub400-build.sh it [SCEN...]  also the integration tests and examples
#
# Copies the working tree to IFS directory DIR on pub400, then runs
# tools/build.sh there, which builds ASYNC into LIB and runs the
# tests. Only ASYNC* objects in LIB are replaced; nothing is cleared.
#
# Needs an SSH key installed for USR. Override the defaults with
# environment variables USR, LIB and DIR.
# ------------------------------------------------------------------
set -euo pipefail

USR=${USR:-LONGDM}
LIB=${LIB:-LONGDM1}
DIR=${DIR:-/home/$USR/async}
HOST=pub400.com
PORT=2222

cd "$(dirname "$0")/.."

# pub400 prints a login banner on every connection
unbanner() {
  grep -v -e '^\*' -e '^ *$' -e 'Enter your password' \
          -e 'http://pub400.com' || true
}

echo "== copying the working tree to $DIR"
rsync -az --delete --exclude .git \
  -e "ssh -o BatchMode=yes -p $PORT" \
  --rsync-path=/QOpenSys/pkgs/bin/rsync \
  ./ "$USR@$HOST:$DIR/" 2>&1 | unbanner

# Run from a file: fed through stdin, the commands it runs would
# read the rest of the script as their input
ssh -o BatchMode=yes -p $PORT "$USR@$HOST" \
    "bash $DIR/tools/build.sh $LIB $DIR </dev/null" 2>&1 | unbanner

if [ "${1:-}" = it ]; then
  shift
  ssh -o BatchMode=yes -p $PORT "$USR@$HOST" \
      "rc=0
       bash $DIR/tools/integration.sh $LIB $DIR $* </dev/null || rc=1
       bash $DIR/tools/examples.sh $LIB </dev/null || rc=1
       exit \$rc" 2>&1 | unbanner
fi
