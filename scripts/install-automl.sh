#!/bin/sh
# Install the IntegratedML AutoML provider into a RUNNING container.
#
# The Dockerfile installs AutoML into /usr/irissys/mgr/python, but this project
# runs with durable %SYS (ISC_DATA_DIRECTORY=/opt/irisbuild/data), so the live
# mgr is /opt/irisbuild/data/mgr on the iris-data volume. A container whose
# volume already exists therefore does NOT get the image's copy, and TRAIN MODEL
# fails with:
#   <PYTHON EXCEPTION> FileNotFoundError: [Errno 2] No such file or directory:
#   '/opt/irisbuild/data/mgr/python/iris_automl/Classifiers/'
#
# Run this once against such a container. Safe to re-run.
#
#   sh scripts/install-automl.sh [container]

set -e
C="${1:-dataintegrator-iris-1}"
SRC=/usr/irissys/mgr/python
DST=/opt/irisbuild/data/mgr/python

# pandas is pinned <3 deliberately. AutoML 1.0.3 uses APIs pandas 3.x removed,
# and time-series training breaks on it - so an unpinned install resolves a
# newer pandas at some future date and the ML tab stops working with no change
# to this project. Same pin as src-iris/Dockerfile; change both together.
echo "== ensuring AutoML is present in the image tree ($SRC)"
docker exec -u root "$C" sh -c "
  [ -d $SRC/iris_automl ] || /usr/irissys/bin/irispython -m pip install \
      --index-url https://registry.intersystems.com/pypi/simple --no-cache-dir \
      --target $SRC 'pandas<3' intersystems-iris-automl"

echo "== copying into the durable mgr ($DST)"
docker exec -u root "$C" sh -c "
  mkdir -p $DST && cp -a $SRC/. $DST/ && chown -R irisowner:irisowner $DST"

echo "== verifying"
docker exec "$C" sh -c "test -d $DST/iris_automl/Classifiers" \
  && echo 'OK: iris_automl/Classifiers present' \
  || { echo 'FAILED: Classifiers missing'; exit 1; }
