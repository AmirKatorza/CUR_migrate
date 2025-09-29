#!/bin/bash
set -euo pipefail

# ============================
# Month CUR Migration Utility
# ============================
# Renames per-slice CSVs from cur-<OLD_ID>-N.csv.gz -> cur-<NEW_ID>-N.csv.gz
# Rewrites per-slice manifests (reportName, reportKeys)
# Rewrites month-level manifest (reportName, reportKeys)
#
# Assumptions:
# - Month prefix path is: hourly/cur-<PAYER_PATH_ID>/<MONTH_ID>/
#   (In your case, PAYER_PATH_ID = NEW_ID, e.g., 695166363537)
# - jq and aws CLI v2 installed.
#
# Usage:
#   ./month-migrate.sh -b <bucket> -m <YYYYMM01-YYYYMM+101> -o <OLD_ID> -n <NEW_ID> [-p <aws_profile>] [--dry-run] [--payer-path-id <ID>] [--force-month]
#
# Example:
#   ./month-migrate.sh \
#     -b cur-695166363537-test \
#     -m 20240801-20240901 \
#     -o 376443268082 \
#     -n 695166363537 \
#     -p cur-migrate \
#     --payer-path-id 695166363537
#
# Flags:
#   --dry-run        : compute and print actions, no writes
#   --payer-path-id  : ID used in the *path* under hourly/cur-<ID>/ (defaults to NEW_ID)
#   --force-month    : (kept for compatibility) previously required to upload month manifest despite missing keys.
#                      Now the script always uploads the month manifest; this flag has no effect on upload behavior.
#
# Debugging:
#   Add -x to shebang (#!/bin/bash -xeuo pipefail) or run: bash -x ./month-migrate.sh ...

AWS_PROFILE=""
BUCKET=""
MONTH_ID=""
OLD_ID=""
NEW_ID=""
DRY_RUN="false"
FORCE_MONTH="false"   # kept for compatibility; no longer controls upload
PAYER_PATH_ID=""

# --------------- arg parsing
print_help() {
  sed -n '1,120p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--bucket) BUCKET="$2"; shift 2 ;;
    -m|--month) MONTH_ID="$2"; shift 2 ;;
    -o|--old) OLD_ID="$2"; shift 2 ;;
    -n|--new) NEW_ID="$2"; shift 2 ;;
    -p|--profile) AWS_PROFILE="$2"; shift 2 ;;
    --payer-path-id) PAYER_PATH_ID="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --force-month) FORCE_MONTH="true"; shift ;;  # retained; informational only
    -h|--help) print_help; exit 0 ;;
    *) echo "Unknown arg: $1"; print_help; exit 1 ;;
  esac
done

if [[ -z "${BUCKET}" || -z "${MONTH_ID}" || -z "${OLD_ID}" || -z "${NEW_ID}" ]]; then
  echo "ERROR: -b/--bucket, -m/--month, -o/--old, -n/--new are required."
  print_help
  exit 1
fi

if [[ -z "${PAYER_PATH_ID}" ]]; then
  PAYER_PATH_ID="${NEW_ID}"
fi

MONTH_PREFIX="hourly/cur-${PAYER_PATH_ID}/${MONTH_ID}"
AWS=(aws)
if [[ -n "${AWS_PROFILE}" ]]; then
  AWS+=(--profile "${AWS_PROFILE}")
fi

echo "=== CUR Month Migration ==="
echo "Bucket          : ${BUCKET}"
echo "Month prefix    : ${MONTH_PREFIX}/"
echo "Old payer ID    : ${OLD_ID}"
echo "New payer ID    : ${NEW_ID}"
echo "Payer ID in path: ${PAYER_PATH_ID}"
echo "Dry run         : ${DRY_RUN}"
echo "Force month     : ${FORCE_MONTH} (no effect; month manifest always uploaded)"
echo

# --------------- helpers
put_object_json() {
  local key="$1"
  local file="$2"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] put-object s3://${BUCKET}/${key} (application/json; charset=UTF-8)"
  else
    "${AWS[@]}" s3api put-object \
      --bucket "${BUCKET}" \
      --key "${key}" \
      --body "${file}" \
      --content-type "application/json; charset=UTF-8" >/dev/null
  fi
}

s3_copy() {
  local src="$1"
  local dst="$2"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] aws s3 cp s3://${BUCKET}/${src} s3://${BUCKET}/${dst}"
  else
    "${AWS[@]}" s3 cp "s3://${BUCKET}/${src}" "s3://${BUCKET}/${dst}" >/dev/null
  fi
}

s3_exists() {
  local key="$1"
  if "${AWS[@]}" s3 ls "s3://${BUCKET}/${key}" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

# --------------- discover slices
echo "Listing slice folders under month..."
SLICES=$("${AWS[@]}" s3 ls "s3://${BUCKET}/${MONTH_PREFIX}/" | awk '/PRE/ {print $2}' | sed 's:/$::' | grep -E '^[0-9]{8}T[0-9]{6}Z$' || true)

if [[ -z "${SLICES}" ]]; then
  echo "No slice folders found at s3://${BUCKET}/${MONTH_PREFIX}/"
  exit 1
fi

echo "Found slices:"
echo "${SLICES}"
echo

# --------------- per-slice migrations
MISSING_TOTAL=0
for SLICE in ${SLICES}; do
  echo "=== Slice: ${SLICE} ==="

  # copy CSVs cur-OLD-x.csv.gz -> cur-NEW-x.csv.gz
  SL_PREFIX="${MONTH_PREFIX}/${SLICE}"
  # enumerate csvs that match old ID naming
  CSV_KEYS=$("${AWS[@]}" s3 ls "s3://${BUCKET}/${SL_PREFIX}/" | awk '{print $4}' | grep -E "^cur-${OLD_ID}-[0-9]+\.csv\.gz$" || true)

  if [[ -z "${CSV_KEYS}" ]]; then
    echo "No CSVs found with old ID in ${SL_PREFIX}/ (maybe already migrated?)"
  else
    for CSV in ${CSV_KEYS}; do
      NEW_CSV="${CSV/cur-${OLD_ID}-/cur-${NEW_ID}-}"
      echo "Copy CSV: ${CSV} -> ${NEW_CSV}"
      s3_copy "${SL_PREFIX}/${CSV}" "${SL_PREFIX}/${NEW_CSV}"
    done
  fi

  # rewrite slice manifest
  OLD_SL_MAN="${SL_PREFIX}/cur-${OLD_ID}-Manifest.json"
  NEW_SL_MAN="${SL_PREFIX}/cur-${NEW_ID}-Manifest.json"

  if ! s3_exists "${OLD_SL_MAN}"; then
    echo "WARNING: Missing old slice manifest: ${OLD_SL_MAN} (skipping slice manifest rewrite)"
  else
    echo "Download slice manifest: ${OLD_SL_MAN}"
    "${AWS[@]}" s3 cp "s3://${BUCKET}/${OLD_SL_MAN}" "./slice-${SLICE}.old.json" >/dev/null

    # transform: reportName -> cur-NEW, reportKeys path and filename replacements
    jq --arg OLD "${OLD_ID}" --arg NEW "${NEW_ID}" --arg PATHID "${PAYER_PATH_ID}" '
      .reportName = ("cur-" + $NEW)
      | .reportKeys = (
          .reportKeys
          | map(
              gsub("/cur-" + $OLD + "/"; "/cur-" + $PATHID + "/")
              | gsub("cur-" + $OLD + "-"; "cur-" + $NEW + "-")
            )
        )
    ' "./slice-${SLICE}.old.json" > "./slice-${SLICE}.new.json"

    echo "Upload new slice manifest: ${NEW_SL_MAN}"
    put_object_json "${NEW_SL_MAN}" "./slice-${SLICE}.new.json"

    # verify all reportKeys exist
    echo "Verify slice reportKeys exist..."
    MISS=0
    while IFS= read -r key; do
      if ! s3_exists "${key}"; then
        echo "MISSING: ${key}"
        MISS=$((MISS+1))
      fi
    done < <(jq -r '.reportKeys[]' "./slice-${SLICE}.new.json")
    if [[ ${MISS} -gt 0 ]]; then
      echo "Slice ${SLICE}: ${MISS} missing data files referenced by manifest."
      MISSING_TOTAL=$((MISSING_TOTAL+MISS))
    else
      echo "Slice ${SLICE}: OK"
    fi
    rm -f "./slice-${SLICE}.old.json" "./slice-${SLICE}.new.json"
  fi

  echo
done

# --------------- month-level manifest
OLD_MONTH_MAN="${MONTH_PREFIX}/cur-${OLD_ID}-Manifest.json"
NEW_MONTH_MAN="${MONTH_PREFIX}/cur-${NEW_ID}-Manifest.json"

if ! s3_exists "${OLD_MONTH_MAN}"; then
  echo "WARNING: Month-level manifest not found at ${OLD_MONTH_MAN}. Skipping month rewrite."
  exit 0
fi

echo "Download month manifest: ${OLD_MONTH_MAN}"
"${AWS[@]}" s3 cp "s3://${BUCKET}/${OLD_MONTH_MAN}" ./month-old.json >/dev/null

# Replace reportName and all reportKeys paths & filenames
jq --arg OLD "${OLD_ID}" --arg NEW "${NEW_ID}" --arg PATHID "${PAYER_PATH_ID}" '
  .reportName = ("cur-" + $NEW)
  | .reportKeys = (
      .reportKeys
      | map(
          gsub("/cur-" + $OLD + "/"; "/cur-" + $PATHID + "/")
          | gsub("cur-" + $OLD + "-"; "cur-" + $NEW + "-")
        )
    )
' ./month-old.json > ./month-new.json

# Preflight existence (informational only; upload happens regardless)
echo "Preflight: verify all month reportKeys exist..."
MISSING_MONTH=0
while IFS= read -r key; do
  if ! s3_exists "${key}"; then
    echo "MISSING: ${key}"
    MISSING_MONTH=$((MISSING_MONTH+1))
  fi
done < <(jq -r '.reportKeys[]' ./month-new.json)

if [[ ${MISSING_MONTH} -gt 0 ]]; then
  echo "WARNING: Month manifest references ${MISSING_MONTH} missing keys."
  echo "Tip: The month manifest usually points to a single 'final assembly' slice (often the last slice of the month)."
  echo "     Ensure that slice’s CSVs were migrated to the new payer ID and paths."
else
  echo "Month manifest clean: all reportKeys exist."
fi

echo "Upload new month manifest: ${NEW_MONTH_MAN}"
put_object_json "${NEW_MONTH_MAN}" ./month-new.json
"${AWS[@]}" s3api head-object --bucket "${BUCKET}" --key "${NEW_MONTH_MAN}" | jq -r '.ContentType' || true

rm -f ./month-old.json ./month-new.json

if [[ ${MISSING_TOTAL} -gt 0 || ${MISSING_MONTH} -gt 0 ]]; then
  echo "Completed with warnings: missing refs (slice_total=${MISSING_TOTAL}, month=${MISSING_MONTH})."
else
  echo "=== Done: month ${MONTH_ID} migrated cleanly. ==="
fi
