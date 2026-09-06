#!/bin/bash
#SBATCH --job-name=fds160
#SBATCH --output=fds160_%j.out
#SBATCH --error=fds160_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=50
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

# MPI configuration
MPI_PML="ob1"
MPI_BTL="self,tcp"

# FDS benchmark configuration
GLOBAL_I=160
GLOBAL_J=160
GLOBAL_K=160

EXPECTED_CELLS=$((GLOBAL_I * GLOBAL_J * GLOBAL_K))

T_END="2.6"

# Reduced deltaT
FIXED_DT="0.0015"

CHID="spray_burner"

# Thread configuration
export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close
unset OMP_PLACES || true

# Helper functions
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

require_executable()
{
    [[ -x "$1" ]] ||
        die "Required executable not found or not executable: $1"
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

print(f"{end - start:.6f}")
PYTIME
}

show_failure_logs()
{
    local stdout_file="$1"
    local stderr_file="$2"

    echo "---------------- stdout ----------------"

    if [[ -s "$stdout_file" ]]; then
        tail -n 200 "$stdout_file"
    fi

    echo "---------------- stderr ----------------"

    if [[ -s "$stderr_file" ]]; then
        tail -n 200 "$stderr_file"
    fi

    echo "----------------------------------------"
}

# Mesh layouts
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
        *)   return 1 ;;
    esac
}

# Runtime check
case "$RUNTIME" in

    host|container)
        ;;

    *)
        die "RUNTIME must be host or container. Received: $RUNTIME"
        ;;
esac

# SLURM checks
(( NODES > 0 )) ||
    die "Submit this script through sbatch."

(( TASKS > 0 )) ||
    die "SLURM_NTASKS is unavailable."

(( CPUS_PER_TASK == 1 )) ||
    die "This benchmark requires --cpus-per-task=1."

# MPI process lists
case "$NODES" in

    1) PROCS_LIST="2 4 8 10 16 20 25 32 40 50"; REQUIRED_TASKS=50 ;;
    2) PROCS_LIST="2 4 8 10 16 20 32 40 50 64 80 100"; REQUIRED_TASKS=100 ;;
    4) PROCS_LIST="4 8 16 20 32 40 64 80 100 128 160 200"; REQUIRED_TASKS=200 ;;
    *) die "Only 1, 2, and 4 node allocations are supported." ;;
esac

(( TASKS >= REQUIRED_TASKS )) ||
    die "Need at least $REQUIRED_TASKS tasks; received $TASKS."

# Validate layouts before starting
for N in $PROCS_LIST; do

    (( N <= TASKS )) ||
        die "$N ranks exceed the $TASKS-task allocation."

    (( N % NODES == 0 )) ||
        die "$N ranks cannot be balanced across $NODES nodes."

    PPN_CHECK=$((N / NODES))

    (( PPN_CHECK <= TASKS_PER_NODE )) ||
        die "$N ranks require $PPN_CHECK ranks/node; only $TASKS_PER_NODE allocated."

    read -r NX NY NZ < <(layout_for_ranks "$N") ||
        die "No mesh layout defined for N=$N."

    (( NX * NY * NZ == N )) ||
        die "Invalid layout ${NX}x${NY}x${NZ} for N=$N."

    (( GLOBAL_I % NX == 0 )) ||
        die "GLOBAL_I=$GLOBAL_I is not divisible by NX=$NX."

    (( GLOBAL_J % NY == 0 )) ||
        die "GLOBAL_J=$GLOBAL_J is not divisible by NY=$NY."

    (( GLOBAL_K % NZ == 0 )) ||
        die "GLOBAL_K=$GLOBAL_K is not divisible by NZ=$NZ."

done

# Load host software stack
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
    sort \
    uniq \
    wc \
    tee \
    scontrol
do
    require_command "$command_name"
done

MPI_VERSION="$(mpirun --version | sed -n '1p')"

case "$MPI_VERSION" in

    *4.1.5*)
        ;;

    *)
        die "Expected OpenMPI 4.1.5; detected: $MPI_VERSION"
        ;;
esac

# Runtime-specific paths
if [[ "$RUNTIME" == "container" ]]; then

    BASE_ROOT="/beegfs/gopal/new/fds"

    IMAGE="${BASE_ROOT}/fds_image.sif"

    CASE_SOURCE="/opt/fds/Verification/Fires/spray_burner.fds"

    FDS_BIN="/opt/fds/bin/fds"

    ROOT="${BASE_ROOT}/results/spray_burner_160cube_container_fixedDT_explicit_mpi_${NODES}node_${JOB_ID}"

    require_file "$IMAGE"
    require_command apptainer

else

    BASE_ROOT="/beegfs/gopal/new/fds/host"

    CASE_SOURCE="${BASE_ROOT}/fds/Verification/Fires/spray_burner.fds"

    FDS_BIN="${BASE_ROOT}/bin/fds"

    ROOT="${BASE_ROOT}/results/spray_burner_160cube_host_fixedDT_explicit_mpi_${NODES}node_${JOB_ID}"

    require_file "$CASE_SOURCE"
    require_executable "$FDS_BIN"

fi

# Output directories
BASE_CASE="${ROOT}/base_case"
RUNS_DIR="${ROOT}/runs"
LOGS_DIR="${ROOT}/logs"

SUMMARY_FILE="${ROOT}/timing_summary.tsv"

rm -rf "$ROOT"

mkdir -p \
    "$BASE_CASE" \
    "$RUNS_DIR" \
    "$LOGS_DIR"

# Capture complete console output
exec > >(stdbuf -oL -eL tee -a "${LOGS_DIR}/console.log") 2>&1

echo "============================================================"
echo "FDS 160 x 160 x 160 explicit-MPI benchmark"
echo "============================================================"
echo "Runtime:             $RUNTIME"
echo "Job ID:              $JOB_ID"
echo "Nodes:               $NODES"
echo "Allocated tasks:     $TASKS"
echo "Tasks per node:      $TASKS_PER_NODE"
echo "Processor list:      $PROCS_LIST"
echo "Global mesh:         ${GLOBAL_I} x ${GLOBAL_J} x ${GLOBAL_K}"
echo "Total cells:         $EXPECTED_CELLS"
echo "Meshes:              one per MPI rank"
echo "T_END:               $T_END"
echo "Fixed DT:            $FIXED_DT"
echo "LOCK_TIME_STEP:      TRUE"
echo "MPI:                 $MPI_VERSION"
echo "MPI PML/BTL:         $MPI_PML / $MPI_BTL"
echo "Results:             $ROOT"
echo "============================================================"

# Record allocated nodes
scontrol show hostnames "$SLURM_JOB_NODELIST" \
    | tee "${LOGS_DIR}/allocated_nodes.txt"

# Obtain original FDS case
ORIGINAL_CASE="${BASE_CASE}/spray_burner_original.fds"

if [[ "$RUNTIME" == "container" ]]; then

    apptainer exec \
        --cleanenv \
        "$IMAGE" \
        /bin/bash -lc \
        "cat '${CASE_SOURCE}'" \
        > "$ORIGINAL_CASE"

else

    cp "$CASE_SOURCE" "$ORIGINAL_CASE"

fi

require_nonempty_file "$ORIGINAL_CASE"

# Summary header
printf \
'nodes\tranks\tranks_per_node\tused_hosts\tactual_placement\tlayout\tlocal_mesh\ttotal_cells\tmeshes\tcells_per_rank\tt_end\tfixed_dt\tfinal_step\tfinal_time\texternal_time_s\texit_code\tstatus\tcase_directory\n' \
    > "$SUMMARY_FILE"

# Benchmark sweep
for N in $PROCS_LIST; do

    # Mesh layout
    read -r NX NY NZ < <(layout_for_ranks "$N")

    LOCAL_I=$((GLOBAL_I / NX))
    LOCAL_J=$((GLOBAL_J / NY))
    LOCAL_K=$((GLOBAL_K / NZ))

    LOCAL_CELLS=$((LOCAL_I * LOCAL_J * LOCAL_K))

    PPN=$((N / NODES))

    (( LOCAL_CELLS * N == EXPECTED_CELLS )) ||
        die "Local cell count mismatch for N=$N."

    # Run directories
    RUN_DIR="${RUNS_DIR}/case_N${N}"

    WORK_DIR="${RUN_DIR}/work"

    RUN_LOG_DIR="${RUN_DIR}/logs"

    CASE_FILE="${CHID}_160x160x160_${N}proc.fds"

    CASE_PATH="${WORK_DIR}/${CASE_FILE}"

    RUN_LOG="${RUN_LOG_DIR}/log.${N}proc"

    RUN_ERR="${RUN_LOG_DIR}/err.${N}proc"

    PLACEMENT_RAW="${RUN_LOG_DIR}/placement.${N}.raw"

    PLACEMENT_SUMMARY="${RUN_LOG_DIR}/placement.${N}.summary"

    PLACEMENT_ERR="${RUN_LOG_DIR}/placement.${N}.err"

    rm -rf "$RUN_DIR"

    mkdir -p \
        "$WORK_DIR" \
        "$RUN_LOG_DIR"

    cp "$ORIGINAL_CASE" "$CASE_PATH"

    # Generate FDS meshes and fixed TIME record
    python3 - \
        "$CASE_PATH" \
        "$GLOBAL_I" \
        "$GLOBAL_J" \
        "$GLOBAL_K" \
        "$NX" \
        "$NY" \
        "$NZ" \
        "$N" \
        "$T_END" \
        "$FIXED_DT" \
        <<'PYCASE'

from pathlib import Path
import re
import sys

path = Path(sys.argv[1])

global_i = int(sys.argv[2])
global_j = int(sys.argv[3])
global_k = int(sys.argv[4])

nx = int(sys.argv[5])
ny = int(sys.argv[6])
nz = int(sys.argv[7])

expected_meshes = int(sys.argv[8])

t_end = sys.argv[9]
fixed_dt = sys.argv[10]

text = path.read_text()

# Locate original MESH record
mesh_pattern = re.compile(
    r"(?ims)^[ \t]*&MESH\b.*?/[ \t]*(?:\r?\n|$)"
)

matches = list(mesh_pattern.finditer(text))

if not matches:
    raise SystemExit("No original &MESH record found.")

original_mesh = matches[0].group(0)

# Extract physical boundaries
xb_match = re.search(
    r"(?i)\bXB\s*=\s*"
    r"([-+0-9.eEdD]+)\s*,\s*"
    r"([-+0-9.eEdD]+)\s*,\s*"
    r"([-+0-9.eEdD]+)\s*,\s*"
    r"([-+0-9.eEdD]+)\s*,\s*"
    r"([-+0-9.eEdD]+)\s*,\s*"
    r"([-+0-9.eEdD]+)",
    original_mesh,
)

if not xb_match:
    raise SystemExit(
        "Could not extract XB from the original FDS mesh."
    )

def number(value):
    return float(
        value.replace("D", "E").replace("d", "e")
    )

x0, x1, y0, y1, z0, z1 = map(
    number,
    xb_match.groups()
)

# Validate decomposition
if nx * ny * nz != expected_meshes:
    raise SystemExit(
        "Mesh layout does not equal MPI rank count."
    )

if global_i % nx != 0:
    raise SystemExit(
        "Global I dimension is not divisible by NX."
    )

if global_j % ny != 0:
    raise SystemExit(
        "Global J dimension is not divisible by NY."
    )

if global_k % nz != 0:
    raise SystemExit(
        "Global K dimension is not divisible by NZ."
    )

local_i = global_i // nx
local_j = global_j // ny
local_k = global_k // nz

# Generate one MESH block per MPI rank
mesh_lines = []

for ix in range(nx):

    xa = x0 + (x1 - x0) * ix / nx
    xb = x0 + (x1 - x0) * (ix + 1) / nx

    for iy in range(ny):

        ya = y0 + (y1 - y0) * iy / ny
        yb = y0 + (y1 - y0) * (iy + 1) / ny

        for iz in range(nz):

            za = z0 + (z1 - z0) * iz / nz
            zb = z0 + (z1 - z0) * (iz + 1) / nz

            mesh_lines.append(
                "&MESH "
                f"IJK={local_i},{local_j},{local_k}, "
                f"XB="
                f"{xa:.12g},{xb:.12g},"
                f"{ya:.12g},{yb:.12g},"
                f"{za:.12g},{zb:.12g} /"
            )

# Replace original mesh
start, end = matches[0].span()

text = (
    text[:start]
    + "\n".join(mesh_lines)
    + "\n"
    + mesh_pattern.sub("", text[end:])
)

# Replace TIME record
time_pattern = re.compile(
    r"(?ims)^[ \t]*&TIME\b.*?/[ \t]*(?:\r?\n|$)"
)

new_time = (
    f"&TIME "
    f"T_END={t_end}, "
    f"DT={fixed_dt}, "
    f"LOCK_TIME_STEP=.TRUE. /\n"
)

if time_pattern.search(text):

    text = time_pattern.sub(
        new_time,
        text,
        count=1
    )

else:

    text += "\n" + new_time

# Write modified case
path.write_text(text)

# Verify generated TIME record
updated_text = path.read_text()

time_match = time_pattern.search(updated_text)

if not time_match:
    raise SystemExit(
        "Generated &TIME record is missing."
    )

time_record = re.sub(
    r"\s+",
    "",
    time_match.group(0)
)

required_tokens = [
    f"T_END={t_end}",
    f"DT={fixed_dt}",
    "LOCK_TIME_STEP=.TRUE.",
]

for token in required_tokens:

    compact_token = re.sub(
        r"\s+",
        "",
        token
    )

    if compact_token not in time_record:
        raise SystemExit(
            "Generated &TIME record does not "
            f"contain required setting: {token}"
        )

PYCASE

    # Validate mesh count
    MESH_COUNT="$(
        grep -iEc \
        '^[[:space:]]*&MESH([[:space:]]|$)' \
        "$CASE_PATH"
    )"

    [[ "$MESH_COUNT" -eq "$N" ]] ||
        die "Expected $N meshes; generated $MESH_COUNT."

    # Record and validate TIME setting
    TIME_SETTING_FILE="${RUN_LOG_DIR}/time_setting.txt"

    grep -i \
        '^[[:space:]]*&TIME' \
        "$CASE_PATH" \
        | tee "$TIME_SETTING_FILE"

    grep -qi \
        "DT=${FIXED_DT}" \
        "$TIME_SETTING_FILE" ||
        die "Generated FDS input does not contain DT=${FIXED_DT}."

    grep -qi \
        "LOCK_TIME_STEP=.TRUE." \
        "$TIME_SETTING_FILE" ||
        die "Generated FDS input does not lock the time step."

    # MPI placement test
    set +e

    mpirun \
        --mca pml "$MPI_PML" \
        --mca btl "$MPI_BTL" \
        --map-by "ppr:${PPN}:node:PE=1" \
        --bind-to core \
        -np "$N" \
        hostname \
        > "$PLACEMENT_RAW" \
        2> "$PLACEMENT_ERR"

    PLACEMENT_RC=$?

    set -e

    if (( PLACEMENT_RC != 0 )); then

        show_failure_logs \
            "$PLACEMENT_RAW" \
            "$PLACEMENT_ERR"

        die "Rank-placement test failed for N=$N."

    fi

    sort "$PLACEMENT_RAW" \
        | uniq -c \
        | awk '{print $1, $2}' \
        > "$PLACEMENT_SUMMARY"

    PLACED_RANKS="$(
        awk \
        '{sum += $1} END {print sum+0}' \
        "$PLACEMENT_SUMMARY"
    )"

    [[ "$PLACED_RANKS" -eq "$N" ]] ||
        die "Placement launched $PLACED_RANKS ranks; expected $N."

    USED_HOSTS="$(
        awk '{print $2}' "$PLACEMENT_SUMMARY" \
        | sort -u \
        | wc -l \
        | tr -d '[:space:]'
    )"

    [[ "$USED_HOSTS" -eq "$NODES" ]] ||
        die "Explicit MPI used $USED_HOSTS hosts; expected $NODES."

    while read -r count host; do

        [[ "$count" -eq "$PPN" ]] ||
            die "$host received $count ranks; expected $PPN."

    done < "$PLACEMENT_SUMMARY"

    ACTUAL_PLACEMENT="$(
        awk '
        BEGIN {
            sep=""
        }
        {
            printf "%s%s:%s",sep,$2,$1
            sep=";"
        }
        END {
            print ""
        }
        ' "$PLACEMENT_SUMMARY"
    )"

    # Run information
    echo
    echo "============================================================"
    echo "RUN: runtime=$RUNTIME, nodes=$NODES, ranks=$N"
    echo "============================================================"
    echo "Ranks per node:      $PPN"
    echo "Used hosts:          $USED_HOSTS"
    echo "Actual placement:    $ACTUAL_PLACEMENT"
    echo "Layout:              ${NX}x${NY}x${NZ}"
    echo "Local mesh:          ${LOCAL_I}x${LOCAL_J}x${LOCAL_K}"
    echo "Cells per rank:      $LOCAL_CELLS"
    echo "T_END:               $T_END"
    echo "Fixed DT:            $FIXED_DT"
    echo "LOCK_TIME_STEP:      TRUE"
    echo "============================================================"

    # Start external timer
    START_TEXT="$(timestamp)"
    START_EPOCH="$(date +%s.%N)"

    set +e

    # Container execution
    if [[ "$RUNTIME" == "container" ]]; then

        (
            cd "$WORK_DIR"

            mpirun \
                --mca pml "$MPI_PML" \
                --mca btl "$MPI_BTL" \
                --map-by "ppr:${PPN}:node:PE=1" \
                --bind-to core \
                -np "$N" \
                apptainer exec \
                    --bind /beegfs/Tools:/beegfs/Tools:ro \
                    --bind "${WORK_DIR}:${WORK_DIR}" \
                    --pwd "$WORK_DIR" \
                    --env OMP_NUM_THREADS=1 \
                    --env OMP_PROC_BIND=close \
                    --env OMPI_MCA_pml="$MPI_PML" \
                    --env OMPI_MCA_btl="$MPI_BTL" \
                    "$IMAGE" \
                    /bin/bash -lc "
                        set -e
                        set -o pipefail

                        test -f /opt/host_mpi_env.sh

                        . /opt/host_mpi_env.sh

                        unset CPATH
                        unset C_INCLUDE_PATH
                        unset CPLUS_INCLUDE_PATH

                        export FDS_HOME=/opt/fds
                        export FDS_BIN=/opt/fds/bin/fds

                        export PATH=/opt/fds/bin:\${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}

                        export OMP_NUM_THREADS=1
                        export OMP_PROC_BIND=close

                        unset OMP_PLACES

                        export OMPI_MCA_pml='${MPI_PML}'
                        export OMPI_MCA_btl='${MPI_BTL}'

                        cd '${WORK_DIR}'

                        test -s '${CASE_FILE}'

                        exec \"\$FDS_BIN\" '${CASE_FILE}'
                    " \
                > "$RUN_LOG" \
                2> "$RUN_ERR"
        )

    # Host execution
    else

        (
            cd "$WORK_DIR"

            export OMP_NUM_THREADS=1
            export OMP_PROC_BIND=close

            unset OMP_PLACES

            export OMPI_MCA_pml="$MPI_PML"
            export OMPI_MCA_btl="$MPI_BTL"

            mpirun \
                --mca pml "$MPI_PML" \
                --mca btl "$MPI_BTL" \
                --map-by "ppr:${PPN}:node:PE=1" \
                --bind-to core \
                -np "$N" \
                "$FDS_BIN" \
                "$CASE_FILE" \
                > "$RUN_LOG" \
                2> "$RUN_ERR"
        )

    fi

    RUN_RC=$?

    set -e
    
    # Stop external timer
    END_EPOCH="$(date +%s.%N)"
    END_TEXT="$(timestamp)"

    EXTERNAL_TIME="$(
        elapsed_seconds \
        "$START_EPOCH" \
        "$END_EPOCH"
    )"

    # Fail immediately on non-zero FDS exit
    if (( RUN_RC != 0 )); then

        show_failure_logs \
            "$RUN_LOG" \
            "$RUN_ERR"

        die "FDS returned nonzero exit code $RUN_RC for N=$N."

    fi

    # Confirm MPI rank count
    DETECTED_RANKS="$(
        grep -h -m1 \
        'Number of MPI Processes:' \
        "$RUN_LOG" \
        "$RUN_ERR" \
        | awk '{print $5}'
    )"

    [[ "$DETECTED_RANKS" == "$N" ]] ||
        die \
        "Requested $N ranks, but FDS reported ${DETECTED_RANKS:-unknown}."

    # Build combined output
    PARSE_FILE="${RUN_LOG_DIR}/combined_output.${N}.txt"

    cat \
        "$RUN_LOG" \
        "$RUN_ERR" \
        > "$PARSE_FILE"

    if [[ -f "${WORK_DIR}/${CHID}.out" ]]; then

        cat \
            "${WORK_DIR}/${CHID}.out" \
            >> "$PARSE_FILE"

    fi

    # Extract actual final step and simulation time
    FINAL_STEP="$(
        sed -nE \
        's/.*Time Step:[[:space:]]*([0-9]+).*/\1/p' \
        "$PARSE_FILE" \
        | tail -1
    )"

    FINAL_TIME="$(
        sed -nE \
        's/.*Simulation Time:[[:space:]]*([-+0-9.eEdD]+).*/\1/p' \
        "$PARSE_FILE" \
        | tail -1
    )"

    # Detect genuine failures
    if grep -Eiq \
        -- \
        'ERROR:[[:space:]]*FDS|Segmentation fault|Floating point exception|MPI_ABORT|Killed process|Out of memory' \
        "$PARSE_FILE"
    then

        show_failure_logs \
            "$RUN_LOG" \
            "$RUN_ERR"

        die \
        "A fatal FDS error was detected for N=$N."

    fi

    # Validate extracted values
    [[ -n "$FINAL_STEP" ]] ||
        die \
        "No final FDS time-step number found for N=$N."

    [[ -n "$FINAL_TIME" ]] ||
        die \
        "No final simulation time found for N=$N."

    # Verify successful FDS completion
    grep -q \
        'STOP: FDS completed successfully' \
        "$PARSE_FILE" ||
        die \
        "FDS did not report successful completion for N=$N."

    # Verify final simulation time
    python3 \
        - "$FINAL_TIME" "$T_END" \
        <<'PYFINAL'

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
    abs_tol=1.0e-6,
):
    raise SystemExit(
        f"Final simulation time {actual} "
        f"does not equal T_END {expected}."
    )

PYFINAL
    # Run completed successfully
    STATUS="completed"
    # Save summary
    printf \
'%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$NODES" \
        "$N" \
        "$PPN" \
        "$USED_HOSTS" \
        "$ACTUAL_PLACEMENT" \
        "${NX}x${NY}x${NZ}" \
        "${LOCAL_I}x${LOCAL_J}x${LOCAL_K}" \
        "$EXPECTED_CELLS" \
        "$MESH_COUNT" \
        "$LOCAL_CELLS" \
        "$T_END" \
        "$FIXED_DT" \
        "$FINAL_STEP" \
        "$FINAL_TIME" \
        "$EXTERNAL_TIME" \
        "$RUN_RC" \
        "$STATUS" \
        "$RUN_DIR" \
        >> "$SUMMARY_FILE"
        
    # Print run summary
    echo
    echo "============================================================"
    echo "FDS RUN SUMMARY"
    echo "============================================================"
    echo "Runtime:               $RUNTIME"
    echo "Nodes:                 $NODES"
    echo "MPI ranks:             $N"
    echo "Ranks per node:        $PPN"
    echo "Used hosts:            $USED_HOSTS"
    echo "Actual placement:      $ACTUAL_PLACEMENT"
    echo "Mesh layout:           ${NX}x${NY}x${NZ}"
    echo "Local mesh:            ${LOCAL_I}x${LOCAL_J}x${LOCAL_K}"
    echo "Total cells:           $EXPECTED_CELLS"
    echo "Cells per rank:        $LOCAL_CELLS"
    echo "Meshes:                $MESH_COUNT"
    echo "T_END:                 $T_END"
    echo "Fixed DT:              $FIXED_DT"
    echo "LOCK_TIME_STEP:        TRUE"
    echo "Final step:            $FINAL_STEP"
    echo "Final simulation time: $FINAL_TIME"
    echo "External elapsed:      $EXTERNAL_TIME s"
    echo "Exit code:             $RUN_RC"
    echo "Status:                $STATUS"
    echo "Start:                 $START_TEXT"
    echo "End:                   $END_TEXT"
    echo "============================================================"

done

# Final summary
echo
echo "============================================================"
echo "ALL FDS RUNS COMPLETED"
echo "============================================================"
echo "Runtime:     $RUNTIME"
echo "Nodes:       $NODES"
echo "Fixed DT:    $FIXED_DT"
echo "Results:     $ROOT"
echo "Summary:     $SUMMARY_FILE"
echo "============================================================"

exit 0
