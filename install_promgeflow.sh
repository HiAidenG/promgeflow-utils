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
#   ./install_progmgeflow.sh [INSTALL_DIR]
# Default INSTALL_DIR is "promgeflow" in the current working directory.

set -euo pipefail

INSTALL_DIR="${1:-promgeflow}"
ENV_NAME="${PROMGE_ENV:-promgeflow}"
NEXTFLOW_VERSION="25.10.4"
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
# 1. Clone the repository into $INSTALL_DIR/proMGEflow
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
# 2. Conda env with nextflow
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
    if [[ "$current_version" != "$NEXTFLOW_VERSION" ]]; then
        echo "[promgeflow] nextflow is '${current_version:-missing}', installing $NEXTFLOW_VERSION"
        conda install -y -n "$ENV_NAME" -c bioconda -c conda-forge "nextflow=$NEXTFLOW_VERSION"
    fi
else
    echo "[promgeflow] creating conda env '$ENV_NAME' with nextflow=$NEXTFLOW_VERSION"
    conda create -y -n "$ENV_NAME" -c bioconda -c conda-forge "nextflow=$NEXTFLOW_VERSION"
fi

# ---------------------------------------------------------------------------
# 2b. reCOGnise conda env (replaces the unreliable ghcr.io/grp-bork/recognise
#     container). Built here on the login node because the env's pip layer
#     git-clones reCOGnise — compute nodes don't have git.
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

# Sanity check: the entry points the nextflow processes will invoke.
for bin in recognise prodigal mapseq fetchMGs; do
    if [[ ! -x "$RECOGNISE_ENV_PREFIX/bin/$bin" ]]; then
        echo "[promgeflow] WARNING: $bin not found in $RECOGNISE_ENV_PREFIX/bin" >&2
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
recognise_marker_db: "$INSTALL_DIR/recognise_markers"
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

if command -v sbatch >/dev/null 2>&1; then
    echo "[promgeflow] submitting database download job"
    sbatch "$SBATCH_SCRIPT"
else
    echo "[promgeflow] sbatch not found; run the download script manually:"
    echo "             sbatch $SBATCH_SCRIPT"
fi

cat <<EOF

  install:       $INSTALL_DIR
  repo:          $REPO_DIR
  databases:     $INSTALL_DIR/{emapper_db,conjscan_models,recombinase_models,recognise_markers,cluster_ref_seqs}
                 (downloads running via SLURM)
  params:        $PARAMS_FILE
  recognise env: $RECOGNISE_ENV_PREFIX
  logs:          $LOG_DIR

To run the workflow once databases finish:
  module load devel/miniforge
  module load system/singularity/3.11.3
  conda activate $ENV_NAME
  bash $INSTALL_DIR/run_promgeflow.sh {PARAMS}
EOF
