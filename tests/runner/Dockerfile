FROM postgres:16

RUN apt-get update \
 && apt-get install -y --no-install-recommends default-mysql-client sqlite3 \
      curl ca-certificates unzip libaio1t64 \
 && rm -rf /var/lib/apt/lists/*

# Oracle Instant Client (basiclite + sqlplus + tools for expdp/impdp).
# The instantclient binaries link against libaio.so.1; trixie ships the
# t64 variant, hence the symlink.
RUN cd /opt \
 && curl -fsSLo bl.zip https://download.oracle.com/otn_software/linux/instantclient/instantclient-basiclite-linuxx64.zip \
 && curl -fsSLo sp.zip https://download.oracle.com/otn_software/linux/instantclient/instantclient-sqlplus-linuxx64.zip \
 && curl -fsSLo tl.zip https://download.oracle.com/otn_software/linux/instantclient/instantclient-tools-linuxx64.zip \
 && unzip -qo bl.zip && unzip -qo sp.zip && unzip -qo tl.zip && rm -f bl.zip sp.zip tl.zip \
 && ln -s /opt/instantclient_* /opt/instantclient \
 && ln -s /usr/lib/x86_64-linux-gnu/libaio.so.1t64 /usr/lib/x86_64-linux-gnu/libaio.so.1

ENV LD_LIBRARY_PATH=/opt/instantclient
ENV PATH=$PATH:/opt/instantclient

# The test servers use auto-generated self-signed certs the MariaDB 11.8
# client refuses to trust (and its verification behavior is inconsistent
# between invocations). TLS is a client-config concern, not dbcopy's — so
# the test environment declares plain TCP here.
RUN printf '[client]\nskip-ssl\n' > /etc/mysql/conf.d/skip-ssl.cnf

ENTRYPOINT []
CMD ["bash"]
