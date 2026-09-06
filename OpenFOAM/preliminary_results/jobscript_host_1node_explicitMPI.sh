#!/bin/bash
#SBATCH --job-name=openfoam_host_balanced
#SBATCH --output=%x_%j.out
#SBATCH --error=%x_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=50
#SBATCH --ntasks-per-node=50
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

# Supports 1, 2, and 4 nodes.

set -e
set -o pipefail

HOST_ROOT="/beegfs/gopal/new/openfoam/host"
OF_ROOT="${HOST_ROOT}/OpenFOAM-v2406"
THIRD_PARTY_ROOT="${HOST_ROOT}/ThirdParty-v2406"
OF_BASHRC="${OF_ROOT}/etc/bashrc"
CASE_SOURCE="${OF_ROOT}/tutorials/combustion/fireFoam/LES/smallPoolFire3D"

NODES="${SLURM_JOB_NUM_NODES:-1}"
TASKS="${SLURM_NTASKS:-1}"
JOB_ID="${SLURM_JOB_ID:-manual}"
CPUS_PER_TASK="${SLURM_CPUS_PER_TASK:-1}"

if (( NODES < 1 || TASKS < 1 )); then
    echo "ERROR: Invalid Slurm allocation."
    exit 1
fi

if (( TASKS % NODES != 0 )); then
    echo "ERROR: ${TASKS} tasks cannot be distributed equally across ${NODES} nodes."
    exit 1
fi

ALLOCATED_TASKS_PER_NODE=$((TASKS / NODES))
MAX_RANKS_PER_NODE="${ALLOCATED_TASKS_PER_NODE}"

RESULT_ROOT="${HOST_ROOT}/results"
CASE_ROOT="${RESULT_ROOT}/smallPoolFire3D_host_${NODES}node_${JOB_ID}"
BASE_CASE="${CASE_ROOT}/base_case"
RUNS_DIR="${CASE_ROOT}/runs"
LOGS="${CASE_ROOT}/logs"

MESH_X=80
MESH_Y=80
MESH_Z=80

DELTA_T="0.00075"
END_TIME="0.075"
ADJUST_TIME_STEP="no"
MAX_CO="0.45"
WRITE_CONTROL="timeStep"
WRITE_INTERVAL="100"

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close
export OMP_PLACES=cores

case "$NODES" in
    1) PROCS_LIST="2 4 8 10 16 20 25 32 40 50" ;;
    2) PROCS_LIST="4 8 10 16 20 32 40 50 64 80 100" ;;
    4) PROCS_LIST="8 16 20 32 40 64 80 100 128 160 200" ;;
    *)
        echo "ERROR: Only 1-, 2-, and 4-node runs are supported."
        exit 2
        ;;
esac

mkdir -p "$BASE_CASE" "$RUNS_DIR" "$LOGS"
exec > >(stdbuf -oL -eL tee -a "${LOGS}/console.log") 2>&1

echo "============================================================"
echo "OpenFOAM v2406 host benchmark"
echo "============================================================"
echo "Job ID:              ${JOB_ID}"
echo "Job name:            ${SLURM_JOB_NAME:-manual}"
echo "Nodes:               ${NODES}"
echo "Allocated tasks:     ${TASKS}"
echo "Tasks per node:      ${ALLOCATED_TASKS_PER_NODE}"
echo "CPUs per task:       ${CPUS_PER_TASK}"
echo "Processor list:      ${PROCS_LIST}"
echo "OpenFOAM root:       ${OF_ROOT}"
echo "ThirdParty root:     ${THIRD_PARTY_ROOT}"
echo "Case source:         ${CASE_SOURCE}"
echo "Result directory:    ${CASE_ROOT}"
echo "Date:                $(date)"
echo "============================================================"

for REQUIRED_PATH in "$OF_ROOT" "$THIRD_PARTY_ROOT" "$OF_BASHRC" "$CASE_SOURCE"; do
    if [[ ! -e "$REQUIRED_PATH" ]]; then
        echo "ERROR: Required host path does not exist: ${REQUIRED_PATH}"
        exit 3
    fi
done

module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5

echo
echo "Loaded modules before sourcing OpenFOAM:"
module list 2>&1 || true

echo
echo "Compiler and MPI before sourcing OpenFOAM:"
gcc --version | sed -n '1p'
mpirun --version | sed -n '1p'
echo "mpirun path: $(command -v mpirun)"

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

if (( BASHRC_RC != 0 )); then
    echo "ERROR: OpenFOAM bashrc returned ${BASHRC_RC}."
    exit "$BASHRC_RC"
fi

module load OpenMPI/4.1.5

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close
export OMP_PLACES=cores
unset CPATH || true
unset C_INCLUDE_PATH || true
unset CPLUS_INCLUDE_PATH || true

echo
echo "Validating host OpenFOAM runtime"
echo "------------------------------------------------------------"
echo "WM_PROJECT_DIR:      ${WM_PROJECT_DIR:-unset}"
echo "WM_PROJECT_VERSION:  ${WM_PROJECT_VERSION:-unset}"
echo "WM_OPTIONS:          ${WM_OPTIONS:-unset}"
echo "WM_MPLIB:            ${WM_MPLIB:-unset}"
echo "FOAM_MPI:            ${FOAM_MPI:-unset}"
echo "blockMesh:           $(command -v blockMesh || true)"
echo "checkMesh:           $(command -v checkMesh || true)"
echo "decomposePar:        $(command -v decomposePar || true)"
echo "fireFoam:            $(command -v fireFoam || true)"
echo "mpirun:              $(command -v mpirun || true)"
echo "------------------------------------------------------------"

for COMMAND in blockMesh checkMesh decomposePar fireFoam mpirun; do
    if ! command -v "$COMMAND" >/dev/null 2>&1; then
        echo "ERROR: Required command is unavailable: ${COMMAND}"
        exit 4
    fi
done

if [[ "$(command -v fireFoam)" != "${OF_ROOT}/"* ]]; then
    echo "ERROR: fireFoam is not being loaded from the requested host build."
    echo "Resolved path: $(command -v fireFoam)"
    exit 5
fi

blockMesh -help >/dev/null 2>"${LOGS}/err.blockMesh-help" || {
    cat "${LOGS}/err.blockMesh-help"
    exit 6
}

fireFoam -help >/dev/null 2>"${LOGS}/err.fireFoam-help" || {
    cat "${LOGS}/err.fireFoam-help"
    exit 7
}

echo "Host OpenFOAM runtime validation passed."
scontrol show hostnames "${SLURM_JOB_NODELIST}" | tee "${LOGS}/nodes.txt"

echo
echo "============================================================"
echo "Preparing common host base case"
echo "============================================================"

rm -rf "${BASE_CASE:?}/"*
cp -a "${CASE_SOURCE}/." "${BASE_CASE}/"

for REQUIRED_PATH in \
    "${BASE_CASE}/system/blockMeshDict" \
    "${BASE_CASE}/system/controlDict" \
    "${BASE_CASE}/0.orig"
do
    if [[ ! -e "$REQUIRED_PATH" ]]; then
        echo "ERROR: Required case item was not copied: ${REQUIRED_PATH}"
        exit 8
    fi
done

echo "Updating mesh to ${MESH_X} x ${MESH_Y} x ${MESH_Z}"

if ! grep -Eq '\([[:space:]]*60[[:space:]]+60[[:space:]]+60[[:space:]]*\)' \
    "${BASE_CASE}/system/blockMeshDict"; then
    echo "ERROR: Original 60 x 60 x 60 mesh entry was not found."
    exit 9
fi

sed -Ei \
    "s/\([[:space:]]*60[[:space:]]+60[[:space:]]+60[[:space:]]*\)/(${MESH_X} ${MESH_Y} ${MESH_Z})/" \
    "${BASE_CASE}/system/blockMeshDict"

set_dict_entry()
{
    local FILE="$1"
    local KEY="$2"
    local VALUE="$3"

    if grep -Eq "^[[:space:]]*${KEY}[[:space:]]+" "$FILE"; then
        sed -Ei "s|^[[:space:]]*${KEY}[[:space:]]+[^;]*;|${KEY}    ${VALUE};|" "$FILE"
    else
        echo "ERROR: ${KEY} was not found in ${FILE}"
        exit 10
    fi
}

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

rm -rf "${BASE_CASE}/processor"* "${BASE_CASE}/constant/polyMesh" "${BASE_CASE}/0"
cp -a "${BASE_CASE}/0.orig" "${BASE_CASE}/0"

echo "Running host blockMesh"
set +e
(
    cd "$BASE_CASE"
    blockMesh
) > "${LOGS}/log.blockMesh" 2> "${LOGS}/err.blockMesh"
BLOCKMESH_RC=$?
set -e

if (( BLOCKMESH_RC != 0 )); then
    echo "ERROR: blockMesh failed with exit code ${BLOCKMESH_RC}."
    tail -n 100 "${LOGS}/log.blockMesh" || true
    tail -n 100 "${LOGS}/err.blockMesh" || true
    exit "$BLOCKMESH_RC"
fi

echo "Running host checkMesh"
set +e
(
    cd "$BASE_CASE"
    checkMesh
) > "${LOGS}/log.checkMesh" 2> "${LOGS}/err.checkMesh"
CHECKMESH_RC=$?
set -e

if (( CHECKMESH_RC != 0 )); then
    echo "ERROR: checkMesh failed with exit code ${CHECKMESH_RC}."
    tail -n 100 "${LOGS}/log.checkMesh" || true
    tail -n 100 "${LOGS}/err.checkMesh" || true
    exit "$CHECKMESH_RC"
fi

if ! grep -q "Mesh OK" "${LOGS}/log.checkMesh"; then
    echo "ERROR: checkMesh did not report 'Mesh OK'."
    tail -n 100 "${LOGS}/log.checkMesh" || true
    tail -n 100 "${LOGS}/err.checkMesh" || true
    exit 11
fi

echo
echo "Fixed simulation configuration"
echo "------------------------------------------------------------"
echo "Execution mode:        host"
echo "Mesh:                  ${MESH_X} x ${MESH_Y} x ${MESH_Z}"
echo "Cells:                 $((MESH_X * MESH_Y * MESH_Z))"
echo "Solver:                fireFoam"
echo "deltaT:                ${DELTA_T} s"
echo "endTime:               ${END_TIME} s"
echo "adjustTimeStep:        ${ADJUST_TIME_STEP}"
echo "maxCo:                 ${MAX_CO}"
echo "Expected time steps:   100"
echo "Pressure iterations:   2"
echo "U/Yi/h/k iterations:   1"
echo "Radiation iterations:  1"
echo "PIMPLE outer:          1"
echo "PIMPLE correctors:     2"
echo "MPI PML:               ob1"
echo "MPI BTL:               self,vader,tcp"
echo "------------------------------------------------------------"

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
        160) echo "8 5 4" ;;
        200) echo "10 5 4" ;;
        *) return 1 ;;
    esac
}

SUMMARY_FILE="${LOGS}/timing_summary.tsv"
printf "mode\tnodes\tranks\tranks_per_node\tdecomposition\telapsed_seconds\texit_code\n" > "$SUMMARY_FILE"

for N in $PROCS_LIST; do
    echo
    echo "============================================================"
    echo "HOST RUN: nodes=${NODES}, ranks=${N}"
    echo "============================================================"

    if (( N % NODES != 0 )); then
        echo "ERROR: ${N} ranks cannot be balanced across ${NODES} nodes."
        exit 12
    fi

    PPN=$((N / NODES))

    if (( PPN > MAX_RANKS_PER_NODE )); then
        echo "ERROR: ${PPN} ranks/node exceeds the allocation of ${MAX_RANKS_PER_NODE}."
        exit 13
    fi

    if (( N > TASKS )); then
        echo "ERROR: ${N} ranks exceeds the ${TASKS}-task allocation."
        exit 14
    fi

    if ! read -r NX NY NZ < <(get_layout "$N"); then
        echo "ERROR: No hierarchical layout is defined for N=${N}."
        exit 15
    fi

    if (( NX * NY * NZ != N )); then
        echo "ERROR: Invalid layout ${NX} x ${NY} x ${NZ} for N=${N}."
        exit 16
    fi

    RUN_DIR="${RUNS_DIR}/${N}proc"
    RUN_LOG="${LOGS}/log.${N}proc"
    RUN_ERR="${LOGS}/err.${N}proc"
    DECOMP_LOG="${LOGS}/log.decompose.${N}"
    DECOMP_ERR="${LOGS}/err.decompose.${N}"

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

    echo "Running host decomposePar for N=${N}"
    set +e
    (
        cd "$RUN_DIR"
        decomposePar -force
    ) > "$DECOMP_LOG" 2> "$DECOMP_ERR"
    DECOMP_RC=$?
    set -e

    if (( DECOMP_RC != 0 )); then
        echo "ERROR: decomposePar failed for N=${N}, exit code ${DECOMP_RC}."
        tail -n 100 "$DECOMP_LOG" || true
        tail -n 100 "$DECOMP_ERR" || true
        exit "$DECOMP_RC"
    fi

    PROCESSOR_COUNT="$(find "$RUN_DIR" -maxdepth 1 -type d -name 'processor[0-9]*' | wc -l)"
    if (( PROCESSOR_COUNT != N )); then
        echo "ERROR: Expected ${N} processor directories, found ${PROCESSOR_COUNT}."
        exit 17
    fi

    echo "Execution mode:      host"
    echo "Nodes:               ${NODES}"
    echo "MPI ranks:           ${N}"
    echo "Ranks per node:      ${PPN}"
    echo "Decomposition:       ${NX} x ${NY} x ${NZ}"
    echo "OpenMP threads:      1"
    echo "MPI PML:             ob1"
    echo "MPI BTL:             self,vader,tcp"
    echo "Mapping:             ppr:${PPN}:node:PE=1"
    echo "Binding:             one core per rank"

    START_NS="$(date +%s%N)"
    set +e
    (
        cd "$RUN_DIR"
        mpirun \
            --mca pml ob1 \
            --mca btl self,vader,tcp \
            --map-by "ppr:${PPN}:node:PE=1" \
            --bind-to core \
            -np "$N" \
            fireFoam -parallel -case "$RUN_DIR"
    ) > "$RUN_LOG" 2> "$RUN_ERR"
    RUN_RC=$?
    set -e

    END_NS="$(date +%s%N)"
    ELAPSED="$(awk -v TSTART="$START_NS" -v TEND="$END_NS" 'BEGIN {printf "%.6f", (TEND-TSTART)/1000000000}')"

    {
        echo
        echo "============================================================"
        echo "Timing and configuration"
        echo "============================================================"
        echo "Execution mode:         host"
        echo "Nodes:                  ${NODES}"
        echo "MPI ranks:              ${N}"
        echo "Ranks per node:         ${PPN}"
        echo "Decomposition:          ${NX} x ${NY} x ${NZ}"
        echo "MPI PML:                ob1"
        echo "MPI BTL:                self,vader,tcp"
        echo "External elapsed time:  ${ELAPSED} s"
        echo "Exit code:              ${RUN_RC}"
        echo "============================================================"
    } >> "$RUN_LOG"

    printf "host\t%s\t%s\t%s\t%sx%sx%s\t%s\t%s\n" \
        "$NODES" "$N" "$PPN" "$NX" "$NY" "$NZ" "$ELAPSED" "$RUN_RC" \
        >> "$SUMMARY_FILE"

    if (( RUN_RC != 0 )); then
        echo "ERROR: host fireFoam failed for N=${N}, exit code ${RUN_RC}."
        echo "Output: ${RUN_LOG}"
        echo "Error:  ${RUN_ERR}"
        tail -n 100 "$RUN_LOG" || true
        tail -n 100 "$RUN_ERR" || true
        exit "$RUN_RC"
    fi

    if ! grep -q "^End$" "$RUN_LOG"; then
        echo "ERROR: OpenFOAM completion marker was not found for N=${N}."
        tail -n 100 "$RUN_LOG" || true
        exit 18
    fi

    echo "COMPLETED: mode=host, N=${N}, elapsed=${ELAPSED} s"
done

echo
echo "============================================================"
echo "ALL OPENFOAM HOST RUNS COMPLETED"
echo "============================================================"
echo "Summary:  ${SUMMARY_FILE}"
echo "Results:  ${CASE_ROOT}"
echo "Finished: $(date)"
echo "============================================================"

exit 0

