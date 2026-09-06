#!/bin/bash
#SBATCH --job-name=fds_container_200cube
#SBATCH --output=/beegfs/gopal/new/fds/logs/fds_container_200cube_%j.out
#SBATCH --error=/beegfs/gopal/new/fds/logs/fds_container_200cube_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=50
#SBATCH --ntasks-per-node=50
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

set -e
set -o pipefail

BASE_DIR="/beegfs/gopal/new/fds"
IMAGE="${BASE_DIR}/fds_image.sif"
CASE_IN_IMAGE="/opt/fds/Verification/Fires/spray_burner.fds"
FDS_BIN="/opt/fds/bin/fds"

MODE="${MODE:-explicit_mpi}"

TOTAL_I=200
TOTAL_J=200
TOTAL_K=200
TOTAL_CELLS=$((TOTAL_I * TOTAL_J * TOTAL_K))
EXPECTED_TOTAL_CELLS=8000000
T_END_VALUE="2.6"
CHID="spray_burner"

MPI_PML="ob1"
MPI_BTL="self,vader,tcp"

NODES="${SLURM_JOB_NUM_NODES:-0}"
ALLOCATED_TASKS="${SLURM_NTASKS:-0}"
TASKS_PER_NODE="${SLURM_NTASKS_PER_NODE:-50}"
TASKS_PER_NODE="${TASKS_PER_NODE%%(*}"
CPUS_PER_TASK="${SLURM_CPUS_PER_TASK:-1}"
JOB_ID="${SLURM_JOB_ID:-manual_$(date +%Y%m%d_%H%M%S)}"

fail(){ echo "ERROR: $*" >&2; exit 1; }
section(){ echo; echo "============================================================"; echo "$*"; echo "============================================================"; }
timestamp(){ date '+%Y-%m-%d %H:%M:%S %Z'; }
elapsed_seconds(){ python3 - "$1" "$2" <<'PY'
import sys
print(f"{float(sys.argv[2])-float(sys.argv[1]):.6f}")
PY
}

layout_for_ranks(){
    case "$1" in
        2) echo "2 1 1" ;;
        4) echo "2 2 1" ;;
        8) echo "2 2 2" ;;
        10) echo "5 2 1" ;;
        16) echo "4 2 2" ;;
        20) echo "5 2 2" ;;
        25) echo "5 5 1" ;;
        32) echo "4 4 2" ;;
        40) echo "5 4 2" ;;
        50) echo "5 5 2" ;;
        64) echo "4 4 4" ;;
        80) echo "5 4 4" ;;
        100) echo "5 5 4" ;;
        128) echo "8 4 4" ;;
        160) echo "8 5 4" ;;
        200) echo "10 5 4" ;;
        *) return 1 ;;
    esac
}

case "$MODE" in
    explicit_mpi|standard_mpi) ;;
    *) fail "MODE must be explicit_mpi or standard_mpi" ;;
esac

(( NODES > 0 )) || fail "Submit with sbatch"
(( ALLOCATED_TASKS > 0 )) || fail "SLURM_NTASKS is missing"
(( CPUS_PER_TASK == 1 )) || fail "Use --cpus-per-task=1"
(( TOTAL_CELLS == EXPECTED_TOTAL_CELLS )) || fail "Mesh is not 8,000,000 cells"

case "$NODES" in
    1)
        REQUIRED_TASKS=50
        PROCS_LIST="2 4 8 10 16 20 25 32 40 50"
        ;;
    2)
        REQUIRED_TASKS=100
        PROCS_LIST="2 4 8 10 16 20 32 40 50 64 80 100"
        ;;
    4)
        REQUIRED_TASKS=200
        if [[ "$MODE" == "explicit_mpi" ]]; then
            PROCS_LIST="4 8 16 20 32 40 64 80 100 128 160 200"
        else
            PROCS_LIST="4 8 10 16 20 32 40 50 64 80 100 128 160 200"
        fi
        ;;
    *) fail "Only 1, 2, and 4 nodes are supported" ;;
esac

(( ALLOCATED_TASKS >= REQUIRED_TASKS )) || fail "Not enough Slurm tasks"

for N in $PROCS_LIST; do
    read -r NX NY NZ < <(layout_for_ranks "$N") || fail "No layout for N=$N"
    (( NX * NY * NZ == N )) || fail "Invalid layout for N=$N"
    (( TOTAL_I % NX == 0 )) || fail "I dimension not divisible for N=$N"
    (( TOTAL_J % NY == 0 )) || fail "J dimension not divisible for N=$N"
    (( TOTAL_K % NZ == 0 )) || fail "K dimension not divisible for N=$N"

    if [[ "$MODE" == "explicit_mpi" ]]; then
        (( N % NODES == 0 )) || fail "$N ranks cannot be balanced across $NODES nodes"
        (( N / NODES <= TASKS_PER_NODE )) || fail "Too many ranks per node for N=$N"
    fi
done

ROOT="${BASE_DIR}/results/spray_burner_200x200x200_container_${NODES}node_${MODE}_${JOB_ID}"
BASE_CASE="${ROOT}/base_case"
RUNS_DIR="${ROOT}/runs"
LOGS_DIR="${ROOT}/logs"
SUMMARY_FILE="${ROOT}/timing_summary.tsv"

mkdir -p "${BASE_DIR}/logs"
rm -rf "$ROOT"
mkdir -p "$BASE_CASE" "$RUNS_DIR" "$LOGS_DIR"
exec > >(stdbuf -oL -eL tee -a "${LOGS_DIR}/console.log") 2>&1

module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5
module list 2>&1 || true

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=false
unset OMP_PLACES || true

[[ -f "$IMAGE" ]] || fail "Image not found: $IMAGE"
command -v apptainer >/dev/null 2>&1 || fail "apptainer not found"
command -v mpirun >/dev/null 2>&1 || fail "mpirun not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"

MPI_VERSION="$(mpirun --version | sed -n '1p')"
[[ "$MPI_VERSION" == *"4.1.5"* ]] || fail "Expected OpenMPI 4.1.5; found $MPI_VERSION"

section "FDS CONTAINER 200x200x200 — ${MODE} — ${NODES} NODE(S)"
echo "Started:          $(timestamp)"
echo "Job ID:           $JOB_ID"
echo "Nodes:            $NODES"
echo "Allocated tasks:  $ALLOCATED_TASKS"
echo "Tasks per node:   $TASKS_PER_NODE"
echo "Processor sweep:  $PROCS_LIST"
echo "Global mesh:      ${TOTAL_I} x ${TOTAL_J} x ${TOTAL_K}"
echo "Total cells:      $TOTAL_CELLS"
echo "Meshes:           equal to MPI ranks"
echo "T_END:            $T_END_VALUE"
echo "MPI:              $MPI_VERSION"
echo "PML/BTL:          $MPI_PML / $MPI_BTL"
echo "Results:          $ROOT"

section "Verify container FDS runtime"
VERIFY_LOG="${LOGS_DIR}/container_verification.log"
set +e
apptainer exec \
    --cleanenv \
    --bind /beegfs/Tools:/beegfs/Tools:ro \
    "$IMAGE" \
    /bin/bash -lc '
        set -e
        set -o pipefail
        . /opt/host_mpi_env.sh
        unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH
        export FDS_HOME=/opt/fds
        export FDS_BIN=/opt/fds/bin/fds
        export PATH=/opt/fds/bin:${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}
        test -x "$FDS_BIN"
        echo "FDS: $(command -v fds)"
        echo "MPI: $(mpirun --version | sed -n "1p")"
        ldd "$FDS_BIN"
        ! ldd "$FDS_BIN" | grep -q "not found"
        ldd "$FDS_BIN" | grep -m1 "libmpi.so" | grep -q "/beegfs/Tools/.*OpenMPI/4.1.5-GCC-12.3.0/"
    ' > "$VERIFY_LOG" 2>&1
VERIFY_RC=$?
set -e
cat "$VERIFY_LOG"
(( VERIFY_RC == 0 )) || fail "Container verification failed"

section "Copy tutorial"
ORIGINAL_CASE="${BASE_CASE}/spray_burner_original.fds"
apptainer exec --cleanenv "$IMAGE" /bin/bash -lc "cat '$CASE_IN_IMAGE'" > "$ORIGINAL_CASE"
[[ -s "$ORIGINAL_CASE" ]] || fail "Copied tutorial is empty"

grep -iE '^[[:space:]]*&HEAD|^[[:space:]]*&MESH|^[[:space:]]*&TIME' "$ORIGINAL_CASE" | head -20

printf 'nodes\tranks\tranks_per_node\tglobal_mesh\tmesh_layout\tlocal_mesh\ttotal_cells\tmeshes\tcells_per_rank\tt_end\tfinal_step\tfinal_time\texternal_time_s\texit_code\tstatus\tcase_directory\n' > "$SUMMARY_FILE"

for N in $PROCS_LIST; do
    section "RUN N=$N"

    read -r NX NY NZ < <(layout_for_ranks "$N")
    LOCAL_I=$((TOTAL_I / NX))
    LOCAL_J=$((TOTAL_J / NY))
    LOCAL_K=$((TOTAL_K / NZ))
    LOCAL_CELLS=$((LOCAL_I * LOCAL_J * LOCAL_K))

    RUN_DIR="${RUNS_DIR}/case_N${N}"
    WORK_DIR="${RUN_DIR}/work"
    RUN_LOG_DIR="${RUN_DIR}/logs"
    CASE_FILE="${CHID}_200x200x200_${N}proc.fds"
    CASE_PATH="${WORK_DIR}/${CASE_FILE}"
    SOLVER_STDOUT="${RUN_LOG_DIR}/log.${N}proc"
    SOLVER_STDERR="${RUN_LOG_DIR}/err.${N}proc"

    rm -rf "$RUN_DIR"
    mkdir -p "$WORK_DIR" "$RUN_LOG_DIR"
    cp "$ORIGINAL_CASE" "$CASE_PATH"

    python3 - "$CASE_PATH" "$TOTAL_I" "$TOTAL_J" "$TOTAL_K" "$NX" "$NY" "$NZ" "$N" "$T_END_VALUE" <<'PYCASE'
from pathlib import Path
import re, sys

path = Path(sys.argv[1])
I, J, K = map(int, sys.argv[2:5])
nx, ny, nz = map(int, sys.argv[5:8])
expected_meshes = int(sys.argv[8])
t_end = sys.argv[9]
text = path.read_text()

mesh_pattern = re.compile(r"(?ims)^[ \t]*&MESH\b.*?/[ \t]*(?:\r?\n|$)")
matches = list(mesh_pattern.finditer(text))
if not matches:
    raise SystemExit("ERROR: no &MESH record found")

first = matches[0].group(0)
xb_match = re.search(
    r"(?i)\bXB\s*=\s*"
    r"([-+0-9.eEdD]+)\s*,\s*([-+0-9.eEdD]+)\s*,\s*"
    r"([-+0-9.eEdD]+)\s*,\s*([-+0-9.eEdD]+)\s*,\s*"
    r"([-+0-9.eEdD]+)\s*,\s*([-+0-9.eEdD]+)", first)
if not xb_match:
    raise SystemExit("ERROR: cannot extract XB")

conv = lambda s: float(s.replace("D", "E").replace("d", "e"))
x0, x1, y0, y1, z0, z1 = map(conv, xb_match.groups())

if nx * ny * nz != expected_meshes:
    raise SystemExit("ERROR: mesh count does not equal rank count")
if I % nx or J % ny or K % nz:
    raise SystemExit("ERROR: grid not divisible by layout")

ii, jj, kk = I // nx, J // ny, K // nz
mesh_lines = []
for ix in range(nx):
    xa = x0 + (x1-x0)*ix/nx
    xb = x0 + (x1-x0)*(ix+1)/nx
    for iy in range(ny):
        ya = y0 + (y1-y0)*iy/ny
        yb = y0 + (y1-y0)*(iy+1)/ny
        for iz in range(nz):
            za = z0 + (z1-z0)*iz/nz
            zb = z0 + (z1-z0)*(iz+1)/nz
            mesh_lines.append(
                "&MESH "
                f"IJK={ii},{jj},{kk}, "
                f"XB={xa:.12g},{xb:.12g},{ya:.12g},{yb:.12g},{za:.12g},{zb:.12g} /"
            )

start, end = matches[0].span()
after = mesh_pattern.sub("", text[end:])
text = text[:start] + "\n".join(mesh_lines) + "\n" + after

time_pattern = re.compile(r"(?ims)^[ \t]*&TIME\b.*?/[ \t]*(?:\r?\n|$)")
new_time = f"&TIME T_END={t_end} /\n"
text = time_pattern.sub(new_time, text, count=1) if time_pattern.search(text) else text + "\n" + new_time
path.write_text(text)

print(f"Generated meshes: {len(mesh_lines)}")
print(f"Layout: {nx}x{ny}x{nz}")
print(f"Local mesh: {ii}x{jj}x{kk}")
print(f"T_END: {t_end}")
PYCASE

    MESH_COUNT="$(grep -iE '^[[:space:]]*&MESH([[:space:]]|$)' "$CASE_PATH" | wc -l | tr -d '[:space:]')"
    (( MESH_COUNT == N )) || fail "Expected $N meshes; found $MESH_COUNT"

    MPI_ARGS=()
    if [[ "$MODE" == "explicit_mpi" ]]; then
        PPN=$((N / NODES))
        MPI_ARGS=(--map-by "ppr:${PPN}:node:PE=1" --bind-to core)
        REPORTED_PPN="$PPN"
    else
        REPORTED_PPN="NA"
    fi

    echo "MPI ranks:       $N"
    echo "Meshes:          $MESH_COUNT"
    echo "Layout:          ${NX}x${NY}x${NZ}"
    echo "Local mesh:      ${LOCAL_I}x${LOCAL_J}x${LOCAL_K}"
    echo "Cells per rank:  $LOCAL_CELLS"
    echo "T_END:           $T_END_VALUE"

    START_EPOCH="$(date +%s.%N)"
    set +e
    mpirun \
        --mca pml "$MPI_PML" \
        --mca btl "$MPI_BTL" \
        "${MPI_ARGS[@]}" \
        -np "$N" \
        apptainer exec \
            --bind /beegfs/Tools:/beegfs/Tools:ro \
            --bind "${WORK_DIR}:/case" \
            --pwd /case \
            --env OMP_NUM_THREADS=1 \
            --env OMP_PROC_BIND=false \
            "$IMAGE" \
            /bin/bash -lc "
                set -e
                set -o pipefail
                . /opt/host_mpi_env.sh
                unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH
                export FDS_HOME=/opt/fds
                export FDS_BIN=/opt/fds/bin/fds
                export PATH=/opt/fds/bin:\${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}
                export OMP_NUM_THREADS=1
                export OMP_PROC_BIND=false
                export OMPI_MCA_pml='${MPI_PML}'
                export OMPI_MCA_btl='${MPI_BTL}'
                cd /case
                exec \"\$FDS_BIN\" '${CASE_FILE}'
            " \
        > "$SOLVER_STDOUT" \
        2> "$SOLVER_STDERR"
    SOLVER_RC=$?
    set -e

    END_EPOCH="$(date +%s.%N)"
    EXTERNAL_TIME="$(elapsed_seconds "$START_EPOCH" "$END_EPOCH")"

    DETECTED_MPI_PROCS="$(grep -h -m1 'Number of MPI Processes:' "$SOLVER_STDOUT" "$SOLVER_STDERR" | awk '{print $5}')"
    [[ "$DETECTED_MPI_PROCS" == "$N" ]] || fail "Requested $N ranks, FDS reported ${DETECTED_MPI_PROCS:-unknown}"

    PARSE_FILE="${RUN_LOG_DIR}/combined_output.${N}.txt"
    cat "$SOLVER_STDOUT" "$SOLVER_STDERR" > "$PARSE_FILE"
    [[ -f "${WORK_DIR}/${CHID}.out" ]] && cat "${WORK_DIR}/${CHID}.out" >> "$PARSE_FILE"

    read -r FINAL_STEP FINAL_TIME < <(python3 - "$PARSE_FILE" <<'PYPARSE'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text(errors="replace")
steps = re.findall(r"Time\s+Step:\s*(\d+)", text, re.I)
times = re.findall(r"Simulation\s+Time:\s*([-+0-9.eEdD]+)", text, re.I)
print(steps[-1] if steps else "NA", times[-1] if times else "NA")
PYPARSE
    )

    STATUS="completed"
    (( SOLVER_RC == 0 )) || STATUS="failed"

    printf '%s\t%s\t%s\t%sx%sx%s\t%sx%sx%s\t%sx%sx%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$NODES" "$N" "$REPORTED_PPN" \
        "$TOTAL_I" "$TOTAL_J" "$TOTAL_K" \
        "$NX" "$NY" "$NZ" \
        "$LOCAL_I" "$LOCAL_J" "$LOCAL_K" \
        "$TOTAL_CELLS" "$MESH_COUNT" "$LOCAL_CELLS" "$T_END_VALUE" \
        "$FINAL_STEP" "$FINAL_TIME" "$EXTERNAL_TIME" "$SOLVER_RC" "$STATUS" "$RUN_DIR" \
        >> "$SUMMARY_FILE"

    (( SOLVER_RC == 0 )) || fail "FDS failed for N=$N"

    if grep -Eiq 'ERROR:|segmentation fault|floating point exception|out of memory|forrtl: severe|MPI_ABORT|STOP:.*error' "$SOLVER_STDOUT" "$SOLVER_STDERR"; then
        fail "Fatal FDS error detected for N=$N"
    fi

    echo "COMPLETED: N=$N, elapsed=${EXTERNAL_TIME} s"
done

section "ALL FDS CONTAINER RUNS COMPLETED"
echo "Summary:  $SUMMARY_FILE"
echo "Results:  $ROOT"
echo "Finished: $(timestamp)"

if command -v column >/dev/null 2>&1; then
    column -t -s $'\t' "$SUMMARY_FILE"
else
    cat "$SUMMARY_FILE"
fi

exit 0

