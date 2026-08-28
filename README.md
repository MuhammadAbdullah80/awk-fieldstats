# fieldstats

Per-column statistics for delimited text, in one POSIX awk script.

```
$ awk -f fieldstats.awk -v FS=, -v header=1 requests.csv
column            count    blank        min        max       mean     stddev     median
path                  5        0          -          -          -          -          -
latency               5        0        100        500        300      158.1        300
status                5        0        200        404      240.8      91.23        200

column                p95
latency               480
status              363.2

text columns
  path           5 distinct (/, /login, /api)
```

## Use

```
awk -f fieldstats.awk [-v FS=,] [-v header=1] [-v cols=2,5] FILE...
```

| Variable | Meaning |
| --- | --- |
| `FS` | Field separator. awk's default (runs of whitespace) if unset. |
| `header` | `1` treats the first row as column names. |
| `cols` | Comma-separated column numbers to restrict the report to. |

Reads stdin when no file is given. Exits non-zero if there are no data rows, so
it fails loudly in a pipeline rather than printing an empty table.

## What it reports

For a column where **every** non-blank cell parses as a number: count, blanks,
min, max, mean, sample standard deviation (n-1), median, and p95.

For anything else: count, blanks, and either the number of distinct values or —
if the column is *mostly* numeric — how the cells split. That last case is the
one worth knowing about:

```
$ printf '1\nn/a\n3\n' | awk -f fieldstats.awk
...
text columns
  col1           2 numeric, 1 non-numeric (n/a)
```

A single `n/a` in a column of ten thousand numbers means any mean you compute is
over a different population than you think. Rather than report a mean of the
subset that happened to parse, the column degrades and says why.

## Details that are deliberate

- **Number detection is stricter than awk's own.** awk coerces `3abc` to `3`.
  This script requires the whole cell to be a number, so a column of version
  strings or IDs does not silently acquire a mean.
- **An empty cell is missing data, not zero.** Blanks are counted separately and
  excluded from every statistic.
- **An empty *line* is reported.** Under the default `FS` a blank line has no
  fields at all, so it cannot be attributed to any column. It is counted and
  printed rather than allowed to vanish between `NR` and the column counts.
- **Sample stddev, not population.** Divides by n-1; a single value reports 0.
- **Percentiles interpolate** between order statistics, matching the convention
  most spreadsheets use.
- **No gawk extensions.** No `asort()`, hence the hand-written insertion sort.
  Runs under gawk and mawk.

One portability limit worth stating: the script calls `sqrt()`, which busybox
awk as packaged by Debian and Ubuntu does not provide - it reports "Math support
is not compiled in". Everything except the stddev column works there.

## Tests

```
bash test/run.sh
AWK=mawk bash test/run.sh
```

32 checks. CI runs them under both gawk and mawk.

## License

MIT
