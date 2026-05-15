#!/usr/bin/env bash
# run_promgeflow.sh — thin wrapper around grp-bork/proMGEflow.
#
# Everything that *can* live in Nextflow config does (see nextflow.config +
# hpc.config + params.yml). This script only does what Nextflow can't:
#
#   1. Expand any .zip archives in --input-dir and stage their FASTAs into a
#      single dir; or accept a --input-sheet TSV and pass it straight through.
#   2. Validate that the DB paths in params.yml actually exist on disk
#      before launching anything.
#   3. Export MGEXPOSE_ENV_YAML so the global mgexpose conda override resolves.
#   4. Invoke `nextflow run grp-bork/proMGEflow` with the right -c / -profile /
#      -params-file / --input_dir | --input_sheet.
#
# Usage:
#   ./run_promgeflow.sh -i <dir>   -o <out> [options]
#   ./run_promgeflow.sh -s <sheet> -o <out> [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- defaults ----------
INPUT_DIR=""
INPUT_SHEET=""
OUTPUT_DIR=""
WORK_DIR=""
PARAMS_FILE="${SCRIPT_DIR}/params.yml"
NF_CONFIG="${SCRIPT_DIR}/nextflow.config"
PROFILES="singularity,slurm"
SINGULARITY_CACHEDIR=""
EXTRA_NF_ARGS=()
RESUME=0
DRY_RUN=0
STAGE_DIR=""
KEEP_STAGE=0

usage() {
  cat <<'EOF'
Usage: run_promgeflow.sh [-i <input_dir> | -s <input_sheet>] -o <output_dir> [options]

Input (exactly one):
  -i, --input-dir DIR     Directory of genome FASTA files (.fa/.fna/.fasta,
                          optionally .gz). Loose FASTAs and .zip archives in
                          any subdirectory are picked up; zips are expanded.
  -s, --input-sheet TSV   proMGEflow samplesheet (7 tab-separated columns:
                          speci, genome_id, genome, proteins, genes, gff,
                          emapper). Paths in the sheet may be gzipped.

Required:
  -o, --output-dir DIR

Common:
      --params FILE       Params YAML (default: ./params.yml).
      --profile NAMES     Nextflow profiles, comma-separated.
                          (default: singularity,slurm)
      --singularity-cachedir DIR
                          Cache for pulled .sif images (sets
                          $NXF_SINGULARITY_CACHEDIR for nextflow).
  -w, --work-dir DIR      Nextflow -work-dir.
  -r, --resume            Pass -resume to nextflow.
      --stage-dir DIR     Where to expand zips (input-dir mode only).
                          (default: <output_dir>/_staged_input)
      --keep-stage        Don't delete the stage dir on exit.
      --extra ARGS        Extra args appended verbatim to `nextflow run`.
  -n, --dry-run           Print the nextflow command without running it.
  -h, --help              This help.

Examples:
  ./run_promgeflow.sh -i ./genomes -o ./results
  ./run_promgeflow.sh -s sheet.tsv -o ./results --profile singularity,slurm -r
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

# ---------- arg parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input-dir)    INPUT_DIR="$2"; shift 2 ;;
    -s|--input-sheet)  INPUT_SHEET="$2"; shift 2 ;;
    -o|--output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
    --params)          PARAMS_FILE="$2"; shift 2 ;;
    --profile)         PROFILES="$2"; shift 2 ;;
    --singularity-cachedir) SINGULARITY_CACHEDIR="$2"; shift 2 ;;
    -w|--work-dir)     WORK_DIR="$2"; shift 2 ;;
    -r|--resume)       RESUME=1; shift ;;
    --stage-dir)       STAGE_DIR="$2"; shift 2 ;;
    --keep-stage)      KEEP_STAGE=1; shift ;;
    --extra)           EXTRA_NF_ARGS+=("$2"); shift 2 ;;
    -n|--dry-run)      DRY_RUN=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

# ---------- validate ----------
[[ -n "$OUTPUT_DIR" ]] || { usage; die "--output-dir is required"; }

if [[ -n "$INPUT_DIR" && -n "$INPUT_SHEET" ]]; then
  die "specify exactly one of --input-dir / --input-sheet (got both)"
fi
if [[ -z "$INPUT_DIR" && -z "$INPUT_SHEET" ]]; then
  die "specify exactly one of --input-dir / --input-sheet"
fi

[[ -f "$PARAMS_FILE" ]] || die "params file not found: $PARAMS_FILE"
[[ -f "$NF_CONFIG"   ]] || die "nextflow.config not found: $NF_CONFIG"
command -v nextflow >/dev/null 2>&1 || die "nextflow not found in PATH"

# ---------- pull DB paths out of params.yml ----------
# Simple `key: value` YAML; install `yq` and replace this if you need more.
yaml_get() {
  sed -n "s/^${1}:[[:space:]]\+\(.*\)$/\1/p" "$PARAMS_FILE" \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
          -e 's/[[:space:]]*#.*$//' \
          -e 's/^["'\'']\(.*\)["'\'']$/\1/' \
    | head -n 1
}

EMAPPER_DB=$(yaml_get emapper_db)
CONJSCAN_MODELS=$(yaml_get conjscan_models)
RECOMBINASE_SCAN_DB=$(yaml_get recombinase_scan_db)
RECOGNISE_MARKER_DB=$(yaml_get recognise_marker_db)
GENE_CLUSTER_SEQDB=$(yaml_get gene_cluster_seqdb)

for v in EMAPPER_DB CONJSCAN_MODELS RECOMBINASE_SCAN_DB RECOGNISE_MARKER_DB GENE_CLUSTER_SEQDB; do
  [[ -n "${!v}" ]] || die "$v not set in $PARAMS_FILE"
  [[ -e "${!v}" ]] || die "$v path does not exist: ${!v}"
done

# CONJSCAN_MODELS must be the parent of a CONJ/ folder.
[[ -d "$CONJSCAN_MODELS/CONJ" ]] \
  || die "conjscan_models must be the parent dir of a CONJ/ folder; not found: $CONJSCAN_MODELS/CONJ"

# ---------- mgexpose env yaml ----------
if [[ -f "${SCRIPT_DIR}/mgexpose.yml" ]]; then
  export MGEXPOSE_ENV_YAML="${SCRIPT_DIR}/mgexpose.yml"
  echo ">> mgexpose conda env yaml: $MGEXPOSE_ENV_YAML"
fi

# ---------- singularity cache ----------
# --singularity-cachedir wins; otherwise an already-exported NXF_SINGULARITY_CACHEDIR
# is honoured; otherwise nextflow.config falls back to $HOME/.singularity_cache.
if [[ -n "$SINGULARITY_CACHEDIR" ]]; then
  mkdir -p "$SINGULARITY_CACHEDIR"
  export NXF_SINGULARITY_CACHEDIR="$(cd "$SINGULARITY_CACHEDIR" && pwd)"
fi
[[ -n "${NXF_SINGULARITY_CACHEDIR:-}" ]] && echo ">> singularity cachedir: $NXF_SINGULARITY_CACHEDIR"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# ---------- mode-specific input handling ----------
NF_INPUT_ARGS=()

if [[ -n "$INPUT_SHEET" ]]; then
  # ---- samplesheet mode: pass straight through ----
  [[ -f "$INPUT_SHEET" ]] || die "input sheet not found: $INPUT_SHEET"
  INPUT_SHEET="$(cd "$(dirname "$INPUT_SHEET")" && pwd)/$(basename "$INPUT_SHEET")"
  echo ">> samplesheet mode: $INPUT_SHEET"
  NF_INPUT_ARGS+=( --input_sheet "$INPUT_SHEET" )
else
  # ---- input-dir mode: zip expansion + flat stage ----
  [[ -d "$INPUT_DIR" ]] || die "input dir does not exist: $INPUT_DIR"
  INPUT_DIR="$(cd "$INPUT_DIR" && pwd)"

  : "${STAGE_DIR:=${OUTPUT_DIR}/_staged_input}"
  mkdir -p "$STAGE_DIR"
  STAGE_DIR="$(cd "$STAGE_DIR" && pwd)"

  cleanup() {
    if [[ "$KEEP_STAGE" -eq 0 && -n "$STAGE_DIR" && -d "$STAGE_DIR" ]]; then
      rm -rf "$STAGE_DIR"
    fi
  }
  trap cleanup EXIT

  stage_fasta() {
    local src="$1" base dst
    base="$(basename "$src")"
    dst="$STAGE_DIR/$base"
    if [[ -e "$dst" ]]; then
      local i=1
      while [[ -e "$STAGE_DIR/${i}_${base}" ]]; do i=$((i+1)); done
      dst="$STAGE_DIR/${i}_${base}"
    fi
    ln -s "$src" "$dst" 2>/dev/null || cp "$src" "$dst"
  }

  echo ">> staging inputs into: $STAGE_DIR"
  n_fasta=0
  n_zip=0

  # loose fastas (recursive)
  while IFS= read -r -d '' f; do
    stage_fasta "$f"
    n_fasta=$((n_fasta+1))
  done < <(find "$INPUT_DIR" -type f \
              \( -iname '*.fa' -o -iname '*.fa.gz' \
              -o -iname '*.fna' -o -iname '*.fna.gz' \
              -o -iname '*.fasta' -o -iname '*.fasta.gz' \) -print0)

  # zip archives
  while IFS= read -r -d '' z; do
    n_zip=$((n_zip+1))
    command -v unzip >/dev/null 2>&1 || die "found zip ($z) but 'unzip' not in PATH"
    tmp="$(mktemp -d "${STAGE_DIR}/.unzip.XXXXXX")"
    echo "   unzipping $z"
    unzip -q -o "$z" -d "$tmp"
    while IFS= read -r -d '' f; do
      stage_fasta "$f"
      n_fasta=$((n_fasta+1))
    done < <(find "$tmp" -type f \
                \( -iname '*.fa' -o -iname '*.fa.gz' \
                -o -iname '*.fna' -o -iname '*.fna.gz' \
                -o -iname '*.fasta' -o -iname '*.fasta.gz' \) -print0)
  done < <(find "$INPUT_DIR" -type f -iname '*.zip' -print0)

  [[ "$n_fasta" -gt 0 ]] || die "no FASTA files found in $INPUT_DIR (after expanding $n_zip zip(s))"
  echo ">> staged $n_fasta FASTA file(s) (from $n_zip zip archive(s) + loose files)"

  NF_INPUT_ARGS+=( --input_dir "$STAGE_DIR" )
fi

# ---------- build nextflow cmd ----------
NF_CMD=( nextflow run grp-bork/proMGEflow
         -c "$NF_CONFIG"
         -profile "$PROFILES"
         -params-file "$PARAMS_FILE" )

[[ "$RESUME" -eq 1 ]] && NF_CMD+=( -resume )
[[ -n "$WORK_DIR" ]] && NF_CMD+=( -work-dir "$WORK_DIR" )

NF_CMD+=( "${NF_INPUT_ARGS[@]}" --output_dir "$OUTPUT_DIR" )

if [[ "${#EXTRA_NF_ARGS[@]}" -gt 0 ]]; then
  NF_CMD+=( "${EXTRA_NF_ARGS[@]}" )
fi

echo ">> command:"
printf '   %q ' "${NF_CMD[@]}"; echo

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo ">> dry run, exiting."
  exit 0
fi

"${NF_CMD[@]}"
