#!/bin/bash
#SBATCH --job-name=openfoam160run
#SBATCH --output=openfoam160run_%j.out
#SBATCH --error=openfoam160run_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=2
#SBATCH --ntasks=100
#SBATCH --ntasks-per-node=50
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

set -e
set -o pipefail

RUNTIME="${RUNTIME:-container}"
NODES="${SLURM_JOB_NUM_NODES:-0}"
TASKS="${SLURM_NTASKS:-0}"
TASKS_PER_NODE="${SLURM_NTASKS_PER_NODE:-50}"
TASKS_PER_NODE="${TASKS_PER_NODE%%(*}"
CPUS_PER_TASK="${SLURM_CPUS_PER_TASK:-1}"
JOB_ID="${SLURM_JOB_ID:-manual_$(date +%Y%m%d_%H%M%S)}"

MPI_PML="ob1"
MPI_BTL="self,tcp"

MESH_X=160
MESH_Y=160
MESH_Z=160
TOTAL_CELLS=$((MESH_X * MESH_Y * MESH_Z))

DELTA_T="0.00075"
END_TIME="0.075"
MAX_CO="0.45"
WRITE_INTERVAL=100

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close
unset OMP_PLACES || true

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

require_file()
{
    [[ -f "$1" ]] || die "Required file not found: $1"
}

require_dir()
{
    [[ -d "$1" ]] || die "Required directory not found: $1"
}

require_command()
{
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}

elapsed_seconds()
{
    python3 - "$1" "$2" <<'PYTIME'
import sys
print(f"{float(sys.argv[2]) - float(sys.argv[1]):.6f}")
PYTIME
}

set_dictionary_entry()
{
    local file="$1"
    local key="$2"
    local value="$3"

    python3 - "$file" "$key" "$value" <<'PYDICT'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]

text = path.read_text()
pattern = rf"(?m)^[ \t]*{re.escape(key)}[ \t]+[^;]+;"
replacement = f"{key:<18}{value};"

if not re.search(pattern, text):
    raise SystemExit(f"Missing dictionary entry {key!r} in {path}")

path.write_text(re.sub(pattern, replacement, text, count=1))
PYDICT
}

layout_for_ranks()
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

case "$RUNTIME" in
    host|container)
        ;;
    *)
        die "RUNTIME must be host or container."
        ;;
esac

(( NODES > 0 && TASKS > 0 )) ||
    die "Submit this script using sbatch."

(( CPUS_PER_TASK == 1 )) ||
    die "This benchmark requires --cpus-per-task=1."

case "$NODES" in
    1)
        PROCS_LIST="2 4 8 10 16 20 25 32 40 50"
        REQUIRED_TASKS=50
        ;;
    2)
        PROCS_LIST="2 4 8 10 16 20 32 40 50 64 80 100"
        REQUIRED_TASKS=100
        ;;
    4)
        PROCS_LIST="4 8 16 20 32 40 64 80 100 128 160 200"
        REQUIRED_TASKS=200
        ;;
    *)
        die "Only 1-, 2-, and 4-node allocations are supported."
        ;;
esac

(( TASKS >= REQUIRED_TASKS )) ||
    die "Expected at least ${REQUIRED_TASKS} tasks; received ${TASKS}."

for N in $PROCS_LIST; do
    (( N <= TASKS )) ||
        die "${N} ranks exceed the allocation."

    (( N % NODES == 0 )) ||
        die "${N} ranks cannot be balanced across ${NODES} nodes."
done

module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5

for command_name in \
    gcc mpirun python3 awk grep sed find
do
    require_command "$command_name"
done

MPI_VERSION="$(mpirun --version | sed -n '1p')"

case "$MPI_VERSION" in
    *4.1.5*)
        ;;
    *)
        die "Expected OpenMPI 4.1.5; detected: ${MPI_VERSION}"
        ;;
esac

# Runtime-specific configuration
if [[ "$RUNTIME" == "container" ]]; then
    PROJECT_ROOT="/beegfs/gopal/new/openfoam"
    IMAGE="${PROJECT_ROOT}/openfoam_image.sif"

    OF_ROOT="/opt/OpenFOAM/OpenFOAM-v2406"
    CASE_SOURCE="${OF_ROOT}/tutorials/combustion/fireFoam/LES/smallPoolFire3D"
    HOST_MPI_ENV="/opt/host_mpi_env.sh"

    RESULT_ROOT="${PROJECT_ROOT}/results"
    ROOT="${RESULT_ROOT}/smallPoolFire3D_160cube_container_explicit_mpi_run_${NODES}node_${JOB_ID}"

    require_file "$IMAGE"
    require_command apptainer

    CONTAINER_INIT="
        set -e
        set -o pipefail

        test -f '${HOST_MPI_ENV}'
        . '${HOST_MPI_ENV}'

        export FOAM_INST_DIR=/opt/OpenFOAM
        export WM_PROJECT_INST_DIR=/opt/OpenFOAM
        export WM_PROJECT_DIR='${OF_ROOT}'
        export WM_THIRD_PARTY_DIR=/opt/OpenFOAM/ThirdParty-v2406
        export WM_COMPILER_TYPE=system
        export WM_COMPILER=Gcc
        export WM_MPLIB=SYSTEMOPENMPI
        export WM_PRECISION_OPTION=DP
        export WM_LABEL_SIZE=32
        export WM_COMPILE_OPTION=Opt

        set +e
        set +u
        set +o pipefail
        . '${OF_ROOT}/etc/bashrc'
        BASHRC_RC=\$?
        set -e
        set -o pipefail

        if [ \"\$BASHRC_RC\" -ne 0 ]; then
            exit \"\$BASHRC_RC\"
        fi

        . '${HOST_MPI_ENV}'

        unset CPATH
        unset C_INCLUDE_PATH
        unset CPLUS_INCLUDE_PATH

        export OMP_NUM_THREADS=1
        export OMP_PROC_BIND=false
        unset OMP_PLACES
    "

    run_serial()
    {
        local case_dir="$1"
        shift
        local command="$*"

        apptainer exec \
            --cleanenv \
            --bind /beegfs/Tools:/beegfs/Tools:ro \
            --bind "${case_dir}:/case" \
            --pwd /case \
            --env OMP_NUM_THREADS=1 \
            --env OMP_PROC_BIND=false \
            "$IMAGE" \
            /bin/bash -lc "
                ${CONTAINER_INIT}
                cd /case
                ${command}
            "
    }
else
    HOST_ROOT="/beegfs/gopal/new/openfoam/host"
    OF_BASHRC=""

    for candidate in \
        "${HOST_ROOT}/OpenFOAM/OpenFOAM-v2406/etc/bashrc" \
        "${HOST_ROOT}/OpenFOAM-v2406/etc/bashrc" \
        "${HOST_ROOT}/OpenFOAM/OpenFOAM-2406/etc/bashrc" \
        "${HOST_ROOT}/OpenFOAM-2406/etc/bashrc"
    do
        if [[ -f "$candidate" ]]; then
            OF_BASHRC="$candidate"
            break
        fi
    done

    if [[ -z "$OF_BASHRC" ]]; then
        OF_BASHRC="$(
            find "$HOST_ROOT" \
                -type f \
                -path '*/OpenFOAM-v2406/etc/bashrc' \
                -print \
                -quit 2>/dev/null || true
        )"
    fi

    [[ -n "$OF_BASHRC" && -f "$OF_BASHRC" ]] ||
        die "Could not locate host OpenFOAM-v2406/etc/bashrc below ${HOST_ROOT}."

    OF_ROOT="$(dirname "$(dirname "$OF_BASHRC")")"
    FOAM_BASE="$(dirname "$OF_ROOT")"

    CASE_SOURCE="${OF_ROOT}/tutorials/combustion/fireFoam/LES/smallPoolFire3D"
    RESULT_ROOT="${HOST_ROOT}/results"
    ROOT="${RESULT_ROOT}/smallPoolFire3D_160cube_host_explicit_mpi_2ndrun_${NODES}node_${JOB_ID}"

    require_dir "$CASE_SOURCE"

    export FOAM_INST_DIR="$FOAM_BASE"
    export WM_PROJECT_INST_DIR="$FOAM_BASE"
    export WM_PROJECT_DIR="$OF_ROOT"
    export WM_THIRD_PARTY_DIR="${FOAM_BASE}/ThirdParty-v2406"
    export WM_COMPILER_TYPE=system
    export WM_COMPILER=Gcc
    export WM_MPLIB=SYSTEMOPENMPI
    export WM_PRECISION_OPTION=DP
    export WM_LABEL_SIZE=32
    export WM_COMPILE_OPTION=Opt

    set +e
    set +u
    set +o pipefail

    . "$OF_BASHRC"
    BASHRC_RC=$?

    set -e
    set -o pipefail

    (( BASHRC_RC == 0 )) ||
        die "OpenFOAM environment failed while sourcing ${OF_BASHRC}."

    for command_name in blockMesh checkMesh decomposePar fireFoam; do
        require_command "$command_name"
    done

    run_serial()
    {
        local case_dir="$1"
        shift
        (
            cd "$case_dir"
            "$@"
        )
    }
fi

# Output directories
BASE_CASE="${ROOT}/base_case"
RUNS_DIR="${ROOT}/runs"
LOGS_DIR="${ROOT}/logs"
SUMMARY_FILE="${ROOT}/timing_summary.tsv"

rm -rf "$ROOT"
mkdir -p "$BASE_CASE" "$RUNS_DIR" "$LOGS_DIR"

exec > >(stdbuf -oL -eL tee -a "${LOGS_DIR}/console.log") 2>&1

echo "============================================================"
echo "OpenFOAM v2406-160-cube explicit MPI"
echo "============================================================"
echo "Runtime:             ${RUNTIME}"
echo "Nodes:               ${NODES}"
echo "Allocated tasks:     ${TASKS}"
echo "Processor list:      ${PROCS_LIST}"
echo "Mesh:                ${MESH_X} x ${MESH_Y} x ${MESH_Z}"
echo "Total cells:         ${TOTAL_CELLS}"
echo "deltaT:              ${DELTA_T}"
echo "endTime:             ${END_TIME}"
echo "Expected steps:      100"
echo "MPI:                 ${MPI_VERSION}"
echo "Results:             ${ROOT}"
if [[ "$RUNTIME" == "host" ]]; then
    echo "OpenFOAM root:       ${OF_ROOT}"
    echo "OpenFOAM bashrc:     ${OF_BASHRC}"
fi
echo "============================================================"

# Copy tutorial
if [[ "$RUNTIME" == "container" ]]; then
    run_serial "$BASE_CASE" "cp -a '${CASE_SOURCE}/.' /case/"
else
    cp -a "${CASE_SOURCE}/." "${BASE_CASE}/"
fi

require_file "${BASE_CASE}/system/blockMeshDict"
require_file "${BASE_CASE}/system/controlDict"
require_dir "${BASE_CASE}/0.orig"

# Change mesh and simulation settings
python3 - "${BASE_CASE}/system/blockMeshDict" <<'PYMESH'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

pattern = r"\(\s*60\s+60\s+60\s*\)"

if not re.search(pattern, text):
    raise SystemExit("Original (60 60 60) mesh entry was not found.")

path.write_text(re.sub(pattern, "(160 160 160)", text, count=1))
PYMESH

set_dictionary_entry "${BASE_CASE}/system/controlDict" deltaT "$DELTA_T"
set_dictionary_entry "${BASE_CASE}/system/controlDict" endTime "$END_TIME"
set_dictionary_entry "${BASE_CASE}/system/controlDict" adjustTimeStep no
set_dictionary_entry "${BASE_CASE}/system/controlDict" maxCo "$MAX_CO"
set_dictionary_entry "${BASE_CASE}/system/controlDict" writeControl timeStep
set_dictionary_entry "${BASE_CASE}/system/controlDict" writeInterval "$WRITE_INTERVAL"

# Fixed-iteration fvSolution
cat > "${BASE_CASE}/system/fvSolution" <<'EOF_FVSOLUTION'
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
EOF_FVSOLUTION

# Generate and validate common mesh
rm -rf \
    "${BASE_CASE}/processor"* \
    "${BASE_CASE}/constant/polyMesh" \
    "${BASE_CASE}/0"

cp -a "${BASE_CASE}/0.orig" "${BASE_CASE}/0"

if [[ "$RUNTIME" == "container" ]]; then
    run_serial "$BASE_CASE" \
        "blockMesh > /case/log.blockMesh 2> /case/err.blockMesh"

    run_serial "$BASE_CASE" \
        "checkMesh > /case/log.checkMesh 2> /case/err.checkMesh"
else
    (
        cd "$BASE_CASE"
        blockMesh > log.blockMesh 2> err.blockMesh
        checkMesh > log.checkMesh 2> err.checkMesh
    )
fi

grep -q "Mesh OK" "${BASE_CASE}/log.checkMesh" ||
    die "checkMesh did not report Mesh OK."

DETECTED_CELLS="$(
    awk '
        /^[[:space:]]*cells:/ {
            value=$2
        }
        END {
            print value
        }
    ' "${BASE_CASE}/log.checkMesh"
)"

[[ "$DETECTED_CELLS" == "$TOTAL_CELLS" ]] ||
    die "Expected ${TOTAL_CELLS} cells; detected ${DETECTED_CELLS:-unknown}."

echo "Exact ${TOTAL_CELLS}-cell mesh confirmed."

# Benchmark sweep
printf \
'nodes\tranks\tlayout\tlocal_mesh\tcells_per_rank\telapsed_seconds\texit_code\n' \
    > "$SUMMARY_FILE"

for N in $PROCS_LIST; do
    read -r NX NY NZ < <(layout_for_ranks "$N") ||
        die "No layout defined for N=${N}."

    (( NX * NY * NZ == N )) ||
        die "Invalid decomposition ${NX}x${NY}x${NZ} for N=${N}."

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
    PPN=$((N / NODES))

    RUN_DIR="${RUNS_DIR}/case_N${N}"
    RUN_LOG="${LOGS_DIR}/log.${N}proc"
    RUN_ERR="${LOGS_DIR}/err.${N}proc"

    rm -rf "$RUN_DIR"
    mkdir -p "$RUN_DIR"
    cp -a "${BASE_CASE}/." "$RUN_DIR/"

    rm -rf "${RUN_DIR}/processor"* "${RUN_DIR}/0"
    cp -a "${RUN_DIR}/0.orig" "${RUN_DIR}/0"
    cat > "${RUN_DIR}/system/decomposeParDict" <<EOF_DECOMPOSE
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
EOF_DECOMPOSE

    echo
    echo "============================================================"
    echo "RUN: runtime=${RUNTIME}, nodes=${NODES}, ranks=${N}"
    echo "============================================================"
    echo "Decomposition:      ${NX} x ${NY} x ${NZ}"
    echo "Local mesh/rank:    ${LOCAL_X} x ${LOCAL_Y} x ${LOCAL_Z}"
    echo "Cells per rank:     ${CELLS_PER_RANK}"
    echo "Ranks per node:     ${PPN}"

    if [[ "$RUNTIME" == "container" ]]; then
        run_serial "$RUN_DIR" \
            "decomposePar -force > /case/log.decompose 2> /case/err.decompose"
    else
        (
            cd "$RUN_DIR"
            decomposePar -force > log.decompose 2> err.decompose
        )
    fi

    grep -q "^End$" "${RUN_DIR}/log.decompose" ||
        die "decomposePar did not complete for N=${N}."

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

    START_EPOCH="$(date +%s.%N)"

    set +e

    if [[ "$RUNTIME" == "container" ]]; then
        export OMP_NUM_THREADS=1
        export OMP_PROC_BIND=close
        unset OMP_PLACES || true

        export OMPI_MCA_pml="$MPI_PML"
        export OMPI_MCA_btl="$MPI_BTL"

        mpirun \
            --mca pml "$MPI_PML" \
            --mca btl "$MPI_BTL" \
            --map-by "ppr:${PPN}:node:PE=1" \
            --bind-to core \
            -np "$N" \
            apptainer exec \
                --bind /beegfs/Tools:/beegfs/Tools:ro \
                --bind "${RUN_DIR}:/case" \
                --pwd /case \
                --env OMP_NUM_THREADS=1 \
                --env OMP_PROC_BIND=close \
                --env OMPI_MCA_pml="$MPI_PML" \
                --env OMPI_MCA_btl="$MPI_BTL" \
                "$IMAGE" \
                /bin/bash -lc "
                    ${CONTAINER_INIT}
                    export OMP_NUM_THREADS=1
                    export OMP_PROC_BIND=close
                    unset OMP_PLACES

                    export OMPI_MCA_pml='${MPI_PML}'
                    export OMPI_MCA_btl='${MPI_BTL}'
                    cd /case
                    exec fireFoam -parallel -case /case
                " \
            > "$RUN_LOG" \
            2> "$RUN_ERR"
    else
        export OMP_NUM_THREADS=1
        export OMP_PROC_BIND=close
        unset OMP_PLACES || true

        export OMPI_MCA_pml="$MPI_PML"
        export OMPI_MCA_btl="$MPI_BTL"
        mpirun \
            --mca pml "$MPI_PML" \
            --mca btl "$MPI_BTL" \
            --map-by "ppr:${PPN}:node:PE=1" \
            --bind-to core \
            -np "$N" \
            fireFoam \
                -parallel \
                -case "$RUN_DIR" \
            > "$RUN_LOG" \
            2> "$RUN_ERR"
    fi

    RUN_RC=$?
    set -e

    END_EPOCH="$(date +%s.%N)"
    ELAPSED="$(elapsed_seconds "$START_EPOCH" "$END_EPOCH")"

    if (( RUN_RC != 0 )); then
        tail -n 100 "$RUN_LOG" || true
        tail -n 100 "$RUN_ERR" || true
        die "fireFoam failed for N=${N}, exit code ${RUN_RC}."
    fi

    grep -q "^End$" "$RUN_LOG" ||
        die "OpenFOAM completion marker missing for N=${N}."

    DETECTED_NPROCS="$(
        awk '
            /^[[:space:]]*nProcs[[:space:]]*:/ {
                print $3
                exit
            }
        ' "$RUN_LOG"
    )"

    [[ "$DETECTED_NPROCS" == "$N" ]] ||
        die "Requested ${N} ranks, but OpenFOAM reported ${DETECTED_NPROCS:-unknown}."

    printf \
'%s\t%s\t%sx%sx%s\t%sx%sx%s\t%s\t%s\t%s\n' \
        "$NODES" \
        "$N" \
        "$NX" "$NY" "$NZ" \
        "$LOCAL_X" "$LOCAL_Y" "$LOCAL_Z" \
        "$CELLS_PER_RANK" \
        "$ELAPSED" \
        "$RUN_RC" \
        >> "$SUMMARY_FILE"

    echo "COMPLETED: N=${N}, elapsed=${ELAPSED} s"
done

echo
echo "============================================================"
echo "ALL OPENFOAM RUNS COMPLETED"
echo "============================================================"
echo "Runtime:  ${RUNTIME}"
echo "Results:  ${ROOT}"
echo "Summary:  ${SUMMARY_FILE}"
echo "============================================================"
