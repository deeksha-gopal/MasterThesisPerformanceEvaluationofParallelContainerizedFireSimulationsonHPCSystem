#!/bin/bash
#SBATCH --job-name=pato4096k_serial
#SBATCH --output=pato4096k_serial_%j.out
#SBATCH --error=pato4096k_serial_%j.err
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

# Same software/runtime configuration as parallel runs
MPI_PML="ob1"
MPI_BTL="self,tcp"

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close
unset OMP_PLACES || true

# Does not create MPI processes in this script. But preserves the same OpenMPI environment.
export OMPI_MCA_pml="$MPI_PML"
export OMPI_MCA_btl="$MPI_BTL"

# Simulation configuration
DELTA_T="0.00075"
END_TIME="0.075"
EXPECTED_STEPS=100

NPS=64
NPD=34
NPY=320

EXPECTED_CELLS=4096000

REGION="porousMat"

# Helper Function
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

require_nonempty_file()
{
    [[ -s "$1" ]] ||
        die "Required file missing or empty: $1"
}

require_directory()
{
    [[ -d "$1" ]] ||
        die "Required directory not found: $1"
}

require_executable()
{
    [[ -x "$1" ]] ||
        die "Required executable missing or not executable: $1"
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

# Disable PATO probing output
# Same modification used in your parallel PATO benchmark.
disable_probing_functions()
{
    local file="$1"

    python3 - "$file" <<'PYPROBE'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

pattern = re.compile(
    r"(?ms)"
    r"^[ \t]*probingFunctions[ \t]*\n"
    r"[ \t]*\([ \t]*\n"
    r".*?"
    r"^[ \t]*\)[ \t]*;"
)

matches = list(pattern.finditer(text))

if len(matches) != 1:
    raise SystemExit(
        f"Expected exactly one probingFunctions list "
        f"in {path}; found {len(matches)}"
    )

replacement = (
    "  probingFunctions\n"
    "  (\n"
    "  );"
)

path.write_text(
    pattern.sub(
        replacement,
        text,
        count=1,
    )
)
PYPROBE
}

verify_probing_disabled()
{
    local file="$1"

    python3 - "$file" <<'PYVERIFY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

match = re.search(
    r"(?ms)"
    r"^[ \t]*probingFunctions[ \t]*\n"
    r"[ \t]*\((.*?)^[ \t]*\)[ \t]*;",
    text,
)

if not match:
    raise SystemExit(
        f"probingFunctions list not found in {path}"
    )

if match.group(1).strip():
    raise SystemExit(
        f"probingFunctions is not empty in {path}: "
        f"{match.group(1)!r}"
    )

print("Confirmed: probingFunctions is empty")
PYVERIFY
}

# Validate allocation
case "$RUNTIME" in

    host|container)
        ;;

    *)
        die "RUNTIME must be host or container. Received: $RUNTIME."
        ;;

esac

(( NODES == 1 )) ||
    die "Serial baseline requires exactly 1 node; received $NODES."

(( TASKS == 1 )) ||
    die "Serial baseline requires exactly 1 Slurm task; received $TASKS."

(( CPUS_PER_TASK == 1 )) ||
    die "Serial baseline requires --cpus-per-task=1."

# Load same compiler and MPI stack
module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5
module load M4/1.4.19

for command_name in \
    gcc \
    mpirun \
    python3 \
    awk \
    grep \
    sed \
    m4 \
    find \
    wc \
    tee \
    scontrol
do
    require_command "$command_name"
done

GCC_VERSION="$(gcc --version | head -1)"
MPI_VERSION="$(mpirun --version | head -1)"

case "$GCC_VERSION" in

    *12.3.0*)
        ;;

    *)
        die "Expected GCC 12.3.0; detected: $GCC_VERSION"
        ;;

esac

case "$MPI_VERSION" in

    *4.1.5*)
        ;;

    *)
        die "Expected OpenMPI 4.1.5; detected: $MPI_VERSION"
        ;;

esac

# Runtime-specific configuration
if [[ "$RUNTIME" == "container" ]]; then

    BASE_ROOT="/beegfs/gopal/new/pato"

    IMAGE="${BASE_ROOT}/pato_image.sif"

    PATO_ROOT="/opt/pato-3.1"
    OPENFOAM_ROOT="/opt/OpenFOAM/OpenFOAM-7"
    HOST_MPI_ENV="/opt/host_mpi_env.sh"

    CASE_SOURCE="${PATO_ROOT}/tutorials/3D/ArcJet_cylinder_3D"
    PATO_BIN="${PATO_ROOT}/install/bin/PATOx"

    ROOT="${BASE_ROOT}/results/ArcJet_cylinder_3D_4096k_container_serial_1proc_${JOB_ID}"

    require_file "$IMAGE"
    require_command apptainer
    
    # Container initialization
    read -r -d '' CONTAINER_INIT <<EOF_CONTAINER_INIT || true
set -e
set -o pipefail

test -f '${HOST_MPI_ENV}'

. '${HOST_MPI_ENV}'

export FOAM_INST_DIR=/opt/OpenFOAM
export WM_PROJECT_INST_DIR=/opt/OpenFOAM
export WM_PROJECT_DIR='${OPENFOAM_ROOT}'
export WM_THIRD_PARTY_DIR=/opt/OpenFOAM/ThirdParty-7

export WM_COMPILER_TYPE=system
export WM_COMPILER=Gcc
export WM_MPLIB=SYSTEMOPENMPI

export WM_PRECISION_OPTION=DP
export WM_LABEL_SIZE=32
export WM_COMPILE_OPTION=Opt

export PATO_DIR='${PATO_ROOT}'

set +e
set +u
set +o pipefail

. '${OPENFOAM_ROOT}/etc/bashrc'
OPENFOAM_RC=\$?

. '${PATO_ROOT}/bashrc'
PATO_RC=\$?

set -e
set -o pipefail

if [ "\$OPENFOAM_RC" -ne 0 ] || [ "\$PATO_RC" -ne 0 ]; then
    echo 'ERROR: OpenFOAM/PATO environment initialization failed.'
    exit 10
fi

# Re-apply cluster OpenMPI/GCC environment after OpenFOAM/PATO bashrc.
. '${HOST_MPI_ENV}'

unset CPATH
unset C_INCLUDE_PATH
unset CPLUS_INCLUDE_PATH

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close
unset OMP_PLACES

export OMPI_MCA_pml='${MPI_PML}'
export OMPI_MCA_btl='${MPI_BTL}'
EOF_CONTAINER_INIT

    # Serial helper for setup commands
    run_serial_container()
    {
        local case_dir="$1"

        shift

        local command="$*"
        local container_command

        container_command="$(
            cat <<EOF_SERIAL
${CONTAINER_INIT}

cd /case

${command}
EOF_SERIAL
        )"

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
            /bin/bash -lc "$container_command"
    }

else

    BASE_ROOT="/beegfs/gopal/new/pato/host"

    OPENFOAM_BASE="${BASE_ROOT}/OpenFOAM"
    OPENFOAM_ROOT="${OPENFOAM_BASE}/OpenFOAM-7"

    PATO_ROOT="${BASE_ROOT}/pato-3.1"

    CASE_SOURCE="${PATO_ROOT}/tutorials/3D/ArcJet_cylinder_3D"
    PATO_BIN="${PATO_ROOT}/install/bin/PATOx"

    ROOT="${BASE_ROOT}/results/ArcJet_cylinder_3D_4096k_host_serial_1proc_${JOB_ID}"

    require_file "${OPENFOAM_ROOT}/etc/bashrc"
    require_file "${PATO_ROOT}/bashrc"

    require_directory "$CASE_SOURCE"
    require_executable "$PATO_BIN"

    export FOAM_INST_DIR="$OPENFOAM_BASE"
    export WM_PROJECT_INST_DIR="$OPENFOAM_BASE"
    export WM_PROJECT_DIR="$OPENFOAM_ROOT"
    export WM_THIRD_PARTY_DIR="${OPENFOAM_BASE}/ThirdParty-7"

    export WM_COMPILER_TYPE=system
    export WM_COMPILER=Gcc
    export WM_MPLIB=SYSTEMOPENMPI

    export WM_PRECISION_OPTION=DP
    export WM_LABEL_SIZE=32
    export WM_COMPILE_OPTION=Opt

    export PATO_DIR="$PATO_ROOT"

    set +e
    set +u
    set +o pipefail

    . "${OPENFOAM_ROOT}/etc/bashrc"
    OPENFOAM_RC=$?

    . "${PATO_ROOT}/bashrc"
    PATO_RC=$?

    set -e
    set -o pipefail

    (( OPENFOAM_RC == 0 && PATO_RC == 0 )) ||
        die "OpenFOAM/PATO environment initialization failed."

    for command_name in \
        blockMesh \
        checkMesh
    do
        require_command "$command_name"
    done

fi

# Result directories
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
echo "PATO SERIAL BASELINE"
echo "============================================================"
echo "Runtime:             $RUNTIME"
echo "Job ID:              $JOB_ID"
echo "Nodes:               1"
echo "Processes:           1"
echo "OpenMP threads:      1"
echo "Region:              $REGION"
echo "NPS/NPD/NPY:         $NPS / $NPD / $NPY"
echo "Expected cells:      $EXPECTED_CELLS"
echo "deltaT:              $DELTA_T"
echo "endTime:             $END_TIME"
echo "Expected steps:      $EXPECTED_STEPS"
echo "Probe output:        disabled"
echo "Compiler:            $GCC_VERSION"
echo "MPI environment:     $MPI_VERSION"
echo "MPI PML/BTL:         $MPI_PML / $MPI_BTL"
echo "Execution mode:      SERIAL"
echo "Results:             $ROOT"
echo "============================================================"

scontrol show hostnames "$SLURM_JOB_NODELIST" |
    tee "${LOGS_DIR}/allocated_nodes.txt"

# Copy tutorial
if [[ "$RUNTIME" == "container" ]]; then

    run_serial_container \
        "$BASE_CASE" \
        "cp -a '${CASE_SOURCE}/.' /case/"

else

    cp -a \
        "${CASE_SOURCE}/." \
        "${BASE_CASE}/"

fi

# Validate original case
require_file "${BASE_CASE}/system/controlDict"
require_file "${BASE_CASE}/cylinderMesh.m4"

require_directory "${BASE_CASE}/origin.0"

require_nonempty_file \
    "${BASE_CASE}/constant/${REGION}/BoundaryConditions"

require_nonempty_file \
    "${BASE_CASE}/constant/${REGION}/fluxFactorMap"

require_nonempty_file \
    "${BASE_CASE}/constant/${REGION}/porousMatProperties"

# Disable probingFunctions
# Keep exactly the same benchmark modification as MPI runs.
disable_probing_functions \
    "${BASE_CASE}/constant/${REGION}/porousMatProperties"

verify_probing_disabled \
    "${BASE_CASE}/constant/${REGION}/porousMatProperties"

# Clean the output
rm -rf "${BASE_CASE}/output"

mkdir -p \
    "${BASE_CASE}/output/empty"

# Set exactly the same simulation controls
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
    writeControl \
    timeStep

set_dictionary_entry \
    "${BASE_CASE}/system/controlDict" \
    writeInterval \
    "$EXPECTED_STEPS"

# Set exact 4,096,000-cell mesh
python3 - \
    "${BASE_CASE}/cylinderMesh.m4" \
    "$NPS" \
    "$NPD" \
    "$NPY" <<'PYMESH'

from pathlib import Path
import re
import sys

path = Path(sys.argv[1])

values = {
    "NPS": sys.argv[2],
    "NPD": sys.argv[3],
    "NPY": sys.argv[4],
}

text = path.read_text()

for key, value in values.items():

    pattern = (
        rf"(?m)^"
        rf"(\s*define\(\s*{key}\s*,\s*)"
        rf"[^)]+"
        rf"(\).*)$"
    )

    if not re.search(pattern, text):
        raise SystemExit(
            f"Missing {key} definition in {path}"
        )

    text = re.sub(
        pattern,
        rf"\g<1>{value}\g<2>",
        text,
        count=1,
    )

path.write_text(text)

PYMESH

mkdir -p \
    "${BASE_CASE}/constant/${REGION}/polyMesh"

m4 \
    "${BASE_CASE}/cylinderMesh.m4" \
    > "${BASE_CASE}/constant/${REGION}/polyMesh/blockMeshDict"

# Prepare initial condition directory
rm -rf "${BASE_CASE}/0"

cp -a \
    "${BASE_CASE}/origin.0" \
    "${BASE_CASE}/0"

# Build and validate mesh
if [[ "$RUNTIME" == "container" ]]; then

    run_serial_container \
        "$BASE_CASE" \
        "blockMesh -region '${REGION}' > /case/log.blockMesh 2> /case/err.blockMesh"

    run_serial_container \
        "$BASE_CASE" \
        "checkMesh -region '${REGION}' > /case/log.checkMesh 2> /case/err.checkMesh"

else

    (
        cd "$BASE_CASE"

        blockMesh \
            -region "$REGION" \
            > log.blockMesh \
            2> err.blockMesh

        checkMesh \
            -region "$REGION" \
            > log.checkMesh \
            2> err.checkMesh
    )

fi

# Validate mesh
grep -q "Mesh OK" \
    "${BASE_CASE}/log.checkMesh" ||
    die "checkMesh did not report Mesh OK."

DETECTED_CELLS="$(
    awk '
        /^[[:space:]]*cells:/ {
            cells=$2
        }

        END {
            print cells
        }
    ' "${BASE_CASE}/log.checkMesh"
)"

[[ "$DETECTED_CELLS" == "$EXPECTED_CELLS" ]] ||
    die \
    "Expected $EXPECTED_CELLS cells; detected ${DETECTED_CELLS:-unknown}."

echo
echo "Exact ${EXPECTED_CELLS}-cell mesh confirmed."

# Prepare serial run directory
rm -rf "$RUN_DIR"

mkdir -p "$RUN_DIR"

cp -a \
    "${BASE_CASE}/." \
    "$RUN_DIR/"

# Ensure no parallel decomposition exists
rm -rf "${RUN_DIR}/processor"*

PROCESSOR_COUNT="$(
    find "$RUN_DIR" \
        -maxdepth 1 \
        -type d \
        -name 'processor[0-9]*' |
    wc -l |
    tr -d '[:space:]'
)"

[[ "$PROCESSOR_COUNT" -eq 0 ]] ||
    die "Serial case unexpectedly contains processor directories."

# Clean output again immediately before timing
rm -rf "${RUN_DIR}/output"

mkdir -p \
    "${RUN_DIR}/output/empty"

# Validate required PATO files
REQUIRED_CASE_FILES=(
    "${RUN_DIR}/constant/${REGION}/BoundaryConditions"
    "${RUN_DIR}/constant/${REGION}/fluxFactorMap"
    "${RUN_DIR}/constant/${REGION}/porousMatProperties"

    "${RUN_DIR}/0/${REGION}/Ta"
    "${RUN_DIR}/0/${REGION}/p"
    "${RUN_DIR}/0/${REGION}/p_dyn"
    "${RUN_DIR}/0/${REGION}/rhoeUeCH"
)

for required_case_file in "${REQUIRED_CASE_FILES[@]}"
do
    require_nonempty_file \
        "$required_case_file"
done

verify_probing_disabled \
    "${RUN_DIR}/constant/${REGION}/porousMatProperties"

# Summary header
printf \
'nodes\tranks\tthreads\tcells\tcells_per_rank\tfinal_runtime\tfinal_timestep\texecution_time_s\tclock_time_s\texternal_time_s\texit_code\tstatus\tcase_directory\n' \
    > "$SUMMARY_FILE"

# SERIAL PATO execution
echo
echo "============================================================"
echo "PATO SERIAL RUN"
echo "============================================================"
echo "Runtime:             $RUNTIME"
echo "Nodes:               1"
echo "Processes:           1"
echo "OpenMP threads:      1"
echo "Total cells:         $EXPECTED_CELLS"
echo "Cells per process:   $EXPECTED_CELLS"
echo "deltaT:              $DELTA_T"
echo "endTime:             $END_TIME"
echo "Expected steps:      $EXPECTED_STEPS"
echo "Probe output:        disabled"
echo "Case directory:      $RUN_DIR"
echo "Command:             PATOx -case ."
echo "============================================================"

START_TEXT="$(timestamp)"
START_EPOCH="$(date +%s.%N)"

set +e

# Container serial execution
if [[ "$RUNTIME" == "container" ]]; then

    SERIAL_CONTAINER_COMMAND="$(
        cat <<EOF_SERIAL_RUN
${CONTAINER_INIT}

cd /case

test -s constant/${REGION}/BoundaryConditions
test -s constant/${REGION}/fluxFactorMap
test -s constant/${REGION}/porousMatProperties

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close
unset OMP_PLACES

export OMPI_MCA_pml='${MPI_PML}'
export OMPI_MCA_btl='${MPI_BTL}'

exec '${PATO_BIN}' -case .
EOF_SERIAL_RUN
    )"

    apptainer exec \
        --bind /beegfs/Tools:/beegfs/Tools:ro \
        --bind "${RUN_DIR}:/case" \
        --pwd /case \
        --env OMP_NUM_THREADS=1 \
        --env OMP_PROC_BIND=close \
        --env OMPI_MCA_pml="$MPI_PML" \
        --env OMPI_MCA_btl="$MPI_BTL" \
        "$IMAGE" \
        /bin/bash -lc "$SERIAL_CONTAINER_COMMAND" \
        > "$RUN_LOG" \
        2> "$RUN_ERR"

# Host serial execution
else

    (
        cd "$RUN_DIR"

        test -s \
            "constant/${REGION}/BoundaryConditions"

        test -s \
            "constant/${REGION}/fluxFactorMap"

        test -s \
            "constant/${REGION}/porousMatProperties"

        export OMP_NUM_THREADS=1
        export OMP_PROC_BIND=close
        unset OMP_PLACES || true

        export OMPI_MCA_pml="$MPI_PML"
        export OMPI_MCA_btl="$MPI_BTL"

        exec "$PATO_BIN" \
            -case . \
            > "$RUN_LOG" \
            2> "$RUN_ERR"
    )

fi

RUN_RC=$?

set -e

END_EPOCH="$(date +%s.%N)"
END_TEXT="$(timestamp)"

EXTERNAL_TIME="$(
    elapsed_seconds \
        "$START_EPOCH" \
        "$END_EPOCH"
)"

# Return-code validation
if (( RUN_RC != 0 )); then

    show_failure_logs \
        "$RUN_LOG" \
        "$RUN_ERR"

    die \
        "Serial PATO failed with exit code $RUN_RC."

fi

# Detect PATO/OpenFOAM failures
if grep -Eiq \
    -- '--> FOAM FATAL|FOAM parallel run exiting|MPI_ABORT|Segmentation fault|Floating point exception \(core dumped\)|Killed process|Out of memory' \
    "$RUN_LOG" \
    "$RUN_ERR"
then

    show_failure_logs \
        "$RUN_LOG" \
        "$RUN_ERR"

    die \
        "A genuine fatal PATO/OpenFOAM error was detected."

fi

# Extract final simulation information
FINAL_RUNTIME="$(
    sed -nE \
        's/.*runTime[[:space:]]*=[[:space:]]*([-+0-9.eEdD]+).*/\1/p' \
        "$RUN_LOG" |
    tail -1
)"

FINAL_TIMESTEP="$(
    sed -nE \
        's/.*Time step[[:space:]]*=[[:space:]]*([-+0-9.eEdD]+).*/\1/p' \
        "$RUN_LOG" |
    tail -1
)"

EXECUTION_TIME="$(
    sed -nE \
        's/.*ExecutionTime[[:space:]]*=[[:space:]]*([-+0-9.eEdD]+).*/\1/p' \
        "$RUN_LOG" |
    tail -1
)"

CLOCK_TIME="$(
    sed -nE \
        's/.*ClockTime[[:space:]]*=[[:space:]]*([-+0-9.eEdD]+).*/\1/p' \
        "$RUN_LOG" |
    tail -1
)"

# Required completion values
[[ -n "$FINAL_RUNTIME" ]] ||
    die "No final runTime value found."

[[ -n "$FINAL_TIMESTEP" ]] ||
    die "No final time-step value found."

[[ -n "$EXECUTION_TIME" ]] ||
    die "No ExecutionTime value found."

[[ -n "$CLOCK_TIME" ]] ||
    die "No ClockTime value found."

# Check required physical end time
python3 - \
    "$FINAL_RUNTIME" \
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
        f"Final runTime {actual} "
        f"does not equal required endTime {expected}."
    )

PYFINAL

# Verify probing remained disabled
if find "${RUN_DIR}/output" \
    -type f \
    -name 'Ta_plot' \
    -print -quit |
    grep -q .
then

    die \
        "Unexpected Ta_plot created; probingFunctions was not disabled."

fi

# Ensure no processor directories were generated
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

# Successful serial run
STATUS="completed"

printf \
'%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "1" \
    "1" \
    "1" \
    "$EXPECTED_CELLS" \
    "$EXPECTED_CELLS" \
    "$FINAL_RUNTIME" \
    "$FINAL_TIMESTEP" \
    "$EXECUTION_TIME" \
    "$CLOCK_TIME" \
    "$EXTERNAL_TIME" \
    "$RUN_RC" \
    "$STATUS" \
    "$RUN_DIR" \
    >> "$SUMMARY_FILE"

# Final report
echo
echo "============================================================"
echo "PATO SERIAL BASELINE SUMMARY"
echo "============================================================"
echo "Runtime:              $RUNTIME"
echo "Nodes:                1"
echo "Processes:            1"
echo "OpenMP threads:       1"
echo "Execution mode:       serial"
echo "Solver command:       PATOx -case ."
echo "Total cells:          $EXPECTED_CELLS"
echo "Cells per process:    $EXPECTED_CELLS"
echo "NPS/NPD/NPY:          $NPS / $NPD / $NPY"
echo "deltaT:               $DELTA_T"
echo "endTime:              $END_TIME"
echo "Probe output:         disabled"
echo "Final runTime:        $FINAL_RUNTIME"
echo "Final time step:      $FINAL_TIMESTEP"
echo "ExecutionTime:        $EXECUTION_TIME s"
echo "ClockTime:            $CLOCK_TIME s"
echo "External elapsed:     $EXTERNAL_TIME s"
echo "Exit code:            $RUN_RC"
echo "Status:               $STATUS"
echo "Start:                $START_TEXT"
echo "End:                  $END_TEXT"
echo "Results:              $ROOT"
echo "Summary:              $SUMMARY_FILE"
echo "============================================================"

exit 0
