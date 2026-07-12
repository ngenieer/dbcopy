FROM postgres:16

RUN apt-get update \
 && apt-get install -y --no-install-recommends default-mysql-client \
 && rm -rf /var/lib/apt/lists/*

# The test servers use auto-generated self-signed certs the MariaDB 11.8
# client refuses to trust (and its verification behavior is inconsistent
# between invocations). TLS is a client-config concern, not dbcopy's — so
# the test environment declares plain TCP here.
RUN printf '[client]\nskip-ssl\n' > /etc/mysql/conf.d/skip-ssl.cnf

ENTRYPOINT []
CMD ["bash"]
