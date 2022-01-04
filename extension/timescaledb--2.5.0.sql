--“_timescaledb_catalog、_timescaledb_internal、_timescaledb_cache”这些是 TimescaleDB 扩展使用的内部架构，用于cache/catalog/internal function和table。
--它们是扩展正常运行所必需的。它们在安装扩展程序时安装，如果您删除扩展程序（连同有关扩展程序的所有其他内容，包括您的数据，如果它在超表中并且您使用级联运行命令），
--它们将被删除。有关它们的安装位置，请参阅https://github.com/timescale/timescaledb/blob/master/sql/pre_install/schemas.sql。它们在代码库中有不同的用途，
--并包含不同类型的函数/表。

CREATE SCHEMA IF NOT EXISTS _timescaledb_catalog;
CREATE SCHEMA IF NOT EXISTS _timescaledb_internal;
CREATE SCHEMA IF NOT EXISTS _timescaledb_cache;
CREATE SCHEMA IF NOT EXISTS _timescaledb_config;
CREATE SCHEMA IF NOT EXISTS timescaledb_experimental;
GRANT USAGE ON SCHEMA _timescaledb_cache, _timescaledb_catalog, _timescaledb_internal, _timescaledb_config TO PUBLIC;
GRANT USAGE ON SCHEMA timescaledb_experimental TO PUBLIC;

--
-- The general compressed_data type;
--
CREATE TYPE _timescaledb_internal.compressed_data;

--
-- Remote transaction ID
--
CREATE TYPE rxid;

--placeholder to allow creation of functions below
 
-- 函数必须在 2 个地方运行：
-- 1) 在types.pre.sql 和types.post.sql 之间的预安装中设置类型。
-- 2) 在每次更新时确保函数指向正确的 versioned.so

-- PostgreSQL 复合类型不支持约束检查。 这就是为什么任何具有 ts_interval 列的表都必须使用以下函数进行约束验证的原因。
-- 该函数需要在执行 pre_install/tables.sql 之前定义，因为它被用作 ts_interval 类型的列的验证约束。

-- 文本输入/输出只是二进制表示的 base64 编码
CREATE OR REPLACE FUNCTION _timescaledb_internal.compressed_data_in(CSTRING)
   RETURNS _timescaledb_internal.compressed_data
   AS '$libdir/timescaledb-2.5.0', 'ts_compressed_data_in'
   LANGUAGE C IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.compressed_data_out(_timescaledb_internal.compressed_data)
   RETURNS CSTRING
   AS '$libdir/timescaledb-2.5.0', 'ts_compressed_data_out'
   LANGUAGE C IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.compressed_data_send(_timescaledb_internal.compressed_data)
   RETURNS BYTEA
   AS '$libdir/timescaledb-2.5.0', 'ts_compressed_data_send'
   LANGUAGE C IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.compressed_data_recv(internal)
   RETURNS _timescaledb_internal.compressed_data
   AS '$libdir/timescaledb-2.5.0', 'ts_compressed_data_recv'
   LANGUAGE C IMMUTABLE STRICT;

-- Remote transation ID implementation
CREATE OR REPLACE FUNCTION _timescaledb_internal.rxid_in(cstring) RETURNS rxid
    AS '$libdir/timescaledb-2.5.0', 'ts_remote_txn_id_in' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.rxid_out(rxid) RETURNS cstring
    AS '$libdir/timescaledb-2.5.0', 'ts_remote_txn_id_out' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

--
-- The general compressed_data type;
--
CREATE TYPE _timescaledb_internal.compressed_data (
  INTERNALLENGTH = VARIABLE,
  STORAGE = EXTERNAL,
  ALIGNMENT = double, --需要在ARRAY类型压缩中对齐
  INPUT = _timescaledb_internal.compressed_data_in,
  OUTPUT = _timescaledb_internal.compressed_data_out,
  RECEIVE = _timescaledb_internal.compressed_data_recv,
  SEND = _timescaledb_internal.compressed_data_send
);

--
-- Remote transaction ID
--
CREATE TYPE rxid (
  internallength = 16,
  input = _timescaledb_internal.rxid_in,
  output = _timescaledb_internal.rxid_out
);
 
 
--注意：此文件中的 UPGRADE-SCRIPT-NEEDED 内容不会自动升级。
-- 该文件包含用于表示超表和低级概念的各种抽象和数据结构的表定义。
-- 超表
-- ==========

-- hypertable 是一个抽象，表示一个表被划分为 N 维，其中每个维映射到表中的一列。维度可以是“开放”或“封闭”，这反映了将维度的键空间划分为“切片”的方案。
-- 从概念上讲，分区 -- 称为“块”，是 N 维空间中的超立方体。块将超表元组的子集存储在磁盘上它自己的不同表中。跨越块的超立方体的切片每个对应于块表上的约束，从而在对超表数据的查询期间启用约束排除。

-- 开放式维度
------------------
-- 一个开放维度进行按需切片，只要一个元组落在现有切片之外，就会根据可配置的间隔创建一个新切片。开放维度非常适合递增的列，例如基于时间的列。

-- 封闭式维度
--------------------
-- 封闭维度将其键空间完全划分为可配置数量的切片。切片的数量可以重新配置，但新的分区只影响新创建的块。
-- 唯一约束是 table_name +schema_name。排序很重要，因为我们在按 table_name 过滤时需要索引访问
CREATE SEQUENCE IF NOT EXISTS _timescaledb_catalog.hypertable_id_seq MINVALUE 1;

CREATE TABLE IF NOT EXISTS _timescaledb_catalog.hypertable (
  id INTEGER PRIMARY KEY DEFAULT nextval('_timescaledb_catalog.hypertable_id_seq'), 
  schema_name name NOT NULL CHECK (schema_name != '_timescaledb_catalog'),
  table_name name NOT NULL,
  associated_schema_name name NOT NULL,
  associated_table_prefix name NOT NULL,
  num_dimensions smallint NOT NULL,
  chunk_sizing_func_schema name NOT NULL,
  chunk_sizing_func_name name NOT NULL,
  chunk_target_size bigint NOT NULL CHECK (chunk_target_size >= 0), -- size in bytes
  compression_state smallint NOT NULL DEFAULT 0,
  compressed_hypertable_id integer REFERENCES _timescaledb_catalog.hypertable (id),
  replication_factor smallint NULL,
  UNIQUE (associated_schema_name, associated_table_prefix),
  CONSTRAINT hypertable_table_name_schema_name_key UNIQUE (table_name, schema_name),
  -- 内部压缩的超表具有压缩状态 = 2
  CONSTRAINT hypertable_dim_compress_check CHECK (num_dimensions > 0 OR compression_state = 2),
  CONSTRAINT hypertable_compress_check CHECK ( (compression_state = 0 OR compression_state = 1 )  OR (compression_state = 2 AND compressed_hypertable_id IS NULL)),
  -- replication_factor NULL：常规超表
  -- replication_factor > 0：访问节点上的分布式超表
  -- replication_factor -1：数据节点上的分布式超表，它是更大表的一部分
  CONSTRAINT hypertable_replication_factor_check CHECK (replication_factor > 0 OR replication_factor = -1)
);
ALTER SEQUENCE _timescaledb_catalog.hypertable_id_seq OWNED BY _timescaledb_catalog.hypertable.id;
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.hypertable_id_seq', '');

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.hypertable', '');

CREATE TABLE IF NOT EXISTS _timescaledb_catalog.hypertable_data_node (
  hypertable_id integer NOT NULL REFERENCES _timescaledb_catalog.hypertable (id),
  node_hypertable_id integer NULL,
  node_name name NOT NULL,
  block_chunks boolean NOT NULL,
  UNIQUE (node_hypertable_id, node_name),
  UNIQUE (hypertable_id, node_name)
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.hypertable_data_node', '');

-- 表空间表将表空间映射到超表。
-- 这允许将 hypertable 的块分布在多个磁盘上。
CREATE TABLE IF NOT EXISTS _timescaledb_catalog.tablespace (
  id serial PRIMARY KEY,
  hypertable_id int NOT NULL REFERENCES _timescaledb_catalog.hypertable (id) ON DELETE CASCADE,
  tablespace_name name NOT NULL,
  UNIQUE (hypertable_id, tablespace_name)
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.tablespace', '');

-- 一个维度代表一个轴，数据沿着这个轴进行分区。
CREATE TABLE IF NOT EXISTS _timescaledb_catalog.dimension (
  id serial NOT NULL PRIMARY KEY,
  hypertable_id integer NOT NULL REFERENCES _timescaledb_catalog.hypertable (id) ON DELETE CASCADE,
  column_name name NOT NULL,
  column_type REGTYPE NOT NULL,
  aligned boolean NOT NULL,
  -- 封闭式维度
  num_slices smallint NULL,
  partitioning_func_schema name NULL,
  partitioning_func name NULL,
  -- 开放式维度 (e.g., time)
  interval_length bigint NULL CHECK (interval_length IS NULL OR interval_length > 0),
  integer_now_func_schema name NULL,
  integer_now_func name NULL,
  CHECK ((partitioning_func_schema IS NULL AND partitioning_func IS NULL) OR (partitioning_func_schema IS NOT NULL AND partitioning_func IS NOT NULL)),
  CHECK ((num_slices IS NULL AND interval_length IS NOT NULL) OR (num_slices IS NOT NULL AND interval_length IS NULL)),
  CHECK ((integer_now_func_schema IS NULL AND integer_now_func IS NULL) OR (integer_now_func_schema IS NOT NULL AND integer_now_func IS NOT NULL)),
  UNIQUE (hypertable_id, column_name)
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.dimension', '');

SELECT pg_catalog.pg_extension_config_dump(pg_get_serial_sequence('_timescaledb_catalog.dimension', 'id'), '');

-- 维度切片定义了沿维度轴的键空间范围。
CREATE TABLE IF NOT EXISTS _timescaledb_catalog.dimension_slice (
  id serial NOT NULL PRIMARY KEY,
  dimension_id integer NOT NULL REFERENCES _timescaledb_catalog.dimension (id) ON DELETE CASCADE,
  range_start bigint NOT NULL,
  range_end bigint NOT NULL,
  CHECK (range_start <= range_end),
  UNIQUE (dimension_id, range_start, range_end)
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.dimension_slice', '');

SELECT pg_catalog.pg_extension_config_dump(pg_get_serial_sequence('_timescaledb_catalog.dimension_slice', 'id'), '');

-- 一个chunk是 N 维超空间中的一个partition（hypercube，超立方体）。 每个块与定义块的超立方体的 N 个约束相关联。 属于块的超立方体的元组存储在块的数据表中，如“schema_name”和“table_name”给出的。
CREATE SEQUENCE IF NOT EXISTS _timescaledb_catalog.chunk_id_seq MINVALUE 1;

CREATE TABLE IF NOT EXISTS _timescaledb_catalog.chunk (
  id integer PRIMARY KEY DEFAULT nextval('_timescaledb_catalog.chunk_id_seq'),
  hypertable_id int NOT NULL REFERENCES _timescaledb_catalog.hypertable (id),
  schema_name name NOT NULL,
  table_name name NOT NULL,
  compressed_chunk_id integer REFERENCES _timescaledb_catalog.chunk (id),
  dropped boolean NOT NULL DEFAULT FALSE,
  status integer NOT NULL DEFAULT 0,
  UNIQUE (schema_name, table_name)
);
ALTER SEQUENCE _timescaledb_catalog.chunk_id_seq OWNED BY _timescaledb_catalog.chunk.id;

CREATE INDEX IF NOT EXISTS chunk_hypertable_id_idx ON _timescaledb_catalog.chunk (hypertable_id);

CREATE INDEX IF NOT EXISTS chunk_compressed_chunk_id_idx ON _timescaledb_catalog.chunk (compressed_chunk_id);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.chunk', '');
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.chunk_id_seq', '');

-- 块约束将维度切片映射到块。 与块关联的每个约束也将是块的数据表上的表约束。
CREATE TABLE IF NOT EXISTS _timescaledb_catalog.chunk_constraint (
  chunk_id integer NOT NULL REFERENCES _timescaledb_catalog.chunk (id),
  dimension_slice_id integer NULL REFERENCES _timescaledb_catalog.dimension_slice (id),
  constraint_name name NOT NULL,
  hypertable_constraint_name name NULL,
  UNIQUE (chunk_id, constraint_name)
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.chunk_constraint', '');

CREATE INDEX IF NOT EXISTS chunk_constraint_chunk_id_dimension_slice_id_idx ON _timescaledb_catalog.chunk_constraint (chunk_id, dimension_slice_id);

CREATE SEQUENCE IF NOT EXISTS _timescaledb_catalog.chunk_constraint_name;

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.chunk_constraint_name', '');

CREATE TABLE IF NOT EXISTS _timescaledb_catalog.chunk_index (
  chunk_id integer NOT NULL REFERENCES _timescaledb_catalog.chunk (id) ON DELETE CASCADE,
  index_name name NOT NULL,
  hypertable_id integer NOT NULL REFERENCES _timescaledb_catalog.hypertable (id) ON DELETE CASCADE,
  hypertable_index_name name NOT NULL,
  UNIQUE (chunk_id, index_name)
);

CREATE INDEX IF NOT EXISTS chunk_index_hypertable_id_hypertable_index_name_idx ON _timescaledb_catalog.chunk_index (hypertable_id, hypertable_index_name);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.chunk_index', '');

CREATE TABLE IF NOT EXISTS _timescaledb_catalog.chunk_data_node (
  chunk_id integer NOT NULL REFERENCES _timescaledb_catalog.chunk (id),
  node_chunk_id integer NOT NULL,
  node_name name NOT NULL,
  UNIQUE (node_chunk_id, node_name),
  UNIQUE (chunk_id, node_name)
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.chunk_data_node', '');


-- 默认job的 ID 空间为 [1,1000)。 用户安装的job和在测试中创建的任何job都被赋予了 id 空间 [1000, INT_MAX)。 这样，我们不会在其他 .sql 脚本中始终默认安装 pg_dump job。 这避免了 pg_restore 期间的插入冲突。
MINVALUE 1000;

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_config.bgw_job_id_seq', '');

CREATE TABLE IF NOT EXISTS _timescaledb_config.bgw_job (
  id integer PRIMARY KEY DEFAULT nextval('_timescaledb_config.bgw_job_id_seq'),
  application_name name NOT NULL,
  schedule_interval interval NOT NULL,
  max_runtime interval NOT NULL,
  max_retries integer NOT NULL,
  retry_period interval NOT NULL,
  proc_schema name NOT NULL,
  proc_name name NOT NULL,
  owner name NOT NULL DEFAULT CURRENT_ROLE,
  scheduled bool NOT NULL DEFAULT TRUE,
  hypertable_id integer REFERENCES _timescaledb_catalog.hypertable (id) ON DELETE CASCADE,
  config jsonb
);

ALTER SEQUENCE _timescaledb_config.bgw_job_id_seq OWNED BY _timescaledb_config.bgw_job.id;

CREATE INDEX IF NOT EXISTS bgw_job_proc_hypertable_id_idx ON _timescaledb_config.bgw_job (proc_schema, proc_name, hypertable_id);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_config.bgw_job', 'WHERE id >= 1000');

CREATE TABLE IF NOT EXISTS _timescaledb_internal.bgw_job_stat (
  job_id integer PRIMARY KEY REFERENCES _timescaledb_config.bgw_job (id) ON DELETE CASCADE,
  last_start timestamptz NOT NULL DEFAULT NOW(),
  last_finish timestamptz NOT NULL,
  next_start timestamptz NOT NULL,
  last_successful_finish timestamptz NOT NULL,
  last_run_success bool NOT NULL,
  total_runs bigint NOT NULL,
  total_duration interval NOT NULL,
  total_successes bigint NOT NULL,
  total_failures bigint NOT NULL,
  total_crashes bigint NOT NULL,
  consecutive_failures int NOT NULL,
  consecutive_crashes int NOT NULL
);


--pg_dump 不会故意转储 job_stat 表，因为统计信息可能在实例之间没有太大意义。
-- 现在我们为每个作业/块对定义一个特殊的统计表。 调度程序将使用它来确定是否在特定块上运行特定作业。
CREATE TABLE IF NOT EXISTS _timescaledb_internal.bgw_policy_chunk_stats (
  job_id integer NOT NULL REFERENCES _timescaledb_config.bgw_job (id) ON DELETE CASCADE,
  chunk_id integer NOT NULL REFERENCES _timescaledb_catalog.chunk (id) ON DELETE CASCADE,
  num_times_job_run integer,
  last_time_job_run timestamptz,
  UNIQUE (job_id, chunk_id)
);

CREATE TABLE IF NOT EXISTS _timescaledb_catalog.metadata (
  key NAME NOT NULL PRIMARY KEY,
  value text NOT NULL,
  include_in_telemetry boolean NOT NULL
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.metadata', $$
  WHERE KEY = 'exported_uuid' $$);

CREATE TABLE IF NOT EXISTS _timescaledb_catalog.continuous_agg (
  mat_hypertable_id integer PRIMARY KEY REFERENCES _timescaledb_catalog.hypertable (id) ON DELETE CASCADE,
  raw_hypertable_id integer NOT NULL REFERENCES _timescaledb_catalog.hypertable (id) ON DELETE CASCADE,
  user_view_schema name NOT NULL,
  user_view_name name NOT NULL,
  partial_view_schema name NOT NULL,
  partial_view_name name NOT NULL,
  bucket_width bigint NOT NULL,
  direct_view_schema name NOT NULL,
  direct_view_name name NOT NULL,
  materialized_only bool NOT NULL DEFAULT FALSE,
  UNIQUE (user_view_schema, user_view_name),
  UNIQUE (partial_view_schema, partial_view_name)
);

CREATE INDEX IF NOT EXISTS continuous_agg_raw_hypertable_id_idx ON _timescaledb_catalog.continuous_agg (raw_hypertable_id);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.continuous_agg', '');

CREATE TABLE IF NOT EXISTS _timescaledb_catalog.continuous_aggs_invalidation_threshold (
  hypertable_id integer PRIMARY KEY REFERENCES _timescaledb_catalog.hypertable (id) ON DELETE CASCADE,
  watermark bigint NOT NULL
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.continuous_aggs_invalidation_threshold', '');

-- 这在物化表上没有 FK，因为对这个表的 INSERT 对性能至关重要
CREATE TABLE IF NOT EXISTS _timescaledb_catalog.continuous_aggs_hypertable_invalidation_log (
  hypertable_id integer NOT NULL,
  lowest_modified_value bigint NOT NULL,
  greatest_modified_value bigint NOT NULL
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.continuous_aggs_hypertable_invalidation_log', '');

CREATE INDEX continuous_aggs_hypertable_invalidation_log_idx ON _timescaledb_catalog.continuous_aggs_hypertable_invalidation_log (hypertable_id, lowest_modified_value ASC);

-- 每个失效日志的 cagg 副本
CREATE TABLE IF NOT EXISTS _timescaledb_catalog.continuous_aggs_materialization_invalidation_log (
  materialization_id integer REFERENCES _timescaledb_catalog.continuous_agg (mat_hypertable_id) ON DELETE CASCADE,
  lowest_modified_value bigint NOT NULL,
  greatest_modified_value bigint NOT NULL
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.continuous_aggs_materialization_invalidation_log', '');

CREATE INDEX continuous_aggs_materialization_invalidation_log_idx ON _timescaledb_catalog.continuous_aggs_materialization_invalidation_log (materialization_id, lowest_modified_value ASC);


/* 此数据的来源是列出算法的源代码中的枚举。 此表不会转储。
  */
CREATE TABLE IF NOT EXISTS _timescaledb_catalog.compression_algorithm (
  id smallint PRIMARY KEY,
  version smallint NOT NULL,
  name name NOT NULL,
  description text
);

CREATE TABLE IF NOT EXISTS _timescaledb_catalog.hypertable_compression (
  hypertable_id integer REFERENCES _timescaledb_catalog.hypertable (id) ON DELETE CASCADE,
  attname name NOT NULL,
  compression_algorithm_id smallint REFERENCES _timescaledb_catalog.compression_algorithm (id),
  segmentby_column_index smallint,
  orderby_column_index smallint,
  orderby_asc boolean,
  orderby_nullsfirst boolean,
  PRIMARY KEY (hypertable_id, attname),
  UNIQUE (hypertable_id, segmentby_column_index),
  UNIQUE (hypertable_id, orderby_column_index)
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.hypertable_compression', '');

CREATE TABLE IF NOT EXISTS _timescaledb_catalog.compression_chunk_size (
  chunk_id integer REFERENCES _timescaledb_catalog.chunk (id) ON DELETE CASCADE,
  compressed_chunk_id integer REFERENCES _timescaledb_catalog.chunk (id) ON DELETE CASCADE,
  uncompressed_heap_size bigint NOT NULL,
  uncompressed_toast_size bigint NOT NULL,
  uncompressed_index_size bigint NOT NULL,
  compressed_heap_size bigint NOT NULL,
  compressed_toast_size bigint NOT NULL,
  compressed_index_size bigint NOT NULL,
  numrows_pre_compression bigint,
  numrows_post_compression bigint,
  PRIMARY KEY (chunk_id, compressed_chunk_id)
);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.compression_chunk_size', '');

--这存储了 2pc 远程 txns 的提交决策。 永远不会存储中止决定。
-- 如果任何数据节点的 PREPARE TRANSACTION 失败，则整个前端事务将回滚，并且不会存储任何行。
--frontend_transaction_id 代表整个分布式事务，每个数据节点都会有一个唯一的remote_transaction_id。
CREATE TABLE _timescaledb_catalog.remote_txn (
  data_node_name name, --这实际上只是为了让我们能够在每个节点的基础上清理东西。
  remote_transaction_id text CHECK (remote_transaction_id::rxid IS NOT NULL),
  PRIMARY KEY (remote_transaction_id)
);

CREATE INDEX IF NOT EXISTS remote_txn_data_node_name_idx ON _timescaledb_catalog.remote_txn (data_node_name);

SELECT pg_catalog.pg_extension_config_dump('_timescaledb_catalog.remote_txn', '');

-- 该表存储有关块移动/复制活动已完成阶段的信息
-- 清理活动可以查询和检查后端是否正在运行。 如果后端已经退出，那么我们可以开始清理。 清理活动还可以与“time_start”值进行比较，以确定整个端到端活动是否持续时间过长
-- 我们还跟踪每个阶段的结束时间。 与当前时间的差异将使我们了解当前阶段已经运行了多长时间
-- 成功完成后删除块移动/复制活动的条目
-- 我们不想 pg_dump 这张表的内容。 使用它恢复的节点可能是完全不同的多节点设置的一部分，我们不想从早期继承块复制/移动操作（如果它有意义的话）
CREATE SEQUENCE IF NOT EXISTS _timescaledb_catalog.chunk_copy_operation_id_seq MINVALUE 1;

CREATE TABLE IF NOT EXISTS _timescaledb_catalog.chunk_copy_operation (
  operation_id name PRIMARY KEY, -- the publisher/subscriber identifier used
  backend_pid integer NOT NULL, -- the pid of the backend running this activity
  completed_stage name NOT NULL, -- the completed stage/step
  time_start timestamptz NOT NULL DEFAULT NOW(), -- start time of the activity
  chunk_id integer NOT NULL REFERENCES _timescaledb_catalog.chunk (id) ON DELETE CASCADE,
  source_node_name name NOT NULL,
  dest_node_name name NOT NULL,
  delete_on_source_node bool NOT NULL -- is a move or copy activity
);

-- 设置表权限
-- 我们需要为所有表授予 SELECT 给 PUBLIC 权限，即使是那些没有被标记为被转储的表，因为 pg_dump 将首先尝试访问所有表以检测继承链，然后决定哪些对象实际上需要被转储。
GRANT SELECT ON ALL TABLES IN SCHEMA _timescaledb_catalog TO PUBLIC;

GRANT SELECT ON ALL TABLES IN SCHEMA _timescaledb_config TO PUBLIC;

GRANT SELECT ON ALL TABLES IN SCHEMA _timescaledb_internal TO PUBLIC;

GRANT SELECT ON ALL SEQUENCES IN SCHEMA _timescaledb_catalog TO PUBLIC;

GRANT SELECT ON ALL SEQUENCES IN SCHEMA _timescaledb_config TO PUBLIC;

GRANT SELECT ON ALL SEQUENCES IN SCHEMA _timescaledb_internal TO PUBLIC;
  

--insert data for compression_algorithm --
insert into _timescaledb_catalog.compression_algorithm( id, version, name, description) values
( 0, 1, 'COMPRESSION_ALGORITHM_NONE', 'no compression'),
( 1, 1, 'COMPRESSION_ALGORITHM_ARRAY', 'array'),
( 2, 1, 'COMPRESSION_ALGORITHM_DICTIONARY', 'dictionary'),
( 3, 1, 'COMPRESSION_ALGORITHM_GORILLA', 'gorilla'),
( 4, 1, 'COMPRESSION_ALGORITHM_DELTADELTA', 'deltadelta');
 

CREATE OR REPLACE FUNCTION _timescaledb_internal.restart_background_workers()
RETURNS BOOL 
AS '$libdir/timescaledb', 'ts_bgw_db_workers_restart'
LANGUAGE C VOLATILE;

SELECT _timescaledb_internal.restart_background_workers();
 
 
CREATE OR REPLACE FUNCTION timescaledb_fdw_handler()
RETURNS fdw_handler
AS '$libdir/timescaledb-2.5.0', 'ts_timescaledb_fdw_handler'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION timescaledb_fdw_validator(text[], oid)
RETURNS void
AS '$libdir/timescaledb-2.5.0', 'ts_timescaledb_fdw_validator'
LANGUAGE C STRICT;


CREATE FOREIGN DATA WRAPPER timescaledb_fdw
  HANDLER timescaledb_fdw_handler
  VALIDATOR timescaledb_fdw_validator;
 
-- 函数必须在 2 个地方运行：
-- 1) 在types.pre.sql 和types.post.sql 之间的预安装中设置类型。
-- 2) 在每次更新时确保函数指向正确的 versioned.so

-- PostgreSQL 复合类型不支持约束检查。 这就是为什么任何具有 ts_interval 列的表都必须使用以下函数进行约束验证的原因。
-- 该函数需要在执行 pre_install/tables.sql 之前定义，因为它被用作 ts_interval 类型的列的验证约束。

-- 文本输入/输出只是二进制表示的 base64 编码
CREATE OR REPLACE FUNCTION _timescaledb_internal.compressed_data_in(CSTRING)
   RETURNS _timescaledb_internal.compressed_data
   AS '$libdir/timescaledb-2.5.0', 'ts_compressed_data_in'
   LANGUAGE C IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.compressed_data_out(_timescaledb_internal.compressed_data)
   RETURNS CSTRING
   AS '$libdir/timescaledb-2.5.0', 'ts_compressed_data_out'
   LANGUAGE C IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.compressed_data_send(_timescaledb_internal.compressed_data)
   RETURNS BYTEA
   AS '$libdir/timescaledb-2.5.0', 'ts_compressed_data_send'
   LANGUAGE C IMMUTABLE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.compressed_data_recv(internal)
   RETURNS _timescaledb_internal.compressed_data
   AS '$libdir/timescaledb-2.5.0', 'ts_compressed_data_recv'
   LANGUAGE C IMMUTABLE STRICT;

-- Remote transation ID implementation
CREATE OR REPLACE FUNCTION _timescaledb_internal.rxid_in(cstring) RETURNS rxid
    AS '$libdir/timescaledb-2.5.0', 'ts_remote_txn_id_in' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.rxid_out(rxid) RETURNS cstring
    AS '$libdir/timescaledb-2.5.0', 'ts_remote_txn_id_out' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
 

CREATE OR REPLACE FUNCTION timescaledb_fdw_handler()
RETURNS fdw_handler
AS '$libdir/timescaledb-2.5.0', 'ts_timescaledb_fdw_handler'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION timescaledb_fdw_validator(text[], oid)
RETURNS void
AS '$libdir/timescaledb-2.5.0', 'ts_timescaledb_fdw_validator'
LANGUAGE C STRICT;


-- 在超级表的根表上阻止插入的触发器
CREATE OR REPLACE FUNCTION _timescaledb_internal.insert_blocker() RETURNS trigger
AS '$libdir/timescaledb-2.5.0', 'ts_hypertable_insert_blocker' LANGUAGE C;

-- 记录会使连续聚合无效的突变或插入
CREATE OR REPLACE FUNCTION _timescaledb_internal.continuous_agg_invalidation_trigger() RETURNS TRIGGER
AS '$libdir/timescaledb-2.5.0', 'ts_continuous_agg_invalidation_trigger' LANGUAGE C;

CREATE OR REPLACE FUNCTION set_integer_now_func(hypertable REGCLASS, integer_now_func REGPROC, replace_if_exists BOOL = false) RETURNS VOID
AS '$libdir/timescaledb-2.5.0', 'ts_hypertable_set_integer_now_func'
LANGUAGE C VOLATILE STRICT;
 
-- 使用自适应分块时计算下一个块间隔的内置函数。 该函数可以替换为具有相同签名的用户定义函数。
-- 传递给函数的参数如下：
--Dimension_id：维度的ID，用于计算维度的区间dimension_coord：维度轴上触发此chunk创建的元组所在的坐标/点。
-- chunk_target_size：块应该具有的目标大小（以字节为单位）。
-- 该函数应该以特定于维度的时间（通常为微秒）返回新的间隔。
CREATE OR REPLACE FUNCTION _timescaledb_internal.calculate_chunk_interval(
        dimension_id INTEGER,
        dimension_coord BIGINT,
        chunk_target_size BIGINT
) RETURNS BIGINT AS '$libdir/timescaledb-2.5.0', 'ts_calculate_chunk_interval' LANGUAGE C;

-- 显式块排除功能。 提供一条记录和一组块 ID 作为输入。
-- 用于 WHERE 子句。
-- 一个例子：SELECT * FROM hypertable WHERE _timescaledb_internal.chunks_in(hypertable, ARRAY[1,2]);
-- 请谨慎使用，因为此功能会直接影响正在扫描哪些数据块。
-- 这是一个标记函数，永远不应该被执行（我们将它从计划中删除）
CREATE OR REPLACE FUNCTION _timescaledb_internal.chunks_in(record RECORD, chunks INTEGER[]) RETURNS BOOL
AS '$libdir/timescaledb-2.5.0', 'ts_chunks_in' LANGUAGE C STABLE STRICT PARALLEL SAFE;

-- 给定一个块的 relid，返回 id。 如果不是块重放，则出错。
CREATE OR REPLACE FUNCTION _timescaledb_internal.chunk_id_from_relid(relid OID) RETURNS INTEGER
AS '$libdir/timescaledb-2.5.0', 'ts_chunk_id_from_relid' LANGUAGE C STABLE STRICT PARALLEL SAFE;

-- 显示块的定义。
CREATE OR REPLACE FUNCTION _timescaledb_internal.show_chunk(chunk REGCLASS)
RETURNS TABLE(chunk_id INTEGER, hypertable_id INTEGER, schema_name NAME, table_name NAME, relkind "char", slices JSONB)
AS '$libdir/timescaledb-2.5.0', 'ts_chunk_show' LANGUAGE C VOLATILE;

-- 使用 JSONB 中给出的给定维度约束（切片）创建块。 如果 chunk_table 是一个有效的关系，它将被附加到超表并用作新块的数据表。 请注意，schema_name 和 table_name 不必与 chunk_table 的现有架构和名称相同。 提供的块表将根据需要重命名和/或移动。
CREATE OR REPLACE FUNCTION _timescaledb_internal.create_chunk(
       hypertable REGCLASS,
       slices JSONB,	   
       schema_name NAME = NULL,
       table_name NAME = NULL,
	   chunk_table REGCLASS = NULL)
RETURNS TABLE(chunk_id INTEGER, hypertable_id INTEGER, schema_name NAME, table_name NAME, relkind "char", slices JSONB, created BOOLEAN)
AS '$libdir/timescaledb-2.5.0', 'ts_chunk_create' LANGUAGE C VOLATILE;

-- 更改块的默认数据节点
CREATE OR REPLACE FUNCTION _timescaledb_internal.set_chunk_default_data_node(chunk REGCLASS, node_name NAME) RETURNS BOOLEAN
AS '$libdir/timescaledb-2.5.0', 'ts_chunk_set_default_data_node' LANGUAGE C VOLATILE;

-- 获取块统计信息。
CREATE OR REPLACE FUNCTION _timescaledb_internal.get_chunk_relstats(relid REGCLASS)
RETURNS TABLE(chunk_id INTEGER, hypertable_id INTEGER, num_pages INTEGER, num_tuples REAL, num_allvisible INTEGER)
AS '$libdir/timescaledb-2.5.0', 'ts_chunk_get_relstats' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.get_chunk_colstats(relid REGCLASS)
RETURNS TABLE(chunk_id INTEGER, hypertable_id INTEGER, att_num INTEGER, nullfrac REAL, width INTEGER, distinctval REAL, slotkind INTEGER[], slotopstrings CSTRING[], slotcollations OID[],
slot1numbers FLOAT4[], slot2numbers FLOAT4[], slot3numbers FLOAT4[], slot4numbers FLOAT4[], slot5numbers FLOAT4[],
slotvaluetypetrings CSTRING[], slot1values CSTRING[], slot2values CSTRING[], slot3values CSTRING[], slot4values CSTRING[], slot5values CSTRING[])
AS '$libdir/timescaledb-2.5.0', 'ts_chunk_get_colstats' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.create_chunk_table(
       hypertable REGCLASS,
       slices JSONB,
       schema_name NAME,
       table_name NAME)
RETURNS BOOL AS '$libdir/timescaledb-2.5.0', 'ts_chunk_create_empty_table' LANGUAGE C VOLATILE;
 
 

-- 检查数据节点是否已启动
CREATE OR REPLACE FUNCTION _timescaledb_internal.ping_data_node(node_name NAME) RETURNS BOOLEAN
AS '$libdir/timescaledb-2.5.0', 'ts_data_node_ping' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.remote_txn_heal_data_node(foreign_server_oid oid)
RETURNS INT
AS '$libdir/timescaledb-2.5.0', 'ts_remote_txn_heal_data_node'
LANGUAGE C STRICT;
 
 

-- 位于 chunk_index.h 中的这些函数的文档
CREATE OR REPLACE FUNCTION _timescaledb_internal.chunk_index_clone(chunk_index_oid OID) RETURNS OID
AS '$libdir/timescaledb-2.5.0', 'ts_chunk_index_clone' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.chunk_index_replace(chunk_index_oid_old OID, chunk_index_oid_new OID) RETURNS VOID
AS '$libdir/timescaledb-2.5.0', 'ts_chunk_index_replace' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.create_chunk_replica_table(
    chunk REGCLASS,
    data_node_name NAME
) RETURNS VOID AS '$libdir/timescaledb-2.5.0', 'ts_chunk_create_replica_table' LANGUAGE C VOLATILE;

-- 删除指定数据节点上的指定chunk副本
CREATE OR REPLACE FUNCTION  _timescaledb_internal.chunk_drop_replica(
    chunk                   REGCLASS,
    node_name               NAME
) RETURNS VOID
AS '$libdir/timescaledb-2.5.0', 'ts_chunk_drop_replica' LANGUAGE C VOLATILE;

CREATE OR REPLACE PROCEDURE _timescaledb_internal.wait_subscription_sync(
    schema_name    NAME,
    table_name     NAME,
    retry_count    INT DEFAULT 18000,
    retry_delay_ms NUMERIC DEFAULT 0.200
)
LANGUAGE PLPGSQL AS
$BODY$
DECLARE
    in_sync BOOLEAN;
BEGIN
    FOR i in 1 .. retry_count
    LOOP
        SELECT pgs.srsubstate = 'r'
        INTO in_sync
        FROM pg_subscription_rel pgs
        JOIN pg_class pgc ON relname = table_name
        JOIN pg_namespace n ON (n.OID = pgc.relnamespace)
        WHERE pgs.srrelid = pgc.oid AND schema_name = n.nspname;

        if (in_sync IS NULL OR NOT in_sync) THEN
          PERFORM pg_sleep(retry_delay_ms);
        ELSE
          RETURN;
        END IF;
    END LOOP;
    RAISE 'subscription sync wait timedout';
END
$BODY$;
 

-------------------------------------------------- ---------------
-- 实验性 DDL 函数和 API。
-- 用户不应依赖这些功能，除非他们接受可以随时更改和/或删除这些功能。
-------------------------------------------------- ---------------

-- 阻止在分布式超表的数据节点上创建新块。 NULL 超表意味着它将阻塞所有分布式超表的块 
-------------------------------------------------- ---------------
CREATE OR REPLACE FUNCTION timescaledb_experimental.block_new_chunks(data_node_name NAME, hypertable REGCLASS = NULL, force BOOLEAN = FALSE) RETURNS INTEGER
AS '$libdir/timescaledb-2.5.0', 'ts_data_node_block_new_chunks' LANGUAGE C VOLATILE;

-- 允许在分布式超表的阻塞数据节点上创建块。 NULL 超表意味着它将允许所有分布式超表的块
CREATE OR REPLACE FUNCTION timescaledb_experimental.allow_new_chunks(data_node_name NAME, hypertable REGCLASS = NULL) RETURNS INTEGER
AS '$libdir/timescaledb-2.5.0', 'ts_data_node_allow_new_chunks' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION timescaledb_experimental.refresh_continuous_aggregate(
    continuous_aggregate     REGCLASS,
    hypertable_chunk         REGCLASS
) RETURNS VOID AS '$libdir/timescaledb-2.5.0', 'ts_continuous_agg_refresh_chunk' LANGUAGE C VOLATILE;

CREATE OR REPLACE PROCEDURE timescaledb_experimental.move_chunk(
    chunk REGCLASS,
    source_node NAME = NULL,
    destination_node NAME = NULL)
AS '$libdir/timescaledb-2.5.0', 'ts_move_chunk_proc' LANGUAGE C;

CREATE OR REPLACE PROCEDURE timescaledb_experimental.copy_chunk(
    chunk REGCLASS,
    source_node NAME = NULL,
    destination_node NAME = NULL)
AS '$libdir/timescaledb-2.5.0', 'ts_copy_chunk_proc' LANGUAGE C;

-- copy_chunk 或 move_chunk 过程调用涉及多个节点，并且根据数据大小可能需要很长时间。 当这个长时间运行的活动正在进行时，失败是可能的。 我们需要能够恢复和清理这种失败的块复制/移动活动，它是通过这个过程完成的
CREATE OR REPLACE PROCEDURE timescaledb_experimental.cleanup_copy_chunk_operation(
    operation_id NAME)
AS '$libdir/timescaledb-2.5.0', 'ts_copy_chunk_cleanup_proc' LANGUAGE C;
 

-- 此文件包含用于时间转换的实用程序。
CREATE OR REPLACE FUNCTION _timescaledb_internal.to_unix_microseconds(ts TIMESTAMPTZ) RETURNS BIGINT
    AS '$libdir/timescaledb-2.5.0', 'ts_pg_timestamp_to_unix_microseconds' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.to_timestamp(unixtime_us BIGINT) RETURNS TIMESTAMPTZ
    AS '$libdir/timescaledb-2.5.0', 'ts_pg_unix_microseconds_to_timestamp' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.to_timestamp_without_timezone(unixtime_us BIGINT)
  RETURNS TIMESTAMP
  AS '$libdir/timescaledb-2.5.0', 'ts_pg_unix_microseconds_to_timestamp'
  LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.to_date(unixtime_us BIGINT)
  RETURNS DATE
  AS '$libdir/timescaledb-2.5.0', 'ts_pg_unix_microseconds_to_date'
  LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.to_interval(unixtime_us BIGINT) RETURNS INTERVAL
    AS '$libdir/timescaledb-2.5.0', 'ts_pg_unix_microseconds_to_interval' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

-- 时间可以在超表中表示为 int* (bigint/integer/smallint) 或时间戳类型（带或不带时区）。 在元表和其他内部系统中，所有时间值都存储为 bigint。
-- 从 int* 列转换为内部表示是转换为 bigint。
-- 从时间戳转换为内部表示就是转换为纪元（以微秒为单位）。

-- 获取将给定时间值（在内部表示中）的文字表示为 column_type 的 sql 代码。
CREATE OR REPLACE FUNCTION _timescaledb_internal.time_literal_sql(
    time_value      BIGINT,
    column_type     REGTYPE
)
    RETURNS text LANGUAGE PLPGSQL STABLE AS
$BODY$
DECLARE
    ret text;
BEGIN
    IF time_value IS NULL THEN
        RETURN format('%L', NULL);
    END IF;
    CASE column_type
      WHEN 'BIGINT'::regtype, 'INTEGER'::regtype, 'SMALLINT'::regtype THEN
        RETURN format('%L', time_value); -- scale determined by user.
      WHEN 'TIMESTAMP'::regtype THEN
        --the time_value for timestamps w/o tz does not depend on local timezones. So perform at UTC.
        RETURN format('TIMESTAMP %1$L', timezone('UTC',_timescaledb_internal.to_timestamp(time_value))); -- microseconds
      WHEN 'TIMESTAMPTZ'::regtype THEN
        -- assume time_value is in microsec
        RETURN format('TIMESTAMPTZ %1$L', _timescaledb_internal.to_timestamp(time_value)); -- microseconds
      WHEN 'DATE'::regtype THEN
        RETURN format('%L', timezone('UTC',_timescaledb_internal.to_timestamp(time_value))::date);
      ELSE
         EXECUTE 'SELECT format(''%L'', $1::' || column_type::text || ')' into ret using time_value;
         RETURN ret;
    END CASE;
END
$BODY$;

CREATE OR REPLACE FUNCTION _timescaledb_internal.interval_to_usec(
       chunk_interval INTERVAL
)
RETURNS BIGINT LANGUAGE SQL IMMUTABLE PARALLEL SAFE AS
$BODY$
    SELECT (int_sec * 1000000)::bigint from extract(epoch from chunk_interval) as int_sec;
$BODY$;

CREATE OR REPLACE FUNCTION _timescaledb_internal.time_to_internal(time_val ANYELEMENT)
RETURNS BIGINT AS '$libdir/timescaledb-2.5.0', 'ts_time_to_internal' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.cagg_watermark(hypertable_id INTEGER)
RETURNS INT8 AS '$libdir/timescaledb-2.5.0', 'ts_continuous_agg_watermark' LANGUAGE C STABLE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.subtract_integer_from_now( hypertable_relid REGCLASS, lag INT8 )
RETURNS INT8 AS '$libdir/timescaledb-2.5.0', 'ts_subtract_integer_from_now' LANGUAGE C STABLE STRICT;
 

-- 该文件包含与创建新超表相关的函数。
CREATE OR REPLACE FUNCTION _timescaledb_internal.dimension_is_finite(
    val      BIGINT
)
    RETURNS BOOLEAN LANGUAGE SQL IMMUTABLE PARALLEL SAFE AS
$BODY$
    --为无穷大保留的bigint的结束值
    SELECT val > (-9223372036854775808)::bigint AND val < 9223372036854775807::bigint
$BODY$;


CREATE OR REPLACE FUNCTION _timescaledb_internal.dimension_slice_get_constraint_sql(
    dimension_slice_id  INTEGER
)
    RETURNS TEXT LANGUAGE PLPGSQL VOLATILE AS
$BODY$
DECLARE
    dimension_slice_row _timescaledb_catalog.dimension_slice;
    dimension_row _timescaledb_catalog.dimension;
    dimension_def TEXT;
    dimtype REGTYPE;
    parts TEXT[];
BEGIN
    SELECT * INTO STRICT dimension_slice_row
    FROM _timescaledb_catalog.dimension_slice
    WHERE id = dimension_slice_id;

    SELECT * INTO STRICT dimension_row
    FROM _timescaledb_catalog.dimension
    WHERE id = dimension_slice_row.dimension_id;

    IF dimension_row.partitioning_func_schema IS NOT NULL AND
       dimension_row.partitioning_func IS NOT NULL THEN
        SELECT prorettype INTO STRICT dimtype
        FROM pg_catalog.pg_proc pro
        WHERE pro.oid = format('%I.%I', dimension_row.partitioning_func_schema, dimension_row.partitioning_func)::regproc::oid;

        dimension_def := format('%1$I.%2$I(%3$I)',
             dimension_row.partitioning_func_schema,
             dimension_row.partitioning_func,
             dimension_row.column_name);
    ELSE
        dimension_def := format('%1$I', dimension_row.column_name);
        dimtype := dimension_row.column_type;
    END IF;

    IF dimension_row.num_slices IS NOT NULL THEN

        IF  _timescaledb_internal.dimension_is_finite(dimension_slice_row.range_start) THEN
            parts = parts || format(' %1$s >= %2$L ', dimension_def, dimension_slice_row.range_start);
        END IF;

        IF _timescaledb_internal.dimension_is_finite(dimension_slice_row.range_end) THEN
            parts = parts || format(' %1$s < %2$L ', dimension_def, dimension_slice_row.range_end);
        END IF;

        IF array_length(parts, 1) = 0 THEN
            RETURN NULL;
        END IF;
        return array_to_string(parts, 'AND');
    ELSE
        -- only works with time for now
        IF _timescaledb_internal.time_literal_sql(dimension_slice_row.range_start, dimtype) =
           _timescaledb_internal.time_literal_sql(dimension_slice_row.range_end, dimtype) THEN
            RAISE 'time-based constraints have the same start and end values for column "%": %',
                    dimension_row.column_name,
                    _timescaledb_internal.time_literal_sql(dimension_slice_row.range_end, dimtype);
        END IF;

        parts = ARRAY[]::text[];

        IF _timescaledb_internal.dimension_is_finite(dimension_slice_row.range_start) THEN
            parts = parts || format(' %1$s >= %2$s ',
            dimension_def,
            _timescaledb_internal.time_literal_sql(dimension_slice_row.range_start, dimtype));
        END IF;

        IF _timescaledb_internal.dimension_is_finite(dimension_slice_row.range_end) THEN
            parts = parts || format(' %1$s < %2$s ',
            dimension_def,
            _timescaledb_internal.time_literal_sql(dimension_slice_row.range_end, dimtype));
        END IF;

        return array_to_string(parts, 'AND');
    END IF;
END
$BODY$;

-- 输出 create_hypertable 命令以重新创建给定的超级表。
-- 这目前在我们的单一 hypertable 备份工具内部使用，以便它知道如何在没有用户干预的情况下恢复 hypertable。

-- 它仅适用于最多 2 个维度的超表。
CREATE OR REPLACE FUNCTION _timescaledb_internal.get_create_command(
    table_name NAME
)
    RETURNS TEXT LANGUAGE PLPGSQL VOLATILE AS
$BODY$
DECLARE
    h_id             INTEGER;
    schema_name      NAME;
    time_column      NAME;
    time_interval    BIGINT;
    space_column     NAME;
    space_partitions INTEGER;
    dimension_cnt    INTEGER;
    dimension_row    record;
    ret              TEXT;
BEGIN
    SELECT h.id, h.schema_name
    FROM _timescaledb_catalog.hypertable AS h
    WHERE h.table_name = get_create_command.table_name
    INTO h_id, schema_name;

    IF h_id IS NULL THEN
        RAISE EXCEPTION 'hypertable "%" not found', table_name
        USING ERRCODE = 'TS101';
    END IF;

    SELECT COUNT(*)
    FROM _timescaledb_catalog.dimension d
    WHERE d.hypertable_id = h_id
    INTO STRICT dimension_cnt;

    IF dimension_cnt > 2 THEN
        RAISE EXCEPTION 'get_create_command only supports hypertables with up to 2 dimensions'
        USING ERRCODE = 'TS101';
    END IF;

    FOR dimension_row IN
        SELECT *
        FROM _timescaledb_catalog.dimension d
        WHERE d.hypertable_id = h_id
        LOOP
        IF dimension_row.interval_length IS NOT NULL THEN
            time_column := dimension_row.column_name;
            time_interval := dimension_row.interval_length;
        ELSIF dimension_row.num_slices IS NOT NULL THEN
            space_column := dimension_row.column_name;
            space_partitions := dimension_row.num_slices;
        END IF;
    END LOOP;

    ret := format($$SELECT create_hypertable('%I.%I', '%s'$$, schema_name, table_name, time_column);
    IF space_column IS NOT NULL THEN
        ret := ret || format($$, '%I', %s$$, space_column, space_partitions);
    END IF;
    ret := ret || format($$, chunk_time_interval => %s, create_default_indexes=>FALSE);$$, time_interval);

    RETURN ret;
END
$BODY$;
 
 

-- 基于超表约束对新创建的块创建约束
CREATE OR REPLACE FUNCTION _timescaledb_internal.chunk_constraint_add_table_constraint(
    chunk_constraint_row  _timescaledb_catalog.chunk_constraint
)
    RETURNS VOID LANGUAGE PLPGSQL AS
$BODY$
DECLARE
    chunk_row _timescaledb_catalog.chunk;
    hypertable_row _timescaledb_catalog.hypertable;
    constraint_oid OID;
    constraint_type CHAR;
    check_sql TEXT;
    def TEXT;
    indx_tablespace NAME;
    tablespace_def TEXT;
BEGIN
    SELECT * INTO STRICT chunk_row FROM _timescaledb_catalog.chunk c WHERE c.id = chunk_constraint_row.chunk_id;
    SELECT * INTO STRICT hypertable_row FROM _timescaledb_catalog.hypertable h WHERE h.id = chunk_row.hypertable_id;

    IF chunk_constraint_row.dimension_slice_id IS NOT NULL THEN
        check_sql = _timescaledb_internal.dimension_slice_get_constraint_sql(chunk_constraint_row.dimension_slice_id);
        IF check_sql IS NOT NULL THEN
            def := format('CHECK (%s)',  check_sql);
        ELSE
            def := NULL;
        END IF;
    ELSIF chunk_constraint_row.hypertable_constraint_name IS NOT NULL THEN

        SELECT oid, contype INTO STRICT constraint_oid, constraint_type FROM pg_constraint
        WHERE conname=chunk_constraint_row.hypertable_constraint_name AND
              conrelid = format('%I.%I', hypertable_row.schema_name, hypertable_row.table_name)::regclass::oid;

        IF constraint_type IN ('p','u') THEN
          -- 由于主键和唯一约束由索引支持，因此它们可能有一个索引表空间，分配的表空间不是约束定义的一部分，因此我们必须显式附加它以保留它
          SELECT T.spcname INTO indx_tablespace
          FROM pg_constraint C, pg_class I, pg_tablespace T
          WHERE C.oid = constraint_oid AND C.contype IN ('p', 'u') AND I.oid = C.conindid AND I.reltablespace = T.oid;

          def := pg_get_constraintdef(constraint_oid);

          IF indx_tablespace IS NOT NULL THEN
            def := format('%s USING INDEX TABLESPACE %I', def, indx_tablespace);
          END IF;

        ELSIF constraint_type = 't' THEN
          -- 约束触发器与普通触发器分开复制
          def := NULL;
        ELSE
          def := pg_get_constraintdef(constraint_oid);
        END IF;

    ELSE
        RAISE 'unknown constraint type';
    END IF;

    IF def IS NOT NULL THEN
        EXECUTE format(
            $$ ALTER TABLE %I.%I ADD CONSTRAINT %I %s $$,
            chunk_row.schema_name, chunk_row.table_name, chunk_constraint_row.constraint_name, def
        );
    END IF;
END
$BODY$;
 
 
 

-- 从超表克隆 fk 约束
CREATE OR REPLACE FUNCTION _timescaledb_internal.hypertable_constraint_add_table_fk_constraint(
    user_ht_constraint_name NAME,
    user_ht_schema_name NAME,
    user_ht_table_name NAME,
    compress_ht_id INTEGER
)
    RETURNS VOID LANGUAGE PLPGSQL AS
$BODY$
DECLARE
    compressed_ht_row _timescaledb_catalog.hypertable;
    constraint_oid OID;
    check_sql TEXT;
    def TEXT;
BEGIN
    SELECT * INTO STRICT compressed_ht_row FROM _timescaledb_catalog.hypertable h
    WHERE h.id = compress_ht_id;
    IF user_ht_constraint_name IS NOT NULL THEN
        SELECT oid INTO STRICT constraint_oid FROM pg_constraint
        WHERE conname=user_ht_constraint_name AND contype = 'f' AND
              conrelid = format('%I.%I', user_ht_schema_name, user_ht_table_name)::regclass::oid;
        def := pg_get_constraintdef(constraint_oid);
    ELSE
        RAISE 'unknown constraint type';
    END IF;
    IF def IS NOT NULL THEN
        EXECUTE format(
            $$ ALTER TABLE %I.%I ADD CONSTRAINT %I %s $$,
            compressed_ht_row.schema_name, compressed_ht_row.table_name, user_ht_constraint_name, def
        );
    END IF;

END
$BODY$;
 
 
 

-- 不推荐使用的分区哈希函数
CREATE OR REPLACE FUNCTION _timescaledb_internal.get_partition_for_key(val anyelement)
    RETURNS int
    AS '$libdir/timescaledb-2.5.0', 'ts_get_partition_for_key' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.get_partition_hash(val anyelement)
    RETURNS int
    AS '$libdir/timescaledb-2.5.0', 'ts_get_partition_hash' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.get_time_type(hypertable_id INTEGER)
    RETURNS OID
    AS '$libdir/timescaledb-2.5.0', 'ts_hypertable_get_time_type' LANGUAGE C STABLE STRICT;
 
 
 

-- 此文件包含与获取有关超表模式的信息（包括列、它们的类型等）相关的函数。


-- 检查给定的表 OID 是否是超级表的主表（即用户执行 SQL 操作的目标表）
CREATE OR REPLACE FUNCTION _timescaledb_internal.is_main_table(
    table_oid regclass
)
    RETURNS bool LANGUAGE SQL STABLE AS
$BODY$
    SELECT EXISTS(SELECT 1 FROM _timescaledb_catalog.hypertable WHERE table_name = relname AND schema_name = nspname)
    FROM pg_class c
    INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
    WHERE c.OID = table_oid;
$BODY$;

-- 检查给定的表是否是超表的主表
CREATE OR REPLACE FUNCTION _timescaledb_internal.is_main_table(
    schema_name NAME,
    table_name  NAME
)
    RETURNS BOOLEAN LANGUAGE SQL STABLE AS
$BODY$
     SELECT EXISTS(
         SELECT 1 FROM _timescaledb_catalog.hypertable h
         WHERE h.schema_name = is_main_table.schema_name AND 
               h.table_name = is_main_table.table_name
     );
$BODY$;

-- 获取给定主表 OID 的超表
CREATE OR REPLACE FUNCTION _timescaledb_internal.hypertable_from_main_table(
    table_oid regclass
)
    RETURNS _timescaledb_catalog.hypertable LANGUAGE SQL STABLE AS
$BODY$
    SELECT h.*
    FROM pg_class c
    INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
    INNER JOIN _timescaledb_catalog.hypertable h ON (h.table_name = c.relname AND h.schema_name = n.nspname)
    WHERE c.OID = table_oid;
$BODY$;

CREATE OR REPLACE FUNCTION _timescaledb_internal.main_table_from_hypertable(
    hypertable_id int
)
    RETURNS regclass LANGUAGE SQL STABLE AS
$BODY$
    SELECT format('%I.%I',h.schema_name, h.table_name)::regclass
    FROM _timescaledb_catalog.hypertable h
    WHERE id = hypertable_id;
$BODY$;
 
 
 

-- 该文件定义了用于添加和操作超表的 DDL 函数。

-- 将常规 postgres 表转换为超表。

--relation-要转换的表的OID
-- time_column_name - 包含给定记录时间的列的名称
-- partitioning_column - 用于对数据进行分区的列的名称
-- number_partitions -（可选）数据的分区数
-- associated_schema_name -（可选）内部超表的模式
-- associated_table_prefix -（可选）内部超表表名的前缀
-- chunk_time_interval - （可选）块的初始时间间隔
-- create_default_indexes - （可选）是否创建默认索引
-- if_not_exists - （可选）如果表已经是超表，则不要失败
-- partitioning_func - （可选）用于空间分区的分区函数
-- migrate_data - （可选）设置为 true 以将表中的任何现有数据迁移到块
-- chunk_target_size - （可选）块的目标大小（例如，'1000MB'、'estimate' 或 'off'）
-- chunk_sizing_func - （可选）计算新块的块时间间隔的函数
-- time_partitioning_func - （可选）用于“时间”分区的分区函数
-- replication_factor - (可选) 1 或更大的值使这个超表分布式
-- data_nodes -（可选）用于分发此超表的特定数据节点
CREATE OR REPLACE FUNCTION  create_hypertable(
    relation                REGCLASS,
    time_column_name        NAME,
    partitioning_column     NAME = NULL,
    number_partitions       INTEGER = NULL,
    associated_schema_name  NAME = NULL,
    associated_table_prefix NAME = NULL,
    chunk_time_interval     ANYELEMENT = NULL::bigint,
    create_default_indexes  BOOLEAN = TRUE,
    if_not_exists           BOOLEAN = FALSE,
    partitioning_func       REGPROC = NULL,
    migrate_data            BOOLEAN = FALSE,
    chunk_target_size       TEXT = NULL,
    chunk_sizing_func       REGPROC = '_timescaledb_internal.calculate_chunk_interval'::regproc,
    time_partitioning_func  REGPROC = NULL,
    replication_factor      INTEGER = NULL,
    data_nodes              NAME[] = NULL
) RETURNS TABLE(hypertable_id INT, schema_name NAME, table_name NAME, created BOOL) AS '$libdir/timescaledb-2.5.0', 'ts_hypertable_create' LANGUAGE C VOLATILE;

-- 与 create_hypertable 功能相同，只需复制因子 > 0（默认为 1）
CREATE OR REPLACE FUNCTION  create_distributed_hypertable(
    relation                REGCLASS,
    time_column_name        NAME,
    partitioning_column     NAME = NULL,
    number_partitions       INTEGER = NULL,
    associated_schema_name  NAME = NULL,
    associated_table_prefix NAME = NULL,
    chunk_time_interval     ANYELEMENT = NULL::bigint,
    create_default_indexes  BOOLEAN = TRUE,
    if_not_exists           BOOLEAN = FALSE,
    partitioning_func       REGPROC = NULL,
    migrate_data            BOOLEAN = FALSE,
    chunk_target_size       TEXT = NULL,
    chunk_sizing_func       REGPROC = '_timescaledb_internal.calculate_chunk_interval'::regproc,
    time_partitioning_func  REGPROC = NULL,
    replication_factor      INTEGER = 1,
    data_nodes              NAME[] = NULL
) RETURNS TABLE(hypertable_id INT, schema_name NAME, table_name NAME, created BOOL) AS '$libdir/timescaledb-2.5.0', 'ts_hypertable_distributed_create' LANGUAGE C VOLATILE;

-- 设置自适应分块。 要禁用，请设置 chunk_target_size => 'off'。
CREATE OR REPLACE FUNCTION  set_adaptive_chunking(
    hypertable                     REGCLASS,
    chunk_target_size              TEXT,
    INOUT chunk_sizing_func        REGPROC = '_timescaledb_internal.calculate_chunk_interval'::regproc,
    OUT chunk_target_size          BIGINT
) RETURNS RECORD AS '$libdir/timescaledb-2.5.0', 'ts_chunk_adaptive_set' LANGUAGE C VOLATILE;

-- 更新超表的 chunk_time_interval。

-- hypertable - 应更新时间间隔的超表对应的表的 OID
-- chunk_time_interval - 新的时间间隔。 对于具有整数时间列的超表，这必须是整数类型。 对于具有 TIMESTAMP/TIMESTAMPTZ/DATE 类型的超级表，它可以是被视为微秒的整数，也可以是 INTERVAL 类型。
CREATE OR REPLACE FUNCTION  set_chunk_time_interval(
    hypertable              REGCLASS,
    chunk_time_interval     ANYELEMENT,
    dimension_name          NAME = NULL
) RETURNS VOID AS '$libdir/timescaledb-2.5.0', 'ts_dimension_set_interval' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION  set_number_partitions(
    hypertable              REGCLASS,
    number_partitions       INTEGER,
    dimension_name          NAME = NULL
) RETURNS VOID AS '$libdir/timescaledb-2.5.0', 'ts_dimension_set_num_slices' LANGUAGE C VOLATILE;

-- 删除比特定超表或连续聚合的给定时间戳更旧的块。
CREATE OR REPLACE FUNCTION drop_chunks(
    relation               REGCLASS,
    older_than             "any" = NULL,
    newer_than             "any" = NULL,
    verbose                BOOLEAN = FALSE
) RETURNS SETOF TEXT AS '$libdir/timescaledb-2.5.0', 'ts_chunk_drop_chunks'
LANGUAGE C VOLATILE PARALLEL UNSAFE;

-- 显示早于或晚于特定时间的块。
-- `relation` 必须是有效的超表或连续聚合。
CREATE OR REPLACE FUNCTION show_chunks(
    relation               REGCLASS,
    older_than             "any" = NULL,
    newer_than             "any" = NULL
) RETURNS SETOF REGCLASS AS '$libdir/timescaledb-2.5.0', 'ts_chunk_show_chunks'
LANGUAGE C STABLE PARALLEL SAFE;

-- 向超表添加维度（分区）
-- hypertable - 要添加维度的表的 OID
-- column_name - 用于此维度分区的列的名称
-- number_partitions - 非时间维度的分区数
-- interval_length - 时间维度的间隔大小（可以是整数或间隔）
-- partitioning_func - 用于对列进行分区的函数
-- if_not_exists - 如果设置，并且维度已经存在，则生成通知而不是错误
CREATE OR REPLACE FUNCTION  add_dimension(
    hypertable              REGCLASS,
    column_name             NAME,
    number_partitions       INTEGER = NULL,
    chunk_time_interval     ANYELEMENT = NULL::BIGINT,
    partitioning_func       REGPROC = NULL,
    if_not_exists           BOOLEAN = FALSE
) RETURNS TABLE(dimension_id INT, schema_name NAME, table_name NAME, column_name NAME, created BOOL)
AS '$libdir/timescaledb-2.5.0', 'ts_dimension_add' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION attach_tablespace(
    tablespace NAME,
    hypertable REGCLASS,
    if_not_attached BOOLEAN = false
) RETURNS VOID
AS '$libdir/timescaledb-2.5.0', 'ts_tablespace_attach' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION detach_tablespace(
    tablespace NAME,
    hypertable REGCLASS = NULL,
    if_attached BOOLEAN = false
) RETURNS INTEGER
AS '$libdir/timescaledb-2.5.0', 'ts_tablespace_detach' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION detach_tablespaces(hypertable REGCLASS) RETURNS INTEGER
AS '$libdir/timescaledb-2.5.0', 'ts_tablespace_detach_all_from_hypertable' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION show_tablespaces(hypertable REGCLASS) RETURNS SETOF NAME
AS '$libdir/timescaledb-2.5.0', 'ts_tablespace_show' LANGUAGE C VOLATILE STRICT;

-- 向TimescaleDB分布式数据库添加数据节点。
CREATE OR REPLACE FUNCTION add_data_node(
    node_name              NAME,
    host                   TEXT,
    database               NAME = NULL,
    port                   INTEGER = NULL,
    if_not_exists          BOOLEAN = FALSE,
    bootstrap              BOOLEAN = TRUE,
    password               TEXT = NULL
) RETURNS TABLE(node_name NAME, host TEXT, port INTEGER, database NAME,
                node_created BOOL, database_created BOOL, extension_created BOOL)
AS '$libdir/timescaledb-2.5.0', 'ts_data_node_add' LANGUAGE C VOLATILE;

-- Delete a data node from a distributed database
CREATE OR REPLACE FUNCTION delete_data_node(
    node_name              NAME,
    if_exists              BOOLEAN = FALSE,
    force                  BOOLEAN = FALSE,
    repartition            BOOLEAN = TRUE
) RETURNS BOOLEAN AS '$libdir/timescaledb-2.5.0', 'ts_data_node_delete' LANGUAGE C VOLATILE;

-- Attach a data node to a distributed hypertable
CREATE OR REPLACE FUNCTION attach_data_node(
    node_name              NAME,
    hypertable             REGCLASS,
    if_not_attached        BOOLEAN = FALSE,
    repartition            BOOLEAN = TRUE
) RETURNS TABLE(hypertable_id INTEGER, node_hypertable_id INTEGER, node_name NAME)
AS '$libdir/timescaledb-2.5.0', 'ts_data_node_attach' LANGUAGE C VOLATILE;

-- Detach a data node from a distributed hypertable. NULL hypertable means it will detach from all distributed hypertables
CREATE OR REPLACE FUNCTION detach_data_node(
    node_name              NAME,
    hypertable             REGCLASS = NULL,
    if_attached            BOOLEAN = FALSE,
    force                  BOOLEAN = FALSE,
    repartition            BOOLEAN = TRUE
) RETURNS INTEGER
AS '$libdir/timescaledb-2.5.0', 'ts_data_node_detach' LANGUAGE C VOLATILE;

-- 对指定的数据节点列表执行查询。 默认情况下 node_list 为 NULL，表示在每个数据节点上执行查询
CREATE OR REPLACE PROCEDURE distributed_exec(
       query TEXT,
       node_list name[] = NULL,
       transactional BOOLEAN = TRUE)
AS '$libdir/timescaledb-2.5.0', 'ts_distributed_exec' LANGUAGE C;

-- Execute pg_create_restore_point() on each data node
CREATE OR REPLACE FUNCTION create_distributed_restore_point(
    name                   TEXT
) RETURNS TABLE(node_name NAME, node_type TEXT, restore_point pg_lsn)
AS '$libdir/timescaledb-2.5.0', 'ts_create_distributed_restore_point' LANGUAGE C VOLATILE STRICT;

-- Sets new replication factor for distributed hypertable
CREATE OR REPLACE FUNCTION  set_replication_factor(
    hypertable              REGCLASS,
    replication_factor      INTEGER
) RETURNS VOID
AS '$libdir/timescaledb-2.5.0', 'ts_hypertable_distributed_set_replication_factor' LANGUAGE C VOLATILE;

-- 在给定窗口刷新连续聚合。
CREATE OR REPLACE PROCEDURE refresh_continuous_aggregate(
    continuous_aggregate     REGCLASS,
    window_start             "any",
    window_end               "any"
) LANGUAGE C AS '$libdir/timescaledb-2.5.0', 'ts_continuous_agg_refresh';
 
 
 

DROP EVENT TRIGGER IF EXISTS timescaledb_ddl_command_end;

CREATE OR REPLACE FUNCTION _timescaledb_internal.process_ddl_event() RETURNS event_trigger
AS '$libdir/timescaledb-2.5.0', 'ts_timescaledb_process_ddl_event' LANGUAGE C;

--EVENT TRIGGER 必须排除 ALTER EXTENSION 标签。
CREATE EVENT TRIGGER timescaledb_ddl_command_end ON ddl_command_end
WHEN TAG IN ('ALTER TABLE','CREATE TRIGGER','CREATE TABLE','CREATE INDEX','ALTER INDEX', 'DROP TABLE', 'DROP INDEX', 'DROP SCHEMA')
EXECUTE FUNCTION _timescaledb_internal.process_ddl_event();

DROP EVENT TRIGGER IF EXISTS timescaledb_ddl_sql_drop;
CREATE EVENT TRIGGER timescaledb_ddl_sql_drop ON sql_drop
EXECUTE FUNCTION _timescaledb_internal.process_ddl_event();
 
 
 

CREATE OR REPLACE FUNCTION _timescaledb_internal.first_sfunc(internal, anyelement, "any")
RETURNS internal
AS '$libdir/timescaledb-2.5.0', 'ts_first_sfunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.first_combinefunc(internal, internal)
RETURNS internal
AS '$libdir/timescaledb-2.5.0', 'ts_first_combinefunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.last_sfunc(internal, anyelement, "any")
RETURNS internal
AS '$libdir/timescaledb-2.5.0', 'ts_last_sfunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.last_combinefunc(internal, internal)
RETURNS internal
AS '$libdir/timescaledb-2.5.0', 'ts_last_combinefunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.bookend_finalfunc(internal, anyelement, "any")
RETURNS anyelement
AS '$libdir/timescaledb-2.5.0', 'ts_bookend_finalfunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.bookend_serializefunc(internal)
RETURNS bytea
AS '$libdir/timescaledb-2.5.0', 'ts_bookend_serializefunc'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.bookend_deserializefunc(bytea, internal)
RETURNS internal
AS '$libdir/timescaledb-2.5.0', 'ts_bookend_deserializefunc'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;


-- 一旦完全支持语法，我们就开始使用 CREATE OR REPLACE AGGREGATE 进行聚合创建，因为这样更容易支持幂等更改。 这将允许更改支持聚合的函数，例如，定义和包含用于窗口函数支持的反函数。 但是，仍然应该注意，用于聚合内部状态的数据结构的更改必须向后兼容，并且任何新函数都必须接受旧格式，以便它们继续使用连续聚合，其中旧状态可能已经materialized。

-- 当按第二个参数排序时，此聚合返回第一个参数的“第一个”值。
-- EX. first(temp, time) 返回时间最短的行的临时值
CREATE OR REPLACE AGGREGATE first(anyelement, "any") (
    SFUNC = _timescaledb_internal.first_sfunc,
    STYPE = internal,
    COMBINEFUNC = _timescaledb_internal.first_combinefunc,
    SERIALFUNC = _timescaledb_internal.bookend_serializefunc,
    DESERIALFUNC = _timescaledb_internal.bookend_deserializefunc,
    PARALLEL = SAFE,
    FINALFUNC = _timescaledb_internal.bookend_finalfunc,
    FINALFUNC_EXTRA
);

-- 当按第二个参数排序时，此聚合返回第一个参数的“最后”值。
-- EX。 last(temp, time) 返回时间最长的行的临时值
CREATE OR REPLACE AGGREGATE last(anyelement, "any") (
    SFUNC = _timescaledb_internal.last_sfunc,
    STYPE = internal,
    COMBINEFUNC = _timescaledb_internal.last_combinefunc,
    SERIALFUNC = _timescaledb_internal.bookend_serializefunc,
    DESERIALFUNC = _timescaledb_internal.bookend_deserializefunc,
    PARALLEL = SAFE,
    FINALFUNC = _timescaledb_internal.bookend_finalfunc,
    FINALFUNC_EXTRA
);
 
 
 

-- time_bucket 返回 ts 落入的桶的左边缘。
-- 桶跨越的时间间隔等于 bucket_width 并与纪元对齐。
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts TIMESTAMP) RETURNS TIMESTAMP
	AS '$libdir/timescaledb-2.5.0', 'ts_timestamp_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

--timestamptz 的分桶发生在 UTC 时间
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts TIMESTAMPTZ) RETURNS TIMESTAMPTZ
	AS '$libdir/timescaledb-2.5.0', 'ts_timestamptz_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

--bucketing on date 不应该做任何时区转换
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts DATE) RETURNS DATE
	AS '$libdir/timescaledb-2.5.0', 'ts_date_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

--bucketing with origin
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts TIMESTAMP, origin TIMESTAMP) RETURNS TIMESTAMP
	AS '$libdir/timescaledb-2.5.0', 'ts_timestamp_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts TIMESTAMPTZ, origin TIMESTAMPTZ) RETURNS TIMESTAMPTZ
	AS '$libdir/timescaledb-2.5.0', 'ts_timestamptz_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts DATE, origin DATE) RETURNS DATE
	AS '$libdir/timescaledb-2.5.0', 'ts_date_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

-- bucketing of int
CREATE OR REPLACE FUNCTION time_bucket(bucket_width SMALLINT, ts SMALLINT) RETURNS SMALLINT
	AS '$libdir/timescaledb-2.5.0', 'ts_int16_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INT, ts INT) RETURNS INT
	AS '$libdir/timescaledb-2.5.0', 'ts_int32_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE OR REPLACE FUNCTION time_bucket(bucket_width BIGINT, ts BIGINT) RETURNS BIGINT
	AS '$libdir/timescaledb-2.5.0', 'ts_int64_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

-- bucketing of int with offset
CREATE OR REPLACE FUNCTION time_bucket(bucket_width SMALLINT, ts SMALLINT, "offset" SMALLINT) RETURNS SMALLINT
	AS '$libdir/timescaledb-2.5.0', 'ts_int16_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INT, ts INT, "offset" INT) RETURNS INT
	AS '$libdir/timescaledb-2.5.0', 'ts_int32_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE OR REPLACE FUNCTION time_bucket(bucket_width BIGINT, ts BIGINT, "offset" BIGINT) RETURNS BIGINT
	AS '$libdir/timescaledb-2.5.0', 'ts_int64_bucket' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

-- 如果将区间作为第三个参数给出，则桶对齐会被区间偏移。
CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts TIMESTAMP, "offset" INTERVAL)
    RETURNS TIMESTAMP LANGUAGE SQL IMMUTABLE PARALLEL SAFE STRICT AS
$BODY$
    SELECT @extschema@.time_bucket(bucket_width, ts-"offset")+"offset";
$BODY$;

CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts TIMESTAMPTZ, "offset" INTERVAL)
    RETURNS TIMESTAMPTZ LANGUAGE SQL IMMUTABLE PARALLEL SAFE STRICT AS
$BODY$
    SELECT @extschema@.time_bucket(bucket_width, ts-"offset")+"offset";
$BODY$;

CREATE OR REPLACE FUNCTION time_bucket(bucket_width INTERVAL, ts DATE, "offset" INTERVAL)
    RETURNS DATE LANGUAGE SQL IMMUTABLE PARALLEL SAFE STRICT AS
$BODY$
    SELECT (@extschema@.time_bucket(bucket_width, ts-"offset")+"offset")::date;
$BODY$;

 
 
 

-- time_bucket_ng() 是 time_bucket() 的 _experimental_ 新版本。
-- 与 time_bucket() 不同，time_bucket_ng() 支持可变大小的桶，例如月份和年份，以及时区。请注意，此功能的行为和界面可能会发生变化。可能存在错误，并且实现并不声称是完整的。使用风险自负。
-- 此函数可能会根据本地时区数据库的版本对相同的参数返回不同的结果。尽管如此，函数仍被标记为 IMMUTABLE。这与 PostgreSQL 提供的函数的易变性 [1] 是一致的。有关更多详细信息，请参阅讨论 [2]。
-- 我们不会禁止用户在未来使用时间戳记，也不会对这种极端情况发出警告。此行为与 PostgreSQL 行为一致 [3]。
-- [1]: https://www.postgresql.org/docs/current/xfunc-volatility.html
-- [2]: https://postgr.es/m/CAJ7c6TOMG8zSNEZtCn5SPe+cCk3Lfxb71ZaQwT2F4T7PJ_t=KA@mail.gmail.com
-- [3]: https://www.postgresql.org/docs/current/datatype-datetime.html#DATATYPE-TIMEZONES

-- time_bucket_ng() 的 DATE 版本。
CREATE OR REPLACE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts DATE) RETURNS DATE
    AS '$libdir/timescaledb-2.5.0', 'ts_time_bucket_ng_date' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts DATE, origin DATE) RETURNS DATE
    AS '$libdir/timescaledb-2.5.0', 'ts_time_bucket_ng_date' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

-- time_bucket_ng() 的时间戳版本。
CREATE OR REPLACE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMP) RETURNS TIMESTAMP
    AS '$libdir/timescaledb-2.5.0', 'ts_time_bucket_ng_timestamp' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMP, origin TIMESTAMP) RETURNS TIMESTAMP
    AS '$libdir/timescaledb-2.5.0', 'ts_time_bucket_ng_timestamp' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;

-- time_bucket_ng() 的 TIMESTAMPTZ 版本。
CREATE OR REPLACE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMPTZ, timezone TEXT) RETURNS TIMESTAMPTZ
    AS '$libdir/timescaledb-2.5.0', 'ts_time_bucket_ng_timezone' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;
CREATE OR REPLACE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMPTZ, origin TIMESTAMPTZ, timezone TEXT) RETURNS TIMESTAMPTZ
    AS '$libdir/timescaledb-2.5.0', 'ts_time_bucket_ng_timezone_origin' LANGUAGE C IMMUTABLE PARALLEL SAFE STRICT;


-- 保留以下两个版本的 time_bucket_ng() 只是为了与 time_bucket() 向后兼容。 他们将 'ts' 转换为 UTC 而不是在给定的时区中处理它，这几乎肯定不是您想要的。
-- 未来的版本可能会警告你这个事实，并最终被完全删除。

-- 这些函数是稳定的，因为它们的实现依赖于稳定的函数 timestamptz_date()。 最新的是 STABLE，因为它考虑了会话参数。
CREATE OR REPLACE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMPTZ) RETURNS TIMESTAMPTZ
    AS '$libdir/timescaledb-2.5.0', 'ts_time_bucket_ng_timestamptz' LANGUAGE C STABLE PARALLEL SAFE STRICT;

CREATE OR REPLACE FUNCTION timescaledb_experimental.time_bucket_ng(bucket_width INTERVAL, ts TIMESTAMPTZ, origin TIMESTAMPTZ) RETURNS TIMESTAMPTZ
    AS '$libdir/timescaledb-2.5.0', 'ts_time_bucket_ng_timestamptz' LANGUAGE C STABLE PARALLEL SAFE STRICT;
 
 
 

CREATE OR REPLACE FUNCTION _timescaledb_internal.get_git_commit()
    RETURNS TABLE(commit_tag TEXT, commit_hash TEXT, commit_time TIMESTAMPTZ)
    AS '$libdir/timescaledb-2.5.0', 'ts_get_git_commit' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.get_os_info()
    RETURNS TABLE(sysname TEXT, version TEXT, release TEXT, version_pretty TEXT)
    AS '$libdir/timescaledb-2.5.0', 'ts_get_os_info' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION get_telemetry_report(always_display_report boolean DEFAULT false) RETURNS TEXT
    AS '$libdir/timescaledb-2.5.0', 'ts_get_telemetry_report' LANGUAGE C STABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.tsl_loaded() RETURNS BOOLEAN
AS '$libdir/timescaledb-2.5.0', 'ts_tsl_loaded' LANGUAGE C;
 
 
 

-- 该文件包含用于获取超表、块和超表索引的关系大小的实用函数。

CREATE OR REPLACE VIEW _timescaledb_internal.hypertable_chunk_local_size AS 
SELECT *, 
   compressed_total_size - COALESCE(compressed_index_size, 0) - COALESCE(compressed_toast_size, 0) as compressed_heap_size
FROM
( SELECT
   h.schema_name AS hypertable_schema,
   h.table_name AS hypertable_name,
   h.id as hypertable_id,
   c.id as chunk_id,
   c.schema_name as chunk_schema,
   c.table_name as chunk_name,
   pg_total_relation_size(format('%I.%I', c.schema_name, c.table_name))::bigint AS total_bytes,
   pg_indexes_size(format('%I.%I', c.schema_name, c.table_name))::bigint AS index_bytes,
   pg_total_relation_size(pgc.reltoastrelid)::bigint AS toast_bytes,
   CASE WHEN map.table_name IS NOT NULL 
        THEN pg_total_relation_size(format('%I.%I', map.schema_name, map.table_name))::bigint 
        ELSE 0
   END AS compressed_total_size,
   CASE WHEN map.table_name IS NOT NULL 
        THEN pg_indexes_size(format('%I.%I', map.schema_name, map.table_name))::bigint 
        ELSE 0
   END AS compressed_index_size,
   CASE WHEN map.reltoastrelid IS NOT NULL 
        THEN pg_total_relation_size(map.reltoastrelid)::bigint 
        ELSE 0
   END AS compressed_toast_size
FROM
   _timescaledb_catalog.hypertable h 
   INNER JOIN
      _timescaledb_catalog.chunk c 
      ON h.id = c.hypertable_id 
      and c.dropped = false 
   INNER JOIN
      pg_class pgc 
      ON pgc.relname = c.table_name 
   INNER JOIN
      pg_namespace pns 
      ON pns.oid = pgc.relnamespace 
      AND pns.nspname = c.schema_name 
   LEFT OUTER JOIN
      ( SELECT comp.id, comp.schema_name, comp.table_name, reltoastrelid
        FROM _timescaledb_catalog.chunk comp, pg_class, pg_namespace
        WHERE comp.table_name = pg_class.relname
        AND comp.schema_name = pg_namespace.nspname
        AND pg_namespace.oid = pg_class.relnamespace ) map
  ON map.id = c.compressed_chunk_id ) subq;

GRANT SELECT ON  _timescaledb_internal.hypertable_chunk_local_size TO PUBLIC;
 
CREATE OR REPLACE FUNCTION _timescaledb_internal.data_node_hypertable_info(
    node_name              NAME,
    schema_name_in name,
    table_name_in name
)
RETURNS TABLE (
    table_bytes     bigint,
    index_bytes     bigint,
    toast_bytes     bigint,
    total_bytes     bigint)
AS '$libdir/timescaledb-2.5.0', 'ts_dist_remote_hypertable_info' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.data_node_chunk_info(
    node_name              NAME,
    schema_name_in name,
    table_name_in name
)
RETURNS TABLE (
    chunk_id        integer,
    chunk_schema    name,
    chunk_name      name,
    table_bytes     bigint,
    index_bytes     bigint,
    toast_bytes     bigint,
    total_bytes     bigint)
AS '$libdir/timescaledb-2.5.0', 'ts_dist_remote_chunk_info' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.hypertable_local_size(
	schema_name_in name,
	table_name_in name)
RETURNS TABLE (
	table_bytes bigint,
	index_bytes bigint,
	toast_bytes bigint,
	total_bytes bigint)
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
	SELECT
		(COALESCE(sum(ch.total_bytes), 0) - COALESCE(sum(ch.index_bytes), 0) - COALESCE(sum(ch.toast_bytes), 0) + COALESCE(sum(ch.compressed_heap_size), 0))::bigint + pg_relation_size(format('%I.%I', schema_name_in, table_name_in)::regclass)::bigint AS heap_bytes,
		(COALESCE(sum(ch.index_bytes), 0) + COALESCE(sum(ch.compressed_index_size), 0))::bigint + pg_indexes_size(format('%I.%I', schema_name_in, table_name_in)::regclass)::bigint AS index_bytes,
		(COALESCE(sum(ch.toast_bytes), 0) + COALESCE(sum(ch.compressed_toast_size), 0))::bigint AS toast_bytes,
		(COALESCE(sum(ch.total_bytes), 0) + COALESCE(sum(ch.compressed_total_size), 0))::bigint + pg_total_relation_size(format('%I.%I', schema_name_in, table_name_in)::regclass)::bigint AS total_bytes
	FROM
		_timescaledb_internal.hypertable_chunk_local_size ch
	WHERE
		hypertable_schema = schema_name_in
		AND hypertable_name = table_name_in
$BODY$;

CREATE OR REPLACE FUNCTION _timescaledb_internal.hypertable_remote_size(
    schema_name_in name,
    table_name_in name)
RETURNS TABLE (
    table_bytes bigint,
    index_bytes bigint,
    toast_bytes bigint,
    total_bytes bigint,
    node_name   NAME)
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
    SELECT
        sum(entry.table_bytes)::bigint AS table_bytes,
        sum(entry.index_bytes)::bigint AS index_bytes,
        sum(entry.toast_bytes)::bigint AS toast_bytes,
        sum(entry.total_bytes)::bigint AS total_bytes,
        srv.node_name
    FROM (
        SELECT
            s.node_name,
            _timescaledb_internal.ping_data_node (s.node_name) AS node_up
        FROM
            _timescaledb_catalog.hypertable AS ht,
            _timescaledb_catalog.hypertable_data_node AS s
        WHERE
            ht.schema_name = schema_name_in
            AND ht.table_name = table_name_in
            AND s.hypertable_id = ht.id
         ) AS srv
    LEFT OUTER JOIN LATERAL _timescaledb_internal.data_node_hypertable_info(
    CASE WHEN srv.node_up THEN
        srv.node_name
    ELSE
        NULL
    END, schema_name_in, table_name_in) entry ON TRUE
    GROUP BY srv.node_name;
$BODY$;

-- 获取超表的关系大小
-- 像 pg_relation_size(hypertable)
-- hypertable - hypertable 获取大小

-- Return：
-- table_bytes - hypertable 使用的磁盘空间（如 pg_relation_size(hypertable)）
-- index_bytes - 索引使用的磁盘空间
-- toast_bytes - toast 表的磁盘空间
-- total_bytes - 指定表使用的总磁盘空间，包括所有索引和 TOAST 数据

CREATE OR REPLACE FUNCTION hypertable_detailed_size(
    hypertable              REGCLASS)
RETURNS TABLE (table_bytes BIGINT,
               index_bytes BIGINT,
               toast_bytes BIGINT,
               total_bytes BIGINT,
               node_name   NAME)
LANGUAGE PLPGSQL VOLATILE STRICT AS
$BODY$
DECLARE
        table_name       NAME = NULL;
        schema_name      NAME = NULL;
        is_distributed   BOOL = FALSE;
BEGIN
        SELECT relname, nspname, replication_factor > 0
        INTO table_name, schema_name, is_distributed
        FROM pg_class c
        INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
        INNER JOIN _timescaledb_catalog.hypertable ht ON (ht.schema_name = n.nspname AND ht.table_name = c.relname)
        WHERE c.OID = hypertable;

		IF table_name IS NULL THEN
		    RETURN;
		END IF;

        CASE WHEN is_distributed THEN
			RETURN QUERY
			SELECT *, NULL::name
			FROM _timescaledb_internal.hypertable_local_size(schema_name, table_name)
			UNION
			SELECT *
			FROM _timescaledb_internal.hypertable_remote_size(schema_name, table_name);
        ELSE
			RETURN QUERY
			SELECT *, NULL::name
			FROM _timescaledb_internal.hypertable_local_size(schema_name, table_name);
        END CASE;
END;
$BODY$;

--- 返回超级表的总字节数（包括表 + 索引）
CREATE OR REPLACE FUNCTION hypertable_size(
    hypertable              REGCLASS)
RETURNS BIGINT 
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
   -- 每个数据节点返回一行（在分布式超表的情况下），因此总结一下：
   SELECT sum(total_bytes)::bigint
   FROM hypertable_detailed_size(hypertable);
$BODY$;

CREATE OR REPLACE FUNCTION _timescaledb_internal.chunks_local_size(
    schema_name_in name,
    table_name_in name)
RETURNS TABLE (
    chunk_id    integer,
    chunk_schema NAME,
    chunk_name  NAME,
    table_bytes bigint,
    index_bytes bigint,
    toast_bytes bigint,
    total_bytes bigint)
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
   SELECT
      ch.chunk_id,
      ch.chunk_schema,
      ch.chunk_name,
      (ch.total_bytes - COALESCE( ch.index_bytes , 0 ) - COALESCE( ch.toast_bytes, 0 ) + COALESCE( ch.compressed_heap_size , 0 ))::bigint  as heap_bytes,
      (COALESCE( ch.index_bytes, 0 ) + COALESCE( ch.compressed_index_size , 0) )::bigint as index_bytes,
      (COALESCE( ch.toast_bytes, 0 ) + COALESCE( ch.compressed_toast_size, 0 ))::bigint as toast_bytes,
      (ch.total_bytes + COALESCE( ch.compressed_total_size, 0 ))::bigint as total_bytes 
   FROM
	  _timescaledb_internal.hypertable_chunk_local_size ch
   WHERE
      ch.hypertable_schema = schema_name_in
      AND ch.hypertable_name = table_name_in;
$BODY$;

---should return same information as chunks_local_size--
CREATE OR REPLACE FUNCTION _timescaledb_internal.chunks_remote_size(
    schema_name_in name,
    table_name_in name)
RETURNS TABLE (
    chunk_id    integer,
    chunk_schema NAME,
    chunk_name  NAME,
    table_bytes bigint,
    index_bytes bigint,
    toast_bytes bigint,
    total_bytes bigint,
    node_name NAME)
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
    SELECT
        entry.chunk_id,
        entry.chunk_schema,
        entry.chunk_name,
        entry.table_bytes AS table_bytes,
        entry.index_bytes AS index_bytes,
        entry.toast_bytes AS toast_bytes,
        entry.total_bytes AS total_bytes,
        srv.node_name
    FROM (
        SELECT
            s.node_name,
            _timescaledb_internal.ping_data_node (s.node_name) AS node_up
        FROM
            _timescaledb_catalog.hypertable AS ht,
            _timescaledb_catalog.hypertable_data_node AS s
        WHERE
            ht.schema_name = schema_name_in
            AND ht.table_name = table_name_in
            AND s.hypertable_id = ht.id
         ) AS srv
    LEFT OUTER JOIN LATERAL _timescaledb_internal.data_node_chunk_info(
    CASE WHEN srv.node_up THEN
        srv.node_name
    ELSE
        NULL
    END , schema_name_in, table_name_in) entry ON TRUE
	WHERE
	    entry.chunk_name IS NOT NULL;
$BODY$;


-- 获取超表块的关系大小
-- hypertable - hypertable 获取大小

-- Return：
-- chunk_schema - 块的模式名称
-- chunk_name - 块表名
-- table_bytes - 块表使用的磁盘空间
-- index_bytes - 索引使用的磁盘空间
-- toast_bytes - toast 表的磁盘空间
-- total_bytes - 总共使用的磁盘空间
-- node_name - 如果这是分布式超表，则块所在的节点。 
CREATE OR REPLACE FUNCTION chunks_detailed_size(
    hypertable              REGCLASS
)
RETURNS TABLE (
               chunk_schema NAME,
               chunk_name NAME,
               table_bytes BIGINT,
               index_bytes BIGINT,
               toast_bytes BIGINT,
               total_bytes BIGINT,
               node_name   NAME)
LANGUAGE PLPGSQL VOLATILE STRICT AS
$BODY$
DECLARE
        table_name       NAME;
        schema_name      NAME;
        is_distributed   BOOL;
BEGIN
        SELECT relname, nspname, replication_factor > 0
        INTO table_name, schema_name, is_distributed
        FROM pg_class c
        INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
        INNER JOIN _timescaledb_catalog.hypertable ht ON (ht.schema_name = n.nspname AND ht.table_name = c.relname)
        WHERE c.OID = hypertable;

		IF table_name IS NULL THEN
		    RETURN;
		END IF;

        CASE WHEN is_distributed THEN
            RETURN QUERY SELECT ch.chunk_schema, ch.chunk_name, ch.table_bytes, ch.index_bytes, 
                        ch.toast_bytes, ch.total_bytes, ch.node_name   
            FROM _timescaledb_internal.chunks_remote_size(schema_name, table_name) ch;
        ELSE
            RETURN QUERY SELECT chl.chunk_schema, chl.chunk_name, chl.table_bytes, chl.index_bytes, 
                        chl.toast_bytes, chl.total_bytes, NULL::NAME   
            FROM _timescaledb_internal.chunks_local_size(schema_name, table_name) chl;
        END CASE;
END;
$BODY$;
---------- end of detailed size functions ------

CREATE OR REPLACE FUNCTION _timescaledb_internal.range_value_to_pretty(
    time_value      BIGINT,
    column_type     REGTYPE
)
    RETURNS TEXT LANGUAGE PLPGSQL STABLE AS
$BODY$
DECLARE
BEGIN
    IF NOT _timescaledb_internal.dimension_is_finite(time_value) THEN
        RETURN '';
    END IF;
    IF time_value IS NULL THEN
        RETURN format('%L', NULL);
    END IF;
    CASE column_type
      WHEN 'BIGINT'::regtype, 'INTEGER'::regtype, 'SMALLINT'::regtype THEN
        RETURN format('%L', time_value); -- scale determined by user.
      WHEN 'TIMESTAMP'::regtype, 'TIMESTAMPTZ'::regtype THEN
        -- assume time_value is in microsec
        RETURN format('%1$L', _timescaledb_internal.to_timestamp(time_value)); -- microseconds
      WHEN 'DATE'::regtype THEN
        RETURN format('%L', timezone('UTC',_timescaledb_internal.to_timestamp(time_value))::date);
      ELSE
        RETURN time_value;
    END CASE;
END
$BODY$;

--- 返回近似行数的便捷函数
-- relation - 表或超表以获得近似的行数
-- Return：
-- 根据目录表估计的行数
CREATE OR REPLACE FUNCTION approximate_row_count(relation REGCLASS)
RETURNS BIGINT
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
  WITH RECURSIVE inherited_id(oid) AS
  (
    SELECT relation
    UNION ALL
    SELECT i.inhrelid
    FROM pg_inherits i
    JOIN inherited_id b ON i.inhparent = b.oid
  )
  -- 分区表的 reltuples 是它在 pg14 中的子项的总和，所以我们需要过滤掉它们
  SELECT COALESCE((SUM(reltuples) FILTER (WHERE reltuples > 0 AND relkind <> 'p')), 0)::BIGINT
  FROM inherited_id
  JOIN pg_class USING (oid);
$BODY$;

-------- stats related to compression ------
CREATE OR REPLACE VIEW _timescaledb_internal.compressed_chunk_stats AS
SELECT
    srcht.schema_name AS hypertable_schema,
    srcht.table_name AS hypertable_name,
    srcch.schema_name AS chunk_schema,
    srcch.table_name AS chunk_name,
    CASE WHEN srcch.compressed_chunk_id IS NULL THEN
        'Uncompressed'::text
    ELSE
        'Compressed'::text
    END AS compression_status,
    map.uncompressed_heap_size,
    map.uncompressed_index_size,
    map.uncompressed_toast_size,
    map.uncompressed_heap_size + map.uncompressed_toast_size + map.uncompressed_index_size AS uncompressed_total_size,
    map.compressed_heap_size,
    map.compressed_index_size,
    map.compressed_toast_size,
    map.compressed_heap_size + map.compressed_toast_size + map.compressed_index_size AS compressed_total_size
FROM
    _timescaledb_catalog.hypertable AS srcht
    JOIN _timescaledb_catalog.chunk AS srcch ON srcht.id = srcch.hypertable_id
        AND srcht.compressed_hypertable_id IS NOT NULL
        AND srcch.dropped = FALSE
    LEFT JOIN _timescaledb_catalog.compression_chunk_size map ON srcch.id = map.chunk_id;

GRANT SELECT ON _timescaledb_internal.compressed_chunk_stats TO PUBLIC;

CREATE OR REPLACE FUNCTION _timescaledb_internal.data_node_compressed_chunk_stats (node_name name, schema_name_in name, table_name_in name)
    RETURNS TABLE (
        chunk_schema name,
        chunk_name name,
        compression_status text,
        before_compression_table_bytes bigint,
        before_compression_index_bytes bigint,
        before_compression_toast_bytes bigint,
        before_compression_total_bytes bigint,
        after_compression_table_bytes bigint,
        after_compression_index_bytes bigint,
        after_compression_toast_bytes bigint,
        after_compression_total_bytes bigint
    )
AS '$libdir/timescaledb-2.5.0' , 'ts_dist_remote_compressed_chunk_info' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.compressed_chunk_local_stats (schema_name_in name, table_name_in name)
    RETURNS TABLE (
        chunk_schema name,
        chunk_name name,
        compression_status text,
        before_compression_table_bytes bigint,
        before_compression_index_bytes bigint,
        before_compression_toast_bytes bigint,
        before_compression_total_bytes bigint,
        after_compression_table_bytes bigint,
        after_compression_index_bytes bigint,
        after_compression_toast_bytes bigint,
        after_compression_total_bytes bigint)
    LANGUAGE SQL
    STABLE STRICT
    AS
$BODY$
    SELECT
        ch.chunk_schema,
        ch.chunk_name,
        ch.compression_status,
        ch.uncompressed_heap_size,
        ch.uncompressed_index_size,
        ch.uncompressed_toast_size,
        ch.uncompressed_total_size,
        ch.compressed_heap_size,
        ch.compressed_index_size,
        ch.compressed_toast_size,
        ch.compressed_total_size
    FROM
        _timescaledb_internal.compressed_chunk_stats ch
    WHERE
        ch.hypertable_schema = schema_name_in
        AND ch.hypertable_name = table_name_in;
$BODY$;

CREATE OR REPLACE FUNCTION _timescaledb_internal.compressed_chunk_remote_stats (schema_name_in name, table_name_in name)
    RETURNS TABLE (
        chunk_schema name,
        chunk_name name,
        compression_status text,
        before_compression_table_bytes bigint,
        before_compression_index_bytes bigint,
        before_compression_toast_bytes bigint,
        before_compression_total_bytes bigint,
        after_compression_table_bytes bigint,
        after_compression_index_bytes bigint,
        after_compression_toast_bytes bigint,
        after_compression_total_bytes bigint,
        node_name name)
    LANGUAGE SQL
    STABLE STRICT
    AS
$BODY$
    SELECT
        ch.*,
        srv.node_name
    FROM (
        SELECT
            s.node_name,
            _timescaledb_internal.ping_data_node (s.node_name) AS node_up
        FROM
            _timescaledb_catalog.hypertable AS ht,
            _timescaledb_catalog.hypertable_data_node AS s
        WHERE
            ht.schema_name = schema_name_in
            AND ht.table_name = table_name_in
            AND s.hypertable_id = ht.id) AS srv
    LEFT OUTER JOIN LATERAL _timescaledb_internal.data_node_compressed_chunk_stats (
    CASE WHEN srv.node_up THEN
        srv.node_name
    ELSE
        NULL
    END, schema_name_in, table_name_in) ch ON TRUE
	WHERE ch.chunk_name IS NOT NULL;
$BODY$;

-- 获取启用压缩的超表的每个块压缩统计信息
CREATE OR REPLACE FUNCTION chunk_compression_stats (hypertable REGCLASS)
    RETURNS TABLE (
        chunk_schema name,
        chunk_name name,
        compression_status text,
        before_compression_table_bytes bigint,
        before_compression_index_bytes bigint,
        before_compression_toast_bytes bigint,
        before_compression_total_bytes bigint,
        after_compression_table_bytes bigint,
        after_compression_index_bytes bigint,
        after_compression_toast_bytes bigint,
        after_compression_total_bytes bigint,
        node_name name)
    LANGUAGE PLPGSQL
    STABLE STRICT
    AS $BODY$
DECLARE
    table_name name;
    schema_name name;
    is_distributed bool;
BEGIN
    SELECT
        relname,
        nspname,
        replication_factor > 0
    INTO
	    table_name,
        schema_name,
        is_distributed
    FROM
        pg_class c
        INNER JOIN pg_namespace n ON (n.OID = c.relnamespace)
        INNER JOIN _timescaledb_catalog.hypertable ht ON (ht.schema_name = n.nspname
                AND ht.table_name = c.relname)
    WHERE
        c.OID = hypertable;

    IF table_name IS NULL THEN
	    RETURN;
	END IF;

    CASE WHEN is_distributed THEN
        RETURN QUERY
        SELECT
            *
        FROM
            _timescaledb_internal.compressed_chunk_remote_stats (schema_name, table_name);
    ELSE
        RETURN QUERY
        SELECT
            *,
            NULL::name
        FROM
            _timescaledb_internal.compressed_chunk_local_stats (schema_name, table_name);
    END CASE;
END;
$BODY$;

-- 获取启用压缩的超表的压缩统计信息
CREATE OR REPLACE FUNCTION hypertable_compression_stats (hypertable REGCLASS)
    RETURNS TABLE (
        total_chunks bigint,
        number_compressed_chunks bigint,
        before_compression_table_bytes bigint,
        before_compression_index_bytes bigint,
        before_compression_toast_bytes bigint,
        before_compression_total_bytes bigint,
        after_compression_table_bytes bigint,
        after_compression_index_bytes bigint,
        after_compression_toast_bytes bigint,
        after_compression_total_bytes bigint,
        node_name name)
    LANGUAGE SQL
    STABLE STRICT
    AS	
$BODY$
	SELECT
        count(*)::bigint AS total_chunks,
        (count(*) FILTER (WHERE ch.compression_status = 'Compressed'))::bigint AS number_compressed_chunks,
        sum(ch.before_compression_table_bytes)::bigint AS before_compression_table_bytes,
        sum(ch.before_compression_index_bytes)::bigint AS before_compression_index_bytes,
        sum(ch.before_compression_toast_bytes)::bigint AS before_compression_toast_bytes,
        sum(ch.before_compression_total_bytes)::bigint AS before_compression_total_bytes,
        sum(ch.after_compression_table_bytes)::bigint AS after_compression_table_bytes,
        sum(ch.after_compression_index_bytes)::bigint AS after_compression_index_bytes,
        sum(ch.after_compression_toast_bytes)::bigint AS after_compression_toast_bytes,
        sum(ch.after_compression_total_bytes)::bigint AS after_compression_total_bytes,
        ch.node_name
    FROM
	    chunk_compression_stats(hypertable) ch
    GROUP BY
        ch.node_name;
$BODY$;

-------------Get index size for hypertables -------
--schema_name - 超表索引的 schema_name
-- index_name - 超级表上的索引
---注意查询与超表的模式名称匹配
-- 输入在超表索引而不是块索引上。
CREATE OR REPLACE FUNCTION _timescaledb_internal.indexes_local_size(
    schema_name_in             NAME,
    index_name_in              NAME
)
RETURNS TABLE ( hypertable_id INTEGER,
                total_bytes BIGINT ) 
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
    WITH chunk_index_size (num_bytes) AS (
        SELECT
		    COALESCE(sum(pg_relation_size(c.oid)), 0)::bigint
        FROM                                      
            pg_class c,
            pg_namespace n,
            _timescaledb_catalog.chunk ch,
            _timescaledb_catalog.chunk_index ci,
			_timescaledb_catalog.hypertable h
         WHERE ch.schema_name = n.nspname
             AND c.relnamespace = n.oid
             AND c.relname = ci.index_name
             AND ch.id = ci.chunk_id
             AND h.id = ci.hypertable_id
             AND h.schema_name = schema_name_in 
             AND ci.hypertable_index_name = index_name_in
    ) SELECT
	      h.id,
		  -- 添加所有块上的索引大小 + 根表上的索引大小
		  (SELECT num_bytes FROM chunk_index_size) + pg_relation_size(format('%I.%I', schema_name_in, index_name_in)::regclass)::bigint
	  FROM
	      pg_class c, pg_index i, _timescaledb_catalog.hypertable h
	  WHERE
	     i.indexrelid = format('%I.%I', schema_name_in, index_name_in)::regclass
		 AND c.oid = i.indrelid
		 AND h.schema_name = schema_name_in
		 AND h.table_name = c.relname;
$BODY$;

CREATE OR REPLACE FUNCTION _timescaledb_internal.data_node_index_size (node_name name, schema_name_in name, index_name_in name)
RETURNS TABLE ( hypertable_id INTEGER, total_bytes BIGINT)
AS '$libdir/timescaledb-2.5.0' , 'ts_dist_remote_hypertable_index_info' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.indexes_remote_size(
    schema_name_in             NAME,
    table_name_in              NAME,
    index_name_in              NAME
)
RETURNS BIGINT
LANGUAGE SQL VOLATILE STRICT AS
$BODY$
    SELECT
        sum(entry.total_bytes)::bigint AS total_bytes
    FROM (
        SELECT
            s.node_name,
            _timescaledb_internal.ping_data_node (s.node_name) AS node_up
        FROM
            _timescaledb_catalog.hypertable AS ht,
            _timescaledb_catalog.hypertable_data_node AS s
        WHERE
            ht.schema_name = schema_name_in
            AND ht.table_name = table_name_in
            AND s.hypertable_id = ht.id
         ) AS srv
    JOIN LATERAL _timescaledb_internal.data_node_index_size(
    CASE WHEN srv.node_up THEN
        srv.node_name
    ELSE
        NULL
    END, schema_name_in, index_name_in) entry ON TRUE;
$BODY$;

-- 获取超表索引的大小
-- index_name - 超级表上的索引
-- Return：
-- total_bytes - 磁盘索引的大小

CREATE OR REPLACE FUNCTION  hypertable_index_size(
    index_name              REGCLASS
)
RETURNS BIGINT
LANGUAGE PLPGSQL VOLATILE STRICT AS
$BODY$
DECLARE
        ht_index_name       NAME;
        ht_schema_name      NAME;
        ht_name      NAME;
        is_distributed   BOOL;
        ht_id INTEGER;
        index_bytes BIGINT;
BEGIN
   SELECT c.relname, cl.relname, nsp.nspname, ht.replication_factor > 0
   INTO ht_index_name, ht_name, ht_schema_name, is_distributed
   FROM pg_class c, pg_index cind, pg_class cl,
        pg_namespace nsp, _timescaledb_catalog.hypertable ht
   WHERE c.oid = cind.indexrelid AND cind.indrelid = cl.oid
         AND cl.relnamespace = nsp.oid AND c.oid = index_name
		 AND ht.schema_name = nsp.nspname ANd ht.table_name = cl.relname;

   IF ht_index_name IS NULL THEN
       RETURN NULL;
   END IF;

   -- 获取访问节点索引的本地大小或大小
   SELECT il.total_bytes
   INTO index_bytes
   FROM _timescaledb_internal.indexes_local_size(ht_schema_name, ht_index_name) il;

   IF index_bytes IS NULL THEN
       index_bytes = 0;
   END IF;

   -- 从数据节点添加大小
   IF is_distributed THEN
       index_bytes = index_bytes + _timescaledb_internal.indexes_remote_size(ht_schema_name, ht_name, ht_index_name);
   END IF;

   RETURN index_bytes;
END;
$BODY$;

-------------End index size for hypertables -------
 
 
 

CREATE OR REPLACE FUNCTION _timescaledb_internal.hist_sfunc (state INTERNAL, val DOUBLE PRECISION, MIN DOUBLE PRECISION, MAX DOUBLE PRECISION, nbuckets INTEGER)
RETURNS INTERNAL
AS '$libdir/timescaledb-2.5.0', 'ts_hist_sfunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.hist_combinefunc(state1 INTERNAL, state2 INTERNAL)
RETURNS INTERNAL
AS '$libdir/timescaledb-2.5.0', 'ts_hist_combinefunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.hist_serializefunc(INTERNAL)
RETURNS bytea
AS '$libdir/timescaledb-2.5.0', 'ts_hist_serializefunc'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.hist_deserializefunc(bytea, INTERNAL)
RETURNS INTERNAL
AS '$libdir/timescaledb-2.5.0', 'ts_hist_deserializefunc'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.hist_finalfunc(state INTERNAL, val DOUBLE PRECISION, MIN DOUBLE PRECISION, MAX DOUBLE PRECISION, nbuckets INTEGER)
RETURNS INTEGER[]
AS '$libdir/timescaledb-2.5.0', 'ts_hist_finalfunc'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

-- 一旦完全支持语法，我们就开始使用 CREATE OR REPLACE AGGREGATE 进行聚合创建，因为这样更容易支持幂等更改。 这将允许更改支持聚合的函数，例如，定义和包含用于窗口函数支持的反函数。 但是，仍然应该注意，用于聚合内部状态的数据结构的更改必须向后兼容，并且任何新函数都必须接受旧格式，以便它们继续使用连续聚合，其中旧状态 可能已经实现。

-- 此聚合将数据集划分为指定数量的桶 (nbuckets)，范围从输入的最小值到最大值。
CREATE OR REPLACE AGGREGATE histogram (DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, INTEGER) (
    SFUNC = _timescaledb_internal.hist_sfunc,
    STYPE = INTERNAL,
    COMBINEFUNC = _timescaledb_internal.hist_combinefunc,
    SERIALFUNC = _timescaledb_internal.hist_serializefunc,
    DESERIALFUNC = _timescaledb_internal.hist_deserializefunc,
    PARALLEL = SAFE,
    FINALFUNC = _timescaledb_internal.hist_finalfunc,
    FINALFUNC_EXTRA
);
 
 
 

-- 此文件包含用于使 C 中保存的 TimescaleDB 元数据缓存的缓存失效的基础结构。请查看 cache_invalidate.c 以了解其工作原理。
CREATE TABLE IF NOT EXISTS  _timescaledb_cache.cache_inval_hypertable();

-- 用于通知调度程序对 bgw_job 表的更改。
CREATE TABLE IF NOT EXISTS  _timescaledb_cache.cache_inval_bgw_job();

--这很微妙。 我们创建这个虚拟的 cache_inval_extension 表只是为了在 DROP 扩展上删除它时获取 relcache 失效事件。 它没有相关的触发器。 当表失效时，所有后端都会收到通知，并且知道它们必须使所有缓存的信息失效，包括目录表和索引 OID 等。
CREATE TABLE IF NOT EXISTS  _timescaledb_cache.cache_inval_extension();

-- 实际上并不是严格需要的，但有利于理智，因为所有的表都应该被转储。
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_cache.cache_inval_hypertable', '');
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_cache.cache_inval_extension', '');
SELECT pg_catalog.pg_extension_config_dump('_timescaledb_cache.cache_inval_bgw_job', '');

GRANT SELECT ON ALL TABLES IN SCHEMA _timescaledb_cache TO PUBLIC;

 
 
 

CREATE OR REPLACE FUNCTION _timescaledb_internal.restart_background_workers()
RETURNS BOOL
AS '$libdir/timescaledb', 'ts_bgw_db_workers_restart'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.stop_background_workers()
RETURNS BOOL
AS '$libdir/timescaledb', 'ts_bgw_db_workers_stop'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.start_background_workers()
RETURNS BOOL
AS '$libdir/timescaledb', 'ts_bgw_db_workers_start'
LANGUAGE C VOLATILE;

INSERT INTO _timescaledb_config.bgw_job (id, application_name, schedule_interval, max_runtime, max_retries, retry_period, proc_schema, proc_name, owner, scheduled) VALUES
(1, 'Telemetry Reporter [1]', INTERVAL '24h', INTERVAL '100s', -1, INTERVAL '1h', '_timescaledb_internal', 'policy_telemetry', CURRENT_ROLE, true)
ON CONFLICT (id) DO NOTHING;
 
 
 

CREATE OR REPLACE FUNCTION _timescaledb_internal.generate_uuid() RETURNS UUID
AS '$libdir/timescaledb-2.5.0', 'ts_uuid_generate' LANGUAGE C VOLATILE STRICT;

-- 在创建数据库时插入 uuid 和 install_timestamp。 不要创建exported_uuid，因为它在pg_dump 期间被导出和安装，这会导致冲突。
INSERT INTO _timescaledb_catalog.metadata
SELECT 'uuid', _timescaledb_internal.generate_uuid(), TRUE ON CONFLICT DO NOTHING;
INSERT INTO _timescaledb_catalog.metadata
SELECT 'install_timestamp', now(), TRUE ON CONFLICT DO NOTHING;
 
 
 

CREATE OR REPLACE FUNCTION _timescaledb_internal.set_dist_id(dist_id UUID) RETURNS BOOL
AS '$libdir/timescaledb-2.5.0', 'ts_dist_set_id' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.set_peer_dist_id(dist_id UUID) RETURNS BOOL
AS '$libdir/timescaledb-2.5.0', 'ts_dist_set_peer_id' LANGUAGE C VOLATILE STRICT;

-- Function to validate that a node has local settings to function as
-- a data node. Throws error if validation fails.
CREATE OR REPLACE FUNCTION _timescaledb_internal.validate_as_data_node() RETURNS void
AS '$libdir/timescaledb-2.5.0', 'ts_dist_validate_as_data_node' LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION _timescaledb_internal.show_connection_cache()
RETURNS TABLE (
    node_name           name,
    user_name           name,
    host                text,
    port                int,
    database            name,
    backend_pid         int,
    connection_status   text,
    transaction_status  text,
    transaction_depth   int,
    processing          boolean,
    invalidated         boolean)
AS '$libdir/timescaledb-2.5.0', 'ts_remote_connection_cache_show' LANGUAGE C VOLATILE STRICT;
 
 
 

CREATE SCHEMA IF NOT EXISTS timescaledb_information;

-- 列出所有超级表的便捷视图
CREATE OR REPLACE VIEW timescaledb_information.hypertables AS
SELECT ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name,
  t.tableowner AS owner,
  ht.num_dimensions,
  (
    SELECT count(1)
    FROM _timescaledb_catalog.chunk ch
    WHERE ch.hypertable_id = ht.id) AS num_chunks,
  (
    CASE WHEN compression_state = 1 THEN
      TRUE 
    ELSE
      FALSE 
    END) AS compression_enabled,
  (
    CASE WHEN ht.replication_factor > 0 THEN
      TRUE
    ELSE
      FALSE
    END) AS is_distributed,
  ht.replication_factor,
  dn.node_list AS data_nodes,
  srchtbs.tablespace_list AS tablespaces
FROM _timescaledb_catalog.hypertable ht
  INNER JOIN pg_tables t ON ht.table_name = t.tablename
    AND ht.schema_name = t.schemaname
  LEFT OUTER JOIN _timescaledb_catalog.continuous_agg ca ON ca.mat_hypertable_id = ht.id
  LEFT OUTER JOIN (
    SELECT hypertable_id,
      array_agg(tablespace_name ORDER BY id) AS tablespace_list
    FROM _timescaledb_catalog.tablespace
    GROUP BY hypertable_id) srchtbs ON ht.id = srchtbs.hypertable_id
  LEFT OUTER JOIN (
  SELECT hypertable_id,
    array_agg(node_name ORDER BY node_name) AS node_list
  FROM _timescaledb_catalog.hypertable_data_node
  GROUP BY hypertable_id) dn ON ht.id = dn.hypertable_id
WHERE ht.compression_state != 2 --> no internal compression tables
  AND ca.mat_hypertable_id IS NULL;

CREATE OR REPLACE VIEW timescaledb_information.job_stats AS
SELECT ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name,
  j.id AS job_id,
  js.last_start AS last_run_started_at,
  js.last_successful_finish AS last_successful_finish,
  CASE WHEN js.last_finish < '4714-11-24 00:00:00+00 BC' THEN
    NULL
  WHEN js.last_finish IS NOT NULL THEN
    CASE WHEN js.last_run_success = 't' THEN
      'Success'
    WHEN js.last_run_success = 'f' THEN
      'Failed'
    END
  END AS last_run_status,
  CASE WHEN pgs.state = 'active' THEN
    'Running'
  WHEN j.scheduled = FALSE THEN
    'Paused'
  ELSE
    'Scheduled'
  END AS job_status,
  CASE WHEN js.last_finish > js.last_start THEN
  (js.last_finish - js.last_start)
  END AS last_run_duration,
  CASE WHEN j.scheduled THEN
    js.next_start
  END AS next_start,
  js.total_runs,
  js.total_successes,
  js.total_failures
FROM _timescaledb_config.bgw_job j
  INNER JOIN _timescaledb_internal.bgw_job_stat js ON j.id = js.job_id
  LEFT JOIN _timescaledb_catalog.hypertable ht ON j.hypertable_id = ht.id
  LEFT JOIN pg_stat_activity pgs ON pgs.datname = current_database()
    AND pgs.application_name = j.application_name
  ORDER BY ht.schema_name,
    ht.table_name;

-- 查看后台工作人员的工作
CREATE OR REPLACE VIEW timescaledb_information.jobs AS
SELECT j.id AS job_id,
  j.application_name,
  j.schedule_interval,
  j.max_runtime,
  j.max_retries,
  j.retry_period,
  j.proc_schema,
  j.proc_name,
  j.owner,
  j.scheduled,
  j.config,
  js.next_start,
  ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name
FROM _timescaledb_config.bgw_job j
  LEFT JOIN _timescaledb_catalog.hypertable ht ON ht.id = j.hypertable_id
  LEFT JOIN _timescaledb_internal.bgw_job_stat js ON js.job_id = j.id;

-- 连续聚合查询的视图 ---
CREATE OR REPLACE VIEW timescaledb_information.continuous_aggregates AS
SELECT ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name,
  cagg.user_view_schema AS view_schema,
  cagg.user_view_name AS view_name,
  viewinfo.viewowner AS view_owner,
  cagg.materialized_only,
  mat_ht.schema_name AS materialization_hypertable_schema,
  mat_ht.table_name AS materialization_hypertable_name,
  directview.viewdefinition AS view_definition
FROM _timescaledb_catalog.continuous_agg cagg,
  _timescaledb_catalog.hypertable ht,
  LATERAL (
    SELECT C.oid,
      pg_get_userbyid(C.relowner) AS viewowner
    FROM pg_class C
      LEFT JOIN pg_namespace N ON (N.oid = C.relnamespace)
    WHERE C.relkind = 'v'
      AND C.relname = cagg.user_view_name
      AND N.nspname = cagg.user_view_schema) viewinfo,
  LATERAL (
    SELECT pg_get_viewdef(C.oid) AS viewdefinition
    FROM pg_class C
    LEFT JOIN pg_namespace N ON (N.oid = C.relnamespace)
  WHERE C.relkind = 'v'
    AND C.relname = cagg.direct_view_name
    AND N.nspname = cagg.direct_view_schema) directview,
  LATERAL (
    SELECT schema_name, table_name
    FROM _timescaledb_catalog.hypertable
    WHERE cagg.mat_hypertable_id = id) mat_ht
WHERE cagg.raw_hypertable_id = ht.id;

CREATE OR REPLACE VIEW timescaledb_information.data_nodes AS
SELECT s.node_name,
  s.owner,
  s.options
FROM (
  SELECT srvname AS node_name,
    srvowner::regrole::name AS owner,
    srvoptions AS options
  FROM pg_catalog.pg_foreign_server AS srv,
    pg_catalog.pg_foreign_data_wrapper AS fdw
  WHERE srv.srvfdw = fdw.oid
    AND fdw.fdwname = 'timescaledb_fdw') AS s;

-- 块元数据视图，显示有关具有 CTE 的主维度列查询计划的信息并不总是由 PG 优化。 所以使用内联表。

CREATE OR REPLACE VIEW timescaledb_information.chunks AS
SELECT hypertable_schema,
  hypertable_name,
  schema_name AS chunk_schema,
  chunk_name,
  primary_dimension,
  primary_dimension_type,
  range_start,
  range_end,
  integer_range_start AS range_start_integer,
  integer_range_end AS range_end_integer,
  is_compressed,
  chunk_table_space AS chunk_tablespace,
  node_list AS data_nodes
FROM (
  SELECT ht.schema_name AS hypertable_schema,
    ht.table_name AS hypertable_name,
    srcch.schema_name AS schema_name,
    srcch.table_name AS chunk_name,
    dim.column_name AS primary_dimension,
    dim.column_type AS primary_dimension_type,
    row_number() OVER (PARTITION BY chcons.chunk_id ORDER BY dim.id) AS chunk_dimension_num,
    CASE WHEN (dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype) THEN
      _timescaledb_internal.to_timestamp(dimsl.range_start)
    ELSE
      NULL
    END AS range_start,
    CASE WHEN (dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype) THEN
      _timescaledb_internal.to_timestamp(dimsl.range_end)
    ELSE
      NULL
    END AS range_end,
    CASE WHEN (dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype) THEN
      NULL
    ELSE
      dimsl.range_start
    END AS integer_range_start,
    CASE WHEN (dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype) THEN
      NULL
    ELSE
      dimsl.range_end
    END AS integer_range_end,
    CASE WHEN (srcch.status & 1 = 1) THEN --distributed compress_chunk() 肯定被调用了 远程chunk压缩状态还不确定
        TRUE
    ELSE FALSE --远程块压缩状态不确定
    END AS is_compressed,
    pgtab.spcname AS chunk_table_space,
    chdn.node_list
  FROM _timescaledb_catalog.chunk srcch
    INNER JOIN _timescaledb_catalog.hypertable ht ON ht.id = srcch.hypertable_id
    INNER JOIN _timescaledb_catalog.chunk_constraint chcons ON srcch.id = chcons.chunk_id
    INNER JOIN _timescaledb_catalog.dimension dim ON srcch.hypertable_id = dim.hypertable_id
    INNER JOIN _timescaledb_catalog.dimension_slice dimsl ON dim.id = dimsl.dimension_id
      AND chcons.dimension_slice_id = dimsl.id
    INNER JOIN (
      SELECT relname,
        reltablespace,
        nspname AS schema_name
      FROM pg_class,
        pg_namespace
      WHERE pg_class.relnamespace = pg_namespace.oid) cl ON srcch.table_name = cl.relname
      AND srcch.schema_name = cl.schema_name
    LEFT OUTER JOIN pg_tablespace pgtab ON pgtab.oid = reltablespace
  LEFT OUTER JOIN (
    SELECT chunk_id,
      array_agg(node_name ORDER BY node_name) AS node_list
    FROM _timescaledb_catalog.chunk_data_node
    GROUP BY chunk_id) chdn ON srcch.id = chdn.chunk_id
  WHERE srcch.dropped IS FALSE
    AND ht.compression_state != 2 ) finalq
WHERE chunk_dimension_num = 1;

-- hypertable 的维度信息
-- 查询中不使用 CTE，因为 PG 并不总是按预期优化它们。

CREATE OR REPLACE VIEW timescaledb_information.dimensions AS
SELECT ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name,
  rank() OVER (PARTITION BY hypertable_id ORDER BY dim.id) AS dimension_number,
  dim.column_name,
  dim.column_type,
  CASE WHEN dim.interval_length IS NULL THEN
    'Space'
  ELSE
    'Time'
  END AS dimension_type,
  CASE WHEN dim.interval_length IS NOT NULL THEN
    CASE WHEN dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype THEN
      _timescaledb_internal.to_interval (dim.interval_length)
    ELSE
      NULL
    END
  END AS time_interval,
  CASE WHEN dim.interval_length IS NOT NULL THEN
    CASE WHEN dim.column_type = 'TIMESTAMP'::regtype
      OR dim.column_type = 'TIMESTAMPTZ'::regtype
      OR dim.column_type = 'DATE'::regtype THEN
      NULL
    ELSE
      dim.interval_length
    END
  END AS integer_interval,
  dim.integer_now_func,
  dim.num_slices AS num_partitions
FROM _timescaledb_catalog.hypertable ht,
  _timescaledb_catalog.dimension dim
WHERE dim.hypertable_id = ht.id;

---compression parameters information ---
CREATE OR REPLACE VIEW timescaledb_information.compression_settings AS
SELECT ht.schema_name AS hypertable_schema,
  ht.table_name AS hypertable_name,
  segq.attname,
  segq.segmentby_column_index,
  segq.orderby_column_index,
  segq.orderby_asc,
  segq.orderby_nullsfirst
FROM _timescaledb_catalog.hypertable_compression segq,
  _timescaledb_catalog.hypertable ht
WHERE segq.hypertable_id = ht.id
  AND (segq.segmentby_column_index IS NOT NULL
    OR segq.orderby_column_index IS NOT NULL)
ORDER BY table_name,
  segmentby_column_index,
  orderby_column_index;

GRANT USAGE ON SCHEMA timescaledb_information TO PUBLIC;

GRANT SELECT ON ALL TABLES IN SCHEMA timescaledb_information TO PUBLIC;
 
 
 

CREATE OR REPLACE VIEW timescaledb_experimental.chunk_replication_status AS
SELECT
    h.schema_name AS hypertable_schema,
    h.table_name AS hypertable_name,
    c.schema_name AS chunk_schema,
    c.table_name AS chunk_name,
    h.replication_factor AS desired_num_replicas,
    count(cdn.chunk_id) AS num_replicas,
    array_agg(cdn.node_name) AS replica_nodes,
    -- compute the set of data nodes that doesn't have the chunk
    (SELECT array_agg(node_name) FROM
            (SELECT node_name FROM _timescaledb_catalog.hypertable_data_node hdn
             WHERE hdn.hypertable_id = h.id
             EXCEPT
             SELECT node_name FROM _timescaledb_catalog.chunk_data_node cdn
             WHERE cdn.chunk_id = c.id
             ORDER BY node_name) nodes) AS non_replica_nodes
FROM _timescaledb_catalog.chunk c
INNER JOIN _timescaledb_catalog.chunk_data_node cdn ON (cdn.chunk_id = c.id)
INNER JOIN _timescaledb_catalog.hypertable h ON (h.id = c.hypertable_id)
GROUP BY h.id, c.id, hypertable_schema, hypertable_name, chunk_schema, chunk_name
ORDER BY h.id, c.id, hypertable_schema, hypertable_name, chunk_schema, chunk_name;

GRANT SELECT ON ALL TABLES IN SCHEMA timescaledb_experimental TO PUBLIC;
 
 
 

CREATE OR REPLACE FUNCTION time_bucket_gapfill(bucket_width SMALLINT, ts SMALLINT, start SMALLINT=NULL, finish SMALLINT=NULL) RETURNS SMALLINT
	AS '$libdir/timescaledb-2.5.0', 'ts_gapfill_int16_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION time_bucket_gapfill(bucket_width INT, ts INT, start INT=NULL, finish INT=NULL) RETURNS INT
	AS '$libdir/timescaledb-2.5.0', 'ts_gapfill_int32_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION time_bucket_gapfill(bucket_width BIGINT, ts BIGINT, start BIGINT=NULL, finish BIGINT=NULL) RETURNS BIGINT
	AS '$libdir/timescaledb-2.5.0', 'ts_gapfill_int64_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION time_bucket_gapfill(bucket_width INTERVAL, ts DATE, start DATE=NULL, finish DATE=NULL) RETURNS DATE
	AS '$libdir/timescaledb-2.5.0', 'ts_gapfill_date_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION time_bucket_gapfill(bucket_width INTERVAL, ts TIMESTAMP, start TIMESTAMP=NULL, finish TIMESTAMP=NULL) RETURNS TIMESTAMP
	AS '$libdir/timescaledb-2.5.0', 'ts_gapfill_timestamp_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION time_bucket_gapfill(bucket_width INTERVAL, ts TIMESTAMPTZ, start TIMESTAMPTZ=NULL, finish TIMESTAMPTZ=NULL) RETURNS TIMESTAMPTZ
	AS '$libdir/timescaledb-2.5.0', 'ts_gapfill_timestamptz_bucket' LANGUAGE C VOLATILE PARALLEL SAFE;

-- locf function
CREATE OR REPLACE FUNCTION locf(value ANYELEMENT, prev ANYELEMENT=NULL, treat_null_as_missing BOOL=false) RETURNS ANYELEMENT
	AS '$libdir/timescaledb-2.5.0', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

-- interpolate functions
CREATE OR REPLACE FUNCTION interpolate(value SMALLINT,prev RECORD=NULL,next RECORD=NULL) RETURNS SMALLINT
	AS '$libdir/timescaledb-2.5.0', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION interpolate(value INT,prev RECORD=NULL,next RECORD=NULL) RETURNS INT
	AS '$libdir/timescaledb-2.5.0', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION interpolate(value BIGINT,prev RECORD=NULL,next RECORD=NULL) RETURNS BIGINT
	AS '$libdir/timescaledb-2.5.0', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION interpolate(value REAL,prev RECORD=NULL,next RECORD=NULL) RETURNS REAL
	AS '$libdir/timescaledb-2.5.0', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION interpolate(value FLOAT,prev RECORD=NULL,next RECORD=NULL) RETURNS FLOAT
	AS '$libdir/timescaledb-2.5.0', 'ts_gapfill_marker' LANGUAGE C VOLATILE PARALLEL SAFE;

 
 
 

-- chunk - 要集群的块的 OID
-- index - 要在其上进行聚类的索引的 OID，或 NULL 以使用上次使用的索引
CREATE OR REPLACE FUNCTION reorder_chunk(
    chunk REGCLASS,
    index REGCLASS=NULL,
    verbose BOOLEAN=FALSE
) RETURNS VOID AS '$libdir/timescaledb-2.5.0', 'ts_reorder_chunk' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION move_chunk(
    chunk REGCLASS,
    destination_tablespace Name,
    index_destination_tablespace Name=NULL,
    reorder_index REGCLASS=NULL,
    verbose BOOLEAN=FALSE
) RETURNS VOID AS '$libdir/timescaledb-2.5.0', 'ts_move_chunk' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION compress_chunk(
    uncompressed_chunk REGCLASS,
    if_not_compressed BOOLEAN = false
) RETURNS REGCLASS AS '$libdir/timescaledb-2.5.0', 'ts_compress_chunk' LANGUAGE C STRICT VOLATILE;

CREATE OR REPLACE FUNCTION decompress_chunk(
    uncompressed_chunk REGCLASS,
    if_compressed BOOLEAN = false
) RETURNS REGCLASS AS '$libdir/timescaledb-2.5.0', 'ts_decompress_chunk' LANGUAGE C STRICT VOLATILE;

CREATE OR REPLACE FUNCTION recompress_chunk(
    chunk REGCLASS,
    if_not_compressed BOOLEAN = false
) RETURNS REGCLASS AS '$libdir/timescaledb-2.5.0', 'ts_recompress_chunk' LANGUAGE C STRICT VOLATILE;
 
 
 

CREATE OR REPLACE FUNCTION _timescaledb_internal.partialize_agg(arg ANYELEMENT)
RETURNS BYTEA AS '$libdir/timescaledb-2.5.0', 'ts_partialize_agg' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION _timescaledb_internal.finalize_agg_sfunc(
tstate internal, aggfn TEXT, inner_agg_collation_schema NAME, inner_agg_collation_name NAME, inner_agg_input_types NAME[][], inner_agg_serialized_state BYTEA, return_type_dummy_val ANYELEMENT)
RETURNS internal
AS '$libdir/timescaledb-2.5.0', 'ts_finalize_agg_sfunc'
LANGUAGE C IMMUTABLE ;

CREATE OR REPLACE FUNCTION _timescaledb_internal.finalize_agg_ffunc(
tstate internal, aggfn TEXT, inner_agg_collation_schema NAME, inner_agg_collation_name NAME, inner_agg_input_types NAME[][], inner_agg_serialized_state BYTEA, return_type_dummy_val ANYELEMENT)
RETURNS anyelement
AS '$libdir/timescaledb-2.5.0', 'ts_finalize_agg_ffunc'
LANGUAGE C IMMUTABLE ;

CREATE OR REPLACE AGGREGATE _timescaledb_internal.finalize_agg(agg_name TEXT,  inner_agg_collation_schema NAME,  inner_agg_collation_name NAME, inner_agg_input_types NAME[][], inner_agg_serialized_state BYTEA, return_type_dummy_val anyelement) (
    SFUNC = _timescaledb_internal.finalize_agg_sfunc,
    STYPE = internal,
    FINALFUNC = _timescaledb_internal.finalize_agg_ffunc,
    FINALFUNC_EXTRA
);
 
 
 

CREATE OR REPLACE FUNCTION timescaledb_pre_restore() RETURNS BOOL AS
$BODY$
DECLARE
    db text;
BEGIN
    SELECT current_database() INTO db;
    EXECUTE format($$ALTER DATABASE %I SET timescaledb.restoring ='on'$$, db);
    SET SESSION timescaledb.restoring = 'on';
    PERFORM _timescaledb_internal.stop_background_workers();
    --exported uuid 可能包含在转储中，因此请备份版本
    UPDATE _timescaledb_catalog.metadata SET key='exported_uuid_bak' WHERE key='exported_uuid';
    RETURN true;
END
$BODY$
LANGUAGE PLPGSQL;


CREATE OR REPLACE FUNCTION timescaledb_post_restore() RETURNS BOOL AS
$BODY$
DECLARE
    db text;
BEGIN
    SELECT current_database() INTO db;
    EXECUTE format($$ALTER DATABASE %I RESET timescaledb.restoring $$, db);
    RESET timescaledb.restoring;
    PERFORM _timescaledb_internal.restart_background_workers();

    --try to restore the backed up uuid, if the restore did not set one
    INSERT INTO _timescaledb_catalog.metadata
       SELECT 'exported_uuid', value, include_in_telemetry FROM _timescaledb_catalog.metadata WHERE key='exported_uuid_bak'
       ON CONFLICT DO NOTHING;
    DELETE FROM _timescaledb_catalog.metadata WHERE key='exported_uuid_bak';

    RETURN true;
END
$BODY$
LANGUAGE PLPGSQL;
 
 
 

CREATE OR REPLACE FUNCTION add_job(
  proc REGPROC,
  schedule_interval INTERVAL,
  config JSONB DEFAULT NULL,
  initial_start TIMESTAMPTZ DEFAULT NULL,
  scheduled BOOL DEFAULT true
) RETURNS INTEGER AS '$libdir/timescaledb-2.5.0', 'ts_job_add' LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION delete_job(job_id INTEGER) RETURNS VOID AS '$libdir/timescaledb-2.5.0', 'ts_job_delete' LANGUAGE C VOLATILE STRICT;
CREATE OR REPLACE PROCEDURE run_job(job_id INTEGER) AS '$libdir/timescaledb-2.5.0', 'ts_job_run' LANGUAGE C;

-- Returns the updated job schedule values
CREATE OR REPLACE FUNCTION alter_job(
    job_id INTEGER,
    schedule_interval INTERVAL = NULL,
    max_runtime INTERVAL = NULL,
    max_retries INTEGER = NULL,
    retry_period INTERVAL = NULL,
    scheduled BOOL = NULL,
    config JSONB = NULL,
    next_start TIMESTAMPTZ = NULL,
    if_exists BOOL = FALSE
)
RETURNS TABLE (job_id INTEGER, schedule_interval INTERVAL, max_runtime INTERVAL, max_retries INTEGER, retry_period INTERVAL, scheduled BOOL, config JSONB, next_start TIMESTAMPTZ)
AS '$libdir/timescaledb-2.5.0', 'ts_job_alter'
LANGUAGE C VOLATILE;
 
 
 

-- 向超表或连续聚合添加保留策略。
--retention_window（通常是 INTERVAL）确定在执行策略时（例如，“1 周”）丢弃数据的窗口。 请注意，保留窗口将始终与块边界对齐，因此该窗口可能大于给定的窗口，但绝不会更小。 换句话说，保留窗口之外的一些数据可能会被保留，但窗口内的数据将永远不会被删除。
CREATE OR REPLACE FUNCTION add_retention_policy(
       relation REGCLASS,
       drop_after "any",
       if_not_exists BOOL = false
)
RETURNS INTEGER AS '$libdir/timescaledb-2.5.0', 'ts_policy_retention_add'
LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION remove_retention_policy(
    relation REGCLASS,
    if_exists BOOL = false
) RETURNS VOID
AS '$libdir/timescaledb-2.5.0', 'ts_policy_retention_remove'
LANGUAGE C VOLATILE STRICT;

/* reorder policy */
CREATE OR REPLACE FUNCTION add_reorder_policy(hypertable REGCLASS, index_name NAME, if_not_exists BOOL = false) RETURNS INTEGER
AS '$libdir/timescaledb-2.5.0', 'ts_policy_reorder_add'
LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION remove_reorder_policy(hypertable REGCLASS, if_exists BOOL = false) RETURNS VOID
AS '$libdir/timescaledb-2.5.0', 'ts_policy_reorder_remove'
LANGUAGE C VOLATILE STRICT;

/* compression policy */
CREATE OR REPLACE FUNCTION add_compression_policy(hypertable REGCLASS, compress_after "any", if_not_exists BOOL = false)
RETURNS INTEGER
AS '$libdir/timescaledb-2.5.0', 'ts_policy_compression_add'
LANGUAGE C VOLATILE STRICT;

CREATE OR REPLACE FUNCTION remove_compression_policy(hypertable REGCLASS, if_exists BOOL = false) RETURNS BOOL
AS '$libdir/timescaledb-2.5.0', 'ts_policy_compression_remove'
LANGUAGE C VOLATILE STRICT;

/* continuous aggregates policy */
CREATE OR REPLACE FUNCTION add_continuous_aggregate_policy(continuous_aggregate REGCLASS, start_offset "any", end_offset "any", schedule_interval INTERVAL, if_not_exists BOOL = false)
RETURNS INTEGER
AS '$libdir/timescaledb-2.5.0', 'ts_policy_refresh_cagg_add'
LANGUAGE C VOLATILE;

CREATE OR REPLACE FUNCTION remove_continuous_aggregate_policy(continuous_aggregate REGCLASS, if_not_exists BOOL = false)
RETURNS VOID
AS '$libdir/timescaledb-2.5.0', 'ts_policy_refresh_cagg_remove'
LANGUAGE C VOLATILE STRICT;
 
 
 

CREATE OR REPLACE PROCEDURE _timescaledb_internal.policy_retention(job_id INTEGER, config JSONB)
AS '$libdir/timescaledb-2.5.0', 'ts_policy_retention_proc'
LANGUAGE C;

CREATE OR REPLACE PROCEDURE _timescaledb_internal.policy_reorder(job_id INTEGER, config JSONB)
AS '$libdir/timescaledb-2.5.0', 'ts_policy_reorder_proc'
LANGUAGE C;

CREATE OR REPLACE PROCEDURE _timescaledb_internal.policy_recompression(job_id INTEGER, config JSONB)
AS '$libdir/timescaledb-2.5.0', 'ts_policy_recompression_proc'
LANGUAGE C;

CREATE OR REPLACE PROCEDURE _timescaledb_internal.policy_refresh_continuous_aggregate(job_id INTEGER, config JSONB)
AS '$libdir/timescaledb-2.5.0', 'ts_policy_refresh_cagg_proc'
LANGUAGE C;

CREATE OR REPLACE PROCEDURE
_timescaledb_internal.policy_compression_interval( job_id INTEGER, 
   htid INTEGER,
   lag INTERVAL,
   maxchunks INTEGER,
   verbose_log BOOLEAN,
   recompress_enabled BOOLEAN)
AS $$
DECLARE
  htoid regclass;
  chunk_rec record;
  numchunks integer := 1;
BEGIN

  SELECT format('%I.%I',schema_name, table_name) INTO htoid
  FROM _timescaledb_catalog.hypertable
  WHERE id = htid;

  FOR chunk_rec IN
    SELECT show.oid, ch.schema_name, ch.table_name, ch.status
    FROM show_chunks( htoid, older_than => lag) as show(oid)
      INNER JOIN pg_class pgc ON pgc.oid = show.oid
      INNER JOIN pg_namespace pgns ON pgc.relnamespace = pgns.oid
      INNER JOIN _timescaledb_catalog.chunk ch ON ch.table_name = pgc.relname and ch.schema_name = pgns.nspname and ch.hypertable_id = htid
    WHERE ch.dropped is false and  (ch.status = 0 OR ch.status = 3)
  LOOP
    IF chunk_rec.status = 0 THEN
       PERFORM compress_chunk( chunk_rec.oid );
    ELSIF chunk_rec.status = 3 AND recompress_enabled = 'true' THEN
       PERFORM recompress_chunk( chunk_rec.oid );
    END IF;
    COMMIT;
    IF verbose_log THEN
       RAISE LOG 'job % completed processing chunk %.%', job_id, chunk_rec.schema_name, chunk_rec.table_name;
    END IF;
    numchunks := numchunks + 1;
    IF maxchunks > 0 AND numchunks >= maxchunks THEN  
         EXIT; 
    END IF;  
  END LOOP;
END;
$$ LANGUAGE PLPGSQL;

CREATE OR REPLACE PROCEDURE
_timescaledb_internal.policy_compression_integer( job_id INTEGER, 
   htid INTEGER,
   lag BIGINT,
   maxchunks INTEGER,
   verbose_log BOOLEAN,
   recompress_enabled BOOLEAN)
AS $$
DECLARE
  htoid regclass;
  chunk_rec record;
  numchunks integer := 0;
  lag_integer BIGINT;
BEGIN

  SELECT format('%I.%I',schema_name, table_name) INTO htoid
  FROM _timescaledb_catalog.hypertable
  WHERE id = htid;

	--对于整数情况，我们必须计算滞后 w.r.t
   -- integer_now 函数，然后传递给 show_chunks
  lag_integer := _timescaledb_internal.subtract_integer_from_now( htoid, lag);

  FOR chunk_rec IN
    SELECT show.oid, ch.schema_name, ch.table_name, ch.status
    FROM show_chunks( htoid, older_than => lag_integer) SHOW (oid)
      INNER JOIN pg_class pgc ON pgc.oid = show.oid
      INNER JOIN pg_namespace pgns ON pgc.relnamespace = pgns.oid
      INNER JOIN _timescaledb_catalog.chunk ch ON ch.table_name = pgc.relname and ch.schema_name = pgns.nspname and ch.hypertable_id = htid
    WHERE ch.dropped is false and  (ch.status = 0 OR ch.status = 3)
  LOOP
    IF chunk_rec.status = 0 THEN
       PERFORM compress_chunk( chunk_rec.oid );
    ELSIF chunk_rec.status = 3 AND recompress_enabled = 'true' THEN
       PERFORM recompress_chunk( chunk_rec.oid );
    END IF;
    COMMIT;
    IF verbose_log THEN
       RAISE LOG 'job % completed processing chunk %.%', job_id, chunk_rec.schema_name, chunk_rec.table_name;
    END IF;

    numchunks := numchunks + 1;
    IF maxchunks > 0 AND numchunks >= maxchunks THEN  
         EXIT; 
    END IF;  
  END LOOP;
END;
$$ LANGUAGE PLPGSQL;

CREATE OR REPLACE PROCEDURE
_timescaledb_internal.policy_compression( job_id INTEGER, config JSONB)
AS $$
DECLARE
  dimtype regtype;
  compress_after text;
  lag_interval interval;
  lag_integer bigint;
  htid integer;
  htoid regclass;
  chunk_rec record;
  verbose_log bool;
  maxchunks integer := 0;
  numchunks integer := 1;
  recompress_enabled bool;
BEGIN
  IF config IS NULL THEN
    RAISE EXCEPTION 'job % has null config', job_id;
  END IF;
 
  htid := jsonb_object_field_text (config, 'hypertable_id')::integer;
  IF htid is NULL THEN
    RAISE EXCEPTION 'job % config must have hypertable_id', job_id;
  END IF;
  
  verbose_log := jsonb_object_field_text (config, 'verbose_log')::boolean;
  IF verbose_log is NULL THEN
     verbose_log = 'false';
  END IF;
  
  maxchunks := jsonb_object_field_text (config, 'maxchunks_to_compress')::integer;
  IF maxchunks IS NULL THEN
    maxchunks = 0;
  END IF;
  
  recompress_enabled := jsonb_object_field_text (config, 'recompress')::boolean;
  IF recompress_enabled IS NULL THEN
    recompress_enabled = 'true';
  END IF;
  
  compress_after := jsonb_object_field_text(config, 'compress_after');
  IF compress_after IS NULL THEN
    RAISE EXCEPTION 'job % config must have compress_after', job_id;
  END IF;

  -- find primary dimension type --
  SELECT column_type INTO STRICT dimtype
  FROM ( SELECT ht.schema_name, ht.table_name, dim.column_name, dim.column_type,
         row_number() over(partition by ht.id order by dim.id) as rn
         FROM  _timescaledb_catalog.hypertable ht , 
               _timescaledb_catalog.dimension dim 
         WHERE ht.id = dim.hypertable_id and ht.id = htid ) q 
  WHERE rn = 1; 
 
  CASE WHEN (dimtype = 'TIMESTAMP'::regtype
      OR dimtype = 'TIMESTAMPTZ'::regtype
      OR dimtype = 'DATE'::regtype) THEN
      lag_interval := jsonb_object_field_text(config, 'compress_after')::interval ;
      CALL _timescaledb_internal.policy_compression_interval( 
           job_id, htid, lag_interval, 
           maxchunks, verbose_log, recompress_enabled);
  ELSE
      lag_integer := jsonb_object_field_text(config, 'compress_after')::bigint;
      CALL _timescaledb_internal.policy_compression_integer( 
            job_id, htid, lag_integer, 
            maxchunks, verbose_log, recompress_enabled );
  END CASE;
END;
$$ LANGUAGE PLPGSQL;
 
 
 

-- 向本地数据节点添加物化失效日志条目

-- mat_hypertable_id - 接入节点中CAGG物化超表的超表ID
-- start_time - 物化失效日志条目的开始时间
-- end_time - 物化失效日志条目的结束时间
CREATE OR REPLACE FUNCTION _timescaledb_internal.invalidation_cagg_log_add_entry(
    mat_hypertable_id INTEGER,
    start_time BIGINT,
    end_time BIGINT
) RETURNS VOID AS '$libdir/timescaledb-2.5.0', 'ts_invalidation_cagg_log_add_entry' LANGUAGE C STRICT VOLATILE;

-- 向本地数据节点添加物化失效日志条目

-- raw_hypertable_id - Access Node中原始分布式hypertable的hypertable ID
-- start_time - 物化失效日志条目的开始时间
-- end_time - 物化失效日志条目的结束时间
CREATE OR REPLACE FUNCTION _timescaledb_internal.invalidation_hyper_log_add_entry(
    raw_hypertable_id INTEGER,
    start_time BIGINT,
    end_time BIGINT
) RETURNS VOID AS '$libdir/timescaledb-2.5.0', 'ts_invalidation_hyper_log_add_entry' LANGUAGE C STRICT VOLATILE;

-- raw_hypertable_id - Access Node中原始分布式hypertable的hypertable ID
CREATE OR REPLACE FUNCTION _timescaledb_internal.hypertable_invalidation_log_delete(
    raw_hypertable_id INTEGER
) RETURNS VOID AS '$libdir/timescaledb-2.5.0', 'ts_hypertable_invalidation_log_delete' LANGUAGE C STRICT VOLATILE;

-- mat_hypertable_id - 接入节点中CAGG物化超表的超表ID
CREATE OR REPLACE FUNCTION _timescaledb_internal.materialization_invalidation_log_delete(
    mat_hypertable_id INTEGER
) RETURNS VOID AS '$libdir/timescaledb-2.5.0', 'ts_materialization_invalidation_log_delete' LANGUAGE C STRICT VOLATILE;

-- raw_hypertable_id - Access Node中原始分布式hypertable的hypertable ID
CREATE OR REPLACE FUNCTION _timescaledb_internal.drop_dist_ht_invalidation_trigger(
    raw_hypertable_id INTEGER
) RETURNS VOID AS '$libdir/timescaledb-2.5.0', 'ts_drop_dist_ht_invalidation_trigger' LANGUAGE C STRICT VOLATILE;

-- 为所有属于访问节点中超表 ID 为“raw_hypertable_id”的分布式超表的 CAGG 处理数据节点中的超表失效日志。 失效被剪切、合并并移动到物化失效日志。

-- mat_hypertable_id - 当前正在刷新的Access Node中CAGG物化超表的超表ID
-- raw_hypertable_id - Access Node中原始分布式hypertable的hypertable ID
-- dimtype - 此 CAGG 的时间维度类型的 OID
-- mat_hypertable_ids - 属于“raw_hypertable_id”的访问节点中所有 CAGG 物化超表的超表 ID 数组
--bucket_widths - 属于“raw_hypertable_id”的所有 CAGG 的时间段宽度数组
-- max_bucket_widths - 属于“raw_hypertable_id”的所有 CAGG 的最大时间桶宽度数组
CREATE OR REPLACE FUNCTION _timescaledb_internal.invalidation_process_hypertable_log(
    mat_hypertable_id INTEGER,
    raw_hypertable_id INTEGER,
    dimtype REGTYPE,
    mat_hypertable_ids INTEGER[],
    bucket_widths BIGINT[],
    max_bucket_widths BIGINT[]
) RETURNS VOID AS '$libdir/timescaledb-2.5.0', 'ts_invalidation_process_hypertable_log' LANGUAGE C STRICT VOLATILE;

-- 处理数据节点中的物化失效日志，用于刷新属于访问节点中超表ID为'raw_hypertable_id'的分布式超表的CAGG。失效被剪切、合并并作为单个刷新窗口返回。

-- mat_hypertable_id - 当前正在刷新的访问节点中 CAGG 物化超表的超表 ID。
-- raw_hypertable_id - Access Node中原始分布式hypertable的hypertable ID
-- dimtype - 此 CAGG 的时间维度类型的 OID
-- window_start - CAGG刷新窗口的开始时间
-- window_end - CAGG刷新窗口的结束时间
-- mat_hypertable_ids - 属于“raw_hypertable_id”的访问节点中所有 CAGG 物化超表的超表 ID 数组
--bucket_widths - 属于“raw_hypertable_id”的所有 CAGG 的时间段宽度数组
-- max_bucket_widths - 属于“raw_hypertable_id”的所有 CAGG 的最大时间桶宽度数组

-- 返回一个元组：
-- ret_window_start - 合并后的刷新窗口开始时间
-- ret_window_end - 合并刷新窗口结束时间
CREATE OR REPLACE FUNCTION _timescaledb_internal.invalidation_process_cagg_log(
    mat_hypertable_id INTEGER,
    raw_hypertable_id INTEGER,
    dimtype REGTYPE,
    window_start BIGINT,
    window_end BIGINT,
    mat_hypertable_ids INTEGER[],
    bucket_widths BIGINT[],
    max_bucket_widths BIGINT[],
    OUT ret_window_start BIGINT,
    OUT ret_window_end BIGINT
) RETURNS RECORD AS '$libdir/timescaledb-2.5.0', 'ts_invalidation_process_cagg_log' LANGUAGE C STRICT VOLATILE;
 
 
 

DO language plpgsql $$
DECLARE
  telemetry_string TEXT;
BEGIN
  IF current_setting('timescaledb.telemetry_level') = 'off'
  THEN
    telemetry_string = E'Note: Please enable telemetry to help us improve our product by running: ALTER DATABASE "' || current_database() || E'" SET timescaledb.telemetry_level = ''basic'';';
  ELSE
    telemetry_string = E'Note: TimescaleDB collects anonymous reports to better understand and assist our users.\nFor more information and how to disable, please see our docs https://docs.timescale.com/timescaledb/latest/how-to-guides/configuration/telemetry.';
  END IF;

  RAISE WARNING E'%\n%\n',
    E'\nWELCOME TO\n' ||
    E' _____ _                               _     ____________  \n' ||
    E'|_   _(_)                             | |    |  _  \\ ___ \\ \n' ||
    E'  | |  _ _ __ ___   ___  ___  ___ __ _| | ___| | | | |_/ / \n' ||
    '  | | | |  _ ` _ \ / _ \/ __|/ __/ _` | |/ _ \ | | | ___ \ ' || E'\n' ||
    '  | | | | | | | | |  __/\__ \ (_| (_| | |  __/ |/ /| |_/ /' || E'\n' ||
    '  |_| |_|_| |_| |_|\___||___/\___\__,_|_|\___|___/ \____/' || E'\n' ||
    E'               Running version ' || '2.5.0' || E'\n' ||

    E'For more information on TimescaleDB, please visit the following links:\n\n'
    ||
    E' 1. Getting started: https://docs.timescale.com/timescaledb/latest/getting-started\n' ||
    E' 2. API reference documentation: https://docs.timescale.com/api/latest\n' ||
    E' 3. How TimescaleDB is designed: https://docs.timescale.com/timescaledb/latest/overview/core-concepts\n',
    telemetry_string;
END;
$$;
