#!/usr/bin/env bash
# Test harness for fieldstats.awk. Runs under any POSIX awk; pass AWK=mawk etc.
#
# Input is passed as an argument rather than piped in: a `printf | expect`
# pipeline would run expect in a subshell, and the pass/fail counters it
# incremented would be discarded when that subshell exited - leaving a harness
# that reports failures on stdout but still exits 0.
set -u

AWK="${AWK:-awk}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PROG="${HERE}/../fieldstats.awk"

passed=0
failed=0

run() {
	local input="$1"
	shift
	printf '%b' "$input" | "$AWK" -f "$PROG" "$@" 2>&1
}

# expect NAME INPUT WANTED [awk-args...]
expect() {
	local name="$1" input="$2" want="$3" got
	shift 3
	got="$(run "$input" "$@")"
	if printf '%s' "$got" | grep -qF -- "$want"; then
		passed=$((passed + 1))
	else
		failed=$((failed + 1))
		printf 'FAIL %s\n      want substring: [%s]\n      got:\n%s\n\n' \
			"$name" "$want" "$got"
	fi
}

# reject NAME INPUT UNWANTED [awk-args...]
reject() {
	local name="$1" input="$2" unwanted="$3" got
	shift 3
	got="$(run "$input" "$@")"
	if printf '%s' "$got" | grep -qF -- "$unwanted"; then
		failed=$((failed + 1))
		printf 'FAIL %s\n      should not contain: [%s]\n      got:\n%s\n\n' \
			"$name" "$unwanted" "$got"
	else
		passed=$((passed + 1))
	fi
}

N='1\n2\n3\n4\n'

# --- numeric summary -------------------------------------------------------

expect 'mean of 1..4' "$N" '2.5'
expect 'min of 1..4' "$N" '         1'
expect 'max of 1..4' "$N" '         4'
# Sample stddev of 1,2,3,4 is sqrt(5/3) = 1.291.
expect 'sample stddev uses n-1' "$N" '1.291'
# Median of an even count interpolates between the middle two.
expect 'median interpolates on even counts' "$N" '2.5'
expect 'p95 is reported for numeric columns' "$N" 'p95'
expect 'a single value has zero stddev' '5\n' '         0'
expect 'constant column has zero stddev' '2\n2\n2\n' '         0'
expect 'negative numbers parse' '-5\n5\n' '        -5'
expect 'exponent notation parses' '1e3\n2e3\n' '      1000'
expect 'decimals parse' '0.25\n0.75\n' '0.5'

# --- header and labels -----------------------------------------------------

expect 'header supplies the label' 'latency\n100\n200\n' 'latency' -v header=1
expect 'without a header columns are numbered' '100\n200\n' 'col1'
expect 'long labels are truncated' 'a_very_long_column_name\n1\n' 'a_very_long_c~' -v header=1

# --- text and mixed columns ------------------------------------------------

expect 'a text column reports distinct values' 'a\nb\nc\n' '3 distinct'
reject 'a text column gets no p95 section' 'a\nb\nc\n' 'p95'
expect 'repeated text values count once' 'a\na\nb\n' '2 distinct'
expect 'a mixed column names the split' '1\nn/a\n3\n' '2 numeric, 1 non-numeric'
reject 'a mixed column gets no p95 section' '1\nn/a\n3\n' 'p95'
# awk would coerce "3abc" to 3; is_number must not.
expect 'partial numbers are not numbers' '1\n3abc\n' '1 numeric, 1 non-numeric'
expect 'examples are quoted back' '1\nn/a\n' '(n/a)'

# --- missing data ----------------------------------------------------------

expect 'an empty field counts as blank' 'a,1\nb,\nc,3\n' '        1' -v FS=,
expect 'blanks do not enter the mean' 'a,1\nb,\nc,3\n' '         2' -v FS=,
expect 'an empty line is reported, not dropped' '1\n\n3\n' '1 empty line(s) skipped'
reject 'no empty-line note when there are none' '1\n3\n' 'empty line(s) skipped'

# --- options ---------------------------------------------------------------

expect 'FS selects the delimiter' 'a,b\n1,2\n' 'col2' -v FS=,
expect 'cols restricts to one column' 'x,y,z\n1,2,3\n4,5,6\n' 'y' -v FS=, -v header=1 -v cols=2
reject 'cols excludes the others' 'x,y,z\n1,2,3\n4,5,6\n' 'z' -v FS=, -v header=1 -v cols=2

# --- errors ----------------------------------------------------------------

expect 'empty input is an error, not an empty table' '' 'no data rows'
expect 'a header with no rows is an error' 'only,a,header\n' 'no data rows' -v FS=, -v header=1

# --- exit status -----------------------------------------------------------

if run '' >/dev/null 2>&1; then
	failed=$((failed + 1))
	printf 'FAIL empty input should exit non-zero\n'
else
	passed=$((passed + 1))
fi

if run "$N" >/dev/null 2>&1; then
	passed=$((passed + 1))
else
	failed=$((failed + 1))
	printf 'FAIL valid input should exit zero\n'
fi

# --- report ----------------------------------------------------------------

total=$((passed + failed))
if [ "$failed" -eq 0 ]; then
	printf 'all %d checks passed\n' "$total"
	exit 0
fi
printf '%d of %d checks FAILED\n' "$failed" "$total"
exit 1
