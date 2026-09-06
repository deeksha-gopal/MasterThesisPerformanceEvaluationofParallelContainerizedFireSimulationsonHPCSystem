# The below code represents the installation of basic host FDS

#!/bin/bash
#SBATCH --job-name=install_fds_host
#SBATCH --output=install_fds_host_%j.out
#SBATCH --error=install_fds_host_%j.err
#SBATCH --time=12:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --cpus-per-task=1

set -e
set -o pipefail

BASE_DIR="/beegfs/gopal/fds/host"
FDS_DIR="${BASE_DIR}/fds"
BUILD_DIR="${FDS_DIR}/Build/ompi_gnu_linux"

echo "==> Host: $(hostname)"
echo "==> Date: $(date)"
echo "==> Base dir: $BASE_DIR"

mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

# =========================
# MODULES (IMPORTANT)
# =========================
echo "==> Loading modules"
module purge

# ⚠️ USE SAME STACK AS PATO FOR FAIR COMPARISON
module load 2023a
module load GCC/12.3.0 OpenMPI/4.1.5 CMake

module list

# =========================
# CHECK COMPILER + MPI
# =========================
echo "==> Checking compilers"
which gcc
which gfortran
which mpirun

# =========================
# DOWNLOAD FDS
# =========================
if [ ! -d "$FDS_DIR" ]; then
    echo "==> Cloning FDS repository"
    git clone https://github.com/firemodels/fds.git
else
    echo "==> FDS already exists, skipping clone"
fi

# =========================
# BUILD FDS
# =========================
cd "$BUILD_DIR"

echo "==> Building FDS (MPI version)"
./make_fds.sh 2>&1 | tee build.log

# =========================
# VERIFY BUILD
# =========================
FDS_BIN="$BUILD_DIR/fds_ompi_gnu_linux"

if [ ! -x "$FDS_BIN" ]; then
    echo "ERROR: FDS build failed"
    exit 1
fi

echo "==> FDS built successfully"

# =========================
# CREATE SYMLINK (CLEAN USAGE)
# =========================
mkdir -p "$BASE_DIR/bin"
ln -sf "$FDS_BIN" "$BASE_DIR/bin/fds"

# =========================
# TEST EXECUTION
# =========================
echo "==> Testing FDS"
"$BASE_DIR/bin/fds" -v || true

echo "==> Finished at $(date)"
echo "==> FDS binary: $BASE_DIR/bin/fds"
