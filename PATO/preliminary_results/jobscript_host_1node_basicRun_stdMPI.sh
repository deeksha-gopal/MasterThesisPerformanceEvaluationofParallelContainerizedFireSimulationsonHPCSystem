#!/bin/bash
#SBATCH --job-name=pato_host_clean
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=12
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

set -e
set -o pipefail

SRC_CASE="/beegfs/gopal/pato/host/pato-3.1/tutorials/3D/ArcJet_cylinder_3D"

ROOT="/beegfs/gopal/pato/host/pato_host_${SLURM_JOB_ID}"
BASE_CASE="${ROOT}/base_case"
RUNS_DIR="${ROOT}/runs"
LOGS="${ROOT}/logs"

REGION="porousMat"
PROCS_LIST="2 4 6 8 10 12"

FOAM_INST_DIR="/beegfs/gopal/pato/host/OpenFOAM"
PATO_DIR="/beegfs/gopal/pato/host/pato-3.1"

mkdir -p "$BASE_CASE" "$RUNS_DIR" "$LOGS"

exec > >(stdbuf -oL -eL tee -a "$LOGS/console.log") 2>&1

echo "==> Host: $(hostname)"
echo "==> Date: $(date)"
echo "==> Source case: $SRC_CASE"
echo "==> Root: $ROOT"
echo "==> Processor list: $PROCS_LIST"

echo "==> Loading modules"
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

echo "==> Sourcing OpenFOAM and PATO"
SOURCE_LOG="$LOGS/source_env.log"

set +e
source "$FOAM_INST_DIR/OpenFOAM-7/etc/bashrc" >> "$SOURCE_LOG" 2>&1
S1=$?
source "$PATO_DIR/bashrc" >> "$SOURCE_LOG" 2>&1
S2=$?
set -e

echo "OpenFOAM source rc=$S1"
echo "PATO source rc=$S2"

if [ "$S1" -ne 0 ] || [ "$S2" -ne 0 ]; then
    echo "ERROR: failed to source OpenFOAM/PATO"
    tail -n 100 "$SOURCE_LOG"
    exit 1
fi

unset FOAM_SIGFPE
export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close

echo "==> Environment check"
echo "blockMesh:    $(command -v blockMesh || true)"
echo "checkMesh:    $(command -v checkMesh || true)"
echo "decomposePar: $(command -v decomposePar || true)"
echo "PATOx:        $(command -v PATOx || true)"
echo "mpirun:       $(command -v mpirun || true)"
foamVersion || true

if ! command -v blockMesh >/dev/null 2>&1; then echo "ERROR: blockMesh not found"; exit 2; fi
if ! command -v checkMesh >/dev/null 2>&1; then echo "ERROR: checkMesh not found"; exit 3; fi
if ! command -v decomposePar >/dev/null 2>&1; then echo "ERROR: decomposePar not found"; exit 4; fi
if [ ! -x "$PATO_DIR/install/bin/PATOx" ]; then echo "ERROR: PATOx not found"; exit 5; fi

echo "==> Copying tutorial case to base case"
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

echo "==> Running base mesh check"
cd "$BASE_CASE"

blockMesh -region "$REGION" \
    > "$BASE_CASE/logs/log.blockMesh.$REGION" \
    2> "$BASE_CASE/logs/err.blockMesh.$REGION"

checkMesh -region "$REGION" \
    > "$BASE_CASE/logs/log.checkMesh.$REGION" \
    2> "$BASE_CASE/logs/err.checkMesh.$REGION"

cp -a "$BASE_CASE/logs" "$LOGS/base_mesh_logs"

echo "==> Mesh info"
grep "nCells" "$BASE_CASE/logs/log.blockMesh.$REGION" || true

SOLVER_PATH="$PATO_DIR/install/bin/PATOx"

for N in $PROCS_LIST; do
    echo "======================================"
    echo "Running N=$N"
    echo "======================================"

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

    {
        echo "Host: $(hostname)"
        echo "Date: $(date)"
        echo "N=$N"
        echo "FOAM_INST_DIR=$FOAM_INST_DIR"
        echo "PATO_DIR=$PATO_DIR"
        echo "blockMesh=$(command -v blockMesh || true)"
        echo "decomposePar=$(command -v decomposePar || true)"
        echo "PATOx=$SOLVER_PATH"
        echo "mpirun=$(command -v mpirun || true)"
        echo -n "foamVersion: "
        foamVersion || true
    } > "logs/run.info" 2>&1

    echo "==> decomposePar -region $REGION N=$N"
    decomposePar -region "$REGION" \
        > "logs/log.decompose.$REGION.$N" \
        2> "logs/err.decompose.$REGION.$N"

    echo "==> mpirun -np $N PATOx -parallel"
    mpirun -np "$N" "$SOLVER_PATH" -parallel -case . \
        > "logs/log.${N}proc" \
        2> "logs/err.${N}proc"

    cp -a "$RUN_CASE/logs" "$LOGS/logs_N${N}"

    echo "==== Done N=$N ===="
done

echo "==> Finished all host runs"
echo "==> Root folder: $ROOT"

echo
echo "Check summary:"
echo "ROOT=$ROOT"
echo 'for N in 2 4 6 8 10 12; do'
echo '  LOG=$ROOT/runs/case_N${N}/logs/log.${N}proc'
echo '  echo "===== N=$N ====="'
echo '  grep "runTime =" "$LOG" | tail -n 1'
echo '  echo -n "runTime outputs: "; grep -c "runTime =" "$LOG"'
echo '  grep "ExecutionTime" "$LOG" | tail -n 1'
echo '  echo -n "nCells: "; grep "nCells" "$ROOT/base_case/logs/log.blockMesh.porousMat"'
echo '  grep -i "fatal\|nan\|segmentation" "$LOG" || echo "No fatal/nan/segmentation"'
echo '  echo'
echo 'done'
