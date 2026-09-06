#!/bin/bash
#SBATCH --job-name=fds_host_1node
#SBATCH --output=/beegfs/gopal/new/fds/host/logs/fds_host_1node_%j.out
#SBATCH --error=/beegfs/gopal/new/fds/host/logs/fds_host_1node_%j.err
#SBATCH --time=12:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=50
#SBATCH --ntasks-per-node=50
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

set -e
set -o pipefail

# Installed host FDS and benchmark configuration
BASE_DIR="/beegfs/gopal/new/fds/host"
FDS_BIN="${BASE_DIR}/bin/fds"
CASE_SRC="${BASE_DIR}/fds/Verification/Fires/spray_burner.fds"
ENV_FILE="${BASE_DIR}/fds_host_env.sh"

EXPECTED_NODES=1
EXPECTED_TASKS=50
PROCS_LIST="2 4 8 10 16 20 32 40 50"

TOTAL_I=80
TOTAL_J=80
TOTAL_K=80
TOTAL_CELLS=$((TOTAL_I * TOTAL_J * TOTAL_K))
T_END_VALUE="2.6"

# The modified spray_burner benchmark has previously completed at:
EXPECTED_FINAL_STEP="131"
EXPECTED_FINAL_TIME="2.60000"

JOB_ID="${SLURM_JOB_ID:-manual}"
ROOT="${BASE_DIR}/results/spray_burner_host_1node_${JOB_ID}"
BASE_CASE_DIR="${ROOT}/base"
RUNS_DIR="${ROOT}/runs"
LOGS_DIR="${ROOT}/logs"
SUMMARY_FILE="${ROOT}/timing_summary.tsv"

mkdir -p "${BASE_DIR}/logs" "$BASE_CASE_DIR" "$RUNS_DIR" "$LOGS_DIR"
exec > >(stdbuf -oL -eL tee -a "${LOGS_DIR}/console.log") 2>&1

die() {
    echo "ERROR: $*" >&2
    exit 1
}

section() {
    echo
    echo "============================================================"
    echo "$*"
    echo "============================================================"
}

# Slurm allocation validation

[[ -n "${SLURM_JOB_ID:-}" ]] || die "Submit this script with sbatch."
[[ "${SLURM_JOB_NUM_NODES:-0}" -eq "$EXPECTED_NODES" ]] ||
    die "Expected $EXPECTED_NODES nodes, received ${SLURM_JOB_NUM_NODES:-0}."
[[ "${SLURM_NTASKS:-0}" -ge "$EXPECTED_TASKS" ]] ||
    die "Expected at least $EXPECTED_TASKS tasks, received ${SLURM_NTASKS:-0}."
[[ "${SLURM_NTASKS_PER_NODE:-0}" -ge 50 ]] ||
    die "Expected at least 50 tasks per node."


# Host software environment
for variable in OPAL_PREFIX OMPI_HOME MPI_HOME OMPI_MCA_pml OMPI_MCA_btl; do
    unset "$variable" || true
done

module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close
export OMP_PLACES=cores

command -v mpirun >/dev/null 2>&1 || die "mpirun is unavailable."
command -v python3 >/dev/null 2>&1 || die "python3 is unavailable."
[[ -x "$FDS_BIN" ]] || die "Installed host FDS executable is missing: $FDS_BIN"
[[ -f "$CASE_SRC" ]] || die "Tutorial case is missing: $CASE_SRC"
[[ -f "$ENV_FILE" ]] || echo "WARNING: Environment file not found: $ENV_FILE"

case "$(mpirun --version | sed -n '1p')" in
    *4.1.5*) ;;
    *) die "OpenMPI 4.1.5 is not active." ;;
esac

MPI_LIBRARY="$(ldd "$FDS_BIN" | awk '/libmpi\.so/ {print $3; exit}')"
case "${MPI_LIBRARY:-}" in
    /beegfs/Tools/*/OpenMPI/4.1.5-GCC-12.3.0/*) ;;
    *) die "FDS resolves an unexpected MPI library: ${MPI_LIBRARY:-not-found}" ;;
esac

"$FDS_BIN" -v 2>&1 | tee "${LOGS_DIR}/fds_version.log"
"$FDS_BIN" -v 2>&1 | grep -q "Open MPI v4.1.5" ||
    die "Installed FDS does not report Open MPI v4.1.5."

section "FDS HOST BENCHMARK — 1 NODE(S)"

echo "Job ID                 : $SLURM_JOB_ID"
echo "Allocated nodes        : $SLURM_JOB_NUM_NODES"
echo "Allocated tasks        : $SLURM_NTASKS"
echo "Tasks per node         : $SLURM_NTASKS_PER_NODE"
echo "Processor sweep        : $PROCS_LIST"
echo "Host FDS               : $FDS_BIN"
echo "Source tutorial        : $CASE_SRC"
echo "Global mesh            : $TOTAL_I x $TOTAL_J x $TOTAL_K"
echo "Total cells            : $TOTAL_CELLS"
echo "Number of meshes       : number of MPI ranks"
echo "T_END                  : $T_END_VALUE"
echo "MPI PML                : ob1"
echo "MPI BTL                : self,vader,tcp"
echo "MPI mapping            : ppr:PPN:node:PE=1"
echo "MPI binding            : core"
echo "Results                : $ROOT"

scontrol show hostnames "$SLURM_JOB_NODELIST" | tee "${LOGS_DIR}/allocated_nodes.txt"
cp "$CASE_SRC" "${BASE_CASE_DIR}/spray_burner_original.fds"

printf "nodes\tranks\tranks_per_node\tmesh_layout\tmesh_count\tcells_per_rank\ttotal_cells\tt_end\tfinal_step\tfinal_time\tfds_step_time_s\tfds_total_time_s\texternal_time_s\treturn_code\tstatus\trun_directory\n"     > "$SUMMARY_FILE"

# Processor sweep
for N in $PROCS_LIST; do
    section "RUN N=$N"

    (( N % EXPECTED_NODES == 0 )) ||
        die "N=$N is not divisible by $EXPECTED_NODES nodes."

    PPN=$((N / EXPECTED_NODES))
    (( PPN <= 50 )) || die "N=$N requires $PPN ranks per node; maximum is 50."

    case "$N" in
        2) NX=2; NY=1; NZ=1 ;;
        4) NX=2; NY=2; NZ=1 ;;
        8) NX=2; NY=2; NZ=2 ;;
        10) NX=5; NY=2; NZ=1 ;;
        16) NX=4; NY=2; NZ=2 ;;
        20) NX=5; NY=2; NZ=2 ;;
        32) NX=4; NY=4; NZ=2 ;;
        40) NX=5; NY=4; NZ=2 ;;
        50) NX=5; NY=5; NZ=2 ;;
        *) die "No mesh layout is defined for N=$N." ;;
    esac

    (( NX * NY * NZ == N )) ||
        die "Layout ${NX}x${NY}x${NZ} does not equal N=$N."

    (( TOTAL_I % NX == 0 && TOTAL_J % NY == 0 && TOTAL_K % NZ == 0 )) ||
        die "80x80x80 is not divisible by ${NX}x${NY}x${NZ}."

    RUN_DIR="${RUNS_DIR}/case_N${N}"
    WORK_DIR="${RUN_DIR}/work"
    RUN_LOG_DIR="${RUN_DIR}/logs"
    CASE_FILE="spray_burner_80x80x80_${N}proc.fds"

    rm -rf "$RUN_DIR"
    mkdir -p "$WORK_DIR" "$RUN_LOG_DIR"
    cp "${BASE_CASE_DIR}/spray_burner_original.fds" "${WORK_DIR}/${CASE_FILE}"

    python3 - "$WORK_DIR/$CASE_FILE" "$NX" "$NY" "$NZ"         "$TOTAL_I" "$TOTAL_J" "$TOTAL_K" "$N" "$T_END_VALUE" <<'PY'
from pathlib import Path
import re
import sys

case = Path(sys.argv[1])
nx, ny, nz = map(int, sys.argv[2:5])
total_i, total_j, total_k = map(int, sys.argv[5:8])
expected_meshes = int(sys.argv[8])
t_end = sys.argv[9]

text = case.read_text()

if nx * ny * nz != expected_meshes:
    raise SystemExit("Mesh layout does not equal the MPI rank count.")

if total_i % nx or total_j % ny or total_k % nz:
    raise SystemExit("Global mesh is not divisible by the decomposition.")

cells_i = total_i // nx
cells_j = total_j // ny
cells_k = total_k // nz

mesh_lines = []
for ix in range(nx):
    for iy in range(ny):
        for iz in range(nz):
            x0, x1 = ix / nx, (ix + 1) / nx
            y0, y1 = iy / ny, (iy + 1) / ny
            z0, z1 = iz / nz, (iz + 1) / nz
            mesh_lines.append(
                f"&MESH IJK={cells_i},{cells_j},{cells_k} "
                f"XB={x0:.6f},{x1:.6f},"
                f"{y0:.6f},{y1:.6f},"
                f"{z0:.6f},{z1:.6f} /"
            )

output = []
inserted = False
for line in text.splitlines():
    if line.strip().upper().startswith("&MESH"):
        if not inserted:
            output.extend(mesh_lines)
            inserted = True
        continue
    output.append(line)

if not inserted:
    raise SystemExit("No original &MESH entry was found.")

text = "\n".join(output) + "\n"
text, count = re.subn(
    r"&TIME\s+T_END\s*=\s*[^/]+/",
    f"&TIME T_END={t_end} /",
    text,
    flags=re.IGNORECASE,
)
if count == 0:
    raise SystemExit("No &TIME T_END entry was found.")

case.write_text(text)
print(f"Generated {len(mesh_lines)} meshes")
print(f"Layout: {nx}x{ny}x{nz}")
print(f"Cells per mesh: {cells_i}x{cells_j}x{cells_k}")
PY

    cd "$WORK_DIR"

    MESH_COUNT="$(grep -ic '^[[:space:]]*&MESH' "$CASE_FILE" || true)"
    CELLS_I=$((TOTAL_I / NX))
    CELLS_J=$((TOTAL_J / NY))
    CELLS_K=$((TOTAL_K / NZ))
    CELLS_PER_RANK=$((CELLS_I * CELLS_J * CELLS_K))
    VERIFIED_TOTAL=$((MESH_COUNT * CELLS_PER_RANK))

    [[ "$MESH_COUNT" -eq "$N" ]] ||
        die "Expected $N meshes, found $MESH_COUNT."
    [[ "$VERIFIED_TOTAL" -eq "$TOTAL_CELLS" ]] ||
        die "Expected $TOTAL_CELLS total cells, found $VERIFIED_TOTAL."

    grep -i '^[[:space:]]*&TIME' "$CASE_FILE" |
        tee "${RUN_LOG_DIR}/time_setting.txt"

  
    # Verify balanced placement before running FDS
    PLACEMENT_RAW="${RUN_LOG_DIR}/placement_raw.txt"
    PLACEMENT_SUMMARY="${RUN_LOG_DIR}/placement_summary.txt"

    mpirun         --mca pml ob1         --mca btl self,vader,tcp         --map-by "ppr:${PPN}:node:PE=1"         --bind-to core         -np "$N"         hostname         > "$PLACEMENT_RAW"

    sort "$PLACEMENT_RAW" | uniq -c | awk '{print $1, $2}' |
        tee "$PLACEMENT_SUMMARY"

    PLACED_RANKS="$(awk '{sum += $1} END {print sum+0}' "$PLACEMENT_SUMMARY")"
    PLACED_HOSTS="$(awk '{print $2}' "$PLACEMENT_SUMMARY" | sort -u | wc -l | tr -d '[:space:]')"

    [[ "$PLACED_RANKS" -eq "$N" ]] ||
        die "Placement test found $PLACED_RANKS ranks instead of $N."
    [[ "$PLACED_HOSTS" -eq "$EXPECTED_NODES" ]] ||
        die "Placement used $PLACED_HOSTS nodes instead of $EXPECTED_NODES."

    while read -r rank_count node_name; do
        [[ "$rank_count" -eq "$PPN" ]] ||
            die "$node_name received $rank_count ranks; expected $PPN."
    done < "$PLACEMENT_SUMMARY"

    # Run installed host FDS
    MAIN_LOG="${RUN_LOG_DIR}/log.${N}proc"
    ERR_LOG="${RUN_LOG_DIR}/err.${N}proc"
    FDS_OUT="${WORK_DIR}/spray_burner.out"

    echo "Command: mpirun --mca pml ob1 --mca btl self,vader,tcp --map-by ppr:${PPN}:node:PE=1 --bind-to core -np $N $FDS_BIN $CASE_FILE"

    START_NS="$(date +%s%N)"
    START_SEC="$(date +%s)"

    set +e
    mpirun         --mca pml ob1         --mca btl self,vader,tcp         --map-by "ppr:${PPN}:node:PE=1"         --bind-to core         -np "$N"         "$FDS_BIN" "$CASE_FILE"         > "$MAIN_LOG"         2> "$ERR_LOG"
    RC=$?
    set -e

    END_NS="$(date +%s%N)"
    END_SEC="$(date +%s)"

    EXTERNAL_TIME="$(awk -v start="$START_NS" -v end="$END_NS"         'BEGIN {printf "%.3f", (end-start)/1000000000}')"

    STATUS="FAILED"
    FINAL_STEP="NA"
    FINAL_SIM_TIME="NA"
    FDS_STEP_TIME="NA"
    FDS_TOTAL_TIME="NA"

    if [[ "$RC" -eq 0 ]] &&
       grep -q "STOP: FDS completed successfully" "$ERR_LOG"; then
        STATUS="COMPLETED"
    fi

    FINAL_RECORD="$(grep "Time Step:" "$ERR_LOG" | tail -n 1 || true)"
    if [[ -n "$FINAL_RECORD" ]]; then
        FINAL_STEP="$(printf '%s\n' "$FINAL_RECORD" | awk '{gsub(",", "", $3); print $3}')"
        FINAL_SIM_TIME="$(printf '%s\n' "$FINAL_RECORD" | awk '{print $6}')"
    fi

    if [[ -f "$FDS_OUT" ]]; then
        FDS_STEP_TIME="$(sed -n 's/.*Time Stepping Wall Clock Time (s):[[:space:]]*//p' "$FDS_OUT" | tail -n 1)"
        FDS_TOTAL_TIME="$(sed -n 's/.*Total Elapsed Wall Clock Time (s):[[:space:]]*//p' "$FDS_OUT" | tail -n 1)"
        [[ -n "$FDS_STEP_TIME" ]] || FDS_STEP_TIME="NA"
        [[ -n "$FDS_TOTAL_TIME" ]] || FDS_TOTAL_TIME="NA"
    fi

    {
        echo
        echo "============================================================"
        echo "Timing and validation information"
        echo "============================================================"
        echo "Nodes                       = $EXPECTED_NODES"
        echo "MPI ranks                   = $N"
        echo "Ranks per node              = $PPN"
        echo "Mesh arrangement            = $NX x $NY x $NZ"
        echo "Mesh count                  = $MESH_COUNT"
        echo "Global mesh                 = $TOTAL_I x $TOTAL_J x $TOTAL_K"
        echo "Total cells                 = $TOTAL_CELLS"
        echo "Cells per MPI rank          = $CELLS_PER_RANK"
        echo "T_END                       = $T_END_VALUE"
        echo "Final timestep              = $FINAL_STEP"
        echo "Final simulation time       = $FINAL_SIM_TIME s"
        echo "FDS time-stepping wall time = $FDS_STEP_TIME s"
        echo "FDS total elapsed wall time = $FDS_TOTAL_TIME s"
        echo "External mpirun wall time   = $EXTERNAL_TIME s"
        echo "MPI return code             = $RC"
        echo "Status                      = $STATUS"
        echo "Start                       = $(date -d "@$START_SEC")"
        echo "End                         = $(date -d "@$END_SEC")"
        echo "============================================================"
    } >> "$MAIN_LOG"

    printf "%s\t%s\t%s\t%sx%sx%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n"         "$EXPECTED_NODES" "$N" "$PPN" "$NX" "$NY" "$NZ"         "$MESH_COUNT" "$CELLS_PER_RANK" "$TOTAL_CELLS" "$T_END_VALUE"         "$FINAL_STEP" "$FINAL_SIM_TIME" "$FDS_STEP_TIME" "$FDS_TOTAL_TIME"         "$EXTERNAL_TIME" "$RC" "$STATUS" "$RUN_DIR"         >> "$SUMMARY_FILE"

    if [[ "$STATUS" != "COMPLETED" ]]; then
        tail -n 100 "$ERR_LOG" || true
        die "FDS failed or successful completion was not confirmed for N=$N."
    fi

    [[ "$FINAL_STEP" == "$EXPECTED_FINAL_STEP" ]] ||
        die "Expected final step $EXPECTED_FINAL_STEP, found $FINAL_STEP."
    [[ "$FINAL_SIM_TIME" == "$EXPECTED_FINAL_TIME" ]] ||
        die "Expected final time $EXPECTED_FINAL_TIME, found $FINAL_SIM_TIME."

    echo "DONE N=$N | FDS total=${FDS_TOTAL_TIME} s | external=${EXTERNAL_TIME} s"
done

section "FDS HOST 1-NODE SUMMARY"

column -t -s $'\t' "$SUMMARY_FILE" 2>/dev/null || cat "$SUMMARY_FILE"
echo "Results stored in: $ROOT"
echo "Summary file:      $SUMMARY_FILE"

