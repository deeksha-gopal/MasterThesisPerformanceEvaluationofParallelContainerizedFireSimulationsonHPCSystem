# The below code is the execution of FDS container without including the Host software modules of OpenMPI and GCC.

#!/bin/bash
#SBATCH --job-name=fds_80mesh_scaling
#SBATCH --output=/beegfs/gopal/fds/logs/fds_80mesh_%j.out
#SBATCH --error=/beegfs/gopal/fds/logs/fds_80mesh_%j.err
#SBATCH --time=10:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=50
#SBATCH --cpus-per-task=1
#SBATCH --exclusive

set -e
set -o pipefail

module purge
module load 2023a GCC/12.3.0 OpenMPI/4.1.5

export OMP_NUM_THREADS=1
export OMP_PROC_BIND=close

WORKDIR="/beegfs/gopal/fds"
IMG="${WORKDIR}/fds.sif"
CASE_IN_IMG="/opt/fds/Verification/Fires/spray_burner.fds"

ROOT="${WORKDIR}/fds_80mesh_1node_${SLURM_JOB_ID}"
BASE="${ROOT}/base"
RUNS="${ROOT}/runs"
LOGS="${ROOT}/logs"

PROCS_LIST="2 4 8 10 16 20 32 40 50"
T_END_VALUE="2.6"

mkdir -p "$BASE" "$RUNS" "$LOGS" "${WORKDIR}/logs"

exec > >(stdbuf -oL -eL tee -a "$LOGS/console.log") 2>&1

echo "=================================="
echo "HOST: $(hostname)"
echo "DATE: $(date)"
echo "ROOT: $ROOT"
echo "TOTAL MESH: 80 x 80 x 80"
echo "T_END: $T_END_VALUE"
echo "PROCS_LIST: $PROCS_LIST"
echo "NODES:"
scontrol show hostnames "$SLURM_JOB_NODELIST" | tee "$LOGS/nodes.txt"
echo "=================================="

HOSTFILE="$LOGS/hostfile"
rm -f "$HOSTFILE"
echo "$(hostname) slots=$SLURM_NTASKS" > "$HOSTFILE"
echo "HOSTFILE:"
cat "$HOSTFILE"

echo "==> Checking FDS container"
apptainer exec "$IMG" which fds
apptainer exec "$IMG" fds -v

echo "==> Checking host MPI"
which mpirun
mpirun --version | head -n 2

echo "==> Copying base case"
apptainer exec "$IMG" cat "$CASE_IN_IMG" > "$BASE/base.fds"

for N in $PROCS_LIST; do
    echo "=================================="
    echo "RUN N=$N"
    echo "=================================="

    if [ $((N % SLURM_JOB_NUM_NODES)) -ne 0 ]; then
        echo "ERROR: N=$N is not divisible by nodes=$SLURM_JOB_NUM_NODES"
        exit 2
    fi

    case "$N" in
        2)  NX=2; NY=1; NZ=1 ;;
        4)  NX=2; NY=2; NZ=1 ;;
        8)  NX=2; NY=2; NZ=2 ;;
        10) NX=5; NY=2; NZ=1 ;;
        16) NX=4; NY=2; NZ=2 ;;
        20) NX=5; NY=2; NZ=2 ;;
        32) NX=4; NY=4; NZ=2 ;;
        40) NX=5; NY=4; NZ=2 ;;
        50) NX=5; NY=5; NZ=2 ;;
        *) echo "ERROR: No balanced layout defined for N=$N"; exit 3 ;;
    esac

    PPN=$((N / SLURM_JOB_NUM_NODES))

    RUN="${RUNS}/case_N${N}"
    WORK="${RUN}/work"
    CASEFILE="spray_burner_80mesh_${N}proc.fds"

    rm -rf "$RUN"
    mkdir -p "$WORK" "$RUN/logs"

    cp "$BASE/base.fds" "$WORK/$CASEFILE"

    python3 - <<EOF
from pathlib import Path
import re

case = Path("$WORK/$CASEFILE")
text = case.read_text()

nx, ny, nz = $NX, $NY, $NZ
T_END = "$T_END_VALUE"

I = J = K = 80

if I % nx != 0 or J % ny != 0 or K % nz != 0:
    raise SystemExit(f"ERROR: 80x80x80 not divisible by layout {(nx, ny, nz)}")

ii = I // nx
jj = J // ny
kk = K // nz

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
                f"&MESH IJK={ii},{jj},{kk} "
                f"XB={x0:.6f},{x1:.6f},{y0:.6f},{y1:.6f},{z0:.6f},{z1:.6f} /"
            )

new_mesh = "\\n".join(mesh_lines)

out = []
inserted = False

for line in text.splitlines():
    if line.strip().upper().startswith("&MESH"):
        if not inserted:
            out.append(new_mesh)
            inserted = True
        continue
    out.append(line)

if not inserted:
    raise SystemExit("ERROR: No &MESH line found in original FDS case.")

text = "\\n".join(out) + "\\n"

text, count = re.subn(
    r"&TIME\\s+T_END\\s*=\\s*[^/]+/",
    f"&TIME T_END={T_END} /",
    text,
    flags=re.IGNORECASE
)

if count == 0:
    text += f"\\n&TIME T_END={T_END} /\\n"

case.write_text(text)
EOF

    cd "$WORK"

    MESH_COUNT=$(grep -i "^[[:space:]]*&MESH" "$CASEFILE" | wc -l)

    echo "Layout: NX=$NX NY=$NY NZ=$NZ"
    echo "Meshes: $MESH_COUNT"
    grep -i "T_END" "$CASEFILE"

    if [ "$MESH_COUNT" -ne "$N" ]; then
        echo "ERROR: Expected $N meshes, found $MESH_COUNT"
        exit 4
    fi

    echo "Running N=$N, PPN=$PPN"

    START=$(date +%s)

    mpirun \
        --hostfile "$HOSTFILE" \
        --map-by ppr:${PPN}:node \
        --bind-to core \
        --mca btl self,tcp \
        --mca pml ob1 \
        -x OMPI_MCA_btl=self,tcp \
        -x OMPI_MCA_pml=ob1 \
        -np "$N" \
        apptainer exec \
            --bind "$WORK:$WORK" \
            --pwd "$WORK" \
            "$IMG" \
            bash -lc "
                export OMP_NUM_THREADS=1
                export OMP_PROC_BIND=close
                export OMPI_MCA_btl=self,tcp
                export OMPI_MCA_pml=ob1
                fds '$CASEFILE'
            " > "$RUN/logs/log.${N}proc" \
              2> "$RUN/logs/err.${N}proc"

    END=$(date +%s)
    ELAPSED=$((END - START))

    {
        echo ""
        echo "=============================="
        echo "Timing information"
        echo "N = $N"
        echo "Nodes = $SLURM_JOB_NUM_NODES"
        echo "Ranks per node = $PPN"
        echo "Total mesh = 80 x 80 x 80"
        echo "Mesh layout = $NX x $NY x $NZ"
        echo "T_END = $T_END_VALUE"
        echo "Start = $(date -d @$START)"
        echo "End   = $(date -d @$END)"
        echo "Elapsed wall time = ${ELAPSED} s"
        echo "=============================="
    } >> "$RUN/logs/log.${N}proc"

    grep -i "Time Step" "$RUN/logs/err.${N}proc" | tail -n 5 >> "$RUN/logs/log.${N}proc"

    echo "DONE N=$N"
done

echo "ALL DONE"
echo "Results stored in: $ROOT"
