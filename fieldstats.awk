#!/usr/bin/awk -f
#
# fieldstats - per-column statistics for delimited text.
#
#   awk -f fieldstats.awk data.tsv
#   awk -f fieldstats.awk -v FS=, -v header=1 data.csv
#   awk -f fieldstats.awk -v FS=, -v cols=2,5 data.csv
#
# Reports count, min, max, mean, stddev, median and p95 for every column that
# holds numbers, and count plus distinct-value count for every column that does
# not. Written against POSIX awk - no gawk extensions - so it runs under mawk
# and gawk alike. That rules out asort(), hence the hand-written sort below.
#
# It does use sqrt(), which busybox awk as packaged by Debian and Ubuntu does
# not have ("Math support is not compiled in"). Everything except stddev works
# there; the stddev line is what fails.

function is_number(s) {
    # A leading + or -, digits with at most one dot, an optional exponent.
    # Deliberately stricter than awk's own coercion, which would read "3abc"
    # as 3 and quietly fold a text column into the numeric summary.
    return s ~ /^[+-]?([0-9]+(\.[0-9]+)?|\.[0-9]+)([eE][+-]?[0-9]+)?$/
}

# Insertion sort over v[lo..hi]. Column counts are small enough that the
# simplicity is worth more than the asymptotics, and it is stable.
function sort_slice(v, lo, hi,    i, j, key) {
    for (i = lo + 1; i <= hi; i++) {
        key = v[i]
        j = i - 1
        while (j >= lo && v[j] > key) {
            v[j + 1] = v[j]
            j--
        }
        v[j + 1] = key
    }
}

# Linear interpolation between order statistics, matching the "exclusive"
# convention most spreadsheets use for a percentile that falls between samples.
function quantile(v, n, q,    pos, lo, frac) {
    if (n == 1) return v[1]
    pos = q * (n - 1) + 1
    lo = int(pos)
    frac = pos - lo
    if (lo >= n) return v[n]
    return v[lo] + frac * (v[lo + 1] - v[lo])
}

function fmt(x) {
    # Integers print without a misleading ".00" tail.
    if (x == int(x) && x < 1e15 && x > -1e15) return sprintf("%d", x)
    return sprintf("%.4g", x)
}

BEGIN {
    if (header == "") header = 0

    # Which percentiles to report. p95 alone answers "how bad is the tail", but
    # not "how bad is the tail compared to typical", which needs p50 beside it
    # and p99 beyond it.
    if (pct == "") pct = "95"
    n_pct = split(pct, pct_list, ",")
    for (i = 1; i <= n_pct; i++) {
        p = pct_list[i] + 0
        if (p <= 0 || p >= 100) {
            printf "fieldstats: percentile %s is not between 0 and 100\n", pct_list[i] > "/dev/stderr"
            # `exit` from BEGIN still runs END, so without this flag the END
            # block would append a second, misleading "no data rows" error.
            aborted = 1
            exit 1
        }
        pct_value[i] = p
    }
    if (cols != "") {
        n_wanted = split(cols, wanted_list, ",")
        for (i = 1; i <= n_wanted; i++) wanted[wanted_list[i] + 0] = 1
        restrict = 1
    }
    ncol = 0
}

NR == 1 && header {
    for (i = 1; i <= NF; i++) name[i] = $i
    ncol = NF
    next
}

{
    # A wholly empty line has no fields at all under the default FS, so it can
    # neither be counted as data nor attributed to any column. Count it and say
    # so, rather than letting rows vanish between NR and the per-column counts.
    if (NF == 0) { skipped_rows++; next }

    if (NF > ncol) ncol = NF
    for (i = 1; i <= NF; i++) {
        if (restrict && !(i in wanted)) continue

        value = $i
        # An empty cell is missing data, not a zero.
        if (value == "") { blank[i]++; continue }

        count[i]++
        if (is_number(value)) {
            numeric_count[i]++
            v = value + 0
            store[i, numeric_count[i]] = v
            sum[i] += v
            sumsq[i] += v * v
            if (numeric_count[i] == 1 || v < min[i]) min[i] = v
            if (numeric_count[i] == 1 || v > max[i]) max[i] = v
        } else {
            if (!((i, value) in seen)) {
                seen[i, value] = 1
                distinct[i]++
            }
            if (distinct[i] <= 3 && length(examples[i]) < 40) {
                examples[i] = examples[i] (examples[i] == "" ? "" : ", ") value
            }
        }
    }
}

END {
    if (aborted) exit 1

    if (NR == 0 || (header && NR == 1)) {
        print "fieldstats: no data rows" > "/dev/stderr"
        exit 1
    }

    printf "%-14s %8s %8s %10s %10s %10s %10s %10s\n", \
        "column", "count", "blank", "min", "max", "mean", "stddev", "median"

    for (i = 1; i <= ncol; i++) {
        if (restrict && !(i in wanted)) continue
        if (count[i] == 0 && blank[i] == 0) continue

        label = (i in name) ? name[i] : ("col" i)
        if (length(label) > 14) label = substr(label, 1, 13) "~"

        n = numeric_count[i]
        # A column is numeric only if every non-blank cell parsed as a number.
        # One stray "n/a" makes the mean a lie, so the whole column degrades to
        # a categorical summary rather than silently reporting a partial mean.
        if (n > 0 && n == count[i]) {
            for (k = 1; k <= n; k++) sorted[k] = store[i, k]
            sort_slice(sorted, 1, n)

            mean = sum[i] / n
            if (n > 1) {
                var = (sumsq[i] - n * mean * mean) / (n - 1)
                if (var < 0) var = 0      # guard against rounding below zero
                sd = sqrt(var)
            } else {
                sd = 0
            }

            printf "%-14s %8d %8d %10s %10s %10s %10s %10s\n", \
                label, n, blank[i] + 0, fmt(min[i]), fmt(max[i]), \
                fmt(mean), fmt(sd), fmt(quantile(sorted, n, 0.5))

            if (n > 1) {
                for (k = 1; k <= n_pct; k++) {
                    pctile[i, k] = quantile(sorted, n, pct_value[k] / 100)
                }
                has_pct[i] = 1
            }
            has_numeric = 1
            for (k = 1; k <= n; k++) delete sorted[k]
        } else {
            printf "%-14s %8d %8d %10s %10s %10s %10s %10s\n", \
                label, count[i], blank[i] + 0, "-", "-", "-", "-", "-"
            # Naming the reason a column degraded is more use than a distinct
            # count, which would only ever have counted the non-numeric cells
            # and so read as "1 distinct" for a column of mostly numbers.
            if (numeric_count[i] == 0) {
                text_note[i] = distinct[i] " distinct"
            } else {
                text_note[i] = numeric_count[i] " numeric, "
                text_note[i] = text_note[i] (count[i] - numeric_count[i]) " non-numeric"
            }
            if (examples[i] != "") text_note[i] = text_note[i] " (" examples[i] ")"
            has_text = 1
        }
    }

    if (has_numeric) {
        printf "\n%-14s", "column"
        for (k = 1; k <= n_pct; k++) printf " %9s", "p" pct_list[k]
        printf "\n"

        for (i = 1; i <= ncol; i++) {
            if (restrict && !(i in wanted)) continue
            if (!(i in has_pct)) continue
            label = (i in name) ? name[i] : ("col" i)
            if (length(label) > 14) label = substr(label, 1, 13) "~"
            printf "%-14s", label
            for (k = 1; k <= n_pct; k++) printf " %9s", fmt(pctile[i, k])
            printf "\n"
        }
    }

    if (skipped_rows > 0) {
        printf "\n%d empty line(s) skipped\n", skipped_rows
    }

    if (has_text) {
        printf "\ntext columns\n"
        for (i = 1; i <= ncol; i++) {
            if (i in text_note) {
                label = (i in name) ? name[i] : ("col" i)
                printf "  %-14s %s\n", label, text_note[i]
            }
        }
    }
}
