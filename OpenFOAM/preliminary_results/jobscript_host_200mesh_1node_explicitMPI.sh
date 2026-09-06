#!/bin/bash
#SBATCH --job-name=openfoam_host_200cube_explicit_mpi
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=50
#SBATCH --ntasks-per-node=50
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

set -euo pipefail

# Supports 1, 2, and 4 nodes.

HOST_ROOT="/beegfs/gopal/new/openfoam/host"
OF_ROOT="${HOST_ROOT}/OpenFOAM-v2406"
THIRD_PARTY_ROOT="${HOST_ROOT}/ThirdParty-v2406"
OF_BASHRC="${OF_ROOT}/etc/bashrc"
CASE_SOURCE="${OF_ROOT}/tutorials/combustion/fireFoam/LES/smallPoolFire3D"

MODE="explicit_mpi"

NODES="${SLURM_JOB_NUM_NODES:-0}"
TASKS="${SLURM_NTASKS:-0}"
JOB_ID="${SLURM_JOB_ID:-manual_$(date +%Y%m%d_%H%M%S)}"
CPUS_PER_TASK="${SLURM_CPUS_PER_TASK:-1}"
TASKS_PER_NODE="${SLURM_NTASKS_PER_NODE:-50}"
TASKS_PER_NODE="${TASKS_PER_NODE%%(*}"

MAX_RANKS_PER_NODE=50

if (( NODES < 1 || TASKS < 1 )); then
    echo "ERROR: Submit this script with sbatch."
    exit 1
fi

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
        echo "ERROR: Only 1-, 2-, and 4-node runs are supported."
        exit 2
        ;;
esac

if (( TASKS < NODES * MAX_RANKS_PER_NODE )); then
    echo "ERROR: Expected at least $((NODES * MAX_RANKS_PER_NODE)) allocated tasks."
    exit 3
fi

RESULT_ROOT="${HOST_ROOT}/results"
CASE_ROOT="${RESULT_ROOT}/smallPoolFire3D_200cube_host_${MODE}_${NODES}node_${JOB_ID}"
BASE_CASE="${CASE_ROOT}/base_case"
RUNS_DIR="${CASE_ROOT}/runs"
LOGS="${CASE_ROOT}/logs"

# Simulation parameters
MESH_X=200
MESH_Y=200
MESH_Z=200
TOTAL_CELLS=$((MESH_X * MESH_Y * MESH_Z))

DELTA_T="0.00075"
END_TIME="0.075"
ADJUST_TIME_STEP="no"
MAX_CO="0.45"
WRITE_CONTROL="timeStep"
WRITE_INTERVAL="100"

MPI_PML="ob1"
MPI_BTL="self,vader,tcp"

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=false
unset OMP_PLACES || true

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

set_dict_entry()
{
    local file="$1"
    local key="$2"
    local value="$3"

    if grep -Eq "^[[:space:]]*${key}[[:space:]]+" "$file"; then
        sed -Ei \
            "s|^[[:space:]]*${key}[[:space:]]+[^;]*;|${key}    ${value};|" \
            "$file"
    else
        die "${key} was not found in ${file}"
    fi
}

get_layout()
{
    case "$1" in
        2)   echo "2 1 1" ;;
        4)   echo "2 2 1" ;;
        8)   echo "2 2 2" ;;
        10)  echo "5 2 1" ;;
        16)  echo "4 2 2" ;;
        20)  echo "5 2 2" ;;
        25)  echo "5 5 1" ;;
        32)  echo "4 4 2" ;;
        40)  echo "5 4 2" ;;
        50)  echo "5 5 2" ;;
        64)  echo "4 4 4" ;;
        80)  echo "5 4 4" ;;
        100) echo "5 5 4" ;;
        128) echo "8 4 4" ;;
        160) echo "10 4 4" ;;
        200) echo "10 5 4" ;;
        *) return 1 ;;
    esac
}

elapsed_seconds()
{
    python3 - "$1" "$2" <<'PYTIME'
import sys
print(f"{float(sys.argv[2]) - float(sys.argv[1]):.6f}")
PYTIME
}

# Output and logging
mkdir -p "${HOST_ROOT}/logs"
mkdir -p "$BASE_CASE" "$RUNS_DIR" "$LOGS"

exec > >(stdbuf -oL -eL tee -a "${LOGS}/console.log") 2>&1

echo "============================================================"
echo "OpenFOAM v2406 HOST benchmark"
echo "============================================================"
echo "Mode:                ${MODE}"
echo "Job ID:              ${JOB_ID}"
echo "Nodes:               ${NODES}"
echo "Allocated tasks:     ${TASKS}"
echo "Tasks per node:      ${TASKS_PER_NODE}"
echo "CPUs per task:       ${CPUS_PER_TASK}"
echo "Processor list:      ${PROCS_LIST}"
echo "OpenFOAM root:       ${OF_ROOT}"
echo "ThirdParty root:     ${THIRD_PARTY_ROOT}"
echo "Case source:         ${CASE_SOURCE}"
echo "Mesh:                ${MESH_X} x ${MESH_Y} x ${MESH_Z}"
echo "Total cells:         ${TOTAL_CELLS}"
echo "Result directory:    ${CASE_ROOT}"
echo "Date:                $(date)"
echo "============================================================"

for required_path in \
    "$OF_ROOT" \
    "$THIRD_PARTY_ROOT" \
    "$OF_BASHRC" \
    "$CASE_SOURCE"
do
    [[ -e "$required_path" ]] ||
        die "Required host path does not exist: ${required_path}"
done

# Load host software
module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5
module list 2>&1 || true

export FOAM_INST_DIR="$HOST_ROOT"
export WM_PROJECT_INST_DIR="$HOST_ROOT"
export WM_PROJECT_DIR="$OF_ROOT"
export WM_THIRD_PARTY_DIR="$THIRD_PARTY_ROOT"
export WM_COMPILER_TYPE=system
export WM_COMPILER=Gcc
export WM_MPLIB=SYSTEMOPENMPI
export WM_PRECISION_OPTION=DP
export WM_LABEL_SIZE=32
export WM_COMPILE_OPTION=Opt

set +e
set +u
set +o pipefail
source "$OF_BASHRC"
BASHRC_RC=$?
set -e
set -o pipefail

(( BASHRC_RC == 0 )) ||
    die "OpenFOAM bashrc returned ${BASHRC_RC}."

module load OpenMPI/4.1.5

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=false
unset OMP_PLACES || true
unset CPATH || true
unset C_INCLUDE_PATH || true
unset CPLUS_INCLUDE_PATH || true

for command_name in \
    blockMesh checkMesh decomposePar fireFoam \
    mpirun python3 scontrol
do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "Required command is unavailable: ${command_name}"
done

[[ "$(command -v fireFoam)" == "${OF_ROOT}/"* ]] ||
    die "fireFoam is not loaded from ${OF_ROOT}."

blockMesh -help >/dev/null 2>"${LOGS}/err.blockMesh-help" ||
    die "blockMesh runtime check failed."

fireFoam -help >/dev/null 2>"${LOGS}/err.fireFoam-help" ||
    die "fireFoam runtime check failed."

scontrol show hostnames "${SLURM_JOB_NODELIST}" |
    tee "${LOGS}/nodes.txt"

echo
echo "============================================================"
echo "Preparing common host base case"
echo "============================================================"

rm -rf "${BASE_CASE:?}/"*
cp -a "${CASE_SOURCE}/." "${BASE_CASE}/"

for required_path in \
    "${BASE_CASE}/system/blockMeshDict" \
    "${BASE_CASE}/system/controlDict" \
    "${BASE_CASE}/0.orig"
do
    [[ -e "$required_path" ]] ||
        die "Required case item was not copied: ${required_path}"
done

echo "Updating mesh to ${MESH_X} x ${MESH_Y} x ${MESH_Z}"

grep -Eq \
    '\([[:space:]]*60[[:space:]]+60[[:space:]]+60[[:space:]]*\)' \
    "${BASE_CASE}/system/blockMeshDict" ||
    die "Original 60 x 60 x 60 mesh entry was not found."

sed -Ei \
    "s/\([[:space:]]*60[[:space:]]+60[[:space:]]+60[[:space:]]*\)/(${MESH_X} ${MESH_Y} ${MESH_Z})/" \
    "${BASE_CASE}/system/blockMeshDict"

CONTROL_DICT="${BASE_CASE}/system/controlDict"

set_dict_entry "$CONTROL_DICT" deltaT "$DELTA_T"
set_dict_entry "$CONTROL_DICT" endTime "$END_TIME"
set_dict_entry "$CONTROL_DICT" adjustTimeStep "$ADJUST_TIME_STEP"
set_dict_entry "$CONTROL_DICT" maxCo "$MAX_CO"
set_dict_entry "$CONTROL_DICT" writeControl "$WRITE_CONTROL"
set_dict_entry "$CONTROL_DICT" writeInterval "$WRITE_INTERVAL"

sed -i '/^[[:space:]]*functions[[:space:]]*$/,$d' "$CONTROL_DICT"

cat >> "$CONTROL_DICT" <<'FOAM_FUNCTIONS'

functions
{
    time
    {
        type            timeInfo;
        libs            (utilityFunctionObjects);
        writeControl    timeStep;
        writeInterval   1;
        writeToFile     yes;
        perTimeStep     yes;
    }

    solverInfo
    {
        type            solverInfo;
        libs            (utilityFunctionObjects);
        writeControl    timeStep;
        writeInterval   1;
        fields          (ph_rgh p_rgh U h O2 CH4 CO2 H2O k);
    }
}
FOAM_FUNCTIONS

cat > "${BASE_CASE}/system/fvSolution" <<'FOAM_FVSOLUTION'
FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      fvSolution;
}

solvers
{
    "(rho|rhoFinal)"
    {
        solver          PCG;
        preconditioner  DIC;
        tolerance       1e-6;
        relTol          0;
        minIter         0;
        maxIter         0;
    }

    p_rgh
    {
        solver          GAMG;
        tolerance       1e-6;
        relTol          0.1;
        smoother        GaussSeidel;
        minIter         2;
        maxIter         2;
    }

    p_rghFinal
    {
        $p_rgh;
        tolerance       1e-6;
        relTol          0;
        minIter         2;
        maxIter         2;
    }

    ph_rgh
    {
        $p_rgh;
        minIter         2;
        maxIter         2;
    }

    "(U|Yi|k|h)"
    {
        solver          PBiCGStab;
        preconditioner  DILU;
        tolerance       1e-6;
        relTol          0.1;
        nSweeps         1;
        minIter         1;
        maxIter         1;
    }

    "(U|Yi|k|h)Final"
    {
        $U;
        tolerance       1e-6;
        relTol          0;
        minIter         1;
        maxIter         1;
    }

    Ii
    {
        solver          GAMG;
        tolerance       1e-4;
        relTol          0;
        smoother        symGaussSeidel;
        minIter         1;
        maxIter         1;
        nPostSweeps     1;
    }

    G
    {
        solver          PCG;
        preconditioner  DIC;
        tolerance       1e-4;
        relTol          0;
        minIter         1;
        maxIter         1;
    }
}

PIMPLE
{
    momentumPredictor           yes;
    nOuterCorrectors            1;
    nCorrectors                 2;
    nNonOrthogonalCorrectors    0;
    hydrostaticInitialization   yes;
    nHydrostaticCorrectors      5;
}

relaxationFactors
{
    equations
    {
        "(U|k).*"                    1;
        "(CH4|O2|H2O|CO2|h).*"      1;
    }
}
FOAM_FVSOLUTION

# Build and verify 200^3 mesh
rm -rf \
    "${BASE_CASE}/processor"* \
    "${BASE_CASE}/constant/polyMesh" \
    "${BASE_CASE}/0"

cp -a "${BASE_CASE}/0.orig" "${BASE_CASE}/0"

set +e
(
    cd "$BASE_CASE"
    blockMesh
) > "${LOGS}/log.blockMesh" 2> "${LOGS}/err.blockMesh"
BLOCKMESH_RC=$?
set -e

(( BLOCKMESH_RC == 0 )) || {
    tail -n 100 "${LOGS}/log.blockMesh" || true
    tail -n 100 "${LOGS}/err.blockMesh" || true
    die "blockMesh failed."
}

set +e
(
    cd "$BASE_CASE"
    checkMesh
) > "${LOGS}/log.checkMesh" 2> "${LOGS}/err.checkMesh"
CHECKMESH_RC=$?
set -e

(( CHECKMESH_RC == 0 )) || {
    tail -n 100 "${LOGS}/log.checkMesh" || true
    tail -n 100 "${LOGS}/err.checkMesh" || true
    die "checkMesh failed."
}

grep -q "Mesh OK" "${LOGS}/log.checkMesh" ||
    die "checkMesh did not report Mesh OK."

DETECTED_CELLS="$(
    awk '
        /cells:/ {
            value=$2
        }
        END {
            print value
        }
    ' "${LOGS}/log.checkMesh"
)"

[[ "$DETECTED_CELLS" == "$TOTAL_CELLS" ]] ||
    die "Expected ${TOTAL_CELLS} cells; detected ${DETECTED_CELLS:-unknown}."

# Summary
SUMMARY_FILE="${LOGS}/timing_summary.tsv"

printf 'mode\tnodes\tranks\tused_hosts\tactual_placement\tglobal_mesh\tdecomposition\tlocal_mesh\tcells_per_rank\telapsed_seconds\texit_code\n' \
    > "$SUMMARY_FILE"

# Processor sweep
for N in $PROCS_LIST; do
    echo
    echo "============================================================"
    echo "HOST RUN: mode=${MODE}, nodes=${NODES}, ranks=${N}"
    echo "============================================================"

    (( N <= TASKS )) ||
        die "${N} ranks exceeds ${TASKS}-task allocation."

    if ! read -r NX NY NZ < <(get_layout "$N"); then
        die "No hierarchical layout is defined for N=${N}."
    fi

    (( NX * NY * NZ == N )) ||
        die "Invalid layout ${NX} x ${NY} x ${NZ} for N=${N}."

    (( MESH_X % NX == 0 )) ||
        die "MESH_X=${MESH_X} is not divisible by NX=${NX}."
    (( MESH_Y % NY == 0 )) ||
        die "MESH_Y=${MESH_Y} is not divisible by NY=${NY}."
    (( MESH_Z % NZ == 0 )) ||
        die "MESH_Z=${MESH_Z} is not divisible by NZ=${NZ}."

    LOCAL_X=$((MESH_X / NX))
    LOCAL_Y=$((MESH_Y / NY))
    LOCAL_Z=$((MESH_Z / NZ))
    CELLS_PER_RANK=$((LOCAL_X * LOCAL_Y * LOCAL_Z))

    RUN_DIR="${RUNS_DIR}/${N}proc"
    RUN_LOG="${LOGS}/log.${N}proc"
    RUN_ERR="${LOGS}/err.${N}proc"
    DECOMP_LOG="${LOGS}/log.decompose.${N}"
    DECOMP_ERR="${LOGS}/err.decompose.${N}"
    PLACEMENT_RAW="${LOGS}/placement.${N}.raw"
    PLACEMENT_ERR="${LOGS}/placement.${N}.err"
    PLACEMENT_SUMMARY="${LOGS}/placement.${N}.summary"

    rm -rf "$RUN_DIR"
    mkdir -p "$RUN_DIR"
    cp -a "${BASE_CASE}/." "$RUN_DIR/"

    rm -rf "${RUN_DIR}/processor"* "${RUN_DIR}/0"
    cp -a "${RUN_DIR}/0.orig" "${RUN_DIR}/0"

    cat > "${RUN_DIR}/system/decomposeParDict" <<EOF_DECOMP
FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    object      decomposeParDict;
}

numberOfSubdomains ${N};

method hierarchical;

hierarchicalCoeffs
{
    n       (${NX} ${NY} ${NZ});
    delta   0.001;
    order   xyz;
}
EOF_DECOMP

    set +e
    (
        cd "$RUN_DIR"
        decomposePar -force
    ) > "$DECOMP_LOG" 2> "$DECOMP_ERR"
    DECOMP_RC=$?
    set -e

    (( DECOMP_RC == 0 )) || {
        tail -n 100 "$DECOMP_LOG" || true
        tail -n 100 "$DECOMP_ERR" || true
        die "decomposePar failed for N=${N}."
    }

    PROCESSOR_COUNT="$(
        find "$RUN_DIR" \
            -maxdepth 1 \
            -type d \
            -name 'processor[0-9]*' |
        wc -l |
        tr -d '[:space:]'
    )"

    [[ "$PROCESSOR_COUNT" -eq "$N" ]] ||
        die "Expected ${N} processor directories; found ${PROCESSOR_COUNT}."

    MPI_PLACE_ARGS=()

    if [[ "$MODE" == "explicit_mpi" ]]; then
        (( N % NODES == 0 )) ||
            die "${N} ranks cannot be balanced across ${NODES} nodes."

        PPN=$((N / NODES))

        (( PPN <= MAX_RANKS_PER_NODE )) ||
            die "${PPN} ranks/node exceeds ${MAX_RANKS_PER_NODE}."

        MPI_PLACE_ARGS=(
            --map-by "ppr:${PPN}:node:PE=1"
            --bind-to core
        )
    fi

    set +e

    mpirun \
        --mca pml "$MPI_PML" \
        --mca btl "$MPI_BTL" \
        "${MPI_PLACE_ARGS[@]}" \
        -np "$N" \
        hostname \
        > "$PLACEMENT_RAW" \
        2> "$PLACEMENT_ERR"

    PLACEMENT_RC=$?
    set -e

    (( PLACEMENT_RC == 0 )) ||
        die "MPI placement test failed for N=${N}."

    sort "$PLACEMENT_RAW" |
        uniq -c |
        awk '{print $1, $2}' \
        > "$PLACEMENT_SUMMARY"

    PLACED_RANKS="$(
        awk '{sum += $1} END {print sum+0}' "$PLACEMENT_SUMMARY"
    )"

    [[ "$PLACED_RANKS" -eq "$N" ]] ||
        die "Placement used ${PLACED_RANKS} ranks; expected ${N}."

    USED_HOSTS="$(
        awk '{print $2}' "$PLACEMENT_SUMMARY" |
        sort -u |
        wc -l |
        tr -d '[:space:]'
    )"

    if [[ "$MODE" == "explicit_mpi" ]]; then
        [[ "$USED_HOSTS" -eq "$NODES" ]] ||
            die "Explicit placement used ${USED_HOSTS} hosts; expected ${NODES}."

        while read -r rank_count node_name; do
            [[ "$rank_count" -eq "$PPN" ]] ||
                die "${node_name} received ${rank_count} ranks; expected ${PPN}."
        done < "$PLACEMENT_SUMMARY"
    fi

    ACTUAL_PLACEMENT="$(
        awk '
            BEGIN {
                separator=""
            }
            {
                printf "%s%s:%s", separator, $2, $1
                separator=";"
            }
            END {
                print ""
            }
        ' "$PLACEMENT_SUMMARY"
    )"

    echo "Global mesh:        ${MESH_X} x ${MESH_Y} x ${MESH_Z}"
    echo "Total cells:        ${TOTAL_CELLS}"
    echo "MPI ranks:          ${N}"
    echo "Decomposition:      ${NX} x ${NY} x ${NZ}"
    echo "Local mesh/rank:    ${LOCAL_X} x ${LOCAL_Y} x ${LOCAL_Z}"
    echo "Cells per rank:     ${CELLS_PER_RANK}"
    echo "Used hosts:         ${USED_HOSTS}"
    echo "Actual placement:   ${ACTUAL_PLACEMENT}"

    START_EPOCH="$(date +%s.%N)"

    set +e
    (
        cd "$RUN_DIR"

        mpirun \
            --mca pml "$MPI_PML" \
            --mca btl "$MPI_BTL" \
            "${MPI_PLACE_ARGS[@]}" \
            -np "$N" \
            fireFoam \
                -parallel \
                -case "$RUN_DIR"
    ) > "$RUN_LOG" 2> "$RUN_ERR"

    RUN_RC=$?
    set -e

    END_EPOCH="$(date +%s.%N)"
    ELAPSED="$(elapsed_seconds "$START_EPOCH" "$END_EPOCH")"

    {
        echo
        echo "============================================================"
        echo "Timing and configuration"
        echo "============================================================"
        echo "Mode:                  ${MODE}"
        echo "Allocated nodes:       ${NODES}"
        echo "Used hosts:            ${USED_HOSTS}"
        echo "Actual placement:      ${ACTUAL_PLACEMENT}"
        echo "MPI ranks:             ${N}"
        echo "Global mesh:           ${MESH_X} x ${MESH_Y} x ${MESH_Z}"
        echo "Total cells:           ${TOTAL_CELLS}"
        echo "Decomposition:         ${NX} x ${NY} x ${NZ}"
        echo "Local mesh/rank:       ${LOCAL_X} x ${LOCAL_Y} x ${LOCAL_Z}"
        echo "Cells per rank:        ${CELLS_PER_RANK}"
        echo "External elapsed time: ${ELAPSED} s"
        echo "Exit code:             ${RUN_RC}"
        echo "============================================================"
    } >> "$RUN_LOG"

    printf '%s\t%s\t%s\t%s\t%s\t%sx%sx%s\t%sx%sx%s\t%sx%sx%s\t%s\t%s\t%s\n' \
        "$MODE" \
        "$NODES" \
        "$N" \
        "$USED_HOSTS" \
        "$ACTUAL_PLACEMENT" \
        "$MESH_X" "$MESH_Y" "$MESH_Z" \
        "$NX" "$NY" "$NZ" \
        "$LOCAL_X" "$LOCAL_Y" "$LOCAL_Z" \
        "$CELLS_PER_RANK" \
        "$ELAPSED" \
        "$RUN_RC" \
        >> "$SUMMARY_FILE"

    if (( RUN_RC != 0 )); then
        tail -n 100 "$RUN_LOG" || true
        tail -n 100 "$RUN_ERR" || true
        die "fireFoam failed for N=${N}, exit code ${RUN_RC}."
    fi

    grep -q "^End$" "$RUN_LOG" ||
        die "OpenFOAM completion marker was not found for N=${N}."

    echo "COMPLETED: N=${N}, elapsed=${ELAPSED} s"
done

echo
echo "============================================================"
echo "ALL OPENFOAM HOST RUNS COMPLETED"
echo "============================================================"
echo "Mode:     ${MODE}"
echo "Summary:  ${SUMMARY_FILE}"
echo "Results:  ${CASE_ROOT}"
echo "Finished: $(date)"
echo "============================================================"

