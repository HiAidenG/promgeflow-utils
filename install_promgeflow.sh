#!/usr/bin/env bash
#
# Auto-installer for proMGEflow (https://github.com/grp-bork/proMGEflow).
#
# Steps:
#   1. Clone the proMGEflow repo into ./promgeflow/proMGEflow/
#   2. module load devel/miniforge and create a conda env with nextflow
#   3. Scaffold per-database sub-dirs under ./promgeflow/ and write params.yml
#   4. sbatch a SLURM job that downloads all five reference databases
#
# Usage:
#   ./install_progmgeflow.sh [INSTALL_DIR] [--skip-dbs]
# Default INSTALL_DIR is "promgeflow" in the current working directory.
# --skip-dbs writes the sbatch script but doesn't submit it (useful when DBs
# are already downloaded, or when you want to inspect/submit it by hand).

set -euo pipefail

INSTALL_DIR=""
SKIP_DBS=0
for arg in "$@"; do
    case "$arg" in
        --skip-dbs) SKIP_DBS=1 ;;
        -h|--help)
            sed -n '2,14p' "${BASH_SOURCE[0]}"
            exit 0 ;;
        --*)        echo "[promgeflow] unknown option: $arg" >&2; exit 2 ;;
        *)
            [[ -z "$INSTALL_DIR" ]] || { echo "[promgeflow] unexpected arg: $arg" >&2; exit 2; }
            INSTALL_DIR="$arg" ;;
    esac
done
INSTALL_DIR="${INSTALL_DIR:-promgeflow}"

ENV_NAME="${PROMGE_ENV:-promgeflow}"
NEXTFLOW_VERSION="25.10.4"
RECOGNISE_VERSION="0.7.3"   # must match the pin in promgeflow/recognise.yml
REPO_URL="https://github.com/grp-bork/proMGEflow.git"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECOGNISE_YML="$SELF_DIR/promgeflow/recognise.yml"

INSTALL_DIR="$(readlink -m "$INSTALL_DIR")"
REPO_DIR="$INSTALL_DIR/proMGEflow"
LOG_DIR="$INSTALL_DIR/logs"
RECOGNISE_ENV_PREFIX="$INSTALL_DIR/recognise_env"

echo "[promgeflow] install dir:    $INSTALL_DIR"
echo "[promgeflow] repo dir:       $REPO_DIR"
echo "[promgeflow] conda env:      $ENV_NAME"
echo "[promgeflow] recognise env:  $RECOGNISE_ENV_PREFIX"

mkdir -p "$INSTALL_DIR"/{emapper_db,conjscan_models,recombinase_models,recognise_markers,cluster_ref_seqs}
mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------------
# 1. Clone proMGEflow repository into $INSTALL_DIR/proMGEflow
# ---------------------------------------------------------------------------
if [[ -d "$REPO_DIR/.git" ]]; then
    echo "[promgeflow] repo already cloned, skipping git clone"
else
    git clone "$REPO_URL" "$REPO_DIR"
fi

# CONJScan models — clone here on the login node, since compute nodes
# in the SLURM job don't have git available.
CONJ_DIR="$INSTALL_DIR/conjscan_models/CONJ"
if [[ -d "$CONJ_DIR/.git" ]]; then
    echo "[promgeflow] CONJScan already cloned, skipping"
else
    git clone https://github.com/macsy-models/CONJScan.git "$CONJ_DIR"
fi
( cd "$CONJ_DIR" && git checkout d5fc1e3724362cb14c03a6e2f6de879bbdf3f64e )

# ---------------------------------------------------------------------------
# 2a. Conda env with nextflow
# ---------------------------------------------------------------------------
echo "[promgeflow] loading miniforge"
# Initialise the module system in non-interactive shells
if ! command -v module >/dev/null 2>&1; then
    if [[ -f /etc/profile.d/modules.sh ]]; then
        # shellcheck disable=SC1091
        source /etc/profile.d/modules.sh
    elif [[ -f /usr/share/lmod/lmod/init/bash ]]; then
        # shellcheck disable=SC1091
        source /usr/share/lmod/lmod/init/bash
    fi
fi
module load devel/miniforge

source "$(conda info --base)/etc/profile.d/conda.sh"

if conda env list | awk '{print $1}' | grep -qx "$ENV_NAME"; then
    echo "[promgeflow] conda env '$ENV_NAME' already exists"
    current_version="$(conda run -n "$ENV_NAME" nextflow -v 2>/dev/null | awk '{print $3}')"
    # Accept both the bare version (25.10.4) and dotted build suffixes
    # (e.g. 25.10.4.11173) — same upstream release, just a distribution tag.
    if [[ "$current_version" != "$NEXTFLOW_VERSION" && "$current_version" != "$NEXTFLOW_VERSION".* ]]; then
        echo "[promgeflow] nextflow is '${current_version:-missing}', installing $NEXTFLOW_VERSION"
        conda install -y -n "$ENV_NAME" -c bioconda -c conda-forge "nextflow=$NEXTFLOW_VERSION"
    fi
else
    echo "[promgeflow] creating conda env '$ENV_NAME' with nextflow=$NEXTFLOW_VERSION"
    conda create -y -n "$ENV_NAME" -c bioconda -c conda-forge "nextflow=$NEXTFLOW_VERSION"
fi

# ---------------------------------------------------------------------------
# 2b. reCOGnise conda env
# ---------------------------------------------------------------------------
[[ -f "$RECOGNISE_YML" ]] || { echo "[promgeflow] recognise env yml not found: $RECOGNISE_YML" >&2; exit 1; }

if [[ -d "$RECOGNISE_ENV_PREFIX/conda-meta" ]]; then
    echo "[promgeflow] recognise env already exists at $RECOGNISE_ENV_PREFIX"
else
    echo "[promgeflow] creating recognise env at $RECOGNISE_ENV_PREFIX"
    if command -v mamba >/dev/null 2>&1; then
        mamba env create -p "$RECOGNISE_ENV_PREFIX" -f "$RECOGNISE_YML"
    else
        conda env create -p "$RECOGNISE_ENV_PREFIX" -f "$RECOGNISE_YML"
    fi
fi

# Idempotent backfill: ensure perl is installed even when re-running into an
# existing env that predates the perl entry in recognise.yml. fetchMGs.pl
# shebangs `#!/usr/bin/env perl` and we don't want to depend on the compute
# node having a system perl on PATH.
if ! "$RECOGNISE_ENV_PREFIX/bin/perl" -e1 2>/dev/null; then
    echo "[promgeflow] installing perl into recognise env"
    if command -v mamba >/dev/null 2>&1; then
        mamba install -y -p "$RECOGNISE_ENV_PREFIX" -c conda-forge perl
    else
        conda install -y -p "$RECOGNISE_ENV_PREFIX" -c conda-forge perl
    fi
fi

# fetchMGs.pl (motu-tool/fetchMGs.pl) — the Perl tool that reCOGnise calls
# via subprocess when the python `fetchmgs` module is unimportable. We don't
# install the python module (it forces pyhmmer==0.11.2 which conflicts with
# reCOGnise's pyhmmer~=0.12)
FETCHMGS_PL_DIR="$RECOGNISE_ENV_PREFIX/opt/fetchMGs.pl"
FETCHMGS_PL_WRAPPER="$RECOGNISE_ENV_PREFIX/bin/fetchMGs.pl"
if [[ -d "$FETCHMGS_PL_DIR/.git" ]]; then
    echo "[promgeflow] fetchMGs.pl already cloned at $FETCHMGS_PL_DIR"
else
    echo "[promgeflow] cloning fetchMGs.pl into $FETCHMGS_PL_DIR"
    mkdir -p "$(dirname "$FETCHMGS_PL_DIR")"
    git clone https://github.com/motu-tool/fetchMGs.pl.git "$FETCHMGS_PL_DIR"
fi
chmod +x "$FETCHMGS_PL_DIR/fetchMGs.pl"

# Wrapper resolves the real script relative to its own location so the env
# stays relocatable. fetchMGs.pl itself uses FindBin to find sibling lib/ and
# bin/ (bundled hmmsearch + seqtk), so we must invoke the script in place
# rather than symlinking the bare file.
cat > "$FETCHMGS_PL_WRAPPER" <<'WRAPPER'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$HERE/opt/fetchMGs.pl/fetchMGs.pl" "$@"
WRAPPER
chmod +x "$FETCHMGS_PL_WRAPPER"

# Sanity check: entry points the nextflow recognise processes will invoke.
# `recognise` is from pip; prodigal/mapseq from bioconda; fetchMGs.pl from the
# clone above.
for bin in recognise prodigal mapseq fetchMGs.pl; do
    if [[ ! -x "$RECOGNISE_ENV_PREFIX/bin/$bin" ]]; then
        echo "[promgeflow] WARNING: $bin not found in $RECOGNISE_ENV_PREFIX/bin" >&2
    fi
done

# Belt-and-braces: if a prior install left the python `fetchmgs` package
# importable, the import-guarded subprocess fallback in recognise won't fire
# and we'll hit the pyhmmer .decode() bug. Strip it.
if "$RECOGNISE_ENV_PREFIX/bin/python" -c "import fetchmgs" 2>/dev/null; then
    echo "[promgeflow] removing stale python fetchmgs package from recognise env"
    "$RECOGNISE_ENV_PREFIX/bin/pip" uninstall -y fetchmgs fetchMGs 2>/dev/null || true
    "$RECOGNISE_ENV_PREFIX/bin/python" -m pip uninstall -y fetchmgs fetchMGs 2>/dev/null || true
fi

# Ensure reCOGnise is at the pinned version. main has gated specI.txt /
# specI.status output behind a new --with_sentinels flag that proMGEflow's
# recognise.nf doesn't pass, so anything newer than v0.7.3 silently leaves
# those files unwritten and downstream processes mark every genome unknown.
installed_recognise_ver="$(
    "$RECOGNISE_ENV_PREFIX/bin/python" -c \
        "import recognise; print(getattr(recognise, '__version__', ''))" 2>/dev/null \
        | tr -d '[:space:]'
)"
if [[ "$installed_recognise_ver" != "$RECOGNISE_VERSION" ]]; then
    echo "[promgeflow] recognise is '${installed_recognise_ver:-missing}', pinning to $RECOGNISE_VERSION"
    "$RECOGNISE_ENV_PREFIX/bin/pip" install --no-deps --force-reinstall \
        "git+https://github.com/grp-bork/reCOGnise.git@v${RECOGNISE_VERSION}"
fi

# Idempotent backfill for existing envs that predate the hmmer/seqtk entries
# in recognise.yml — fetchMGs.pl needs hmmsearch + seqtk on PATH (see patch
# below).
for tool in hmmsearch seqtk; do
    if ! "$RECOGNISE_ENV_PREFIX/bin/$tool" -h >/dev/null 2>&1 \
        && ! [[ -x "$RECOGNISE_ENV_PREFIX/bin/$tool" ]]; then
        echo "[promgeflow] installing hmmer + seqtk into recognise env"
        if command -v mamba >/dev/null 2>&1; then
            mamba install -y -p "$RECOGNISE_ENV_PREFIX" -c bioconda -c conda-forge hmmer seqtk
        else
            conda install -y -p "$RECOGNISE_ENV_PREFIX" -c bioconda -c conda-forge hmmer seqtk
        fi
        break
    fi
done

# v0.7.3 of reCOGnise hardcodes `-x /usr/bin` when shelling out to
# fetchMGs.pl — only correct inside the upstream docker container. Rewrite
# the literal to `-x ""`, which tells fetchMGs.pl to resolve hmmsearch +
# seqtk via $PATH (where bioconda installs them in this env). Idempotent —
# sed is a no-op once the file is already patched.
for f in "$RECOGNISE_ENV_PREFIX"/lib/python*/site-packages/recognise/__main__.py; do
    [[ -f "$f" ]] || continue
    if grep -q '"-x", "/usr/bin"' "$f"; then
        echo "[promgeflow] patching $f to drop hardcoded /usr/bin in fetchMGs.pl call"
        sed -i 's|"-x", "/usr/bin"|"-x", ""|' "$f"
    fi
done

# ---------------------------------------------------------------------------
# 3. Write params.yml pointing at our database dirs
# ---------------------------------------------------------------------------
PARAMS_FILE="$INSTALL_DIR/params.yml"
echo "[promgeflow] writing $PARAMS_FILE"
cat > "$PARAMS_FILE" <<EOF
### INPUT — set one of input_sheet or input_dir before running
# input_sheet: "/path/to/input/sheet"
# input_dir: "/path/to/input/directory"
# known_speci: "unknown"

### OUTPUT
output_dir: "output/"

### PRODIGAL
prodigal_batch_size: 10

### RECOGNISE
# Points one level into the tarball's wrapper dir — recognise passes this
# straight to mapseq, which opens <marker_db>/COG*.fna directly.
recognise_marker_db: "$INSTALL_DIR/recognise_markers/recognise_markers"
recognise_marker_set: "motus"

### RECOMBINASE_SCAN
recombinase_scan_db: "$INSTALL_DIR/recombinase_models/promge_v1_recombinase_models.hmm"

### MACSYFINDER / CONJScan
# conjscan_models must point at the *parent* of the CONJ/ directory
conjscan_models: "$INSTALL_DIR/conjscan_models"

### EGGNOG-MAPPER
emapper_db: "$INSTALL_DIR/emapper_db"

### LINCLUST
gene_cluster_seqdb: "$INSTALL_DIR/cluster_ref_seqs"
EOF

# ---------------------------------------------------------------------------
# 4. Submit SLURM job for database downloads (~90 GB total)
# ---------------------------------------------------------------------------
SBATCH_SCRIPT="$INSTALL_DIR/download_databases.sbatch"
echo "[promgeflow] writing $SBATCH_SCRIPT"
cat > "$SBATCH_SCRIPT" <<EOF
#!/usr/bin/env bash
#SBATCH --job-name=promgeflow-dbs
#SBATCH --output=$LOG_DIR/db_download_%j.out
#SBATCH --error=$LOG_DIR/db_download_%j.err
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --partition=cpu-single

set -euo pipefail

ROOT="$INSTALL_DIR"

echo "[dbs] starting at \$(date)"

# --- 1) EggNOG-mapper database (~48 GB) ----------------------------------
cd "\$ROOT/emapper_db"
wget -c http://eggnog6.embl.de/download/emapperdb-5.0.2/eggnog.db.gz
wget -c http://eggnog6.embl.de/download/emapperdb-5.0.2/eggnog_proteins.dmnd.gz
wget -c http://eggnog6.embl.de/download/emapperdb-5.0.2/eggnog.taxa.tar.gz
[[ -f eggnog.db ]]              || gunzip -f eggnog.db.gz
[[ -f eggnog_proteins.dmnd ]]   || gunzip -f eggnog_proteins.dmnd.gz
tar xvzf eggnog.taxa.tar.gz

# --- 2) CONJScan models — cloned by the install script on the login node;
#        compute nodes don't have git.

# --- 3) Recombinase HMMs (~1.7 MB) ---------------------------------------
cd "\$ROOT/recombinase_models"
wget -c https://zenodo.org/records/15829523/files/promge_v1_recombinase_models.hmm.gz
[[ -f promge_v1_recombinase_models.hmm ]] || gunzip -f promge_v1_recombinase_models.hmm.gz

# --- 4) reCOGnise marker set (~1 GB) -------------------------------------
# The tarball expands a top-level recognise_markers/ wrapper, so the COG*.fna
# files end up at \$ROOT/recognise_markers/recognise_markers/
cd "\$ROOT/recognise_markers"
wget -c https://zenodo.org/records/17916463/files/recognise_markers.tar.gz
tar xvzf recognise_markers.tar.gz

# --- 5) Pangenome reference sequences (~38.9 GB) -------------------------
cd "\$ROOT/cluster_ref_seqs"
wget -c https://zenodo.org/records/17704403/files/sp095_refdb_v1ypg3.tar
tar xvf sp095_refdb_v1ypg3.tar

echo "[dbs] finished at \$(date)"
EOF
chmod +x "$SBATCH_SCRIPT"

if [[ "$SKIP_DBS" -eq 1 ]]; then
    echo "[promgeflow] --skip-dbs set; not submitting the database download job"
    echo "             submit it manually with: sbatch $SBATCH_SCRIPT"
    DB_STATUS="(skipped via --skip-dbs; sbatch $SBATCH_SCRIPT to run)"
elif command -v sbatch >/dev/null 2>&1; then
    echo "[promgeflow] submitting database download job"
    sbatch "$SBATCH_SCRIPT"
    DB_STATUS="(downloads running via SLURM)"
else
    echo "[promgeflow] sbatch not found; run the download script manually:"
    echo "             sbatch $SBATCH_SCRIPT"
    DB_STATUS="(sbatch not found; run $SBATCH_SCRIPT manually)"
fi

cat <<EOF

  install:       $INSTALL_DIR
  repo:          $REPO_DIR
  databases:     $INSTALL_DIR/{emapper_db,conjscan_models,recombinase_models,recognise_markers,cluster_ref_seqs}
                 $DB_STATUS
  params:        $PARAMS_FILE
  recognise env: $RECOGNISE_ENV_PREFIX
  logs:          $LOG_DIR

To run the workflow once databases finish:
  module load devel/miniforge
  module load system/singularity/3.11.3
  conda activate $ENV_NAME
  bash $INSTALL_DIR/run_promgeflow.sh {PARAMS}
EOF
