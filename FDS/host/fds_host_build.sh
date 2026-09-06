#!/bin/bash
#SBATCH --job-name=fds_host
#SBATCH --output=fds_host_%j.out
#SBATCH --error=fds_host_%j.err
#SBATCH --time=12:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --exclusive

set -euo pipefail

BASE_DIR="/beegfs/gopal/new/fds/host"
FDS_DIR="${BASE_DIR}/fds"
BIN_DIR="${BASE_DIR}/bin"
CONTAINER_IMAGE="/beegfs/gopal/new/fds/fds_image.sif"
FDS_REPOSITORY="https://github.com/firemodels/fds.git"
BUILD_DIR="${FDS_DIR}/Build/ompi_gnu_linux"
FDS_BUILD_BIN="${BUILD_DIR}/fds_ompi_gnu_linux"
FDS_HOST_BIN="${BIN_DIR}/fds"
NBUILD="${SLURM_CPUS_PER_TASK:-8}"
BUILD_LOG="${BASE_DIR}/fds_host_build.log"
VERIFY_LOG="${BASE_DIR}/fds_host_verify.log"
UCX_LOG="${BASE_DIR}/openmpi_ucx_info.log"

mkdir -p "$BASE_DIR" "$BIN_DIR"
rm -f "$BUILD_LOG" "$VERIFY_LOG" "$UCX_LOG"

for v in CC CXX FC F77 F90 FDS_HOME FDS_BIN OPAL_PREFIX OMPI_HOME MPI_HOME CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH; do
    unset "$v" || true
done

module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5
module load CMake

module list 2>&1 || true

for c in git make gcc g++ gfortran mpicc mpicxx mpifort mpirun ompi_info apptainer; do
    command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c unavailable"; exit 10; }
    echo "$c: $(command -v "$c")"
done

gcc --version | sed -n '1p'
gfortran --version | sed -n '1p'
mpirun --version

case "$(gcc -dumpfullversion)" in
    12.3.0*) ;;
    *) echo "ERROR: GCC 12.3.0 is not active"; exit 11 ;;
esac

case "$(mpirun --version | sed -n '1p')" in
    *4.1.5*) ;;
    *) echo "ERROR: OpenMPI 4.1.5 is not active"; exit 12 ;;
esac

MPI_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v mpirun)")")")"
case "$MPI_HOME" in
    /beegfs/Tools/*/OpenMPI/4.1.5-GCC-12.3.0) ;;
    *) echo "ERROR: Unexpected OpenMPI path: $MPI_HOME"; exit 13 ;;
esac

ompi_info --param pml ucx --level 9 >"$UCX_LOG" 2>&1 || true
cat "$UCX_LOG"
grep -q "MCA pml: ucx" "$UCX_LOG" || { echo "ERROR: UCX PML unavailable"; exit 14; }

ompi_info --param btl all --level 1 2>/dev/null | grep -E 'MCA btl: (self|vader|tcp|openib|uct)' || true
command -v ucx_info >/dev/null 2>&1 && ucx_info -v || true
command -v ibv_devinfo >/dev/null 2>&1 && ibv_devinfo -l || true

[[ -f "$CONTAINER_IMAGE" ]] || { echo "ERROR: Missing container: $CONTAINER_IMAGE"; exit 15; }

FDS_COMMIT="$(apptainer exec --bind /beegfs/Tools:/beegfs/Tools:ro "$CONTAINER_IMAGE" /bin/bash -lc 'if [[ -s /opt/fds/FDS_GIT_COMMIT.txt ]]; then cat /opt/fds/FDS_GIT_COMMIT.txt; else git -C /opt/fds rev-parse HEAD; fi' | tr -d '[:space:]')"
[[ "$FDS_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] || { echo "ERROR: Invalid FDS commit: $FDS_COMMIT"; exit 16; }
echo "Container FDS commit: $FDS_COMMIT"

rm -rf "$FDS_DIR"
git clone "$FDS_REPOSITORY" "$FDS_DIR"
git -C "$FDS_DIR" checkout --detach "$FDS_COMMIT"
HOST_COMMIT="$(git -C "$FDS_DIR" rev-parse HEAD)"
[[ "$HOST_COMMIT" == "$FDS_COMMIT" ]] || { echo "ERROR: Host/container commit mismatch"; exit 17; }

[[ -x "$BUILD_DIR/make_fds.sh" ]] || chmod +x "$BUILD_DIR/make_fds.sh"
[[ -f "$BUILD_DIR/make_fds.sh" ]] || { echo "ERROR: Missing $BUILD_DIR/make_fds.sh"; exit 18; }

cd "$BUILD_DIR"
rm -f "$FDS_BUILD_BIN"

export CC="$(command -v mpicc)"
export CXX="$(command -v mpicxx)"
export FC="$(command -v mpifort)"
export F77="$(command -v mpifort)"
export F90="$(command -v mpifort)"
export OMP_NUM_THREADS=1
export MAKEFLAGS="-j${NBUILD}"

set +e
set +o pipefail
./make_fds.sh 2>&1 | tee "$BUILD_LOG"
BUILD_RC="${PIPESTATUS[0]}"
set -o pipefail
set -e

if [[ "$BUILD_RC" -ne 0 ]]; then
    grep -nEi 'fatal error:|error:|undefined reference|cannot find -l|No rule to make target|Killed|No space left|permission denied|out of memory|make(\[[0-9]+\])?: \*\*\*' "$BUILD_LOG" | head -n 200 || true
    tail -n 400 "$BUILD_LOG" || true
    exit 30
fi

[[ -x "$FDS_BUILD_BIN" ]] || { echo "ERROR: Missing built executable: $FDS_BUILD_BIN"; exit 31; }
install -m 755 "$FDS_BUILD_BIN" "$FDS_HOST_BIN"

set +e
set +o pipefail
{
    echo "Host commit: $HOST_COMMIT"
    gcc --version | sed -n '1p'
    gfortran --version | sed -n '1p'
    mpirun --version | sed -n '1p'
    file "$FDS_HOST_BIN"
    ldd "$FDS_HOST_BIN"

    if ldd "$FDS_HOST_BIN" | grep -q "not found"; then
        echo "ERROR: unresolved libraries"
        exit 40
    fi

    MPI_LIBRARY="$(ldd "$FDS_HOST_BIN" | awk '/libmpi\.so/ {print $3; exit}')"
    echo "Resolved libmpi: ${MPI_LIBRARY:-not-found}"
    case "${MPI_LIBRARY:-}" in
        /beegfs/Tools/*/OpenMPI/4.1.5-GCC-12.3.0/*) ;;
        *) echo "ERROR: unexpected MPI library"; exit 41 ;;
    esac

    "$FDS_HOST_BIN" -v
    "$FDS_HOST_BIN" -v 2>&1 | grep -q "Open MPI v4.1.5" || { echo "ERROR: FDS does not report OpenMPI 4.1.5"; exit 42; }
    ompi_info --param pml ucx --level 1 | grep -q "MCA pml: ucx" || { echo "ERROR: UCX unavailable"; exit 43; }
    mpirun -np 1 "$FDS_HOST_BIN" -v
    echo "SUCCESS: FDS host verification completed"
} 2>&1 | tee "$VERIFY_LOG"
VERIFY_RC="${PIPESTATUS[0]}"
set -o pipefail
set -e
[[ "$VERIFY_RC" -eq 0 ]] || exit "$VERIFY_RC"

cat >"${BASE_DIR}/fds_host_env.sh" <<ENVEOF
#!/bin/bash
module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5
export FDS_HOME="${BASE_DIR}"
export FDS_BIN="${FDS_HOST_BIN}"
export PATH="${BIN_DIR}:\${PATH}"
export OMP_NUM_THREADS=1
ENVEOF
chmod 755 "${BASE_DIR}/fds_host_env.sh"

echo "============================================================"
echo "FDS HOST BUILD COMPLETED SUCCESSFULLY"
echo "FDS source:       $FDS_DIR"
echo "FDS commit:       $HOST_COMMIT"
echo "FDS executable:   $FDS_HOST_BIN"
echo "Environment file: ${BASE_DIR}/fds_host_env.sh"
echo "Build log:        $BUILD_LOG"
echo "Verify log:       $VERIFY_LOG"
echo "UCX log:          $UCX_LOG"
echo "============================================================"

