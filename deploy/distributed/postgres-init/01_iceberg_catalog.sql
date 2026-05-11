CREATE USER iceberg WITH PASSWORD 'iceberg';
CREATE DATABASE iceberg_catalog OWNER iceberg;
GRANT ALL PRIVILEGES ON DATABASE iceberg_catalog TO iceberg;
