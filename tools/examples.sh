#!/bin/bash
# ------------------------------------------------------------------
# examples.sh - run the example programs on IBM i and check them
#
#   tools/examples.sh LIB [NAME...]
#
# LIB   library the examples were built into (by build.sh)
# NAME  examples to run, e.g. ASYNCTIME (all of examples/ if none)
#
# Each runs as a batch job that allows threads; its output (QPRINT)
# is printed. An example passes if its output ends with "Done." and
# its job log has no machine checks or unhandled errors. ASYNCBG must
# also have written all three lines of /tmp/asyncbg.log. Exit status
# is non-zero if any failed.
# ------------------------------------------------------------------
set -u
LIB=$1
shift
failed=0
. "$(dirname "$0")/common.sh"

if [ $# -gt 0 ]; then
  NAMES="$*"
else
  NAMES=$(ls "$(dirname "$0")/../examples" | sed 's/\..*//' | tr a-z A-Z)
fi
BADMSGS='^ *(MCH[0-9A-F]{4}|CPF9999|CEE9901|RNQ[0-9]{4}|RNX[0-9]{4}) '

# Output the job wrote to standard output
qprint() {
  /QOpenSys/usr/bin/qsh -c "db2 -S \"select spooled_data from table(
      systools.spooled_file_data(job_name => '$1',
                                 spooled_file_name => 'QPRINT')) x\"" \
    2>/dev/null | sed -e '1,/^------/d' -e '/RECORD(S) SELECTED/d' \
                      -e 's/ *$//' -e '/-=\* .* \*=-/d' | sed '/^$/d'
}

passed=0
total=0
for name in $NAMES; do
  total=$((total + 1))
  echo "== $name"
  job=$(submit "$name" '*YES' "CALL PGM($LIB/$name)")
  if [ -z "$job" ] || ! waitjob "$job" 120; then
    echo "!! $name did not run or did not end within 120 s"
    failed=1
    continue
  fi
  out=$(qprint "$job")
  echo "$out" | sed 's/^/   /'
  if [ "$(echo "$out" | tail -1)" != "Done." ]; then
    echo "!! $name did not finish; job log of $job:"
    joblog "$job" | head -30 | sed 's/^/   /'
    failed=1
  elif ! messages=$(joblog "$job"); then
    echo "!! could not read the job log of $job to check it"
    failed=1
  elif bad=$(echo "$messages" | grep -E "$BADMSGS") && [ -n "$bad" ]; then
    echo "!! $name finished, but its job log ($job) has:"
    echo "$bad" | head -20 | sed 's/^/   /'
    failed=1
  elif [ "$name" = ASYNCBG ] &&
       [ "$(grep -c shipped /tmp/asyncbg.log 2>/dev/null)" != 3 ]; then
    # its background tasks outlive main: ASYNC must have waited for
    # all three before the job ended
    echo "!! ASYNCBG: /tmp/asyncbg.log does not have all three lines"
    failed=1
  else
    passed=$((passed + 1))
  fi
done

echo "== $passed of $total examples ran cleanly"
exit $failed
