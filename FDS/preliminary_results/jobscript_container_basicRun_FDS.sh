# The code below is the basic preliminary execution run of FDS container benchmark application

#!/bin/bash
#SBATCH --job-name=fds_container_balanced
#SBATCH --output=/beegfs/gopal/fds/logs/fds_container_balanced_%j.out
#SBATCH --error=/beegfs/gopal/fds/logs/fds_container_balanced_%j.err
#SBATCH --time=24:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=10
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

set -e
set -o pipefail

WORKDIR="/beegfs/gopal/fds"
IMG="${WORKDIR}/fds.sif"

CASE_IN_IMG="/opt/fds/Verification/Fires/spray_burner.fds"

ROOT="${WORKDIR}/fds_container_balanced_${SLURM_JOB_ID}"
BASE_CASE="${ROOT}/base_case"
RUNS_DIR="${ROOT}/runs"
LOGS="${ROOT}/logs"

PROCS_LIST="2 4 6 8 10"

mkdir -p "$BASE_CASE" "$RUNS_DIR" "$LOGS" "${WORKDIR}/logs"

exec > >(stdbuf -oL -eL tee -a "$LOGS/console.log") 2>&1

echo "==> Host: $(hostname)"
echo "==> Date: $(date)"
echo "==> Image: $IMG"
echo "==> Root: $ROOT"
echo "==> Processor list: $PROCS_LIST"

module purge
module load 2023a GCC/12.3.0 OpenMPI/4.1.5

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close

echo "==> Checking container FDS"
apptainer exec "$IMG" which fds
apptainer exec "$IMG" fds -v
apptainer exec "$IMG" mpirun --version | head -n 2

echo "==> Copying original FDS case"
apptainer exec "$IMG" cat "$CASE_IN_IMG" > "$BASE_CASE/original_spray_burner.fds"

echo "==> Starting balanced FDS container sweep"

for N in $PROCS_LIST; do
    echo "======================================"
    echo "Running N=$N"
    echo "======================================"

    RUN_CASE="${RUNS_DIR}/case_N${N}"
    TMPDIR="/tmp/fds_balanced_${SLURM_JOB_ID}_N${N}"
    CASEFILE="spray_burner_balanced_${N}proc.fds"

    rm -rf "$RUN_CASE" "$TMPDIR"
    mkdir -p "$RUN_CASE/logs" "$TMPDIR"

    cp "$BASE_CASE/original_spray_burner.fds" "$TMPDIR/$CASEFILE"

    python3 - <<EOF
from pathlib import Path
import re

case = Path("$TMPDIR/$CASEFILE")
text = case.read_text()

N = int("$N")

layouts = {
    2:  (2, 1, 1),
    4:  (2, 2, 1),
    6:  (3, 2, 1),
    8:  (2, 2, 2),
    10: (5, 2, 1),
}

nx, ny, nz = layouts[N]

# 60 is chosen because it is divisible by 2, 3, and 5.
# This allows balanced mesh layouts for all tested processor counts.
total_i = 60
total_j = 60
total_k = 60

if total_i % nx != 0 or total_j % ny != 0 or total_k % nz != 0:
    raise SystemExit(f"ERROR: total cells not divisible by layout {(nx, ny, nz)}")

ijk_i = total_i // nx
ijk_j = total_j // ny
ijk_k = total_k // nz

mesh_lines = []

for ix in range(nx):
    for iy in range(ny):
        for iz in range(nz):
            x0 = ix / nx
            x1 = (ix + 1) / nx

            y0 = iy / ny
            y1 = (iy + 1) / ny

            z0 = iz / nz
            z1 = (iz + 1) / nz

            mesh_lines.append(
                f"&MESH IJK={ijk_i},{ijk_j},{ijk_k} "
                f"XB={x0:.6f},{x1:.6f},{y0:.6f},{y1:.6f},{z0:.6f},{z1:.6f} /"
            )

if len(mesh_lines) != N:
    raise SystemExit(f"ERROR: expected {N} meshes, got {len(mesh_lines)}")

new_mesh = "\\n".join(mesh_lines)

lines = text.splitlines()
out = []
inserted = False

for line in lines:
    if line.strip().upper().startswith("&MESH"):
        if not inserted:
            out.append(new_mesh)
            inserted = True
        continue
    out.append(line)

if not inserted:
    raise SystemExit("ERROR: No &MESH line found.")

text = "\\n".join(out) + "\\n"

# Change final simulation time from original T_END=90 to T_END=10
text = re.sub(
    r"&TIME\\s+T_END\\s*=\\s*[^/]+/",
    "&TIME T_END=10. /",
    text,
    flags=re.IGNORECASE
)

case.write_text(text)
EOF

    cd "$TMPDIR"

    echo "==> Verifying case for N=$N"
    grep -i "^[[:space:]]*&MESH" "$CASEFILE"
    grep -i "T_END" "$CASEFILE"

    MESH_COUNT=$(grep -i "^[[:space:]]*&MESH" "$CASEFILE" | wc -l)
    echo "==> Mesh count: $MESH_COUNT"

    if [ "$MESH_COUNT" -ne "$N" ]; then
        echo "ERROR: Expected $N meshes, found $MESH_COUNT"
        exit 2
    fi

    START_TIME=$(date +%s)

    echo "==> Running FDS with $N MPI ranks"

    apptainer exec --bind "$TMPDIR:$TMPDIR" "$IMG" \
        mpirun -np "$N" fds "$CASEFILE" \
        > "log.${N}proc" 2> "err.${N}proc"

    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))

    {
        echo ""
        echo "=============================="
        echo "Timing information"
        echo "N = $N"
        echo "Start = $(date -d @$START_TIME)"
        echo "End   = $(date -d @$END_TIME)"
        echo "Elapsed wall time = ${ELAPSED} s"
        echo "=============================="
    } >> "log.${N}proc"

    cp -a "$TMPDIR/." "$RUN_CASE/"
    cp "$TMPDIR/log.${N}proc" "$RUN_CASE/logs/"
    cp "$TMPDIR/err.${N}proc" "$RUN_CASE/logs/"

    rm -rf "$TMPDIR"

    echo "==== Done N=$N ===="
done

echo "==> Finished all balanced FDS container runs"
echo "==> Root folder: $ROOT"
