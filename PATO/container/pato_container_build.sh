#!/bin/bash
#SBATCH --job-name=pato_build
#SBATCH --output=pato_build_%j.out
#SBATCH --error=pato_build_%j.err
#SBATCH --time=48:00:00
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --exclusive

set -euo pipefail

module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5
module load CMake

# Paths
BASE_DIR="/beegfs/gopal/new/pato"
DEF_FILE="${BASE_DIR}/pato_build.def"
IMAGE="${BASE_DIR}/pato_image.sif"
ENV_FILE="${BASE_DIR}/host_mpi_env.sh"
UCX_INFO_FILE="${BASE_DIR}/host_openmpi_ucx.txt"

cd "$BASE_DIR"

# Job information
echo "============================================================"
echo "PATO-3.1 container build"
echo "============================================================"
echo "Node:       $(hostname)"
echo "Job ID:     ${SLURM_JOB_ID:-not-set}"
echo "Date:       $(date)"
echo "CPUs:       ${SLURM_CPUS_PER_TASK:-not-set}"
echo "Directory:  $BASE_DIR"
echo "Definition: $DEF_FILE"
echo "Image:      $IMAGE"
echo "============================================================"

# Validate required input
if [[ ! -f "$DEF_FILE" ]]; then
    echo "ERROR: Definition file not found:"
    echo "$DEF_FILE"
    exit 1
fi

# Clear inherited OpenFOAM and PATO variables
echo "==> Clearing previously loaded OpenFOAM/PATO variables"

unset FOAM_INST_DIR || true
unset WM_PROJECT_INST_DIR || true
unset WM_PROJECT_DIR || true
unset WM_THIRD_PARTY_DIR || true
unset WM_PROJECT_VERSION || true
unset WM_OPTIONS || true
unset WM_COMPILER || true
unset WM_COMPILER_TYPE || true
unset WM_MPLIB || true
unset FOAM_MPI || true
unset FOAM_APPBIN || true
unset FOAM_LIBBIN || true
unset FOAM_USER_LIBBIN || true
unset PATO_DIR || true
unset PATO_BIN || true

# Load host compiler and MPI modules
echo "==> Loading cluster GCC and OpenMPI modules"

module purge
module load 2023a
module load GCC/12.3.0
module load OpenMPI/4.1.5
module load CMake

echo
echo "Loaded modules:"
module list 2>&1 || true

echo
echo "gcc:"
command -v gcc
gcc --version | sed -n '1p'

echo
echo "g++:"
command -v g++
g++ --version | sed -n '1p'

echo
echo "gfortran:"
command -v gfortran
gfortran --version | sed -n '1p'

echo
echo "mpicc:"
command -v mpicc
mpicc --version | sed -n '1p'

echo
echo "mpicxx:"
command -v mpicxx
mpicxx --version | sed -n '1p'

echo
echo "mpirun:"
command -v mpirun
mpirun --version

# Verify OpenMPI version and installation
MPI_VERSION="$(mpirun --version | sed -n '1p')"

if [[ "$MPI_VERSION" != *"4.1.5"* ]]; then
    echo "ERROR: Expected OpenMPI 4.1.5."
    echo "Detected: $MPI_VERSION"
    exit 10
fi

MPI_HOME="$(dirname "$(dirname "$(command -v mpirun)")")"

echo
echo "Detected MPI_HOME:"
echo "$MPI_HOME"
echo

case "$MPI_HOME" in
    /beegfs/Tools/*OpenMPI/4.1.5-GCC-12.3.0)
        echo "SUCCESS: Expected host OpenMPI installation detected."
        ;;
    *)
        echo "ERROR: Unexpected OpenMPI installation:"
        echo "$MPI_HOME"
        exit 11
        ;;
esac

# Check host OpenMPI UCX support
echo "==> Checking host OpenMPI UCX support"

ompi_info --param pml ucx --level 1 \
    > "$UCX_INFO_FILE" 2>&1 || true

cat "$UCX_INFO_FILE"

if ! grep -q "MCA pml: ucx" "$UCX_INFO_FILE"; then
    echo "ERROR: OpenMPI UCX PML component is unavailable."
    exit 12
fi

echo "SUCCESS: Host OpenMPI UCX PML component is available."

# Generate host EasyBuild environment file
echo "==> Generating host EasyBuild environment"

clean_beegfs_paths()
{
    local value="${1:-}"

    if [[ -z "$value" ]]; then
        return 0
    fi

    printf '%s\n' "$value" |
        tr ':' '\n' |
        awk '
            /^\/beegfs\/Tools\// {
                if (!seen[$0]++) {
                    print $0
                }
            }
        ' |
        paste -sd ':' -
}

{
    echo '#!/bin/bash'
    echo
    echo '# Generated automatically by pato_build.sh.'
    echo '# /beegfs/Tools must be bound at build and runtime.'
    echo

    printf 'export MPI_HOME=%q\n' "$MPI_HOME"

    CLEAN_PATH="$(clean_beegfs_paths "${PATH:-}")"
    CLEAN_LD_LIBRARY_PATH="$(
        clean_beegfs_paths "${LD_LIBRARY_PATH:-}"
    )"
    CLEAN_LIBRARY_PATH="$(
        clean_beegfs_paths "${LIBRARY_PATH:-}"
    )"
    CLEAN_CPATH="$(
        clean_beegfs_paths "${CPATH:-}"
    )"
    CLEAN_C_INCLUDE_PATH="$(
        clean_beegfs_paths "${C_INCLUDE_PATH:-}"
    )"
    CLEAN_CPLUS_INCLUDE_PATH="$(
        clean_beegfs_paths "${CPLUS_INCLUDE_PATH:-}"
    )"
    CLEAN_PKG_CONFIG_PATH="$(
        clean_beegfs_paths "${PKG_CONFIG_PATH:-}"
    )"
    CLEAN_CMAKE_PREFIX_PATH="$(
        clean_beegfs_paths "${CMAKE_PREFIX_PATH:-}"
    )"

    if [[ -n "$CLEAN_PATH" ]]; then
        printf \
            'export PATH=%q:${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}\n' \
            "$CLEAN_PATH"
    else
        echo \
            'export PATH="${MPI_HOME}/bin:${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"'
    fi

    if [[ -n "$CLEAN_LD_LIBRARY_PATH" ]]; then
        printf \
            'export LD_LIBRARY_PATH=%q:${LD_LIBRARY_PATH:-}\n' \
            "$CLEAN_LD_LIBRARY_PATH"
    else
        echo \
            'export LD_LIBRARY_PATH="${MPI_HOME}/lib:${LD_LIBRARY_PATH:-}"'
    fi

    if [[ -n "$CLEAN_LIBRARY_PATH" ]]; then
        printf \
            'export LIBRARY_PATH=%q:${LIBRARY_PATH:-}\n' \
            "$CLEAN_LIBRARY_PATH"
    fi

    if [[ -n "$CLEAN_CPATH" ]]; then
        printf \
            'export CPATH=%q:${CPATH:-}\n' \
            "$CLEAN_CPATH"
    fi

    if [[ -n "$CLEAN_C_INCLUDE_PATH" ]]; then
        printf \
            'export C_INCLUDE_PATH=%q:${C_INCLUDE_PATH:-}\n' \
            "$CLEAN_C_INCLUDE_PATH"
    fi

    if [[ -n "$CLEAN_CPLUS_INCLUDE_PATH" ]]; then
        printf \
            'export CPLUS_INCLUDE_PATH=%q:${CPLUS_INCLUDE_PATH:-}\n' \
            "$CLEAN_CPLUS_INCLUDE_PATH"
    fi

    if [[ -n "$CLEAN_PKG_CONFIG_PATH" ]]; then
        printf \
            'export PKG_CONFIG_PATH=%q:${PKG_CONFIG_PATH:-}\n' \
            "$CLEAN_PKG_CONFIG_PATH"
    fi

    if [[ -n "$CLEAN_CMAKE_PREFIX_PATH" ]]; then
        printf \
            'export CMAKE_PREFIX_PATH=%q:${CMAKE_PREFIX_PATH:-}\n' \
            "$CLEAN_CMAKE_PREFIX_PATH"
    fi

} > "$ENV_FILE"

chmod 644 "$ENV_FILE"

echo
echo "Generated host environment:"
cat "$ENV_FILE"
echo

# Validate generated environment file
if [[ ! -s "$ENV_FILE" ]]; then
    echo "ERROR: host_mpi_env.sh was not generated."
    exit 13
fi

if grep -E \
    '/beegfs/gopal|OpenFOAM-7|ThirdParty-7|pato-3.1' \
    "$ENV_FILE"
then
    echo "ERROR: Application-specific paths entered host_mpi_env.sh."
    exit 14
fi

if ! grep -q \
    'OpenMPI/4.1.5-GCC-12.3.0' \
    "$ENV_FILE"
then
    echo "ERROR: OpenMPI 4.1.5 is missing from host_mpi_env.sh."
    exit 15
fi

echo "==> EasyBuild MPI-related paths captured"

grep -Ei \
    'OpenMPI|UCX|UCC|PMIx|hwloc|libfabric|libevent|numactl' \
    "$ENV_FILE" || true

# Build container
echo "==> Removing previous PATO image"

rm -f "$IMAGE"

echo "==> Starting Apptainer build"

export APPTAINER_BUILD_CPUS="${SLURM_CPUS_PER_TASK:-16}"

set +e

apptainer build \
    --force \
    --bind /beegfs/Tools:/beegfs/Tools:ro \
    "$IMAGE" \
    "$DEF_FILE"

BUILD_RC=$?

set -e

if [[ "$BUILD_RC" -ne 0 ]]; then
    echo
    echo "============================================================"
    echo "ERROR: Apptainer build failed"
    echo "Exit code: $BUILD_RC"
    echo "============================================================"
    exit "$BUILD_RC"
fi

# Verify generated image exists
echo
echo "============================================================"
echo "Verifying completed PATO image"
echo "============================================================"

if [[ ! -f "$IMAGE" ]]; then
    echo "ERROR: PATO image was not created:"
    echo "$IMAGE"
    exit 20
fi

if [[ ! -s "$IMAGE" ]]; then
    echo "ERROR: PATO image exists but is empty:"
    echo "$IMAGE"
    exit 21
fi

echo
echo "Image:"
ls -lh "$IMAGE"
echo

# Verify software inside container
echo "Running container verification"

set +e

apptainer exec \
    --cleanenv \
    --bind /beegfs/Tools:/beegfs/Tools:ro \
    "$IMAGE" \
    /bin/bash -lc '
        set -e

        # Load host EasyBuild environment
        if [[ ! -f /opt/host_mpi_env.sh ]]; then
            echo "ERROR: host MPI environment file is unavailable."
            exit 1
        fi

        . /opt/host_mpi_env.sh

        # Define OpenFOAM and PATO environment
        export FOAM_INST_DIR=/opt/OpenFOAM
        export WM_PROJECT_INST_DIR=/opt/OpenFOAM
        export WM_PROJECT_DIR=/opt/OpenFOAM/OpenFOAM-7
        export WM_THIRD_PARTY_DIR=/opt/OpenFOAM/ThirdParty-7

        export WM_COMPILER_TYPE=system
        export WM_COMPILER=Gcc
        export WM_MPLIB=SYSTEMOPENMPI
        export WM_PRECISION_OPTION=DP
        export WM_LABEL_SIZE=32
        export WM_COMPILE_OPTION=Opt

        export PATO_DIR=/opt/pato-3.1
        export PATO_BIN=/opt/pato-3.1/install/bin/PATOx

        # Source OpenFOAM and PATO safely
        set +e
        set +u
        set +o pipefail

        . "$WM_PROJECT_DIR/etc/bashrc"
        . "$PATO_DIR/bashrc"

        # Re-enable strict shell handling after the environment scripts.
        set -e
        set -u
        set -o pipefail

        # Reassert required configuration
        export WM_COMPILER_TYPE=system
        export WM_COMPILER=Gcc
        export WM_MPLIB=SYSTEMOPENMPI
        export WM_PRECISION_OPTION=DP
        export WM_LABEL_SIZE=32
        export WM_COMPILE_OPTION=Opt

        # Verify OpenFOAM environment
        if [[ -z "${WM_OPTIONS:-}" ]]; then
            echo "ERROR: OpenFOAM environment was not initialized."
            exit 35
        fi

        if [[ -z "${FOAM_APPBIN:-}" ]]; then
            echo "ERROR: FOAM_APPBIN was not initialized."
            exit 36
        fi

        if [[ -z "${FOAM_LIBBIN:-}" ]]; then
            echo "ERROR: FOAM_LIBBIN was not initialized."
            exit 37
        fi

        # Verify compiler
        echo
        echo "Compiler:"

        if ! command -v gcc >/dev/null 2>&1; then
            echo "ERROR: gcc is unavailable."
            exit 38
        fi

        command -v gcc
        gcc --version | sed -n "1p"
        
        # Verify MPI compiler
        echo
        echo "MPI compiler:"

        if ! command -v mpicc >/dev/null 2>&1; then
            echo "ERROR: mpicc is unavailable."
            exit 39
        fi

        command -v mpicc
        mpicc --version | sed -n "1p"
        
        # Verify MPI launcher
        echo
        echo "MPI launcher:"

        if ! command -v mpirun >/dev/null 2>&1; then
            echo "ERROR: mpirun is unavailable."
            exit 40
        fi

        command -v mpirun
        mpirun --version

        MPI_VERSION="$(mpirun --version | sed -n "1p")"

        if [[ "$MPI_VERSION" != *"4.1.5"* ]]; then
            echo "ERROR: Expected OpenMPI 4.1.5 inside container."
            echo "Detected: $MPI_VERSION"
            exit 41
        fi
        
        # Verify UCX
        echo
        echo "UCX component:"

        ompi_info --param pml ucx --level 1 \
            > /tmp/container_ucx_check.txt 2>&1 || true

        cat /tmp/container_ucx_check.txt

        if ! grep -q \
            "MCA pml: ucx" \
            /tmp/container_ucx_check.txt
        then
            echo "ERROR: UCX PML is unavailable inside the image."
            exit 42
        fi

        # Verify OpenFOAM executables
        echo
        echo "OpenFOAM executables:"

        for foam_command in \
            blockMesh \
            decomposePar \
            reconstructPar
        do
            if ! command -v "$foam_command" >/dev/null 2>&1; then
                echo "ERROR: $foam_command is unavailable."
                exit 43
            fi

            echo "$foam_command: $(command -v "$foam_command")"
        done

        # Locate PATO solver
        PATO_BIN=""

        if command -v PATOx >/dev/null 2>&1; then
            PATO_BIN="$(command -v PATOx)"
        elif [[ -x /opt/pato-3.1/install/bin/PATOx ]]; then
            PATO_BIN=/opt/pato-3.1/install/bin/PATOx
        fi

        if [[ -z "$PATO_BIN" ]] || [[ ! -x "$PATO_BIN" ]]; then
            echo "ERROR: PATOx was not found."
            exit 44
        fi

        echo
        echo "PATO solver:"
        echo "$PATO_BIN"

        # Check PATO dependencies
        echo
        echo "PATOx library dependencies:"

        ldd "$PATO_BIN"

        if ldd "$PATO_BIN" | grep -q "not found"; then
            echo "ERROR: PATOx has unresolved libraries."
            ldd "$PATO_BIN" | grep "not found" || true
            exit 45
        fi

        echo
        echo "MPI-related PATO libraries:"

        ldd "$PATO_BIN" |
            grep -E \
            "libmpi|libopen-rte|libopen-pal|libpmix|libucp|libucs|libuct|libucm|libibverbs|librdmacm|libhwloc" \
            || true

        # Identify linked MPI library
        MPI_LIBRARY="$(
            ldd "$PATO_BIN" |
            awk "
                /libmpi\\.so/ {
                    if (!found) {
                        print \$3
                        found=1
                    }
                }
            "
        )"

        # Fall back to OpenFOAM Pstream if necessary
        if [[ -z "$MPI_LIBRARY" ]]; then
            PSTREAM_LIBRARY="$(
                find "$FOAM_LIBBIN" \
                    -type f \
                    \( \
                        -name "libPstream.so" \
                        -o -name "libPstream*.so" \
                    \) \
                    -print \
                    -quit
            )"

            if [[ -n "$PSTREAM_LIBRARY" ]]; then
                echo
                echo "Checking Pstream library:"
                echo "$PSTREAM_LIBRARY"

                MPI_LIBRARY="$(
                    ldd "$PSTREAM_LIBRARY" |
                    awk "
                        /libmpi\\.so/ {
                            if (!found) {
                                print \$3
                                found=1
                            }
                        }
                    "
                )"
            fi
        fi

        echo
        echo "Resolved libmpi:"
        echo "${MPI_LIBRARY:-not-found}"

        case "${MPI_LIBRARY:-}" in
            /beegfs/Tools/*OpenMPI/4.1.5-GCC-12.3.0/*)
                echo "SUCCESS: PATO uses host OpenMPI 4.1.5."
                ;;
            "")
                echo "ERROR: Could not identify the OpenMPI library."
                exit 46
                ;;
            *)
                echo "ERROR: Unexpected OpenMPI library:"
                echo "$MPI_LIBRARY"
                exit 47
                ;;
        esac

        # Final container verification
        echo
        echo "============================================================"
        echo "Container verification completed successfully"
        echo "============================================================"

        exit 0
    '

VERIFY_RC=$?

set -e

# Check container verification result
if [[ "$VERIFY_RC" -ne 0 ]]; then
    echo
    echo "============================================================"
    echo "ERROR: Container verification failed"
    echo "Verification exit code: $VERIFY_RC"
    echo "============================================================"
    exit "$VERIFY_RC"
fi

# Final success report
echo
echo "============================================================"
echo "PATO CONTAINER BUILD COMPLETED SUCCESSFULLY"
echo "============================================================"
echo "Finished: $(date)"
echo
echo "Image:"
echo "$IMAGE"
echo
echo "Required runtime bind:"
echo "--bind /beegfs/Tools:/beegfs/Tools:ro"
echo

exit 0
