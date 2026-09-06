#!/bin/bash
#SBATCH --job-name=fds_container_1node
#SBATCH --output=/beegfs/gopal/new/fds/logs/fds_container_1node_%j.out
#SBATCH --error=/beegfs/gopal/new/fds/logs/fds_container_1node_%j.err
#SBATCH --time=12:00:00
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
PROCS_LIST="2 4 8 10 16 20 32 40 50"
TOTAL_I=80
TOTAL_J=80
TOTAL_K=80
T_END_VALUE="2.6"

MPI_PML="ob1"
MPI_BTL="self,vader,tcp"

JOB_ID="${SLURM_JOB_ID:-manual_$(date +%Y%m%d_%H%M%S)}"
ROOT="${BASE_DIR}/results/spray_burner_container_1node_SMPI_${JOB_ID}"
BASE_CASE="${ROOT}/base_case"
RUNS_DIR="${ROOT}/runs"
LOGS_DIR="${ROOT}/logs"
SUMMARY_FILE="${ROOT}/timing_summary.tsv"

mkdir -p "${BASE_DIR}/logs" "$BASE_CASE" "$RUNS_DIR" "$LOGS_DIR"

exec > >(stdbuf -oL -eL tee -a "${LOGS_DIR}/console.log") 2>&1

timestamp() {
    date '+%Y-%m-%d %H:%M:%S %Z'
}

section() {
    echo
    echo "============================================================"
    echo "$*"
    echo "============================================================"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

show_tail() {
    local file="$1"
    [[ -f "$file" ]] && tail -n 200 "$file" || true
}

on_error() {
    local rc=$?
    echo
    echo "SCRIPT FAILED"
    echo "Line: ${BASH_LINENO[0]:-unknown}"
    echo "Command: ${BASH_COMMAND:-unknown}"
    echo "Exit code: $rc"
    exit "$rc"
}
trap on_error ERR

layout_for_ranks() {
    case "$1" in
        2)  echo "2 1 1" ;;
        4)  echo "2 2 1" ;;
        8)  echo "2 2 2" ;;
        10) echo "5 2 1" ;;
        16) echo "4 2 2" ;;
        20) echo "5 2 2" ;;
        32) echo "4 4 2" ;;
        40) echo "5 4 2" ;;
        50) echo "5 5 2" ;;
        *) return 1 ;;
    esac
}

elapsed_seconds() {
    python3 - "$1" "$2" <<'PY'
import sys
print(f"{float(sys.argv[2]) - float(sys.argv[1]):.6f}")
PY
}

section "Loading modules"

module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5
module list 2>&1 || true

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=false
export OMPI_MCA_pml="$MPI_PML"
export OMPI_MCA_btl="$MPI_BTL"

for v in FOAM_INST_DIR WM_PROJECT_DIR WM_THIRD_PARTY_DIR WM_OPTIONS \
         WM_COMPILER WM_MPLIB FOAM_MPI FDS_HOME FDS_BIN \
         CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH; do
    unset "$v" || true
done

section "Validating inputs"

[[ -n "${SLURM_JOB_ID:-}" ]] || die "Submit this script with sbatch."
[[ -f "$IMAGE" ]] || die "Image not found: $IMAGE"
[[ "${SLURM_JOB_NUM_NODES:-0}" -eq 1 ]] || die "This script requires exactly one node."
[[ "${SLURM_NTASKS:-0}" -ge 50 ]] || die "At least 50 Slurm tasks are required."

for cmd in apptainer mpirun python3 awk grep sort uniq wc scontrol; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
done

scontrol show hostnames "$SLURM_JOB_NODELIST" | tee "${LOGS_DIR}/allocated_nodes.txt"

section "Environment information"

echo "Started:           $(timestamp)"
echo "Job ID:            $JOB_ID"
echo "Host:              $(hostname)"
echo "Nodes:             ${SLURM_JOB_NUM_NODES}"
echo "Allocated tasks:   ${SLURM_NTASKS}"
echo "Image:             $IMAGE"
echo "Tutorial:          $CASE_IN_IMAGE"
echo "Grid:              ${TOTAL_I} x ${TOTAL_J} x ${TOTAL_K}"
echo "T_END:             $T_END_VALUE"
echo "Processor list:    $PROCS_LIST"
echo "Results:           $ROOT"
echo
echo "Host MPI:"
which mpirun
mpirun --version | head -n 2

section "Verifying FDS container"

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
        export OMP_NUM_THREADS=1

        echo "FDS binary: $(command -v fds)"
        echo "MPI: $(mpirun --version | sed -n "1p")"
        echo "GCC: $(gcc -dumpfullversion)"

        test -x "$FDS_BIN"
        "$FDS_BIN" -v || true
        file "$FDS_BIN"
        ldd "$FDS_BIN"

        if ldd "$FDS_BIN" | grep -q "not found"; then
            exit 20
        fi

        MPI_LINE="$(ldd "$FDS_BIN" | grep -m1 libmpi)"
        echo "$MPI_LINE"

        case "$MPI_LINE" in
            *"/beegfs/Tools/"*"OpenMPI/4.1.5-GCC-12.3.0/"*) ;;
            *) exit 21 ;;
        esac
    ' > "$VERIFY_LOG" 2>&1
VERIFY_RC=$?
set -e

cat "$VERIFY_LOG"
[[ "$VERIFY_RC" -eq 0 ]] || die "Container verification failed."

section "Copying spray_burner tutorial"

ORIGINAL_CASE="${BASE_CASE}/spray_burner_original.fds"

apptainer exec \
    --cleanenv \
    --bind /beegfs/Tools:/beegfs/Tools:ro \
    "$IMAGE" \
    /bin/bash -lc "cat '$CASE_IN_IMAGE'" \
    > "$ORIGINAL_CASE"

[[ -s "$ORIGINAL_CASE" ]] || die "Copied tutorial is empty."

printf 'nodes\tranks\tranks_per_node\ttotal_i\ttotal_j\ttotal_k\ttotal_cells\tmeshes\tmesh_layout\tcells_per_rank\tt_end\telapsed_seconds\texit_code\tstatus\tcase_directory\n' \
    > "$SUMMARY_FILE"

for N in $PROCS_LIST; do
    section "Running FDS with N=${N}"

    read -r NX NY NZ <<< "$(layout_for_ranks "$N")"

    [[ "$((NX * NY * NZ))" -eq "$N" ]] || die "Invalid layout for N=$N."
    (( TOTAL_I % NX == 0 )) || die "TOTAL_I not divisible by NX for N=$N."
    (( TOTAL_J % NY == 0 )) || die "TOTAL_J not divisible by NY for N=$N."
    (( TOTAL_K % NZ == 0 )) || die "TOTAL_K not divisible by NZ for N=$N."

    PPN="$N"
    RUN_DIR="${RUNS_DIR}/case_N${N}"
    WORK_DIR="${RUN_DIR}/work"
    RUN_LOG_DIR="${RUN_DIR}/logs"
    CASE_FILE="spray_burner_80mesh_${N}proc.fds"
    CASE_PATH="${WORK_DIR}/${CASE_FILE}"

    rm -rf "$RUN_DIR"
    mkdir -p "$WORK_DIR" "$RUN_LOG_DIR"
    cp "$ORIGINAL_CASE" "$CASE_PATH"

    python3 - \
        "$CASE_PATH" \
        "$TOTAL_I" "$TOTAL_J" "$TOTAL_K" \
        "$NX" "$NY" "$NZ" \
        "$T_END_VALUE" <<'PY'
from pathlib import Path
import re
import sys

case_path = Path(sys.argv[1])
I, J, K = map(int, sys.argv[2:5])
nx, ny, nz = map(int, sys.argv[5:8])
t_end = sys.argv[8]

text = case_path.read_text()

mesh_pattern = re.compile(r"(?ims)^[ \t]*&MESH\b.*?/[ \t]*(?:\r?\n|$)")
matches = list(mesh_pattern.finditer(text))
if not matches:
    raise SystemExit("ERROR: no &MESH entry found.")

first = matches[0].group(0)

xb_match = re.search(
    r"(?i)\bXB\s*=\s*"
    r"([-+0-9.eEdD]+)\s*,\s*([-+0-9.eEdD]+)\s*,\s*"
    r"([-+0-9.eEdD]+)\s*,\s*([-+0-9.eEdD]+)\s*,\s*"
    r"([-+0-9.eEdD]+)\s*,\s*([-+0-9.eEdD]+)",
    first,
)
if not xb_match:
    raise SystemExit("ERROR: unable to extract XB from original mesh.")

def f(x):
    return float(x.replace("D", "E").replace("d", "e"))

x0, x1, y0, y1, z0, z1 = map(f, xb_match.groups())

if I % nx or J % ny or K % nz:
    raise SystemExit("ERROR: grid is not divisible by selected layout.")

ii, jj, kk = I // nx, J // ny, K // nz

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
                f"IJK={ii},{jj},{kk}, "
                f"XB={xa:.9g},{xb:.9g},"
                f"{ya:.9g},{yb:.9g},"
                f"{za:.9g},{zb:.9g} /"
            )

start, end = matches[0].span()
before = text[:start]
after = text[end:]
after = mesh_pattern.sub("", after)
text = before + "\n".join(mesh_lines) + "\n" + after

time_pattern = re.compile(r"(?ims)^[ \t]*&TIME\b.*?/[ \t]*(?:\r?\n|$)")
new_time = f"&TIME T_END={t_end} /\n"

if time_pattern.search(text):
    text = time_pattern.sub(new_time, text, count=1)
else:
    text += "\n" + new_time

case_path.write_text(text)

print(f"Layout: {nx} x {ny} x {nz}")
print(f"Meshes: {len(mesh_lines)}")
print(f"Cells per mesh: {ii} x {jj} x {kk}")
print(f"Domain: {x0}, {x1}, {y0}, {y1}, {z0}, {z1}")
PY

    MESH_COUNT="$(
        grep -iE '^[[:space:]]*&MESH([[:space:]]|$)' "$CASE_PATH" |
        wc -l |
        tr -d '[:space:]'
    )"

    [[ "$MESH_COUNT" -eq "$N" ]] ||
        die "Expected $N meshes but found $MESH_COUNT."

    TOTAL_CELLS=$((TOTAL_I * TOTAL_J * TOTAL_K))

    CELLS_PER_RANK="$(
        python3 - "$TOTAL_CELLS" "$N" <<'PY'
import sys
print(f"{int(sys.argv[1]) / int(sys.argv[2]):.3f}")
PY
    )"

    echo "Layout:          ${NX} x ${NY} x ${NZ}"
    echo "Meshes:          $MESH_COUNT"
    echo "Total cells:     $TOTAL_CELLS"
    echo "Cells per rank:  $CELLS_PER_RANK"
    grep -iE '^[[:space:]]*&TIME([[:space:]]|$)' "$CASE_PATH" || true

    grep -iE '^[[:space:]]*&MESH([[:space:]]|$)' "$CASE_PATH" \
        > "${RUN_LOG_DIR}/generated_meshes.txt"

    PLACEMENT_RAW="${RUN_LOG_DIR}/rank_placement_raw.txt"
    PLACEMENT_ERR="${RUN_LOG_DIR}/rank_placement.err"
    PLACEMENT_SUMMARY="${RUN_LOG_DIR}/rank_placement_summary.txt"

    set +e
    mpirun \
        --mca pml "$MPI_PML" \
        --mca btl "$MPI_BTL" \
        -np "$N" \
        hostname \
        > "$PLACEMENT_RAW" \
        2> "$PLACEMENT_ERR"
    PLACEMENT_RC=$?
    set -e

    if [[ "$PLACEMENT_RC" -ne 0 ]]; then
        show_tail "$PLACEMENT_ERR"
        die "Rank placement test failed for N=$N."
    fi

    sort "$PLACEMENT_RAW" | uniq -c | tee "$PLACEMENT_SUMMARY"

    PLACED_RANKS="$(awk '{s += $1} END {print s+0}' "$PLACEMENT_SUMMARY")"
    [[ "$PLACED_RANKS" -eq "$N" ]] ||
        die "Rank placement test found $PLACED_RANKS ranks instead of $N."

    SOLVER_STDOUT="${RUN_LOG_DIR}/log.${N}proc"
    SOLVER_STDERR="${RUN_LOG_DIR}/err.${N}proc"

    START_EPOCH="$(date +%s.%N)"
    START_TEXT="$(timestamp)"

    set +e
    mpirun \
        --mca pml "$MPI_PML" \
        --mca btl "$MPI_BTL" \
        -np "$N" \
        apptainer exec \
            --cleanenv \
            --bind /beegfs/Tools:/beegfs/Tools:ro \
            --bind "${WORK_DIR}:${WORK_DIR}" \
            --pwd "$WORK_DIR" \
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
                export OMPI_MCA_pml=${MPI_PML}
                export OMPI_MCA_btl=${MPI_BTL}
                exec \"\$FDS_BIN\" '$CASE_FILE'
            " \
        > "$SOLVER_STDOUT" \
        2> "$SOLVER_STDERR"
    SOLVER_RC=$?
    set -e

    END_EPOCH="$(date +%s.%N)"
    END_TEXT="$(timestamp)"
    ELAPSED="$(elapsed_seconds "$START_EPOCH" "$END_EPOCH")"

    STATUS="completed"
    [[ "$SOLVER_RC" -eq 0 ]] || STATUS="failed"

    {
        echo
        echo "============================================================"
        echo "FDS RUN SUMMARY"
        echo "============================================================"
        echo "Start:              $START_TEXT"
        echo "End:                $END_TEXT"
        echo "Nodes:              1"
        echo "MPI ranks:          $N"
        echo "Ranks per node:     $PPN"
        echo "Mesh layout:        ${NX} x ${NY} x ${NZ}"
        echo "Meshes:             $MESH_COUNT"
        echo "Total grid:         ${TOTAL_I} x ${TOTAL_J} x ${TOTAL_K}"
        echo "Total cells:        $TOTAL_CELLS"
        echo "Cells per rank:     $CELLS_PER_RANK"
        echo "T_END:              $T_END_VALUE"
        echo "Elapsed wall time:  ${ELAPSED} s"
        echo "Exit code:          $SOLVER_RC"
        echo "Status:             $STATUS"
        echo "============================================================"
    } | tee -a "$SOLVER_STDOUT"

    printf '1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$N" "$PPN" "$TOTAL_I" "$TOTAL_J" "$TOTAL_K" "$TOTAL_CELLS" \
        "$MESH_COUNT" "${NX}x${NY}x${NZ}" "$CELLS_PER_RANK" \
        "$T_END_VALUE" "$ELAPSED" "$SOLVER_RC" "$STATUS" "$RUN_DIR" \
        >> "$SUMMARY_FILE"

    if [[ "$SOLVER_RC" -ne 0 ]]; then
        show_tail "$SOLVER_STDOUT"
        show_tail "$SOLVER_STDERR"
        die "FDS failed for N=$N."
    fi

    echo "Completed N=$N in ${ELAPSED} seconds."
done

section "All FDS container benchmark runs completed"

echo "Results directory:"
echo "$ROOT"
echo
echo "Timing summary:"
echo "$SUMMARY_FILE"
echo

if command -v column >/dev/null 2>&1; then
    column -t -s $'\t' "$SUMMARY_FILE"
else
    cat "$SUMMARY_FILE"
fi

echo
echo "Finished: $(timestamp)"
echo "============================================================"

exit 0

