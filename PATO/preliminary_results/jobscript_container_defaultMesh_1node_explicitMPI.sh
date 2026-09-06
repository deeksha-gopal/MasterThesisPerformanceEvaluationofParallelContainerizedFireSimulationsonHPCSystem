# The below code represents execution of PATO container with host software modules, with default mesh cells

#!/bin/bash
#SBATCH --job-name=pato_container_multinode
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=50
#SBATCH --ntasks-per-node=50
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

# Default: 2 nodes and 100 allocated tasks.
#
# Submit for 2 nodes:
# sbatch pato_container_multinode.sh
#
# Submit for 4 nodes:
# sbatch \
#     --nodes=4 \
#     --ntasks=200 \
#     --ntasks-per-node=50 \
#     pato_container_multinode.sh

set -e
set -o pipefail

# Fixed benchmark configuration
IMAGE="/beegfs/gopal/new/pato/pato_image.sif"

CASE_IN_IMAGE="/opt/pato-3.1/tutorials/3D/ArcJet_cylinder_3D"
PATO_BIN="/opt/pato-3.1/install/bin/PATOx"

REGION="porousMat"
EXPECTED_CELLS=30000

END_TIME="0.075"
DELTA_T="0.00075"

# One write after 100 fixed time steps:
# 0.075 / 0.00075 = 100
WRITE_INTERVAL="100"

RESULTS_ROOT="/beegfs/gopal/new/pato/results"

NODES="${SLURM_JOB_NUM_NODES:?SLURM_JOB_NUM_NODES is not set}"
ALLOCATED_TASKS="${SLURM_NTASKS:?SLURM_NTASKS is not set}"
TASKS_PER_NODE="${SLURM_NTASKS_PER_NODE:-50}"
JOB_ID="${SLURM_JOB_ID:-manual}"

# Select balanced rank lists
case "$NODES" in
    1)
        PROCS_LIST="2 4 8 10 12 16 20 24 32 40 50"
        ;;

    2)
        PROCS_LIST="2 4 8 10 12 16 20 24 32 40 50 64 80 100"
        ;;

    4)
        PROCS_LIST="4 8 12 16 20 24 32 40 48 64 80 100 128 160 200"
        ;;

    *)
        echo "ERROR: This script supports only 1-nodes 2-node and 4-node runs."
        echo "Detected number of nodes: $NODES"
        exit 1
        ;;
esac

# Output directories
ROOT="${RESULTS_ROOT}/ArcJet_cylinder_3D_container_${NODES}node_${JOB_ID}"
BASE_CASE="${ROOT}/base_case"
RUNS_DIR="${ROOT}/runs"
LOGS="${ROOT}/logs"
SUMMARY="${LOGS}/timing_summary.tsv"

mkdir -p \
    "$BASE_CASE" \
    "$RUNS_DIR" \
    "$LOGS"

exec > >(
    stdbuf -oL -eL tee -a "$LOGS/console.log"
) 2>&1

# Job information
echo "============================================================"
echo "PATO container benchmark"
echo "============================================================"
echo "Date:                 $(date)"
echo "Submission host:      $(hostname)"
echo "Job ID:               $JOB_ID"
echo "Nodes:                $NODES"
echo "Allocated tasks:      $ALLOCATED_TASKS"
echo "Tasks per node:       $TASKS_PER_NODE"
echo "Container image:      $IMAGE"
echo "Tutorial:             $CASE_IN_IMAGE"
echo "Solver:               $PATO_BIN"
echo "Mesh region:          $REGION"
echo "Expected cells:       $EXPECTED_CELLS"
echo "Decomposition:        scotch"
echo "endTime:              $END_TIME"
echo "deltaT:               $DELTA_T"
echo "Processor list:       $PROCS_LIST"
echo "Results directory:    $ROOT"
echo "============================================================"

# Load host HPC GCC and OpenMPI
if ! type module >/dev/null 2>&1; then
    if [[ -f /etc/profile.d/modules.sh ]]; then
        source /etc/profile.d/modules.sh
    else
        echo "ERROR: Environment Modules is unavailable."
        exit 2
    fi
fi

module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5

module load M4 2>/dev/null ||
module load gm4 2>/dev/null ||
true

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close
export OMP_PLACES=cores

echo
echo "Loaded modules:"
module list 2>&1 || true

echo
echo "Host compiler:"
echo "gcc: $(command -v gcc)"
gcc --version | sed -n '1p'

echo
echo "Host MPI:"
echo "mpirun: $(command -v mpirun)"
mpirun --version | sed -n '1p'

if ! mpirun --version |
    sed -n '1p' |
    grep -q "4.1.5"
then
    echo "ERROR: Expected OpenMPI 4.1.5."
    exit 3
fi

if [[ ! -f "$IMAGE" ]]; then
    echo "ERROR: Container image not found:"
    echo "$IMAGE"
    exit 4
fi

# Container environment initialization
read -r -d '' CONTAINER_INIT <<'EOF' || true
set +e
set +u
set +o pipefail

if [[ ! -f /opt/host_mpi_env.sh ]]; then
    echo "ERROR: /opt/host_mpi_env.sh is unavailable."
    exit 10
fi

. /opt/host_mpi_env.sh
MPI_ENV_RC=$?

export FOAM_INST_DIR=/opt/OpenFOAM
export WM_PROJECT_INST_DIR=/opt/OpenFOAM
export WM_PROJECT_DIR=/opt/OpenFOAM/OpenFOAM-7
export WM_THIRD_PARTY_DIR=/opt/OpenFOAM/ThirdParty-7

export WM_COMPILER_TYPE=system
export WM_COMPILER=Gcc
export WM_MPLIB=SYSTEMOPENMPI
export WM_PRECISION_OPTION=DP
export WM_LABEL_SIZE=32
export WM_COMPILE_OPTION=Opt

export PATO_DIR=/opt/pato-3.1
export PATO_BIN=/opt/pato-3.1/install/bin/PATOx

. /opt/OpenFOAM/OpenFOAM-7/etc/bashrc
OPENFOAM_RC=$?

. /opt/pato-3.1/bashrc
PATO_RC=$?

set -e
set -o pipefail

# Reassert the required build/runtime settings.
export WM_COMPILER_TYPE=system
export WM_COMPILER=Gcc
export WM_MPLIB=SYSTEMOPENMPI
export WM_PRECISION_OPTION=DP
export WM_LABEL_SIZE=32
export WM_COMPILE_OPTION=Opt

export PATO_DIR=/opt/pato-3.1
export PATO_BIN=/opt/pato-3.1/install/bin/PATOx

export PATH="/opt/pato-3.1/install/bin:${PATH}"

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close
export OMP_PLACES=cores

unset FOAM_SIGFPE

if [[ "$MPI_ENV_RC" -ne 0 ||
      "$OPENFOAM_RC" -ne 0 ||
      "$PATO_RC" -ne 0 ]]
then
    echo "ERROR: Container environment initialization failed."
    echo "Host MPI environment rc: $MPI_ENV_RC"
    echo "OpenFOAM environment rc: $OPENFOAM_RC"
    echo "PATO environment rc: $PATO_RC"
    exit 11
fi

if [[ ! -x "$PATO_BIN" ]]; then
    echo "ERROR: PATOx executable is unavailable:"
    echo "$PATO_BIN"
    exit 12
fi
EOF

# Copy tutorial from the container
echo
echo "==> Copying ArcJet_cylinder_3D tutorial"

rm -rf "$BASE_CASE"
mkdir -p "$BASE_CASE"

apptainer exec \
    --cleanenv \
    --bind /beegfs/Tools:/beegfs/Tools:ro \
    --bind "${BASE_CASE}:/case" \
    "$IMAGE" \
    /bin/bash -lc "
        set -e
        cp -a '${CASE_IN_IMAGE}/.' /case/
    "

# Utility to replace OpenFOAM dictionary entries
set_dictionary_entry()
{
    local FILE="$1"
    local KEY="$2"
    local VALUE="$3"

    if grep -Eq \
        "^[[:space:]]*${KEY}[[:space:]]+" \
        "$FILE"
    then
        sed -i -E \
            "s|^[[:space:]]*${KEY}[[:space:]]+[^;]*;|${KEY}    ${VALUE};|" \
            "$FILE"
    else
        printf \
            '\n%s    %s;\n' \
            "$KEY" \
            "$VALUE" \
            >> "$FILE"
    fi
}

# Set the requested controlDict parameters
CONTROL_DICT="${BASE_CASE}/system/controlDict"

if [[ ! -f "$CONTROL_DICT" ]]; then
    echo "ERROR: controlDict was not found:"
    echo "$CONTROL_DICT"
    exit 5
fi

set_dictionary_entry \
    "$CONTROL_DICT" \
    "endTime" \
    "$END_TIME"

set_dictionary_entry \
    "$CONTROL_DICT" \
    "deltaT" \
    "$DELTA_T"

set_dictionary_entry \
    "$CONTROL_DICT" \
    "adjustTimeStep" \
    "no"

set_dictionary_entry \
    "$CONTROL_DICT" \
    "writeControl" \
    "timeStep"

set_dictionary_entry \
    "$CONTROL_DICT" \
    "writeInterval" \
    "$WRITE_INTERVAL"

echo
echo "==> controlDict settings"

grep -nE \
    '^[[:space:]]*(endTime|deltaT|adjustTimeStep|writeControl|writeInterval)[[:space:]]+' \
    "$CONTROL_DICT"

# Generate blockMeshDict using the tutorial m4 file
M4_SOURCE="${BASE_CASE}/cylinderMesh.m4"
BLOCKMESH_DIR="${BASE_CASE}/constant/${REGION}/polyMesh"
BLOCKMESH_DICT="${BLOCKMESH_DIR}/blockMeshDict"

if [[ ! -f "$M4_SOURCE" ]]; then
    echo "ERROR: cylinderMesh.m4 was not found:"
    echo "$M4_SOURCE"
    exit 6
fi

if command -v m4 >/dev/null 2>&1; then
    M4_BIN="$(command -v m4)"
elif command -v gm4 >/dev/null 2>&1; then
    M4_BIN="$(command -v gm4)"
else
    echo "ERROR: Neither m4 nor gm4 is available."
    exit 7
fi

echo
echo "==> Generating blockMeshDict with:"
echo "$M4_BIN"

mkdir -p "$BLOCKMESH_DIR"

"$M4_BIN" \
    "$M4_SOURCE" \
    > "$BLOCKMESH_DICT"

if grep -q "changecom(" "$BLOCKMESH_DICT"; then
    echo "ERROR: blockMeshDict contains unexpanded m4 commands."
    echo "Do not use m4 -P."
    exit 8
fi

# Prepare the initial-condition directory
if [[ ! -d "${BASE_CASE}/origin.0" ]]; then
    echo "ERROR: origin.0 was not found."
    exit 9
fi

rm -rf "${BASE_CASE}/0"
cp -a \
    "${BASE_CASE}/origin.0" \
    "${BASE_CASE}/0"

# Generate and check the base mesh
echo
echo "==> Running blockMesh and checkMesh for region $REGION"

apptainer exec \
    --cleanenv \
    --bind /beegfs/Tools:/beegfs/Tools:ro \
    --bind "${BASE_CASE}:/case" \
    --pwd /case \
    "$IMAGE" \
    /bin/bash -lc "
        ${CONTAINER_INIT}

        mkdir -p /case/logs
        cd /case

        blockMesh \
            -region '${REGION}' \
            > 'logs/log.blockMesh.${REGION}' \
            2> 'logs/err.blockMesh.${REGION}'

        checkMesh \
            -region '${REGION}' \
            > 'logs/log.checkMesh.${REGION}' \
            2> 'logs/err.checkMesh.${REGION}'
    "

# Verify exactly 30,000 cells
BLOCKMESH_LOG="${BASE_CASE}/logs/log.blockMesh.${REGION}"
CHECKMESH_LOG="${BASE_CASE}/logs/log.checkMesh.${REGION}"

if ! grep -Eq \
    "nCells[^0-9]*${EXPECTED_CELLS}([^0-9]|$)" \
    "$BLOCKMESH_LOG"
then
    echo
    echo "ERROR: The generated mesh was not confirmed as 30,000 cells."
    echo
    echo "Cell information from blockMesh:"
    grep -i "cell" "$BLOCKMESH_LOG" |
        tail -n 30 ||
        true
    exit 13
fi

echo
echo "==> Confirmed mesh cell count"

grep -E \
    "nCells[^0-9]*${EXPECTED_CELLS}([^0-9]|$)" \
    "$BLOCKMESH_LOG" ||
    true

echo
echo "==> Final checkMesh information"

grep -E \
    "cells:|Mesh OK|Failed" \
    "$CHECKMESH_LOG" ||
    true

cp -a \
    "${BASE_CASE}/logs/." \
    "${LOGS}/"

# Create timing summary
printf \
    "application\tmode\tnodes\tranks\tranks_per_node\tmesh_cells\tregion\tdecomposition\tendTime\tdeltaT\telapsed_seconds\texit_code\n" \
    > "$SUMMARY"

# Run each processor configuration
for N in $PROCS_LIST; do

    echo
    echo "============================================================"
    echo "Starting N=$N on $NODES nodes"
    echo "============================================================"

    if (( N > ALLOCATED_TASKS )); then
        echo "ERROR: N=$N exceeds allocated tasks=$ALLOCATED_TASKS."
        exit 14
    fi

    if (( N % NODES != 0 )); then
        echo "ERROR: N=$N is not divisible by nodes=$NODES."
        echo "This benchmark requires equal ranks on every node."
        exit 15
    fi

    PPN=$((N / NODES))

    if (( PPN > TASKS_PER_NODE )); then
        echo "ERROR: $PPN ranks per node exceeds the allocation."
        echo "Allocated tasks per node: $TASKS_PER_NODE"
        exit 16
    fi

    RUN_CASE="${RUNS_DIR}/case_N${N}"

    RUN_LOG="${RUN_CASE}/logs/log.${N}proc"
    RUN_ERR="${RUN_CASE}/logs/err.${N}proc"

    rm -rf "$RUN_CASE"
    mkdir -p "$RUN_CASE"

    cp -a \
        "${BASE_CASE}/." \
        "$RUN_CASE/"

    cd "$RUN_CASE"

    rm -rf \
        processor* \
        postProcessing \
        logs

    mkdir -p logs

    rm -rf 0
    cp -a origin.0 0

    mkdir -p "system/${REGION}"

    # Scotch decomposition
    cat > system/decomposeParDict <<EOF
FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      decomposeParDict;
}

numberOfSubdomains ${N};

method          scotch;
EOF

    cp \
        system/decomposeParDict \
        "system/${REGION}/decomposeParDict"

    echo "==> Running Scotch decomposition for N=$N"

    apptainer exec \
        --cleanenv \
        --bind /beegfs/Tools:/beegfs/Tools:ro \
        --bind "${RUN_CASE}:/case" \
        --pwd /case \
        "$IMAGE" \
        /bin/bash -lc "
            ${CONTAINER_INIT}

            cd /case

            decomposePar \
                -region '${REGION}' \
                > 'logs/log.decompose.${REGION}.${N}' \
                2> 'logs/err.decompose.${REGION}.${N}'
        "

    PROCESSOR_COUNT="$(
        find "$RUN_CASE" \
            -maxdepth 1 \
            -type d \
            -name "processor*" |
        wc -l
    )"

    if [[ "$PROCESSOR_COUNT" -ne "$N" ]]; then
        echo "ERROR: Expected $N processor directories."
        echo "Found: $PROCESSOR_COUNT"
        exit 17
    fi

    # PATO parallel execution
    echo
    echo "==> Running PATOx"
    echo "Nodes:          $NODES"
    echo "MPI ranks:      $N"
    echo "Ranks per node: $PPN"
    echo "Mapping:        ppr:${PPN}:node:PE=1"
    echo "Binding:        core"
    echo "PML:            ob1"
    echo "BTLs:           self,vader,tcp"

    START_NS="$(date +%s%N)"

    set +e

    mpirun \
        --mca pml ob1 \
        --mca btl self,vader,tcp \
        --map-by "ppr:${PPN}:node:PE=1" \
        --bind-to core \
        -np "$N" \
        apptainer exec \
            --bind /beegfs/Tools:/beegfs/Tools:ro \
            --bind "${RUN_CASE}:/case" \
            --pwd /case \
            --env OMP_NUM_THREADS=1 \
            --env OMP_PROC_BIND=close \
            --env OMP_PLACES=cores \
            "$IMAGE" \
            /bin/bash -lc "
                ${CONTAINER_INIT}

                cd /case

                exec /opt/pato-3.1/install/bin/PATOx \
                    -parallel \
                    -case /case
            " \
        > "$RUN_LOG" \
        2> "$RUN_ERR"

    RUN_RC=$?

    set -e

    END_NS="$(date +%s%N)"

    ELAPSED="$(
        awk \
            -v TSTART="$START_NS" \
            -v TEND="$END_NS" \
            'BEGIN {
                printf "%.6f",
                    (TEND-TSTART)/1000000000
            }'
    )"

    # Append timing information to the solver log
    {
        echo
        echo "============================================================"
        echo "External benchmark timing"
        echo "============================================================"
        echo "Application       = PATO-3.1 / PATOx"
        echo "Mode              = container"
        echo "Nodes             = $NODES"
        echo "MPI ranks         = $N"
        echo "Ranks per node    = $PPN"
        echo "Mesh cells        = $EXPECTED_CELLS"
        echo "Region            = $REGION"
        echo "Decomposition     = scotch"
        echo "endTime           = $END_TIME"
        echo "deltaT            = $DELTA_T"
        echo "PML               = ob1"
        echo "BTLs              = self,vader,tcp"
        echo "Elapsed wall time = ${ELAPSED} s"
        echo "Exit code         = $RUN_RC"
        echo "============================================================"
    } >> "$RUN_LOG"

    # Append the run to timing_summary.tsv
    printf \
        "PATOx\tcontainer\t%s\t%s\t%s\t%s\t%s\tscotch\t%s\t%s\t%s\t%s\n" \
        "$NODES" \
        "$N" \
        "$PPN" \
        "$EXPECTED_CELLS" \
        "$REGION" \
        "$END_TIME" \
        "$DELTA_T" \
        "$ELAPSED" \
        "$RUN_RC" \
        >> "$SUMMARY"

    # Check execution result
    if [[ "$RUN_RC" -ne 0 ]]; then
        echo
        echo "ERROR: PATOx failed for N=$N."
        echo "Exit code: $RUN_RC"

        echo
        echo "Last 100 stderr lines:"
        tail -n 100 "$RUN_ERR" || true

        echo
        echo "Last 100 stdout lines:"
        tail -n 100 "$RUN_LOG" || true

        exit "$RUN_RC"
    fi

    if grep -Eiq \
        "FOAM FATAL|segmentation fault|(^|[^a-z])nan([^a-z]|$)" \
        "$RUN_LOG" \
        "$RUN_ERR"
    then
        echo "ERROR: Fatal error, segmentation fault, or NaN detected."
        echo "Processor count: $N"

        grep -Ein \
            "FOAM FATAL|segmentation fault|(^|[^a-z])nan([^a-z]|$)" \
            "$RUN_LOG" \
            "$RUN_ERR" ||
            true

        exit 18
    fi

    echo
    echo "==> Completed N=$N"
    echo "Elapsed wall time: ${ELAPSED} seconds"

done

# Final report
echo
echo "============================================================"
echo "All PATO container runs completed successfully"
echo "============================================================"
echo "Results directory:"
echo "$ROOT"
echo
echo "Timing summary:"
echo "$SUMMARY"
echo

column \
    -t \
    -s $'\t' \
    "$SUMMARY" \
    2>/dev/null ||
cat "$SUMMARY"

echo "============================================================"
