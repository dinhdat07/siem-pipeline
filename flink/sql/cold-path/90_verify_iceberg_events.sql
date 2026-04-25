CREATE CATALOG `${ICEBERG_CATALOG_NAME}` WITH (
  'type' = 'iceberg',
  'catalog-impl' = 'org.apache.iceberg.rest.RESTCatalog',
  'uri' = '${ICEBERG_REST_URI_INTERNAL}',
  'warehouse' = '${ICEBERG_WAREHOUSE}',
  'io-impl' = 'org.apache.iceberg.aws.s3.S3FileIO',
  's3.endpoint' = '${S3_ENDPOINT_INTERNAL}',
  's3.path-style-access' = 'true',
  's3.access-key-id' = '${MINIO_ROOT_USER}',
  's3.secret-access-key' = '${MINIO_ROOT_PASSWORD}'
);

SET 'execution.runtime-mode' = 'batch';
SET 'sql-client.execution.result-mode' = 'tableau';

SELECT event_date, event_dataset, COUNT(*) AS event_count
FROM `${ICEBERG_CATALOG_NAME}`.`${ICEBERG_NAMESPACE}`.`${ICEBERG_TABLE}`
GROUP BY event_date, event_dataset
ORDER BY event_date, event_dataset;

SELECT committed_at, operation, snapshot_id
FROM `${ICEBERG_CATALOG_NAME}`.`${ICEBERG_NAMESPACE}`.`${ICEBERG_TABLE}$snapshots`;

SELECT file_format, record_count, file_path
FROM `${ICEBERG_CATALOG_NAME}`.`${ICEBERG_NAMESPACE}`.`${ICEBERG_TABLE}$files`;
