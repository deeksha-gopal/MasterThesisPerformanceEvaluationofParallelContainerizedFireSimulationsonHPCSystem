#!/bin/bash
#SBATCH --job-name=openfoam160_serial
#SBATCH --output=openfoam160_serial_%j.out
#SBATCH --error=openfoam160_serial_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

set -e
set -o pipefail

RUNTIME="${RUNTIME:-host}"

NODES="${SLURM_JOB_NUM_NODES:-0}"
TASKS="${SLURM_NTASKS:-0}"
TASKS_PER_NODE="${SLURM_NTASKS_PER_NODE:-1}"
TASKS_PER_NODE="${TASKS_PER_NODE%%(*}"
CPUS_PER_TASK="${SLURM_CPUS_PER_TASK:-1}"

JOB_ID="${SLURM_JOB_ID:-manual_$(date +%Y%m%d_%H%M%S)}"

# Same MPI/software environment as parallel benchmark
MPI_PML="ob1"
MPI_BTL="self,tcp"

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close
unset OMP_PLACES || true

# Keep the same OpenMPI environment even though mpirun is not used.
export OMPI_MCA_pml="$MPI_PML"
export OMPI_MCA_btl="$MPI_BTL"

# Fixed problem
MESH_X=160
MESH_Y=160
MESH_Z=160

TOTAL_CELLS=$((MESH_X * MESH_Y * MESH_Z))

DELTA_T="0.00075"
END_TIME="0.075"

MAX_CO="0.45"

EXPECTED_STEPS=100
WRITE_INTERVAL=100

# Helper Functions
die()
{
    echo "ERROR: $*" >&2
    exit 1
}

require_file()
{
    [[ -f "$1" ]] ||
        die "Required file not found: $1"
}

require_dir()
{
    [[ -d "$1" ]] ||
        die "Required directory not found: $1"
}

require_command()
{
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}

timestamp()
{
    date '+%Y-%m-%d %H:%M:%S %Z'
}

elapsed_seconds()
{
    python3 - "$1" "$2" <<'PYTIME'
import sys

start = float(sys.argv[1])
end = float(sys.argv[2])

print(f"{end-start:.6f}")
PYTIME
}

show_failure_logs()
{
    local stdout_file="$1"
    local stderr_file="$2"

    echo "---------------- stdout ----------------"

    [[ -s "$stdout_file" ]] &&
        tail -n 200 "$stdout_file" || true

    echo "---------------- stderr ----------------"

    [[ -s "$stderr_file" ]] &&
        tail -n 200 "$stderr_file" || true

    echo "----------------------------------------"
}

# Modify OpenFOAM dictionary entry
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
    raise SystemExit(
        f"Missing dictionary entry {key!r} in {path}"
    )

path.write_text(
    re.sub(
        pattern,
        replacement,
        text,
        count=1,
    )
)

PYDICT
}

# Validate Slurm allocation
case "$RUNTIME" in

    host|container)
        ;;

    *)
        die "RUNTIME must be host or container."
        ;;

esac

(( NODES == 1 )) ||
    die "Serial baseline requires exactly 1 node; received ${NODES}."

(( TASKS == 1 )) ||
    die "Serial baseline requires exactly 1 Slurm task; received ${TASKS}."

(( CPUS_PER_TASK == 1 )) ||
    die "Serial baseline requires --cpus-per-task=1."

# Load same compiler and MPI stack
module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5

for command_name in \
    gcc \
    mpirun \
    python3 \
    awk \
    grep \
    sed \
    find \
    wc \
    tee \
    scontrol
do
    require_command "$command_name"
done

GCC_VERSION="$(gcc --version | head -1)"
MPI_VERSION="$(mpirun --version | sed -n '1p')"

case "$GCC_VERSION" in

    *12.3.0*)
        ;;

    *)
        die "Expected GCC 12.3.0; detected: ${GCC_VERSION}"
        ;;

esac

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

    ROOT="${PROJECT_ROOT}/results/smallPoolFire3D_160cube_container_serial_1proc_${JOB_ID}"

    require_file "$IMAGE"
    require_command apptainer

    # Same container environment as parallel benchmark
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
            echo 'ERROR: OpenFOAM bashrc initialization failed.'
            exit \"\$BASHRC_RC\"
        fi

        # Re-apply host compiler/OpenMPI environment.
        . '${HOST_MPI_ENV}'

        unset CPATH
        unset C_INCLUDE_PATH
        unset CPLUS_INCLUDE_PATH

        export OMP_NUM_THREADS=1
        export OMP_PROC_BIND=close
        unset OMP_PLACES

        export OMPI_MCA_pml='${MPI_PML}'
        export OMPI_MCA_btl='${MPI_BTL}'
    "
    # Helper for untimed serial setup commands
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
            --env OMP_PROC_BIND=close \
            --env OMPI_MCA_pml="$MPI_PML" \
            --env OMPI_MCA_btl="$MPI_BTL" \
            "$IMAGE" \
            /bin/bash -lc "
                ${CONTAINER_INIT}

                cd /case

                ${command}
            "
    }

else
    # Host OpenFOAM
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
        die \
        "Could not locate host OpenFOAM-v2406/etc/bashrc below ${HOST_ROOT}."

    OF_ROOT="$(dirname "$(dirname "$OF_BASHRC")")"

    FOAM_BASE="$(dirname "$OF_ROOT")"

    CASE_SOURCE="${OF_ROOT}/tutorials/combustion/fireFoam/LES/smallPoolFire3D"

    ROOT="${HOST_ROOT}/results/smallPoolFire3D_160cube_host_serial_1proc_${JOB_ID}"

    require_dir "$CASE_SOURCE"
    
    # Same host OpenFOAM environment as parallel benchmark
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
        die \
        "OpenFOAM environment failed while sourcing ${OF_BASHRC}."
        
    # Reassert benchmark environment
    export OMP_NUM_THREADS=1
    export OMP_PROC_BIND=close
    unset OMP_PLACES || true

    export OMPI_MCA_pml="$MPI_PML"
    export OMPI_MCA_btl="$MPI_BTL"

    for command_name in \
        blockMesh \
        checkMesh \
        fireFoam
    do
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

RUN_DIR="${ROOT}/run"

LOGS_DIR="${ROOT}/logs"

RUN_LOG="${RUN_DIR}/log.1proc"
RUN_ERR="${RUN_DIR}/err.1proc"

SUMMARY_FILE="${ROOT}/timing_summary.tsv"

rm -rf "$ROOT"

mkdir -p \
    "$BASE_CASE" \
    "$RUN_DIR" \
    "$LOGS_DIR"

exec > >(
    stdbuf -oL -eL \
    tee -a "${LOGS_DIR}/console.log"
) 2>&1

# Benchmark information
echo "============================================================"
echo "OpenFOAM v2406-160-cube SERIAL BASELINE"
echo "============================================================"
echo "Runtime:             ${RUNTIME}"
echo "Job ID:              ${JOB_ID}"
echo "Nodes:               1"
echo "Processes:           1"
echo "OpenMP threads:      1"
echo "Solver:              fireFoam"
echo "Mesh:                ${MESH_X} x ${MESH_Y} x ${MESH_Z}"
echo "Total cells:         ${TOTAL_CELLS}"
echo "Cells/process:       ${TOTAL_CELLS}"
echo "deltaT:              ${DELTA_T}"
echo "endTime:             ${END_TIME}"
echo "adjustTimeStep:      no"
echo "maxCo:               ${MAX_CO}"
echo "Expected steps:      ${EXPECTED_STEPS}"
echo "writeInterval:       ${WRITE_INTERVAL}"
echo "Compiler:            ${GCC_VERSION}"
echo "MPI environment:     ${MPI_VERSION}"
echo "MPI PML/BTL:         ${MPI_PML} / ${MPI_BTL}"
echo "OMP_NUM_THREADS:     ${OMP_NUM_THREADS}"
echo "OMP_PROC_BIND:       ${OMP_PROC_BIND}"
echo "Execution mode:      serial"
echo "Results:             ${ROOT}"

if [[ "$RUNTIME" == "host" ]]; then

    echo "OpenFOAM root:       ${OF_ROOT}"
    echo "OpenFOAM bashrc:     ${OF_BASHRC}"
fi
echo "============================================================"

scontrol show hostnames "$SLURM_JOB_NODELIST" |
    tee "${LOGS_DIR}/allocated_nodes.txt"

# Copy tutorial
if [[ "$RUNTIME" == "container" ]]; then

    run_serial \
        "$BASE_CASE" \
        "cp -a '${CASE_SOURCE}/.' /case/"

else

    cp -a \
        "${CASE_SOURCE}/." \
        "${BASE_CASE}/"

fi

require_file \
    "${BASE_CASE}/system/blockMeshDict"

require_file \
    "${BASE_CASE}/system/controlDict"

require_dir \
    "${BASE_CASE}/0.orig"

# Change mesh from 60x60x60 to 160x160x160
python3 - \
    "${BASE_CASE}/system/blockMeshDict" <<'PYMESH'

from pathlib import Path
import re
import sys

path = Path(sys.argv[1])

text = path.read_text()

pattern = r"\(\s*60\s+60\s+60\s*\)"

if not re.search(pattern, text):
    raise SystemExit(
        "Original (60 60 60) mesh entry was not found."
    )

text = re.sub(
    pattern,
    "(160 160 160)",
    text,
    count=1,
)

path.write_text(text)

PYMESH

# Exactly same simulation controls as parallel benchmark
set_dictionary_entry \
    "${BASE_CASE}/system/controlDict" \
    deltaT \
    "$DELTA_T"

set_dictionary_entry \
    "${BASE_CASE}/system/controlDict" \
    endTime \
    "$END_TIME"

set_dictionary_entry \
    "${BASE_CASE}/system/controlDict" \
    adjustTimeStep \
    no

set_dictionary_entry \
    "${BASE_CASE}/system/controlDict" \
    maxCo \
    "$MAX_CO"

set_dictionary_entry \
    "${BASE_CASE}/system/controlDict" \
    writeControl \
    timeStep

set_dictionary_entry \
    "${BASE_CASE}/system/controlDict" \
    writeInterval \
    "$WRITE_INTERVAL"

# Same fvSolution as MPI benchmark
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

# Generate global serial mesh
rm -rf \
    "${BASE_CASE}/processor"* \
    "${BASE_CASE}/constant/polyMesh" \
    "${BASE_CASE}/0"

cp -a \
    "${BASE_CASE}/0.orig" \
    "${BASE_CASE}/0"

if [[ "$RUNTIME" == "container" ]]; then

    run_serial \
        "$BASE_CASE" \
        "blockMesh > /case/log.blockMesh 2> /case/err.blockMesh"

    run_serial \
        "$BASE_CASE" \
        "checkMesh > /case/log.checkMesh 2> /case/err.checkMesh"

else

    (
        cd "$BASE_CASE"

        blockMesh \
            > log.blockMesh \
            2> err.blockMesh

        checkMesh \
            > log.checkMesh \
            2> err.checkMesh
    )

fi

# Verify mesh
grep -q "Mesh OK" \
    "${BASE_CASE}/log.checkMesh" ||
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
    die \
    "Expected ${TOTAL_CELLS} cells; detected ${DETECTED_CELLS:-unknown}."

echo
echo "Exact ${TOTAL_CELLS}-cell mesh confirmed."

# Prepare clean run case
rm -rf "$RUN_DIR"

mkdir -p "$RUN_DIR"

cp -a \
    "${BASE_CASE}/." \
    "$RUN_DIR/"

# No parallel decomposition allowed
rm -rf \
    "${RUN_DIR}/processor"*

PROCESSOR_COUNT="$(
    find "$RUN_DIR" \
        -maxdepth 1 \
        -type d \
        -name 'processor[0-9]*' |
    wc -l |
    tr -d '[:space:]'
)"

[[ "$PROCESSOR_COUNT" -eq 0 ]] ||
    die \
    "Serial case unexpectedly contains processor directories."

# Summary file
printf \
'nodes\tranks\tthreads\tmesh\ttotal_cells\tcells_per_rank\tdelta_t\tend_time\texternal_time_s\texit_code\tstatus\tcase_directory\n' \
    > "$SUMMARY_FILE"

# SERIAL RUN
echo
echo "============================================================"
echo "OPENFOAM SERIAL RUN"
echo "============================================================"
echo "Runtime:             ${RUNTIME}"
echo "Nodes:               1"
echo "Processes:           1"
echo "OpenMP threads:      1"
echo "Global mesh:         160 x 160 x 160"
echo "Total cells:         ${TOTAL_CELLS}"
echo "Cells/process:       ${TOTAL_CELLS}"
echo "deltaT:              ${DELTA_T}"
echo "endTime:             ${END_TIME}"
echo "Expected steps:      ${EXPECTED_STEPS}"
echo "Command:             fireFoam -case <case>"
echo "============================================================"

START_TEXT="$(timestamp)"
START_EPOCH="$(date +%s.%N)"

set +e

# Container serial execution
if [[ "$RUNTIME" == "container" ]]; then

    export OMP_NUM_THREADS=1
    export OMP_PROC_BIND=close
    unset OMP_PLACES || true

    export OMPI_MCA_pml="$MPI_PML"
    export OMPI_MCA_btl="$MPI_BTL"

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

            exec fireFoam \
                -case /case
        " \
        > "$RUN_LOG" \
        2> "$RUN_ERR"

# Host serial execution
else

    export OMP_NUM_THREADS=1
    export OMP_PROC_BIND=close
    unset OMP_PLACES || true

    export OMPI_MCA_pml="$MPI_PML"
    export OMPI_MCA_btl="$MPI_BTL"

    fireFoam \
        -case "$RUN_DIR" \
        > "$RUN_LOG" \
        2> "$RUN_ERR"

fi

RUN_RC=$?

set -e

END_EPOCH="$(date +%s.%N)"
END_TEXT="$(timestamp)"

ELAPSED="$(
    elapsed_seconds \
        "$START_EPOCH" \
        "$END_EPOCH"
)"

# Validate return code
if (( RUN_RC != 0 )); then

    show_failure_logs \
        "$RUN_LOG" \
        "$RUN_ERR"

    die \
        "fireFoam serial run failed, exit code ${RUN_RC}."

fi

# Detect genuine OpenFOAM errors
if grep -Eiq \
    -- '--> FOAM FATAL|FOAM parallel run exiting|MPI_ABORT|Segmentation fault|Floating point exception \(core dumped\)|Killed process|Out of memory' \
    "$RUN_LOG" \
    "$RUN_ERR"
then

    show_failure_logs \
        "$RUN_LOG" \
        "$RUN_ERR"

    die \
        "A genuine OpenFOAM error was detected."

fi

# Completion marker
grep -q "^End$" \
    "$RUN_LOG" ||
    die \
    "OpenFOAM completion marker missing."

# Verify this was NOT a parallel run
if grep -q \
    'Pstream initialized with:' \
    "$RUN_LOG"
then

    echo "Pstream initialization detected; checking process count."
fi

# Extract final physical simulation time
FINAL_TIME="$(
    sed -nE \
        's/^[[:space:]]*Time[[:space:]]*=[[:space:]]*([-+0-9.eEdD]+).*/\1/p' \
        "$RUN_LOG" |
    tail -1
)"

# fireFoam commonly prints "Time = ..." rather than "runTime = ..."
[[ -n "$FINAL_TIME" ]] ||
    die \
    "Could not determine final OpenFOAM simulation time."

# Confirm requested endTime
python3 - \
    "$FINAL_TIME" \
    "$END_TIME" <<'PYFINAL'

import math
import sys

actual = float(
    sys.argv[1]
    .replace("D", "E")
    .replace("d", "e")
)

expected = float(sys.argv[2])

if not math.isclose(
    actual,
    expected,
    rel_tol=0.0,
    abs_tol=1.0e-10,
):
    raise SystemExit(
        f"Final simulation time {actual} "
        f"does not equal endTime {expected}."
    )

PYFINAL

# Confirm no processor directories appeared
PROCESSOR_COUNT_AFTER="$(
    find "$RUN_DIR" \
        -maxdepth 1 \
        -type d \
        -name 'processor[0-9]*' |
    wc -l |
    tr -d '[:space:]'
)"

[[ "$PROCESSOR_COUNT_AFTER" -eq 0 ]] ||
    die \
    "Serial execution unexpectedly produced processor directories."

# Summary
STATUS="completed"

printf \
'%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "1" \
    "1" \
    "1" \
    "160x160x160" \
    "$TOTAL_CELLS" \
    "$TOTAL_CELLS" \
    "$DELTA_T" \
    "$END_TIME" \
    "$ELAPSED" \
    "$RUN_RC" \
    "$STATUS" \
    "$RUN_DIR" \
    >> "$SUMMARY_FILE"

# Final report
echo
echo "============================================================"
echo "OPENFOAM SERIAL BASELINE SUMMARY"
echo "============================================================"
echo "Runtime:               ${RUNTIME}"
echo "Nodes:                 1"
echo "Processes:             1"
echo "OpenMP threads:        1"
echo "Execution mode:        serial"
echo "Solver:                fireFoam"
echo "Command:               fireFoam -case ..."
echo "Global mesh:           160 x 160 x 160"
echo "Total cells:           ${TOTAL_CELLS}"
echo "Cells/process:         ${TOTAL_CELLS}"
echo "deltaT:                ${DELTA_T}"
echo "endTime:               ${END_TIME}"
echo "Final simulation time: ${FINAL_TIME}"
echo "External elapsed:      ${ELAPSED} s"
echo "Compiler:              ${GCC_VERSION}"
echo "MPI environment:       ${MPI_VERSION}"
echo "Exit code:             ${RUN_RC}"
echo "Status:                ${STATUS}"
echo "Start:                 ${START_TEXT}"
echo "End:                   ${END_TEXT}"
echo "Results:               ${ROOT}"
echo "Summary:               ${SUMMARY_FILE}"
echo "============================================================"

exit 0
