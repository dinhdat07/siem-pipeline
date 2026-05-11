ARG FLINK_BASE_IMAGE=flink:1.19.2-scala_2.12-java17
FROM ${FLINK_BASE_IMAGE}

SHELL ["/bin/bash", "-c"]

ARG FLINK_SQL_KAFKA_CONNECTOR_VERSION=3.2.0-1.19
ARG ICEBERG_FLINK_RUNTIME_VERSION=1.19
ARG ICEBERG_VERSION=1.10.1
ARG HADOOP_VERSION=3.4.2

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

USER flink
WORKDIR /opt/flink

RUN mkdir -p ./lib/kafka ./lib/iceberg ./lib/hadoop \
    && curl -fLo ./lib/kafka/flink-sql-connector-kafka-${FLINK_SQL_KAFKA_CONNECTOR_VERSION}.jar \
      https://repo.maven.apache.org/maven2/org/apache/flink/flink-sql-connector-kafka/${FLINK_SQL_KAFKA_CONNECTOR_VERSION}/flink-sql-connector-kafka-${FLINK_SQL_KAFKA_CONNECTOR_VERSION}.jar \
    && curl -fLo ./lib/iceberg/iceberg-flink-runtime-${ICEBERG_FLINK_RUNTIME_VERSION}-${ICEBERG_VERSION}.jar \
      https://repo.maven.apache.org/maven2/org/apache/iceberg/iceberg-flink-runtime-${ICEBERG_FLINK_RUNTIME_VERSION}/${ICEBERG_VERSION}/iceberg-flink-runtime-${ICEBERG_FLINK_RUNTIME_VERSION}-${ICEBERG_VERSION}.jar \
    && curl -fLo ./lib/iceberg/iceberg-aws-bundle-${ICEBERG_VERSION}.jar \
      https://repo.maven.apache.org/maven2/org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar \
    && curl -fLo ./lib/hadoop/hadoop-client-api-${HADOOP_VERSION}.jar \
      https://repo.maven.apache.org/maven2/org/apache/hadoop/hadoop-client-api/${HADOOP_VERSION}/hadoop-client-api-${HADOOP_VERSION}.jar \
    && curl -fLo ./lib/hadoop/hadoop-client-runtime-${HADOOP_VERSION}.jar \
      https://repo.maven.apache.org/maven2/org/apache/hadoop/hadoop-client-runtime/${HADOOP_VERSION}/hadoop-client-runtime-${HADOOP_VERSION}.jar \
    && mkdir -p ./plugins/flink-s3-fs-hadoop \
    && cp ./opt/flink-s3-fs-hadoop-*.jar ./plugins/flink-s3-fs-hadoop/
