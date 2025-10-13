# Usage:
#   load_os_ids                     # loads from ./ids.txt
#
# Run this on the utils pod in the target namespace, e.g.
#   ns="hmpps-delius-alfresco-dev"
#   pod=$(kubectl -n "$ns" get pods -l app=utils -o name 2>/dev/null | head -n1 | cut -d/ -f2 || true)
#   kubectl -n "$ns" exec "$pod" -- bash -lc "nohup bash ./load_os_ids.sh &"
# Notes:
#   - Requires psqlr to be installed on the utils pod (part of the utils image).
#   - The target database is determined by the psqlr config (usually via env vars).
#   - The input file should contain one UUID per line.
#   - Existing table public.moj_os_doc_ids will be dropped and recreated.
#   - The table is UNLOGGED for performance, and has a single column 'uuid' (varchar(36)).
#   - The 'uuid' column is the PRIMARY KEY, so duplicates in the input file will be ignored.
# -----------------------------------------------------------------------------
FILE="${1:-./ids.txt}"
APPEND_ROWS=${2:-false}  # set to true to append to existing table instead of recreating
TABLE_NAME="${3:-moj_os_doc_ids}"

# sanity check the file exists
if [[ ! -f "$FILE" ]]; then
  echo "File not found: $FILE" >&2
  exit 1
fi

# 1) Recreate staging table (UNLOGGED, single column, indexed via PK)
if [ "$APPEND_ROWS" != "true" ]; then
  echo "Recreating table public.${TABLE_NAME}..."
  psqlr --variable=t=$TABLE_NAME <<'SQL'
  DROP TABLE IF EXISTS public.:"t";
  CREATE UNLOGGED TABLE public.:"t" (
    uuid varchar(36) PRIMARY KEY
  );
SQL
fi

# 2) Bulk load from the provided file (one ID per line)
# psql does not support :variable substitution within psql backslash commands
psqlr -c "\\copy public.$TABLE_NAME(uuid) FROM '$FILE' WITH (FORMAT text)"
