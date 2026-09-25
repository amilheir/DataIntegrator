ARG IRIS_IMAGE
FROM ${IRIS_IMAGE}

# ODBC SQL Gateway support: unixODBC + the PostgreSQL driver, plus a pre-wired
# DSN (pg_crm_odbc) so the ODBC connection to the demo Postgres survives a
# container recreate. IRIS's iODBC reads $ODBCINI (set in docker-compose).
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends unixodbc odbc-postgresql \
 && rm -rf /var/lib/apt/lists/* \
 && printf '%s\n' '[PostgreSQL ANSI]' 'Description=psqlODBC ANSI' \
      'Driver=/usr/lib/x86_64-linux-gnu/odbc/psqlodbca.so' \
      'Setup=/usr/lib/x86_64-linux-gnu/odbc/psqlodbca.so' > /etc/odbcinst.ini \
 && printf '%s\n' '[ODBC Data Sources]' 'pg_crm_odbc = PostgreSQL ANSI' '' '[pg_crm_odbc]' \
      'Driver=/usr/lib/x86_64-linux-gnu/odbc/psqlodbca.so' \
      'Description=Postgres CRM (psqlODBC ANSI)' \
      'Servername=postgres' 'Server=postgres' 'Port=5432' 'Database=crm' \
      'UID=crm' 'Password=crm' 'UseDeclareFetch=1' > /etc/odbc.ini \
 && sed -i 's/Password *= *the_password/Password = SYS/g' /usr/irissys/mgr/irisodbc.ini
USER ${ISC_PACKAGE_MGRUSER}

# Enterprise AI build is licensed — the key must be in mgr/ before first start
# (durable %SYS copies it into ${ISC_DATA_DIRECTORY}/mgr on first init).
#
# NOTE on which key: an "all non-container" key (the AI Hub EAP key ships as
# one) is rejected by IRIS in Docker with "license file invalid for this
# platform", and every REST/dispatch web app then answers 503. It must be a
# Container(Ubuntu-x64) key.
#
# The key arrives as a BUILD SECRET, not a COPY (IMPROVEMENTS_SPEC SG-2): the
# file lives outside the project tree at ${IRIS_KEY_PATH}, so no credential
# material sits in a directory that could be screen-shared. Secret mounts are
# root-owned and never land in an image layer, hence the copy + chown here.
USER root
RUN --mount=type=secret,id=iris_key \
    cp /run/secrets/iris_key /usr/irissys/mgr/iris.key \
 && chown "${ISC_PACKAGE_MGRUSER}:${ISC_PACKAGE_IRISGROUP}" /usr/irissys/mgr/iris.key \
 && chmod 640 /usr/irissys/mgr/iris.key
USER ${ISC_PACKAGE_MGRUSER}

COPY --chown="${ISC_PACKAGE_MGRUSER}:${ISC_PACKAGE_IRISGROUP}" ./src-iris /opt/irisbuild

WORKDIR /opt/irisbuild
USER irisowner

# The durable-%SYS mount point must exist in the image, owned by irisowner. A
# new named volume copies the ownership of the directory it mounts over; with
# no directory there (src-iris/data is dockerignored) it comes up root-owned
# and the durable-data init aborts on a fresh `docker compose up`.
RUN mkdir -p /opt/irisbuild/data


# IntegratedML AutoML provider. Without it CREATE MODEL succeeds but TRAIN MODEL
# fails with "%ML Provider 'AutoML' is not available on this instance" — the
# framework ships in this image, the provider does not.
#
# Three details that are easy to get wrong:
#  1. It is NOT on PyPI. It comes from registry.intersystems.com, package
#     intersystems-iris-automl (module iris_automl; %ML.AutoML.Provider maps its
#     probe names automl/automlts onto iris_automl.automl/.automlts).
#  2. It must land in <instance>/mgr/python, which is on embedded Python's path.
#  3. Root owns /usr/irissys, so the install needs root and the tree must then be
#     handed back to irisowner or the IRIS process cannot read it.
#
# NOTE for existing deployments: with durable %SYS (ISC_DATA_DIRECTORY) the live
# mgr is /opt/irisbuild/data/mgr, so a container whose iris-data volume already
# exists does NOT pick this up from the image — AutoML then fails with
# FileNotFoundError on .../data/mgr/python/iris_automl/Classifiers/. Copy it in
# once with scripts/install-automl.sh.
USER root
#  4. pandas is pinned <3 DELIBERATELY. AutoML 1.0.3 uses APIs pandas 3.x
#     removed, and time-series training breaks on it. Unpinned, a rebuild
#     silently resolves a newer pandas at some future date and the ML tab stops
#     working with no change to this project. scripts/install-automl.sh carries
#     the same pin - change both together.
RUN /usr/irissys/bin/irispython -m pip install \
      --index-url https://registry.intersystems.com/pypi/simple --no-cache-dir \
      --target /usr/irissys/mgr/python "pandas<3" intersystems-iris-automl \
 && chown -R "${ISC_PACKAGE_MGRUSER}:${ISC_PACKAGE_IRISGROUP}" /usr/irissys/mgr/python
USER irisowner

RUN --mount=type=bind,src=./src-iris,dst=/opt/irisbuild \
    iris start IRIS \
    && iris session IRIS < /opt/irisbuild/iris.script \
    && iris stop IRIS quietly

# NOTE: changePassword.sh is skipped — the AI Hub EAP community build has no
# CSP binaries (/usr/irissys/bin/CSPpwd missing) and the script fails on
# ChangeGatewayMgrPassword. Dev image only; passwords are unexpired via
# iris.script + cpfmerge.cpf, and HTTP is served by the webgateway container.

# openpyxl: embedded-Python .xlsx -> .csv conversion for the File bulk-load source
# psycopg2-binary: the SampleDataOperation business operation writes its
# generated rows straight into the demo Postgres from embedded Python
# No `|| retry` fallback here: an OR-fallback made a failed install look
# like a successful build, and psycopg2 went missing at runtime while the
# image stayed green. Import-check instead so the build fails loudly.
RUN pip3 install --user --break-system-packages openpyxl psycopg2-binary \
 && python3 -c "import openpyxl, psycopg2"