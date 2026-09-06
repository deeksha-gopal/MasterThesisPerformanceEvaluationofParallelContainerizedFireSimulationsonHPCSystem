#!/bin/bash
#SBATCH --job-name=pato_host_multinode_clean
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=2
#SBATCH --ntasks=32
#SBATCH --ntasks-per-node=16
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

set -e
set -o pipefail

SRC_CASE="/beegfs/gopal/pato/host/pato-3.1/tutorials/3D/ArcJet_cylinder_3D"

ROOT="/beegfs/gopal/pato/host/pato_host_clean_2node_32proc_${SLURM_JOB_ID}"
BASE_CASE="${ROOT}/base_case"
RUNS_DIR="${ROOT}/runs"
LOGS="${ROOT}/logs"

REGION="porousMat"
PROCS_LIST="2 4 6 8 10 12 16 20 24 32"

FOAM_INST_DIR="/beegfs/gopal/pato/host/OpenFOAM"
PATO_DIR="/beegfs/gopal/pato/host/pato-3.1"

mkdir -p "$BASE_CASE" "$RUNS_DIR" "$LOGS"

exec > >(stdbuf -oL -eL tee -a "$LOGS/console.log") 2>&1

echo "==> Host: $(hostname)"
echo "==> Date: $(date)"
echo "==> Root: $ROOT"
echo "==> Processor list: $PROCS_LIST"
echo "==> SLURM nodes:"
scontrol show hostnames "$SLURM_JOB_NODELIST" | tee "$LOGS/nodes.txt"

HOSTFILE="$LOGS/hostfile"
rm -f "$HOSTFILE"

while read -r NODE; do
    echo "${NODE} slots=${SLURM_NTASKS_PER_NODE}" >> "$HOSTFILE"
done < "$LOGS/nodes.txt"

echo "==> Hostfile:"
cat "$HOSTFILE"

module purge
module load 2022a
module load gompi/2022a CMake
module load M4 2>/dev/null || module load gm4 2>/dev/null || true

export WM_MPLIB=SYSTEMOPENMPI
export WM_COMPILER=Gcc
export FOAM_INST_DIR="$FOAM_INST_DIR"
export PATO_DIR="$PATO_DIR"

export ZSH_NAME=""
export WM_PROJECT_SITE=""
export WM_PROJECT_USER_DIR="/beegfs/gopal/pato/host/.foam_user"
export FOAM_USER_APPBIN="/beegfs/gopal/pato/host/.foam_user_appbin"
mkdir -p "$WM_PROJECT_USER_DIR" "$FOAM_USER_APPBIN"

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close

echo "==> Sourcing OpenFOAM and PATO"
SOURCE_LOG="$LOGS/source_env.log"

set +e
source "$FOAM_INST_DIR/OpenFOAM-7/etc/bashrc" >> "$SOURCE_LOG" 2>&1
S1=$?
source "$PATO_DIR/bashrc" >> "$SOURCE_LOG" 2>&1
S2=$?
set -e

if [ "$S1" -ne 0 ] || [ "$S2" -ne 0 ]; then
    echo "ERROR: failed to source OpenFOAM/PATO"
    tail -n 100 "$SOURCE_LOG"
    exit 1
fi

unset FOAM_SIGFPE

SOLVER_PATH="$PATO_DIR/install/bin/PATOx"

echo "blockMesh:    $(command -v blockMesh || true)"
echo "checkMesh:    $(command -v checkMesh || true)"
echo "decomposePar: $(command -v decomposePar || true)"
echo "PATOx:        $SOLVER_PATH"
echo "mpirun:       $(command -v mpirun || true)"

if ! command -v blockMesh >/dev/null 2>&1; then echo "ERROR: blockMesh not found"; exit 2; fi
if ! command -v checkMesh >/dev/null 2>&1; then echo "ERROR: checkMesh not found"; exit 3; fi
if ! command -v decomposePar >/dev/null 2>&1; then echo "ERROR: decomposePar not found"; exit 4; fi
if [ ! -x "$SOLVER_PATH" ]; then echo "ERROR: PATOx not found"; exit 5; fi

echo "==> Copying tutorial case"
cp -a "$SRC_CASE/." "$BASE_CASE/"

echo "==> Generating blockMeshDict with m4"
mkdir -p "$BASE_CASE/constant/$REGION/polyMesh"
m4 "$BASE_CASE/cylinderMesh.m4" > "$BASE_CASE/constant/$REGION/polyMesh/blockMeshDict"

if grep -q "changecom(" "$BASE_CASE/constant/$REGION/polyMesh/blockMeshDict"; then
    echo "ERROR: blockMeshDict contains changecom(. Do not use m4 -P."
    exit 6
fi

echo "==> Preparing base 0 directory"
rm -rf "$BASE_CASE/0"
cp -r "$BASE_CASE/origin.0" "$BASE_CASE/0"

mkdir -p "$BASE_CASE/logs"

cd "$BASE_CASE"

echo "==> Running base mesh check"
blockMesh -region "$REGION" > "$BASE_CASE/logs/log.blockMesh.$REGION" 2> "$BASE_CASE/logs/err.blockMesh.$REGION"
checkMesh -region "$REGION" > "$BASE_CASE/logs/log.checkMesh.$REGION" 2> "$BASE_CASE/logs/err.checkMesh.$REGION"

cp -a "$BASE_CASE/logs" "$LOGS/base_mesh_logs"

for N in $PROCS_LIST; do
    echo "======================================"
    echo "Running N=$N"
    echo "======================================"

    if [ $((N % SLURM_JOB_NUM_NODES)) -ne 0 ]; then
        echo "Skipping N=$N because not divisible by nodes=$SLURM_JOB_NUM_NODES"
        continue
    fi

    PPN=$((N / SLURM_JOB_NUM_NODES))

    RUN_CASE="${RUNS_DIR}/case_N${N}"

    rm -rf "$RUN_CASE"
    mkdir -p "$RUN_CASE"

    cp -a "$BASE_CASE/." "$RUN_CASE/"

    cd "$RUN_CASE"

    rm -rf processor* postProcessing logs
    mkdir -p logs

    rm -rf 0
    cp -r origin.0 0

    mkdir -p "system/$REGION"

    cat > system/decomposeParDict <<EOF
FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      decomposeParDict;
}

numberOfSubdomains $N;

method scotch;
EOF

    cp system/decomposeParDict "system/$REGION/decomposeParDict"

    echo "==> decomposePar -region $REGION N=$N"
    decomposePar -region "$REGION" > "logs/log.decompose.$REGION.$N" 2> "logs/err.decompose.$REGION.$N"

    echo "==> Running host PATOx N=$N, PPN=$PPN"

    START_TIME=$(date +%s)

    mpirun \
        --hostfile "$HOSTFILE" \
        --map-by ppr:${PPN}:node \
        --bind-to core \
        -np "$N" \
        "$SOLVER_PATH" -parallel -case . \
        > "logs/log.${N}proc" 2> "logs/err.${N}proc"

    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))

    {
        echo ""
        echo "=============================="
        echo "Timing information"
        echo "N = $N"
        echo "Nodes = $SLURM_JOB_NUM_NODES"
        echo "Ranks per node = $PPN"
        echo "Decomposition = scotch"
        echo "Elapsed wall time = ${ELAPSED} s"
        echo "=============================="
    } >> "logs/log.${N}proc"

    cp -a "$RUN_CASE/logs" "$LOGS/logs_N${N}"

    echo "==== Done N=$N ===="
done

echo "==> Finished all PATO host multi-node runs"
echo "==> Root folder: $ROOT"
