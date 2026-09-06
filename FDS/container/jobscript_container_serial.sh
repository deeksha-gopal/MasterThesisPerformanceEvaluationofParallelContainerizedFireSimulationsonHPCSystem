#!/bin/bash
#SBATCH --job-name=fds160_serial
#SBATCH --output=fds160_serial_%j.out
#SBATCH --error=fds160_serial_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

set -e
set -o pipefail

RUNTIME="${RUNTIME:-container}"

GLOBAL_I=160
GLOBAL_J=160
GLOBAL_K=160

EXPECTED_CELLS=$((GLOBAL_I * GLOBAL_J * GLOBAL_K))

T_END="2.6"
FIXED_DT="0.0015"

CHID="spray_burner"

JOB_ID="${SLURM_JOB_ID:-manual_$(date +%Y%m%d_%H%M%S)}"

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

# Runtime check
case "$RUNTIME" in

    host|container)
        ;;

    *)
        die "RUNTIME must be host or container. Received: $RUNTIME"
        ;;
esac

# Slurm checks
[[ "${SLURM_NTASKS:-0}" -eq 1 ]] ||
    die "Serial benchmark requires exactly one Slurm task."

[[ "${SLURM_CPUS_PER_TASK:-0}" -eq 1 ]] ||
    die "Serial benchmark requires --cpus-per-task=1."

# Load software stack
module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5

for command_name in \
    python3 \
    grep \
    sed \
    awk \
    tee
do
    require_command "$command_name"
done

# Runtime-specific paths
if [[ "$RUNTIME" == "container" ]]; then

    BASE_ROOT="/beegfs/gopal/new/fds"

    IMAGE="${BASE_ROOT}/fds_image.sif"

    CASE_SOURCE="/opt/fds/Verification/Fires/spray_burner.fds"

    FDS_BIN="/opt/fds/bin/fds"

    ROOT="${BASE_ROOT}/results/spray_burner_160cube_container_serial_fixedDT_${JOB_ID}"

    require_file "$IMAGE"
    require_command apptainer

else

    BASE_ROOT="/beegfs/gopal/new/fds/host"

    CASE_SOURCE="${BASE_ROOT}/fds/Verification/Fires/spray_burner.fds"

    FDS_BIN="${BASE_ROOT}/bin/fds"

    ROOT="${BASE_ROOT}/results/spray_burner_160cube_host_serial_fixedDT_${JOB_ID}"

    require_file "$CASE_SOURCE"
    require_executable "$FDS_BIN"

fi

# Output directories
WORK_DIR="${ROOT}/work"
LOG_DIR="${ROOT}/logs"

RUN_LOG="${LOG_DIR}/log.serial"
RUN_ERR="${LOG_DIR}/err.serial"

CASE_FILE="${CHID}_160x160x160_serial.fds"
CASE_PATH="${WORK_DIR}/${CASE_FILE}"

SUMMARY_FILE="${ROOT}/timing_summary.tsv"

rm -rf "$ROOT"

mkdir -p \
    "$WORK_DIR" \
    "$LOG_DIR"

# Capture complete console output
exec > >(stdbuf -oL -eL tee -a "${LOG_DIR}/console.log") 2>&1

echo "============================================================"
echo "FDS 160 x 160 x 160 SERIAL benchmark"
echo "============================================================"
echo "Runtime:             $RUNTIME"
echo "Job ID:              $JOB_ID"
echo "Nodes:               1"
echo "Processes:           1"
echo "Threads:             1"
echo "Global mesh:         ${GLOBAL_I} x ${GLOBAL_J} x ${GLOBAL_K}"
echo "Total cells:         $EXPECTED_CELLS"
echo "FDS meshes:          1"
echo "T_END:               $T_END"
echo "Fixed DT:            $FIXED_DT"
echo "LOCK_TIME_STEP:      TRUE"
echo "Results:             $ROOT"
echo "============================================================"

# Obtain original FDS case
if [[ "$RUNTIME" == "container" ]]; then

    apptainer exec \
        --cleanenv \
        "$IMAGE" \
        /bin/bash -lc \
        "cat '${CASE_SOURCE}'" \
        > "$CASE_PATH"

else

    cp "$CASE_SOURCE" "$CASE_PATH"

fi

require_nonempty_file "$CASE_PATH"

# Generate serial 160 x 160 x 160 mesh and fixed TIME record
python3 - \
    "$CASE_PATH" \
    "$GLOBAL_I" \
    "$GLOBAL_J" \
    "$GLOBAL_K" \
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

t_end = sys.argv[5]
fixed_dt = sys.argv[6]

text = path.read_text()

# Locate original MESH record
mesh_pattern = re.compile(
    r"(?ims)^[ \t]*&MESH\b.*?/[ \t]*(?:\r?\n|$)"
)

matches = list(mesh_pattern.finditer(text))

if not matches:
    raise SystemExit("No original &MESH record found.")

original_mesh = matches[0].group(0)

# Extract original physical domain boundaries
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
        "Could not extract XB from original FDS mesh."
    )

x0, x1, y0, y1, z0, z1 = xb_match.groups()

# Replace all original MESH records with one serial MESH
serial_mesh = (
    f"&MESH "
    f"IJK={global_i},{global_j},{global_k}, "
    f"XB={x0},{x1},{y0},{y1},{z0},{z1} /\n"
)

start, end = matches[0].span()

text = (
    text[:start]
    + serial_mesh
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

# Write final case
path.write_text(text)

# Validate final case
updated = path.read_text()

mesh_count = len(
    re.findall(
        r"(?im)^[ \t]*&MESH\b",
        updated
    )
)

if mesh_count != 1:
    raise SystemExit(
        f"Expected exactly one &MESH block, found {mesh_count}."
    )

if f"IJK={global_i},{global_j},{global_k}" not in \
        re.sub(r"\s+", "", updated):
    raise SystemExit(
        "Generated serial mesh does not contain expected IJK."
    )

time_match = time_pattern.search(updated)

if not time_match:
    raise SystemExit(
        "Generated &TIME record is missing."
    )

compact_time = re.sub(
    r"\s+",
    "",
    time_match.group(0)
)

for token in (
    f"T_END={t_end}",
    f"DT={fixed_dt}",
    "LOCK_TIME_STEP=.TRUE.",
):
    if token not in compact_time:
        raise SystemExit(
            f"Missing TIME setting: {token}"
        )

PYCASE

# Check generated input
MESH_COUNT="$(
    grep -iEc \
    '^[[:space:]]*&MESH([[:space:]]|$)' \
    "$CASE_PATH"
)"

[[ "$MESH_COUNT" -eq 1 ]] ||
    die "Serial case must contain exactly one &MESH block."

echo
echo "Generated MESH record:"
grep -i \
    '^[[:space:]]*&MESH' \
    "$CASE_PATH"

echo
echo "Generated TIME record:"
grep -i \
    '^[[:space:]]*&TIME' \
    "$CASE_PATH"

# Summary
printf \
'runtime\tnodes\tprocesses\tthreads\tmesh\ttotal_cells\tmeshes\tt_end\tfixed_dt\tfinal_step\tfinal_time\tfinal_dt\texternal_time_s\texit_code\tstatus\tcase_directory\n' \
    > "$SUMMARY_FILE"

# Start external timer
echo
echo "============================================================"
echo "STARTING SERIAL FDS RUN"
echo "============================================================"

START_TEXT="$(timestamp)"
START_EPOCH="$(date +%s.%N)"

set +e

# Container serial execution
if [[ "$RUNTIME" == "container" ]]; then

    (
        cd "$WORK_DIR"

        apptainer exec \
            --cleanenv \
            --bind /beegfs/Tools:/beegfs/Tools:ro \
            --bind "${WORK_DIR}:${WORK_DIR}" \
            --pwd "$WORK_DIR" \
            --env OMP_NUM_THREADS=1 \
            --env OMP_PROC_BIND=close \
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

                cd '${WORK_DIR}'

                test -s '${CASE_FILE}'

                exec \"\$FDS_BIN\" '${CASE_FILE}'
            " \
            > "$RUN_LOG" \
            2> "$RUN_ERR"
    )

# Host serial execution
else

    (
        cd "$WORK_DIR"

        export OMP_NUM_THREADS=1
        export OMP_PROC_BIND=close
        unset OMP_PLACES

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

# Check FDS exit
if (( RUN_RC != 0 )); then

    show_failure_logs \
        "$RUN_LOG" \
        "$RUN_ERR"

    die "Serial FDS returned exit code $RUN_RC."

fi

# Build combined output
PARSE_FILE="${LOG_DIR}/combined_output.txt"

cat \
    "$RUN_LOG" \
    "$RUN_ERR" \
    > "$PARSE_FILE"

if [[ -f "${WORK_DIR}/${CHID}.out" ]]; then

    cat \
        "${WORK_DIR}/${CHID}.out" \
        >> "$PARSE_FILE"

fi

# Check genuine runtime failures
if grep -Eiq \
    -- \
    'ERROR:[[:space:]]*FDS|Segmentation fault|Floating point exception|MPI_ABORT|Killed process|Out of memory' \
    "$PARSE_FILE"
then

    show_failure_logs \
        "$RUN_LOG" \
        "$RUN_ERR"

    die "A fatal FDS error was detected."

fi

# Confirm successful FDS completion
grep -q \
    'STOP: FDS completed successfully' \
    "$PARSE_FILE" ||
    die "FDS did not report successful completion."

# Extract final step
FINAL_STEP="$(
    sed -nE \
    's/.*Time Step:[[:space:]]*([0-9]+).*/\1/p' \
    "$PARSE_FILE" \
    | tail -1
)"

# Extract final simulation time
FINAL_TIME="$(
    sed -nE \
    's/.*Simulation Time:[[:space:]]*([-+0-9.eEdD]+).*/\1/p' \
    "$PARSE_FILE" \
    | tail -1
)"

# Extract final reported step size
FINAL_DT="$(
    sed -nE \
    's/.*Step Size:[[:space:]]*([-+0-9.eEdD]+).*/\1/p' \
    "$PARSE_FILE" \
    | tail -1
)"

[[ -n "$FINAL_STEP" ]] ||
    die "Could not extract final time-step number."

[[ -n "$FINAL_TIME" ]] ||
    die "Could not extract final simulation time."

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

# Summary
STATUS="completed"

printf \
'%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$RUNTIME" \
    "1" \
    "1" \
    "1" \
    "160x160x160" \
    "$EXPECTED_CELLS" \
    "$MESH_COUNT" \
    "$T_END" \
    "$FIXED_DT" \
    "$FINAL_STEP" \
    "$FINAL_TIME" \
    "${FINAL_DT:-unknown}" \
    "$EXTERNAL_TIME" \
    "$RUN_RC" \
    "$STATUS" \
    "$WORK_DIR" \
    >> "$SUMMARY_FILE"

# Print final summary
echo
echo "============================================================"
echo "FDS SERIAL RUN SUMMARY"
echo "============================================================"
echo "Runtime:               $RUNTIME"
echo "Nodes:                 1"
echo "Processes:             1"
echo "OpenMP threads:        1"
echo "Global mesh:           160x160x160"
echo "Total cells:           $EXPECTED_CELLS"
echo "FDS meshes:            $MESH_COUNT"
echo "T_END:                 $T_END"
echo "Configured DT:         $FIXED_DT"
echo "LOCK_TIME_STEP:        TRUE"
echo "Final step:            $FINAL_STEP"
echo "Final simulation time: $FINAL_TIME"
echo "Final reported DT:     ${FINAL_DT:-unknown}"
echo "External elapsed:      $EXTERNAL_TIME s"
echo "Exit code:             $RUN_RC"
echo "Status:                $STATUS"
echo "Start:                 $START_TEXT"
echo "End:                   $END_TEXT"
echo "Summary:               $SUMMARY_FILE"
echo "============================================================"

exit 0
