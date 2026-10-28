# Databricks notebook source
# MAGIC %md
# MAGIC # SALES.PRODUCTS: Event Hubs → Bronze → Silver
# MAGIC
# MAGIC Reads the Debezium change events from the `oracle-changes` event hub and turns them into a Delta table that mirrors `SALES.PRODUCTS` in Oracle.
# MAGIC
# MAGIC | Layer | Table | Content |
# MAGIC |---|---|---|
# MAGIC | Bronze | `bronze_change_events` | every event exactly as it arrived (key and value as JSON text) plus its Kafka position |
# MAGIC | Silver | `silver_products` | one row per product, current state; inserts, updates and deletes applied |
# MAGIC
# MAGIC Both steps run as streams with `availableNow`: each run processes whatever is new since the last run and then stops, so nothing runs (or is billed) between runs. Runs on serverless compute. Checkpoints remember the position, so running the notebook again only picks up new events.

# COMMAND ----------

# MAGIC %md
# MAGIC ## Settings
# MAGIC
# MAGIC `start_from`: Bronze ignores events enqueued before this moment. The event hub keeps 7 days of events, including ones from earlier database instances whose SCNs don't line up with the current one, so the stream starts at the current Debezium start. It only applies to the very first run; after that the checkpoint decides.

# COMMAND ----------

from datetime import datetime

dbutils.widgets.text("start_from", "2026-10-27T17:18:00Z")
start_from = dbutils.widgets.get("start_from")
start_ms = int(datetime.fromisoformat(start_from.replace("Z", "+00:00")).timestamp() * 1000)

# Tables go into the workspace's default Unity Catalog catalog.
catalog = spark.sql("SELECT current_catalog()").first()[0]
schema = f"{catalog}.oracle_cdc"
bronze_table = f"{schema}.bronze_change_events"
silver_table = f"{schema}.silver_products"
checkpoints = f"/Volumes/{catalog}/oracle_cdc/checkpoints"

# Namespace and hub come from infra/azure (outputs eventhub_namespace / eventhub_name).
eh_namespace = "evhns-oracle-cdc-rk26rq"
eh_name = "oracle-changes"

print(f"catalog={catalog}  start_from={start_from} ({start_ms})")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Schema, checkpoint volume, Silver table
# MAGIC
# MAGIC Silver is created up front with explicit types, so the MERGE always has a stable target. Columns starting with `_` are CDC metadata, not Oracle columns.

# COMMAND ----------

spark.sql(f"CREATE SCHEMA IF NOT EXISTS {schema}")
spark.sql(f"CREATE VOLUME IF NOT EXISTS {schema}.checkpoints")

spark.sql(f"""
CREATE TABLE IF NOT EXISTS {silver_table} (
    product_sku       STRING NOT NULL,
    product_name      STRING,
    category          STRING,
    list_price        DECIMAL(10, 2),
    in_stock          INT,
    last_updated      TIMESTAMP,
    _op               STRING    COMMENT 'last applied Debezium op: r = snapshot, c = insert, u = update',
    _source_scn       BIGINT    COMMENT 'Oracle SCN of the last applied change',
    _source_ts        TIMESTAMP COMMENT 'commit time in Oracle',
    _kafka_partition  INT,
    _kafka_offset     BIGINT    COMMENT 'position of the last applied event; guards against replays',
    _merged_at        TIMESTAMP
)
COMMENT 'Current state of SALES.PRODUCTS, maintained from Debezium change events'
""")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Bronze: raw events from Event Hubs
# MAGIC
# MAGIC Event Hubs (Standard) speaks the Kafka protocol on port 9093, so the built-in Kafka source reads it directly; no extra library. The user name is the literal `$ConnectionString`, the password is the listen-only connection string from the secret scope (Databricks redacts it in output).
# MAGIC
# MAGIC Bronze stores key and value as plain JSON text, without parsing. If the Silver logic changes, it can be rebuilt from Bronze without going back to Oracle.

# COMMAND ----------

from pyspark.sql import functions as F

eh_conn = dbutils.secrets.get(scope="oracle-cdc", key="eventhubs-connection-string")

kafka_options = {
    "kafka.bootstrap.servers": f"{eh_namespace}.servicebus.windows.net:9093",
    "subscribe": eh_name,
    "kafka.security.protocol": "SASL_SSL",
    "kafka.sasl.mechanism": "PLAIN",
    "kafka.sasl.jaas.config": (
        "kafkashaded.org.apache.kafka.common.security.plain.PlainLoginModule required "
        f'username="$ConnectionString" password="{eh_conn}";'
    ),
    # Event Hubs recommends longer timeouts than the Kafka defaults.
    "kafka.request.timeout.ms": "60000",
    "kafka.session.timeout.ms": "30000",
    "startingTimestamp": str(start_ms),
    # Events older than the 7-day retention can disappear while the stream is stopped.
    "failOnDataLoss": "false",
}

raw = (
    spark.readStream.format("kafka").options(**kafka_options).load()
    .select(
        F.col("partition").alias("kafka_partition"),
        F.col("offset").alias("kafka_offset"),
        F.col("timestamp").alias("enqueued_at"),
        F.col("key").cast("string").alias("key"),
        F.col("value").cast("string").alias("value"),
        F.current_timestamp().alias("ingested_at"),
    )
)

(raw.writeStream
    .option("checkpointLocation", f"{checkpoints}/bronze")
    .trigger(availableNow=True)
    .toTable(bronze_table)
    .awaitTermination())

print(f"{bronze_table}: {spark.table(bronze_table).count()} events")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Silver: apply changes with MERGE
# MAGIC
# MAGIC The Debezium value looks like `{"before": {...}, "after": {...}, "source": {"table": "PRODUCTS", "scn": "...", ...}, "op": "u", "ts_ms": ...}`.
# MAGIC
# MAGIC - **Filter:** only `SALES.PRODUCTS` events with an `op`. Heartbeats land in the same hub and have no `op`.
# MAGIC - **Types:** with `decimal.handling.mode=string` every Oracle `NUMBER` arrives as a JSON string, `NUMBER(5)` included, so `LIST_PRICE` and `IN_STOCK` are read as strings and cast. `TIMESTAMP` arrives as epoch microseconds.
# MAGIC - **Deletes:** `after` is null, the key comes from `before`.
# MAGIC - **Order:** all events for one product sit in one partition (Debezium routes by primary key), so the Kafka offset is the exact order of changes per row. Within a micro-batch only the latest event per product is kept.
# MAGIC - **At-least-once:** Debezium can resend events after a restart. The MERGE only applies an event whose offset is newer than the one stored in Silver, so a replay changes nothing.

# COMMAND ----------

from delta.tables import DeltaTable
from pyspark.sql.window import Window

row_ddl = """PRODUCT_SKU STRING, PRODUCT_NAME STRING, CATEGORY STRING,
             LIST_PRICE STRING, IN_STOCK STRING, LAST_UPDATED BIGINT"""
event_schema = f"""before STRUCT<{row_ddl}>, after STRUCT<{row_ddl}>,
                   source STRUCT<schema: STRING, table: STRING, scn: STRING, ts_ms: BIGINT>,
                   op STRING"""


def parse_products(bronze_df):
    e = bronze_df.withColumn("e", F.from_json("value", event_schema))
    row = F.coalesce("e.after", "e.before")  # after for c/r/u, before for d
    return (
        e.where("e.op IS NOT NULL AND e.source.schema = 'SALES' AND e.source.table = 'PRODUCTS'")
        .select(
            row.PRODUCT_SKU.alias("product_sku"),
            F.col("e.after.PRODUCT_NAME").alias("product_name"),
            F.col("e.after.CATEGORY").alias("category"),
            F.col("e.after.LIST_PRICE").cast("decimal(10,2)").alias("list_price"),
            F.col("e.after.IN_STOCK").cast("int").alias("in_stock"),
            F.timestamp_micros("e.after.LAST_UPDATED").alias("last_updated"),
            F.col("e.op").alias("_op"),
            F.col("e.source.scn").cast("bigint").alias("_source_scn"),
            F.timestamp_millis("e.source.ts_ms").alias("_source_ts"),
            F.col("kafka_partition").alias("_kafka_partition"),
            F.col("kafka_offset").alias("_kafka_offset"),
            F.current_timestamp().alias("_merged_at"),
        )
    )


def merge_batch(batch_df, batch_id):
    latest = (
        parse_products(batch_df)
        .withColumn("rn", F.row_number().over(
            Window.partitionBy("product_sku").orderBy(F.col("_kafka_offset").desc())))
        .where("rn = 1")
        .drop("rn")
    )
    # Delta's MERGE API instead of a temp view + SQL: the micro-batch has its own
    # session (batch_df.sparkSession), and this works the same on classic
    # clusters and serverless.
    newer = "s._kafka_offset > t._kafka_offset"
    (DeltaTable.forName(batch_df.sparkSession, silver_table).alias("t")
        .merge(latest.alias("s"), "t.product_sku = s.product_sku")
        .whenMatchedDelete(condition=f"{newer} AND s._op = 'd'")
        .whenMatchedUpdateAll(condition=newer)
        .whenNotMatchedInsertAll(condition="s._op != 'd'")
        .execute())


(spark.readStream.table(bronze_table)
    .writeStream
    .foreachBatch(merge_batch)
    .option("checkpointLocation", f"{checkpoints}/silver_products")
    .trigger(availableNow=True)
    .start()
    .awaitTermination())

# COMMAND ----------

# MAGIC %md
# MAGIC ## Check the result
# MAGIC
# MAGIC After the initial snapshot Silver has the same 10 rows as Oracle. Change a row in Oracle, wait a few seconds, run the notebook again, and the change shows up here, including deletes.

# COMMAND ----------

display(spark.sql(f"SELECT * FROM {silver_table} ORDER BY product_sku"))

# COMMAND ----------

# What Bronze has received, per table and operation (NULL op = heartbeat).
display(spark.sql(f"""
    SELECT get_json_object(value, '$.source.table') AS source_table,
           get_json_object(value, '$.op')           AS op,
           count(*)                                 AS events,
           max(enqueued_at)                         AS last_enqueued
    FROM {bronze_table}
    GROUP BY ALL
    ORDER BY source_table, op
"""))
