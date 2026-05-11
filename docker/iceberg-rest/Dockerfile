ARG ICEBERG_REST_BASE_IMAGE=apache/iceberg-rest-fixture:1.10.1
FROM ${ICEBERG_REST_BASE_IMAGE}

ARG POSTGRES_JDBC_VERSION=42.7.7

USER root
RUN mkdir -p /usr/lib/iceberg-rest/lib
ADD https://repo1.maven.org/maven2/org/postgresql/postgresql/${POSTGRES_JDBC_VERSION}/postgresql-${POSTGRES_JDBC_VERSION}.jar /usr/lib/iceberg-rest/lib/postgresql.jar
RUN chmod 0644 /usr/lib/iceberg-rest/lib/postgresql.jar \
    && chown iceberg:iceberg /usr/lib/iceberg-rest/lib/postgresql.jar
USER iceberg

CMD ["java", "-cp", "iceberg-rest-adapter.jar:lib/*", "org.apache.iceberg.rest.RESTCatalogServer"]
