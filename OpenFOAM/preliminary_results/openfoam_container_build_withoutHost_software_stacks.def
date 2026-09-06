# This code is to build basic Openfoam-V2406 Apptainer container without including host modules of OpenMPI and GCC and 
# using Bootstrap=Docker and Ubuntu image

BootStrap: docker
From: ubuntu:22.04

%environment
    export WM_PROJECT_DIR=/opt/OpenFOAM/OpenFOAM-v2406
    export WM_THIRD_PARTY_DIR=/opt/OpenFOAM/ThirdParty-v2406
    export FOAM_INST_DIR=/opt/OpenFOAM
    export PATH=$WM_PROJECT_DIR/bin:$WM_PROJECT_DIR/platforms/linux64GccDPInt32Opt/bin:$PATH
    export LD_LIBRARY_PATH=$WM_PROJECT_DIR/platforms/linux64GccDPInt32Opt/lib:$LD_LIBRARY_PATH

%post
    set -e
    export DEBIAN_FRONTEND=noninteractive

    echo "Updating and installing necessary packages"
    apt-get update && apt-get install -y \
        build-essential \
        cmake \
        flex \
        bison \
        zlib1g-dev \
        libopenmpi-dev \
        openmpi-bin \
        wget \
        curl \
        tzdata \
        bash \
        ca-certificates \
        git \
        file

    echo "Setting timezone to Europe/London"
    ln -fs /usr/share/zoneinfo/Europe/London /etc/localtime
    dpkg-reconfigure --frontend noninteractive tzdata

    mkdir -p /opt/OpenFOAM
    cd /opt/OpenFOAM

    echo "Downloading OpenFOAM-v2406"
    wget -L https://sourceforge.net/projects/openfoam/files/v2406/OpenFOAM-v2406.tgz
    tar -xzf OpenFOAM-v2406.tgz
    rm -f OpenFOAM-v2406.tgz

    cd /opt/OpenFOAM/OpenFOAM-v2406

    echo "Building OpenFOAM-v2406"
    /bin/bash -lc '
        export WM_PROJECT_DIR=/opt/OpenFOAM/OpenFOAM-v2406
        export WM_THIRD_PARTY_DIR=/opt/OpenFOAM/ThirdParty-v2406
        export FOAM_INST_DIR=/opt/OpenFOAM
        source /opt/OpenFOAM/OpenFOAM-v2406/etc/bashrc
        ./Allwmake -j8 > /tmp/openfoam_build.log 2>&1
    '

    echo "Checking build outputs"
    /bin/bash -lc '
        source /opt/OpenFOAM/OpenFOAM-v2406/etc/bashrc
        command -v blockMesh
        command -v decomposePar
        command -v fireFoam
    '

    apt-get clean
    rm -rf /var/lib/apt/lists/*

%runscript
    export WM_PROJECT_DIR=/opt/OpenFOAM/OpenFOAM-v2406
    export WM_THIRD_PARTY_DIR=/opt/OpenFOAM/ThirdParty-v2406
    export FOAM_INST_DIR=/opt/OpenFOAM
    source /opt/OpenFOAM/OpenFOAM-v2406/etc/bashrc
    exec "$@"
