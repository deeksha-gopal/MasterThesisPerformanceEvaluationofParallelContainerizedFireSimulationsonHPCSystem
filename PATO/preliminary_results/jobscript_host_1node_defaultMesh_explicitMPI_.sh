#!/bin/bash
#SBATCH --job-name=pato_host_benchmark
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=50
#SBATCH --ntasks-per-node=50
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

# 1 node:
# sbatch --nodes=1 --ntasks=50 \
#        --ntasks-per-node=50 \
#        pato_host_benchmark.sh
#
# 2 nodes:
# sbatch --nodes=2 --ntasks=100 \
#        --ntasks-per-node=50 \
#        pato_host_benchmark.sh
#
# 4 nodes:
# sbatch --nodes=4 --ntasks=200 \
#        --ntasks-per-node=50 \
#        pato_host_benchmark.sh

set -e
set -o pipefail

# USER SETTINGS
HOST_DIR="/beegfs/gopal/new/pato/host"

FOAM_BASE="${HOST_DIR}/OpenFOAM"
OPENFOAM_DIR="${FOAM_BASE}/OpenFOAM-7"
THIRDPARTY_DIR="${FOAM_BASE}/ThirdParty-7"

PATO_INSTALL_DIR="${HOST_DIR}/pato-3.1"

SRC_CASE="${PATO_INSTALL_DIR}/tutorials/3D/ArcJet_cylinder_3D"

REGION="porousMat"

EXPECTED_CELLS=30000

END_TIME="0.075"
DELTA_T="0.00075"
WRITE_INTERVAL="100"

# SLURM INFORMATION
NODES="${SLURM_JOB_NUM_NODES:-1}"

TASKS_PER_NODE="${SLURM_NTASKS_PER_NODE:-50}"

TASKS_PER_NODE="${TASKS_PER_NODE%%(*}"

ALLOCATED_TASKS="$(
    printf "%s" "${SLURM_NTASKS:-$((NODES * TASKS_PER_NODE))}"
)"

# PROCESSOR LIST
case "$NODES" in

    1)
        PROCS_LIST="2 4 8 10 16 20 25 32 40 50"
        ;;

    2)
        PROCS_LIST="2 4 8 10 16 20 32 40 50 64 80 100"
        ;;

    4)
        PROCS_LIST="4 8 16 20 32 40 64 80 100 128 160 200"
        ;;

    *)
        echo "ERROR: Only 1, 2, or 4 nodes are supported." >&2
        exit 1
        ;;
esac

# OUTPUT DIRECTORIES
RESULT_ROOT="${HOST_DIR}/results"

ROOT="${RESULT_ROOT}/ArcJet_cylinder_3D_host_${NODES}node_${SLURM_JOB_ID}"

BASE_CASE="${ROOT}/base_case"
RUNS_DIR="${ROOT}/runs"
LOGS_DIR="${ROOT}/logs"

SUMMARY_FILE="${ROOT}/timing_summary.tsv"

# HELPER FUNCTIONS
die()
{
    echo >&2
    echo "ERROR: $*" >&2
    echo >&2
    exit 1
}


require_file()
{
    [ -f "$1" ] || die "Required file not found: $1"
}


require_dir()
{
    [ -d "$1" ] || die "Required directory not found: $1"
}


require_command()
{
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}


show_failure_logs()
{
    local stdout_file="$1"
    local stderr_file="$2"

    echo
    echo "------------------------------------------------------------"
    echo "Command stdout"
    echo "------------------------------------------------------------"

    if [ -s "$stdout_file" ]; then
        tail -n 150 "$stdout_file" || true
    else
        echo "No stdout was written to:"
        echo "$stdout_file"
    fi

    echo
    echo "------------------------------------------------------------"
    echo "Command stderr"
    echo "------------------------------------------------------------"

    if [ -s "$stderr_file" ]; then
        tail -n 150 "$stderr_file" || true
    else
        echo "No stderr was written to:"
        echo "$stderr_file"
    fi

    echo "------------------------------------------------------------"
}

# VALIDATE PROCESSOR LIST
MAX_RANKS=0

for N in $PROCS_LIST; do

    case "$N" in
        ''|*[!0-9]*)
            die "Invalid MPI rank count in PROCS_LIST: $N"
            ;;
    esac

    [ "$N" -gt 0 ] ||
        die "MPI rank count must be greater than zero: $N"

    [ $((N % NODES)) -eq 0 ] ||
        die "$N MPI ranks are not divisible by $NODES nodes."

    if [ "$N" -gt "$MAX_RANKS" ]; then
        MAX_RANKS="$N"
    fi

done


[ "$MAX_RANKS" -le "$ALLOCATED_TASKS" ] ||
    die "Largest run requires $MAX_RANKS tasks, but the allocation has only $ALLOCATED_TASKS tasks."

rm -rf "$ROOT"

mkdir -p \
    "$BASE_CASE" \
    "$RUNS_DIR" \
    "$LOGS_DIR"


# Send normal script output to both:
#
# 1. Slurm output file
# 2. results/.../logs/console.log

exec > >(
    stdbuf -oL -eL tee -a "$LOGS_DIR/console.log"
) 2>&1

echo "============================================================"
echo "PATO-3.1 host MPI benchmark"
echo "============================================================"
echo "Date:                $(date)"
echo "Launch host:         $(hostname)"
echo "SLURM job ID:        ${SLURM_JOB_ID:-not-set}"
echo "SLURM node list:     ${SLURM_JOB_NODELIST:-not-set}"
echo "Nodes:               $NODES"
echo "Allocated tasks:     $ALLOCATED_TASKS"
echo "Tasks per node:      $TASKS_PER_NODE"
echo "Largest MPI run:     $MAX_RANKS"
echo "Processor list:      $PROCS_LIST"
echo
echo "OpenFOAM:            $OPENFOAM_DIR"
echo "ThirdParty:          $THIRDPARTY_DIR"
echo "PATO:                $PATO_INSTALL_DIR"
echo "Tutorial:            $SRC_CASE"
echo "Region:              $REGION"
echo
echo "Expected cells:      $EXPECTED_CELLS"
echo "endTime:             $END_TIME"
echo "deltaT:              $DELTA_T"
echo "writeInterval:       $WRITE_INTERVAL"
echo
echo "Results:             $ROOT"
echo "============================================================"


echo
echo "Allocated compute nodes:"

if [ -n "${SLURM_JOB_NODELIST:-}" ]; then
    scontrol show hostnames "$SLURM_JOB_NODELIST" || true
else
    echo "SLURM_JOB_NODELIST is not set."
fi

# LOAD MODULES
echo
echo "==> Loading software modules"

module purge

module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5
module load CMake

module load M4 2>/dev/null ||
    module load gm4 2>/dev/null ||
    true

echo
module list 2>&1 || true

# VALIDATE INSTALLATION PATHS
require_dir "$OPENFOAM_DIR"
require_dir "$THIRDPARTY_DIR"
require_dir "$PATO_INSTALL_DIR"
require_dir "$SRC_CASE"

require_file "$OPENFOAM_DIR/etc/bashrc"
require_file "$PATO_INSTALL_DIR/bashrc"

# SOURCE OPENFOAM AND PATO
export FOAM_INST_DIR="$FOAM_BASE"
export WM_PROJECT_INST_DIR="$FOAM_BASE"
export WM_PROJECT_DIR="$OPENFOAM_DIR"
export WM_THIRD_PARTY_DIR="$THIRDPARTY_DIR"

export WM_COMPILER_TYPE=system
export WM_COMPILER=Gcc
export WM_MPLIB=SYSTEMOPENMPI
export WM_PRECISION_OPTION=DP
export WM_LABEL_SIZE=32
export WM_COMPILE_OPTION=Opt

export PATO_DIR="$PATO_INSTALL_DIR"
export BUILD_DOCUMENTATION="no"

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close
export OMP_PLACES=cores

SOURCE_LOG="$LOGS_DIR/source_environment.log"

echo
echo "==> Sourcing OpenFOAM and PATO"

set +e
set +u
set +o pipefail

# shellcheck disable=SC1090
source "$OPENFOAM_DIR/etc/bashrc" \
    >> "$SOURCE_LOG" 2>&1

OPENFOAM_RC=$?

export PATO_DIR="$PATO_INSTALL_DIR"

# shellcheck disable=SC1090
source "$PATO_INSTALL_DIR/bashrc" \
    >> "$SOURCE_LOG" 2>&1

PATO_RC=$?

set -u
set -e
set -o pipefail

echo "OpenFOAM source return code: $OPENFOAM_RC"
echo "PATO source return code:     $PATO_RC"

if [ "$OPENFOAM_RC" -ne 0 ] || [ "$PATO_RC" -ne 0 ]; then

    echo
    echo "Last 150 lines of source log:"
    tail -n 150 "$SOURCE_LOG" || true

    die "Failed to source the OpenFOAM/PATO environment."
fi


# Restore required variables because sourced files can modify them.

export FOAM_INST_DIR="$FOAM_BASE"
export WM_PROJECT_INST_DIR="$FOAM_BASE"
export WM_PROJECT_DIR="$OPENFOAM_DIR"
export WM_THIRD_PARTY_DIR="$THIRDPARTY_DIR"

export WM_COMPILER_TYPE=system
export WM_COMPILER=Gcc
export WM_MPLIB=SYSTEMOPENMPI
export WM_PRECISION_OPTION=DP
export WM_LABEL_SIZE=32
export WM_COMPILE_OPTION=Opt

export PATO_DIR="$PATO_INSTALL_DIR"

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close
export OMP_PLACES=cores

unset FOAM_SIGFPE 2>/dev/null || true

# VALIDATE REQUIRED COMMANDS
for CMD in \
    gcc \
    g++ \
    python3 \
    mpirun \
    ompi_info \
    m4 \
    blockMesh \
    checkMesh \
    decomposePar \
    PATOx
do
    require_command "$CMD"
done

# CHECK COMPILER AND MPI VERSIONS
GCC_VERSION="$(gcc -dumpfullversion 2>/dev/null || gcc -dumpversion)"

MPI_VERSION="$(mpirun --version | sed -n '1p')"

case "$GCC_VERSION" in
    12.3.0*)
        ;;
    *)
        die "Expected GCC 12.3.0, but detected GCC $GCC_VERSION."
        ;;
esac

case "$MPI_VERSION" in
    *4.1.5*)
        ;;
    *)
        die "Expected OpenMPI 4.1.5, but detected: $MPI_VERSION"
        ;;
esac


SOLVER_PATH="$(command -v PATOx)"

[ -x "$SOLVER_PATH" ] ||
    die "PATOx is not executable: $SOLVER_PATH"


echo
echo "==> Active environment"
echo "gcc:             $(command -v gcc)"
echo "gcc version:     $GCC_VERSION"
echo "mpirun:          $(command -v mpirun)"
echo "MPI version:     $MPI_VERSION"
echo "m4:              $(command -v m4)"
echo "blockMesh:       $(command -v blockMesh)"
echo "checkMesh:       $(command -v checkMesh)"
echo "decomposePar:    $(command -v decomposePar)"
echo "PATOx:           $SOLVER_PATH"
echo "WM_OPTIONS:      ${WM_OPTIONS:-not-set}"
echo "WM_MPLIB:        ${WM_MPLIB:-not-set}"
echo "FOAM_MPI:        ${FOAM_MPI:-not-set}"
echo "OMP_NUM_THREADS: $OMP_NUM_THREADS"


{
    echo "Date=$(date)"
    echo "Job ID=${SLURM_JOB_ID:-not-set}"
    echo "Nodes=$NODES"
    echo "Allocated tasks=$ALLOCATED_TASKS"
    echo "Tasks per node=$TASKS_PER_NODE"
    echo "Processor list=$PROCS_LIST"
    echo "Maximum ranks=$MAX_RANKS"
    echo "GCC path=$(command -v gcc)"
    echo "GCC version=$GCC_VERSION"
    echo "MPI path=$(command -v mpirun)"
    echo "MPI version=$MPI_VERSION"
    echo "PATOx path=$SOLVER_PATH"
    echo "OpenFOAM=$OPENFOAM_DIR"
    echo "PATO=$PATO_INSTALL_DIR"
    echo "WM_OPTIONS=${WM_OPTIONS:-not-set}"
    echo "WM_MPLIB=${WM_MPLIB:-not-set}"
    echo "FOAM_MPI=${FOAM_MPI:-not-set}"
} > "$LOGS_DIR/environment.info"

# PREPARE CLEAN BASE CASE
echo
echo "==> Copying tutorial to the base-case directory"

cp -a "$SRC_CASE/." "$BASE_CASE/"


# Remove files copied from old tutorial executions. These files are not related to the current Slurm job and can otherwise be confusing.

rm -rf \
    "$BASE_CASE"/processor* \
    "$BASE_CASE"/postProcessing \
    "$BASE_CASE"/logs

find "$BASE_CASE" \
    -maxdepth 1 \
    -type f \
    \( \
        -name 'log.*' \
        -o -name '*.out' \
        -o -name '*.err' \
    \) \
    -delete


CONTROL_DICT="$BASE_CASE/system/controlDict"
M4_FILE="$BASE_CASE/cylinderMesh.m4"

require_file "$CONTROL_DICT"
require_file "$M4_FILE"
require_dir "$BASE_CASE/origin.0"

# UPDATE controlDict
echo
echo "==> Updating controlDict"

python3 - \
    "$CONTROL_DICT" \
    "$END_TIME" \
    "$DELTA_T" \
    "$WRITE_INTERVAL" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])

end_time = sys.argv[2]
delta_t = sys.argv[3]
write_interval = sys.argv[4]

text = path.read_text()


def replace_required(keyword: str, value: str) -> None:
    global text

    pattern = (
        rf"(?m)^[ \t]*{re.escape(keyword)}"
        rf"[ \t]+[^;]+;"
    )

    replacement = f"{keyword:<18}{value};"

    text, count = re.subn(
        pattern,
        replacement,
        text,
        count=1,
    )

    if count != 1:
        raise SystemExit(
            f"ERROR: Expected exactly one '{keyword}' entry "
            f"in {path}; found {count}."
        )


replace_required("endTime", end_time)
replace_required("deltaT", delta_t)
replace_required("writeInterval", write_interval)

adjust_pattern = (
    r"(?m)^[ \t]*adjustTimeStep"
    r"[ \t]+[^;]+;"
)

if re.search(adjust_pattern, text):
    text = re.sub(
        adjust_pattern,
        f"{'adjustTimeStep':<18}no;",
        text,
        count=1,
    )

path.write_text(text)
PY


echo
echo "controlDict benchmark settings:"

grep -nE \
    '^[[:space:]]*(endTime|deltaT|writeInterval|adjustTimeStep)[[:space:]]' \
    "$CONTROL_DICT" ||
    true

# GENERATE AND CHECK BASE MESH
echo
echo "==> Generating blockMeshDict with m4"

mkdir -p "$BASE_CASE/constant/$REGION/polyMesh"

m4 "$M4_FILE" \
    > "$BASE_CASE/constant/$REGION/polyMesh/blockMeshDict"


if grep -q 'changecom(' \
    "$BASE_CASE/constant/$REGION/polyMesh/blockMeshDict"
then
    die "Generated blockMeshDict contains unexpanded m4 directives."
fi


rm -rf "$BASE_CASE/0"
cp -a "$BASE_CASE/origin.0" "$BASE_CASE/0"

mkdir -p "$BASE_CASE/logs"

cd "$BASE_CASE"


BLOCKMESH_LOG="$BASE_CASE/logs/log.blockMesh.$REGION"
BLOCKMESH_ERR="$BASE_CASE/logs/err.blockMesh.$REGION"

echo
echo "==> Running blockMesh -region $REGION"

set +e

blockMesh -region "$REGION" \
    > "$BLOCKMESH_LOG" \
    2> "$BLOCKMESH_ERR"

BLOCKMESH_RC=$?

set -e

echo "blockMesh return code: $BLOCKMESH_RC"

if [ "$BLOCKMESH_RC" -ne 0 ]; then
    show_failure_logs "$BLOCKMESH_LOG" "$BLOCKMESH_ERR"
    die "blockMesh failed for region $REGION."
fi


CHECKMESH_LOG="$BASE_CASE/logs/log.checkMesh.$REGION"
CHECKMESH_ERR="$BASE_CASE/logs/err.checkMesh.$REGION"

echo
echo "==> Running checkMesh -region $REGION"

set +e

checkMesh -region "$REGION" \
    > "$CHECKMESH_LOG" \
    2> "$CHECKMESH_ERR"

CHECKMESH_RC=$?

set -e

echo "checkMesh return code: $CHECKMESH_RC"

if [ "$CHECKMESH_RC" -ne 0 ]; then
    show_failure_logs "$CHECKMESH_LOG" "$CHECKMESH_ERR"
    die "checkMesh failed for region $REGION."
fi

# DETECT NUMBER OF CELLS
MESH_CELLS="$(
    awk '
        /nCells:/ {
            value=$2
        }

        END {
            print value
        }
    ' "$BLOCKMESH_LOG"
)"


if [ -z "$MESH_CELLS" ]; then

    MESH_CELLS="$(
        awk '
            /^[[:space:]]*cells:/ {
                value=$2
            }

            END {
                print value
            }
        ' "$CHECKMESH_LOG"
    )"

fi


echo
echo "Detected mesh cells: ${MESH_CELLS:-unknown}"


if [ "${MESH_CELLS:-}" != "$EXPECTED_CELLS" ]; then

    echo
    echo "ERROR: Incorrect mesh size."
    echo "Expected cells: $EXPECTED_CELLS"
    echo "Detected cells: ${MESH_CELLS:-unknown}"
    echo
    echo "Inspect:"
    echo "  $BLOCKMESH_LOG"
    echo "  $CHECKMESH_LOG"

    exit 20
fi


cp -a \
    "$BASE_CASE/logs" \
    "$LOGS_DIR/base_mesh_logs"

# CREATE SUMMARY FILE
printf \
    "nodes\tranks\tranks_per_node\tcells\tcells_per_rank\telapsed_seconds\texit_code\tstatus\tcase_directory\n" \
    > "$SUMMARY_FILE"

# RUN BENCHMARKS
for N in $PROCS_LIST; do

    echo
    echo "============================================================"
    echo "Running PATO host benchmark"
    echo "Nodes:      $NODES"
    echo "MPI ranks:  $N"
    echo "============================================================"

    PPN=$((N / NODES))

    [ "$PPN" -gt 0 ] ||
        die "Calculated ranks per node is zero for N=$N."

    [ "$PPN" -le "$TASKS_PER_NODE" ] ||
        die "$N ranks require $PPN ranks/node, but the allocation permits only $TASKS_PER_NODE ranks/node."


    RUN_CASE="$RUNS_DIR/case_N${N}"

    rm -rf "$RUN_CASE"
    mkdir -p "$RUN_CASE"

    cp -a "$BASE_CASE/." "$RUN_CASE/"

    cd "$RUN_CASE"

    rm -rf \
        processor* \
        postProcessing \
        logs

    mkdir -p logs

    find . \
        -maxdepth 1 \
        -type f \
        \( \
            -name 'log.*' \
            -o -name '*.out' \
            -o -name '*.err' \
        \) \
        -delete


    rm -rf 0
    cp -a origin.0 0

    # WRITE decomposeParDict
    mkdir -p "system/$REGION"

    cat > system/decomposeParDict <<EOF
FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    location    "system";
    object      decomposeParDict;
}

numberOfSubdomains $N;

method          scotch;

distributed     no;

roots           ();
EOF


    cp \
        system/decomposeParDict \
        "system/$REGION/decomposeParDict"

    # WRITE RUN INFORMATION
    CELLS_PER_RANK="$(
        awk \
            -v cells="$MESH_CELLS" \
            -v ranks="$N" \
            'BEGIN {
                printf "%.3f", cells / ranks
            }'
    )"


    {
        echo "Date=$(date)"
        echo "SLURM_JOB_ID=${SLURM_JOB_ID:-not-set}"
        echo "Nodes=$NODES"
        echo "Allocated tasks=$ALLOCATED_TASKS"
        echo "Allocated tasks per node=$TASKS_PER_NODE"
        echo "MPI ranks=$N"
        echo "MPI ranks per node=$PPN"
        echo "Mesh cells=$MESH_CELLS"
        echo "Cells per rank=$CELLS_PER_RANK"
        echo "Region=$REGION"
        echo "Decomposition=scotch"
        echo "Solver=$SOLVER_PATH"
        echo "OpenFOAM=$OPENFOAM_DIR"
        echo "PATO=$PATO_INSTALL_DIR"
        echo "MPI PML=ob1"
        echo "MPI BTL=self,vader,tcp"
        echo "MPI mapping=ppr:${PPN}:node:PE=1"
        echo "MPI ranking=OpenMPI default"
        echo "MPI binding=core"
        echo
        echo "Allocated hosts:"

        if [ -n "${SLURM_JOB_NODELIST:-}" ]; then
            scontrol show hostnames "$SLURM_JOB_NODELIST" ||
                true
        else
            echo "SLURM_JOB_NODELIST is not set."
        fi

    } > logs/run.info


    echo
    echo "Run directory:       $RUN_CASE"
    echo "Ranks:               $N"
    echo "Ranks per node:      $PPN"
    echo "Cells per rank:      $CELLS_PER_RANK"
    echo "Region variable:     <$REGION>"
    echo "Solver path:         $SOLVER_PATH"
    echo "Decomposition file:  system/$REGION/decomposeParDict"

    # DECOMPOSE REGION
    DECOMP_LOG="logs/log.decompose.${REGION}.${N}"
    DECOMP_ERR="logs/err.decompose.${REGION}.${N}"

    echo
    echo "==> Running:"
    echo "decomposePar -region \"$REGION\""

    rm -rf processor*

    set +e

    decomposePar -region "$REGION" \
        > "$DECOMP_LOG" \
        2> "$DECOMP_ERR"

    DECOMP_RC=$?

    set -e

    echo "decomposePar return code: $DECOMP_RC"


    if [ "$DECOMP_RC" -ne 0 ]; then

        show_failure_logs \
            "$DECOMP_LOG" \
            "$DECOMP_ERR"

        cp -a \
            "$RUN_CASE/logs" \
            "$LOGS_DIR/logs_N${N}_decompose_failed"

        die "decomposePar failed for N=$N and region $REGION."
    fi


    PROCESSOR_COUNT="$(
        find . \
            -maxdepth 1 \
            -type d \
            -name 'processor[0-9]*' \
            | wc -l
    )"

    PROCESSOR_COUNT="$(
        printf "%s" "$PROCESSOR_COUNT" |
        tr -d '[:space:]'
    )"

    echo "Processor directories created: $PROCESSOR_COUNT"


    [ "$PROCESSOR_COUNT" -eq "$N" ] ||
        die "decomposePar created $PROCESSOR_COUNT processor directories; expected $N."


    # TEST MPI RANK PLACEMENT
    RANK_LOG="logs/rank_distribution.$N"
    RANK_ERR="logs/rank_distribution.$N.err"
    RANK_SUMMARY="logs/rank_distribution_summary.$N"

    echo
    echo "==> Testing MPI rank placement"

    echo "mpirun \\"
    echo "  --mca pml ob1 \\"
    echo "  --mca btl self,vader,tcp \\"
    echo "  --map-by \"ppr:${PPN}:node:PE=1\" \\"
    echo "  --bind-to core \\"
    echo "  -np \"$N\" hostname"


    set +e

    mpirun \
        --mca pml ob1 \
        --mca btl self,vader,tcp \
        --map-by "ppr:${PPN}:node:PE=1" \
        --bind-to core \
        -np "$N" \
        hostname \
        > "$RANK_LOG" \
        2> "$RANK_ERR"

    RANK_RC=$?

    set -e

    echo "MPI rank-placement return code: $RANK_RC"


    if [ "$RANK_RC" -ne 0 ]; then

        show_failure_logs \
            "$RANK_LOG" \
            "$RANK_ERR"

        cp -a \
            "$RUN_CASE/logs" \
            "$LOGS_DIR/logs_N${N}_placement_failed"

        die "MPI rank-placement test failed for N=$N."
    fi


    sort "$RANK_LOG" |
        uniq -c \
        > "$RANK_SUMMARY"


    echo
    echo "MPI rank distribution:"

    cat "$RANK_SUMMARY"


    HOST_COUNT="$(
        awk '
            NF >= 2 {
                count++
            }

            END {
                print count + 0
            }
        ' "$RANK_SUMMARY"
    )"


    [ "$HOST_COUNT" -eq "$NODES" ] ||
        die "MPI used $HOST_COUNT hosts; expected $NODES hosts."


    if ! awk \
        -v expected="$PPN" \
        '
            NF >= 2 && $1 != expected {
                bad=1
            }

            END {
                exit bad
            }
        ' "$RANK_SUMMARY"
    then
        die "MPI rank placement is not balanced for N=$N. Expected $PPN ranks on every node."
    fi


    echo "MPI rank placement passed."

    # RUN PATO
    SOLVER_LOG="logs/log.${N}proc"
    SOLVER_ERR="logs/err.${N}proc"

    echo
    echo "==> Starting PATOx"
    echo "Start time: $(date)"
    echo
    echo "Command:"
    echo "mpirun \\"
    echo "  --mca pml ob1 \\"
    echo "  --mca btl self,vader,tcp \\"
    echo "  --map-by \"ppr:${PPN}:node:PE=1\" \\"
    echo "  --bind-to core \\"
    echo "  -np \"$N\" \\"
    echo "  \"$SOLVER_PATH\" -parallel"
    echo


    START_NS="$(date +%s%N)"


    set +e

    mpirun \
        --mca pml ob1 \
        --mca btl self,vader,tcp \
        --map-by "ppr:${PPN}:node:PE=1" \
        --bind-to core \
        -np "$N" \
        "$SOLVER_PATH" \
        -parallel \
        > "$SOLVER_LOG" \
        2> "$SOLVER_ERR"

    RC=$?

    set -e


    END_NS="$(date +%s%N)"


    echo "PATOx mpirun return code: $RC"
    echo "PATOx finish time:        $(date)"


    ELAPSED="$(
        awk \
            -v start="$START_NS" \
            -v end="$END_NS" \
            'BEGIN {
                printf "%.6f", (end - start) / 1000000000
            }'
    )"


    if [ "$RC" -eq 0 ]; then
        STATUS="completed"
    else
        STATUS="failed"
    fi

    # RECORD TIMING
    {
        echo
        echo "============================================================"
        echo "Benchmark timing"
        echo "============================================================"
        echo "Nodes:              $NODES"
        echo "MPI ranks:          $N"
        echo "MPI ranks per node: $PPN"
        echo "Cells:              $MESH_CELLS"
        echo "Cells per rank:     $CELLS_PER_RANK"
        echo "Elapsed wall time:  $ELAPSED s"
        echo "Exit code:          $RC"
        echo "Status:             $STATUS"
        echo "============================================================"

    } | tee -a "$SOLVER_LOG"


    printf \
        "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$NODES" \
        "$N" \
        "$PPN" \
        "$MESH_CELLS" \
        "$CELLS_PER_RANK" \
        "$ELAPSED" \
        "$RC" \
        "$STATUS" \
        "$RUN_CASE" \
        >> "$SUMMARY_FILE"


    cp -a \
        "$RUN_CASE/logs" \
        "$LOGS_DIR/logs_N${N}"


    if [ "$RC" -ne 0 ]; then

        echo
        echo "ERROR: PATOx failed for N=$N."
        echo "Return code: $RC"
        echo
        echo "Solver stdout:"
        echo "  $RUN_CASE/$SOLVER_LOG"
        echo
        echo "Solver stderr:"
        echo "  $RUN_CASE/$SOLVER_ERR"

        show_failure_logs \
            "$SOLVER_LOG" \
            "$SOLVER_ERR"

        exit "$RC"
    fi


    echo
    echo "Completed N=$N in $ELAPSED seconds."

done

echo
echo "============================================================"
echo "All PATO host benchmark runs completed"
echo "============================================================"
echo "Results directory:"
echo "$ROOT"
echo
echo "Timing summary:"
echo "$SUMMARY_FILE"
echo


if command -v column >/dev/null 2>&1; then
    column -t -s $'\t' "$SUMMARY_FILE"
else
    cat "$SUMMARY_FILE"
fi


echo
echo "Finished: $(date)"
echo "============================================================"

exit 0
