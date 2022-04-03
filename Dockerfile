#
# This is a multi-segmented image. It actually contains two images:
#
# wellbore-build-image  - there all airflow dependencies can be installed (and
#                        built - for those dependencies that require
#                        build essentials). Airflow is installed there with
#                        --user switch so that all the dependencies are
#                        installed to ${HOME}/.local
#
# main                 - this is the actual production image that is much
#                        smaller because it does not contain all the build
#                        essentials. Instead the ${HOME}/.local folder
#                        is copied from the build-image - this way we have
#                        only result of installation and we do not need
#                        all the build essentials. This makes the image
#                        much smaller.
#
# Change to match commit id of version to checkout of Git
ARG WELLBORE_COMMIT_ID="ed3ea06b79faba2017e6560edafd8b2441df1bd0"


ARG WELLBORE_HOME=/opt/wellbore
ARG WELLBORE_UID="1001"
ARG WELLBORE_GID="50000"

ARG CASS_DRIVER_BUILD_CONCURRENCY="8"

ARG PYTHON_BASE_IMAGE="quay.io/odippc64le/ubuntu2004-python38:latest"
ARG PYTHON_MAJOR_MINOR_VERSION="3.8"


##############################################################################################
# This is the build image where we build all dependencies
##############################################################################################
FROM ${PYTHON_BASE_IMAGE} as wellbore-build-image
SHELL ["/bin/bash", "-o", "pipefail", "-e", "-u", "-x", "-c"]

ARG PYTHON_BASE_IMAGE
ENV PYTHON_BASE_IMAGE=${PYTHON_BASE_IMAGE}

ARG PYTHON_MAJOR_MINOR_VERSION
ENV PYTHON_MAJOR_MINOR_VERSION=${PYTHON_MAJOR_MINOR_VERSION}

# Make sure noninteractive debian install is used and language variables set
ENV DEBIAN_FRONTEND=noninteractive LANGUAGE=C.UTF-8 LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    LC_CTYPE=C.UTF-8 LC_MESSAGES=C.UTF-8

ARG DEV_APT_DEPS="\
     apt-utils \
     build-essential \
     ca-certificates \
     curl \
     gnupg2 \
     cmake \
     rustc \
     cargo \
     pkg-config \
     git \
     gnupg \
     locales  \
     lsb-release \
     libssl-dev \
     bison \
     flex \
     ninja-build \
     libboost-all-dev \
     software-properties-common"

ENV DEV_APT_DEPS=${DEV_APT_DEPS}


# Install basic and additional apt dependencies
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         ${DEV_APT_DEPS} \
    && apt-get autoremove -yqq --purge \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*


# Install Apache Arrow C++ libs. Required to build pyarrow==4.0.1 dependency on POWER
RUN pip3 install --user numpy==1.21.1
RUN git clone --branch release-4.0.1 https://github.com/apache/arrow && cd arrow/cpp && mkdir release && cd release && cmake -DARROW_PYTHON=ON -DARROW_PARQUET=ON -DCMAKE_CXX_FLAGS='-fPIC -O3 -mcpu=power8' -DPARQUET_REQUIRE_ENCRYPTION=ON -GNinja .. && ninja install && rm -fr /arrow

ARG WELLBORE_COMMIT_ID
ENV WELLBORE_COMMIT_ID=${WELLBORE_COMMIT_ID}
RUN git clone https://community.opengroup.org/osdu/platform/domain-data-mgmt-services/wellbore/wellbore-domain-services.git src && cd src && git checkout $WELLBORE_COMMIT_ID
ENV PYARROW_WITH_PARQUET=1
RUN pip3 install --user pyarrow==4.0.1


ENV PATH=${PATH}:/root/.local/bin
RUN mkdir -p /root/.local/bin


# This is wellbore version that is put in the label of the image build
ENV WELLBORE_COMMIT_ID=${WELLBORE_COMMIT_ID}

RUN echo "Wellbore builder image COMMIT ID: $WELLBORE_COMMIT_ID"
WORKDIR /opt/wellbore

RUN pip install --user -r /src/requirements.txt

RUN find /root/.local/ -name '*.pyc' -print0 | xargs -0 rm -r || true ; \
    find /root/.local/ -type d -name '__pycache__' -print0 | xargs -0 rm -r || true

# make sure that all directories and files in .local are also group accessible
RUN find /root/.local -executable -print0 | xargs --null chmod g+x && \
    find /root/.local -print0 | xargs --null chmod g+rw

##############################################################################################
# This is the actual Wellbore image - much smaller than the build one. We copy
# installed packaged and all their dependencies from the build image to make it smaller.
##############################################################################################
FROM ${PYTHON_BASE_IMAGE} as main

SHELL ["/bin/bash", "-o", "pipefail", "-e", "-u", "-x", "-c"]

# Note depends on version pf pyarrow required by this version of the  code
ARG ARROW_SO_SUFFIX=400.1.0
ARG ARROW_SO_MAJOR=400
# Copy Apache Arrow C++ libs from  build image for the pyarrow==4.0.1 dependency
# Copying include files as well in case we want to debug the build
#------------------------------------------------------------------------------------------------
COPY --from=wellbore-build-image /usr/local/lib/lib*.a /usr/local/lib
COPY --from=wellbore-build-image /usr/local/lib/lib*.${ARROW_SO_SUFFIX} /usr/local/lib

RUN mkdir -p /usr/local/lib/cmake && mkdir -p /usr/local/include/arrow
COPY --from=wellbore-build-image /usr/local/lib/cmake/  /usr/local/lib/cmake/
COPY --from=wellbore-build-image /usr/local/include/arrow/  /usr/local/include/arrow/
COPY --from=wellbore-build-image /usr/local/include/parquet/  /usr/local/include/parquet/
#------------------------------------------------------------------------------------------------

RUN ln -s /usr/local/lib/libarrow_python.so.${ARROW_SO_SUFFIX} /usr/local/lib/libarrow_python.so.${ARROW_SO_MAJOR} && \
    ln -s /usr/local/lib/libarrow.so.${ARROW_SO_SUFFIX} /usr/local/lib/libarrow.so.${ARROW_SO_MAJOR} && \
    ln -s /usr/local/lib/libarrow_dataset.so.${ARROW_SO_SUFFIX} /usr/local/lib/libarrow_dataset.so.${ARROW_SO_MAJOR} && \
    ln -s /usr/local/lib/libparquet.so.${ARROW_SO_SUFFIX} /usr/local/lib/libparquet.so.${ARROW_SO_MAJOR}

RUN ln -s /usr/local/lib/libarrow_python.so.${ARROW_SO_MAJOR} /usr/local/lib/libarrow_python.so && \
    ln -s /usr/local/lib/libarrow.so.${ARROW_SO_MAJOR} /usr/local/lib/libarrow.so && \
    ln -s /usr/local/lib/libarrow_dataset.so.${ARROW_SO_MAJOR} /usr/local/lib/libarrow_dataset.so && \
    ln -s /usr/local/lib/libparquet.so.${ARROW_SO_MAJOR} /usr/local/lib/libparquet.so


ARG WELLBORE_UID
ARG WELLBORE_GID

ARG PYTHON_BASE_IMAGE
ENV PYTHON_BASE_IMAGE=${PYTHON_BASE_IMAGE}

ARG WELLBORE_COMMIT_ID
ENV WELLBORE_COMMIT_ID=${WELLBORE_COMMIT_ID}

RUN echo "Wellbore image COMMIT ID: $WELLBORE_COMMIT_ID"

# Make sure noninteractive debian install is used and language variables set
ENV DEBIAN_FRONTEND=noninteractive LANGUAGE=C.UTF-8 LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    LC_CTYPE=C.UTF-8 LC_MESSAGES=C.UTF-8


ARG RUNTIME_APT_DEPS="\
       apt-transport-https \
       apt-utils \
       ca-certificates \
       curl \
       locales  \
       lsb-release \
       netcat \
       openssh-client \
       sudo \
       uvicorn \
       wget"

ENV RUNTIME_APT_DEPS=${RUNTIME_APT_DEPS}


# Install basic and additional apt dependencies
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
           ${RUNTIME_APT_DEPS} \
    && apt-get autoremove -yqq --purge \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENV WELLBORE_UID=${WELLBORE_UID}
ENV WELLBORE_GID=${WELLBORE_GID}

ARG WELLBORE_HOME
ENV WELLBORE_HOME=${WELLBORE_HOME}


COPY  --from=wellbore-build-image /root/.local/lib/python3.8/site-packages/ /usr/local/lib/python3.8/dist-packages/
COPY  --from=wellbore-build-image /root/.local/bin "${WELLBORE_HOME}/bin"
COPY  --from=wellbore-build-image /src  "${WELLBORE_HOME}/src"

# Make Wellbore  files belong to the root group and are accessible. This is to accomodate the guidelines from
# OpenShift https://docs.openshift.com/enterprise/3.0/creating_images/guidelines.html
RUN chmod -R g=u ${WELLBORE_HOME}

# Make /etc/passwd root-group-writeable so that user can be dynamically added by OpenShift
# See https://github.com/apache/airflow/issues/9248
RUN chmod g=u /etc/passwd

ENV PATH="${WELLBORE_HOME}/bin:${PATH}"
ENV LD_LIBRARY_PATH="/usr/local/lib"

WORKDIR ${WELLBORE_HOME}/src

EXPOSE 8080

USER ${WELLBORE_UID}

CMD ["uvicorn", "app.wdms_app:base_app", "--host", "0.0.0.0", "--port", "8080"]
