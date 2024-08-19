-- REMOVE EMPTY BILL INVOICE ID
CREATE OR REPLACE VIEW "bb_cur_table" AS (
    SELECT *
    FROM "{CUR_TABLE}"
    WHERE bill_invoice_id <> ''
);

;;;

-- BASIC COST
CREATE OR REPLACE VIEW "bb_dwd_costs" AS (
  SELECT 
    CONCAT(CAST(line_item_usage_start_date AS VARCHAR), identity_line_item_id) AS bb_id
    , CAST(line_item_usage_start_date AS DATE) AS _bb_usage_date
    , product_region_code AS bb_region
    , line_item_unblended_cost AS bb_cost_no_tax
    , line_item_line_item_description AS bb_cost_desc
    , line_item_usage_account_id AS bb_account_id
    , product_region_code AS bb_cost_region_code
    , line_item_product_code AS _bb_service
    , *
    , DATE_FORMAT(line_item_usage_start_date, '%Y-%m') AS _bb_usage_year_month
  FROM "bb_cur_table"  -- !!! CHANGE TO YOUR CUR TABLE
  WHERE 
    bill_invoice_id <> '' -- blank means not final = possible dups
);

;;;

-- DATA TRANSFER COST
CREATE OR REPLACE VIEW "bb_dwd_data_transfer_costs" AS (
  SELECT
    bb_id
    , _bb_service AS _bb_parent_service
    , 'AWSDataTransfer' AS _bb_service
    , line_item_usage_amount AS _bb_dt_gb
    , product_transfer_type AS _bb_dt_type
  FROM "bb_dwd_costs"  -- !!! CHANGE TO YOUR CUR TABLE
  WHERE
    product_product_family = 'Data Transfer'
);

;;;

-- EBS USAGE
CREATE OR REPLACE VIEW "bb_dwd_amazonebs_costs" AS (
    SELECT
        bb_id
        , _bb_service AS _bb_parent_service
        , 'AmazonEBS' AS _bb_service
        , line_item_resource_id AS bb_ebs_volume_id
        , product_volume_api_name AS bb_ebs_volume_type
        , line_item_usage_amount AS bb_ebs_gb_month
        , line_item_unblended_cost AS bb_cost
        , CASE product_product_family
            WHEN 'Storage Snapshot' THEN 'Snapshot'
            ELSE 'Storage'
        END AS _bb_ebs_usage_type
    FROM "bb_dwd_costs"
    WHERE
        line_item_usage_type LIKE '%EBS:%'
        AND line_item_line_item_type <> 'Credit'
);

;;;

-- EC2
CREATE OR REPLACE VIEW "bb_dwd_amazonec2_costs" AS (
    SELECT
        bb_id
        , 'AmazonEC2' AS _bb_service
        , line_item_resource_id AS bb_ec2_instance_id
        , line_item_usage_amount * 3600 AS bb_ec2_seconds
        , COALESCE(
            NULLIF(product_instance_type_family, '')
            , REGEXP_EXTRACT(product_instance_type, '^(.+?)\..+$', 1)
            , 'Unknown'
        ) AS _bb_ec2_instance_type_family
        , COALESCE(
            UPPER(REGEXP_EXTRACT(product_instance_type, '^(.+?)[1-9][0-9]*[a-z]*\..+$', 1))
            , 'Unknown'
        ) AS _bb_ec2_instance_type_grand_family
        , product_instance_type AS _bb_ec2_instance_type
        , CAST(product_vcpu AS INT) * line_item_usage_amount * 3600 AS bb_ec2_vcpu_seconds
        , CASE
            WHEN product_physical_processor LIKE '%Graviton%' THEN 'Graviton'
            ELSE 'x86'
        END AS bb_ec2_platform
    FROM "bb_dwd_costs"
    WHERE 
        line_item_product_code = 'AmazonEC2' 
        AND line_item_usage_type NOT LIKE '%EBS:Volume%'
        AND product_vcpu <> ''
        AND product_servicecode <> 'AWSDataTransfer'
        AND line_item_line_item_type <> 'Credit'
);

;;;

-- EC2 ON-DEMAND
CREATE OR REPLACE VIEW "bb_dwd_amazonec2_od_costs" AS (
    SELECT
        bb_id
        , 'On Demand' AS bb_ec2_purchase_option
        , line_item_unblended_cost AS bb_cost_used
    FROM "bb_dwd_costs"
    WHERE
        line_item_line_item_type = 'Usage'
        AND product_product_family = 'Compute Instance'
);

;;;

-- EC2 > NAT GW
CREATE OR REPLACE VIEW "bb_dwd_ec2_nat_costs" AS (
    SELECT
        bb_id
        , 'NAT Gateway' AS _bb_vpc_usage_type
        , line_item_usage_amount AS _bb_ec2_nat_hours
    FROM "bb_dwd_costs"
    WHERE
        product_product_family = 'NAT Gateway'
);

;;;

-- EC2 RESERVED INSTANCE PAID
CREATE OR REPLACE VIEW "bb_dwd_ri_paid_costs" AS (
    SELECT
        bb_id
        , _bb_usage_year_month
        , _bb_usage_date
        , _bb_service
        , reservation_reservation_a_r_n AS bb_ri_arn
        , line_item_usage_amount AS bb_ec2_hours
        , REGEXP_EXTRACT(line_item_usage_type, '^.+?:(.+)$', 1) AS bb_ec2_instance_type_inferred
        , line_item_unblended_cost AS bb_cost
    FROM "bb_dwd_costs"
    WHERE line_item_line_item_type = 'RIFee'
);


;;;

-- RI > USAGE
CREATE OR REPLACE VIEW "bb_dwd_ri_costs" AS (
    SELECT
        bb_id
        , 'Reserved Instance' AS bb_ec2_purchase_option
        , 'Used' AS bb_ri_cost_type
        , reservation_reservation_a_r_n as bb_ri_arn
        , pricing_lease_contract_length AS bb_ri_term_year
        , reservation_effective_cost as bb_cost_used
    FROM "bb_dwd_costs"
    WHERE line_item_line_item_type = 'DiscountedUsage'
);

;;;

-- RI > UNUSED
CREATE OR REPLACE VIEW "bb_dwd_ri_unused_costs" AS
WITH ri_monthly_used AS (
    SELECT
        _bb_usage_year_month
        , reservation_reservation_a_r_n as bb_ri_arn
        , SUM(reservation_effective_cost) as bb_cost_used
    FROM "bb_dwd_costs"
    WHERE line_item_line_item_type = 'DiscountedUsage'
    GROUP BY _bb_usage_year_month, reservation_reservation_a_r_n
)
SELECT
    CONCAT(a.bb_id, 'UNUSEDRI') AS bb_id
    , a._bb_usage_year_month
    , a._bb_usage_date
    , a._bb_service
    , a.bb_ri_arn
    , 'Unused' AS bb_ri_cost_type
    , ROUND(a.bb_cost-COALESCE(b.bb_cost_used, 0), 2) AS bb_cost
FROM "bb_dwd_ri_paid_costs" a
LEFT JOIN ri_monthly_used b ON (
    a._bb_usage_year_month = b._bb_usage_year_month
    AND a.bb_ri_arn = b.bb_ri_arn
);

;;;

-- SAVINGS PLANS > USAGE
CREATE OR REPLACE VIEW "bb_dwd_sp_costs" AS (
    SELECT
        bb_id
        , _bb_usage_date
        , _bb_usage_year_month
        , 'Savings Plans' AS bb_usage_type
        , 'Used' AS bb_sp_cost_type
        , savings_plan_savings_plan_a_r_n AS bb_sp_arn
        , savings_plan_savings_plan_effective_cost AS bb_cost_used
        , savings_plan_purchase_term AS bb_sp_term_year
    FROM "bb_dwd_costs"
    WHERE line_item_line_item_type = 'SavingsPlanCoveredUsage'
);

;;;

-- SAVINGS PLANS > NEGATION
CREATE OR REPLACE VIEW "bb_dwd_sp_negation_costs" AS (
    SELECT
        bb_id
        , _bb_usage_date
        , savings_plan_savings_plan_a_r_n AS bb_sp_arn
        , line_item_unblended_cost AS bb_sp_cost_negation
        , 0 AS bb_cost
        , 0 AS bb_ec2_seconds
    FROM "bb_dwd_costs"
    WHERE line_item_line_item_type = 'SavingsPlanNegation'
);

;;;

-- SAVINGS PLANS > RECURRING FEE
CREATE OR REPLACE VIEW "bb_dwd_sp_recur_costs" AS (
    SELECT
        bb_id
        , _bb_usage_date
        , _bb_usage_year_month
        , savings_plan_savings_plan_a_r_n AS bb_sp_arn
        , line_item_unblended_cost AS bb_sp_cost_recur
        , 0 AS bb_cost
    FROM "bb_dwd_costs"
    WHERE line_item_line_item_type = 'SavingsPlanRecurringFee'
);

;;;

-- SAVINGS PLANS > UNUSED

CREATE OR REPLACE VIEW "bb_dwd_sp_unused_costs" AS
WITH sp_daily_cost AS
(
    SELECT bb_sp_arn, _bb_usage_year_month, _bb_usage_date, sum(bb_cost_used) AS bb_sp_daily_cost
    FROM bb_dwd_sp_costs
    GROUP BY bb_sp_arn, _bb_usage_year_month, _bb_usage_date
)
SELECT
    CONCAT(a.bb_id, 'UNUSEDSP') AS bb_id
    , a._bb_usage_year_month
    , a._bb_usage_date
    , a.bb_sp_arn
    , 'ComputeSavingsPlans' as _bb_service
    , 'Unused' AS bb_sp_cost_type
    , ROUND(a.bb_sp_cost_recur-b.bb_sp_daily_cost, 4) AS bb_sp_cost_unused
FROM bb_dwd_sp_recur_costs a
LEFT JOIN SP_DAILY_COST b ON (
    a._bb_usage_date = b._bb_usage_date
    AND a.bb_sp_arn = b.bb_sp_arn
);

;;;

-- RDS COSTS

CREATE OR REPLACE VIEW "bb_dwd_rds_costs" AS
SELECT
    bb_id
    , CASE product_product_family
        WHEN 'Database Instance' THEN 'Instance'
        WHEN 'Database Storage' THEN 'Storage'
    END AS bb_rds_usage_type
    , CASE
        WHEN product_physical_processor LIKE '%Graviton%' THEN 'Graviton'
        ELSE 'x86'
    END AS _bb_rds_platform
    , product_database_engine AS bb_rds_engine
    , product_deployment_option AS bb_rds_azness
    , product_instance_type AS bb_rds_instance_type
    , line_item_resource_id AS bb_rds_instance_arn
    , REGEXP_EXTRACT(line_item_resource_id, '^.+:(.+)$', 1) AS bb_rds_instance_name
    , COALESCE(
        NULLIF(product_instance_type_family, '')
        , REGEXP_EXTRACT(product_instance_type, '^(.+?)\..+$', 1)
        , 'Unknown'
    ) AS _bb_rds_instance_type_family
    , COALESCE(
        UPPER(REGEXP_EXTRACT(product_instance_type, '^(.+?)[1-9][0-9]*[a-z]*\..+$', 1))
        , 'Unknown'
    ) AS _bb_rds_instance_type_grand_family
    , CASE
        WHEN product_database_engine IS NOT NULL THEN line_item_usage_amount
        ELSE NULL
    END AS rds_instance_seconds
    , CASE
        WHEN line_item_usage_type LIKE '%GP2-Storage%' THEN 'GP2'
        WHEN line_item_usage_type LIKE '%GP3-Storage%' THEN 'GP3'
        ELSE REGEXP_EXTRACT(product_volume_type, '^(.+-)?(.+)$', 2)
    END AS rds_storage_volume_type
    , CASE
        WHEN product_volume_type IS NOT NULL THEN line_item_usage_amount
        ELSE NULL
    END AS rds_storage_gb_month
FROM bb_dwd_costs;

;;;

-- EMR CLUSTER FEE
CREATE OR REPLACE VIEW "bb_dwd_amazonemr_fee_costs" AS (
    SELECT
        bb_id
        , 'AmazonEMR' AS bb_parent_service
        , resource_tags_user_name AS bb_emr_cluster_name
        , REGEXP_EXTRACT(line_item_resource_id, '(j-.+?)$', 1) AS bb_emr_cluster_id
    FROM "bb_dwd_costs"
    WHERE line_item_product_code = 'ElasticMapReduce'
);

;;;

-- EMR CLUSTER NAME
CREATE OR REPLACE VIEW "bb_dim_amazonemr_cluster_names" AS (
    SELECT
        DISTINCT resource_tags_user_name AS bb_emr_cluster_name
        , REGEXP_EXTRACT(line_item_resource_id, '(j-.+?)$', 1) AS bb_emr_cluster_id
    FROM "bb_dwd_costs"
    WHERE 
        line_item_product_code = 'ElasticMapReduce'
        AND resource_tags_user_name <> ''
);

;;;

-- EMR OTHER COSTS
CREATE OR REPLACE VIEW "bb_dwd_amazonemr_other_costs" AS (
    SELECT
        bb_id
        , 'AmazonEMR' AS bb_parent_service
        , resource_tags_aws_elasticmapreduce_job_flow_id AS bb_emr_cluster_id
        , resource_tags_aws_elasticmapreduce_instance_group_role AS bb_emr_instance_role
    FROM "bb_dwd_costs"
    WHERE
        resource_tags_aws_elasticmapreduce_job_flow_id <> '' 
        OR resource_tags_aws_elasticmapreduce_instance_group_role <> ''
);

;;;

--- S3 STORAGE LEVEL
CREATE OR REPLACE VIEW "bb_dwd_amazons3_storage_level" AS (
    SELECT
        bb_id
        , line_item_usage_amount AS bb_s3_gb_month
        , line_item_resource_id AS bb_s3_bucket
        , CASE
            WHEN line_item_operation = 'StandardStorage' THEN 'Standard'
            WHEN line_item_operation = 'IntelligentTieringIAStorage' THEN 'Intelligent Tiering (Infrequent)'
            WHEN line_item_operation = 'IntelligentTieringFAStorage' THEN 'Inlteligent Tiering (Frequent)'
            WHEN line_item_operation = 'IntelligentTieringAIAStorage' THEN 'Intelligent Tiering (Instant Archive)'
            WHEN line_item_operation = 'IntelligentTieringAAStorage' THEN 'Intelligent Tiering (Archive)'
            WHEN line_item_operation = 'IntelligentTieringDAAStorage' THEN 'Intelligent Tiering (Deep Archive)'
            WHEN line_item_operation = 'DeepArchiveStorage' THEN 'Deep Archive'
            WHEN line_item_operation = 'DeepArchiveStagingStorage' THEN 'Deep Archive - Multipart'
            WHEN line_item_operation = 'DeepArchiveS3ObjectOverhead' THEN 'Deep Archive - Name Metadata'
            WHEN line_item_operation = 'DeepArchiveObjectOverhead' THEN 'Deep Archive - Index Metadata'
            WHEN line_item_operation = 'ExpressOneZoneStorage' THEN 'Express One Zone'
        END AS bb_s3_storage_level
        , 'TimedStorage' AS bb_s3_usage_type
        , line_item_operation LIKE '%SizeOverhead%' AS bb_s3_is_overhead
    FROM "bb_dwd_costs"
    WHERE 
        line_item_usage_type LIKE '%-TimedStorage-%' 
        AND line_item_product_code = 'AmazonS3'
);

;;;

-- S3 REQUESTS COSTS
CREATE OR REPLACE VIEW "bb_dwd_amazons3_costs_requests" AS (
    SELECT
        bb_id
        , line_item_operation AS bb_s3_requested_api
        , REGEXP_EXTRACT(line_item_usage_type, '.+?-(Tier\d)', 1) AS bb_s3_request_cost_tier
        , line_item_usage_amount AS bb_s3_num_requests
        , line_item_resource_id AS bb_s3_bucket
        , 'Requests' AS bb_s3_usage_type
    FROM "bb_dwd_costs"
    WHERE 
        line_item_usage_type LIKE '%-Requests-%'
        AND line_item_product_code = 'AmazonS3'
);

;;;

-- MARKETPLACE COSTS
CREATE OR REPLACE VIEW "bb_dwd_aws_marketplace_costs" AS (
    SELECT
        bb_id
        , line_item_legal_entity AS bb_mp_seller
        , product_product_name AS bb_mp_product_name
        , 'AWSMarketplace' AS _bb_service
    FROM "bb_dwd_costs"
    WHERE
        bill_billing_entity = 'AWS Marketplace'
);

;;;

-- FINAL BIG WIDE TABLE > DROP
DROP TABLE IF EXISTS bb_bwt_costs;

;;;

-- FINAL BIG WIDE TABLE
CREATE TABLE "bb_bwt_costs"
WITH (format = 'PARQUET', partitioned_by = ARRAY['bb_usage_year_month'])
AS
    SELECT
        bb_id
        , COALESCE(
            sp.bb_cost_used, sp_unused.bb_sp_cost_unused
            , ri_unused.bb_cost
            , ebs.bb_cost, ec2_od.bb_cost_used, ri.bb_cost_used
            , costs.line_item_unblended_cost
        ) AS bb_cost
        , COALESCE(
            sp_unused._bb_service, ri_unused._bb_service
            , dt._bb_service
            , ebs._bb_service, ec2._bb_service
            , mp._bb_service, costs._bb_service
        ) AS bb_service
        , COALESCE(
            emr_fee.bb_parent_service
            , emr_other.bb_parent_service
            , sp_unused._bb_service, ri_unused._bb_service
            , dt._bb_parent_service
            , ebs._bb_parent_service, ec2._bb_service
            , mp._bb_service, costs._bb_service) AS bb_parent_service
        , ebs.bb_ebs_volume_id
        , ebs.bb_ebs_volume_type
        , ebs.bb_ebs_gb_month
        , ebs._bb_ebs_usage_type AS bb_ebs_usage_type
        , ec2.bb_ec2_instance_id
        , ec2._bb_ec2_instance_type AS bb_ec2_instance_type
        , ec2._bb_ec2_instance_type_family AS bb_ec2_instance_type_family
        , ec2._bb_ec2_instance_type_grand_family AS bb_ec2_instance_type_grand_family
        , COALESCE(ec2.bb_ec2_seconds) AS bb_ec2_seconds
        , COALESCE(ec2.bb_ec2_vcpu_seconds) AS bb_ec2_vcpu_seconds
        , ec2.bb_ec2_platform
        , ri.bb_ri_arn
        , ri.bb_ri_term_year
        , COALESCE(sp_unused.bb_sp_arn, sp.bb_sp_arn) AS bb_sp_arn
        , sp.bb_sp_term_year
        , sp_unused.bb_sp_cost_unused
        , nat._bb_ec2_nat_hours AS bb_ec2_nat_hours
        , COALESCE(nat._bb_vpc_usage_type) AS bb_vpc_usage_type
        , COALESCE(sp_unused.bb_sp_cost_type, sp.bb_sp_cost_type) AS bb_sp_cost_type
        , COALESCE(ri_unused.bb_ri_cost_type, ri.bb_ri_cost_type) AS bb_ri_cost_type
        , COALESCE(emr_name.bb_emr_cluster_name, emr_fee.bb_emr_cluster_name) AS bb_emr_cluster_name
        , COALESCE(emr_other.bb_emr_cluster_id, emr_fee.bb_emr_cluster_id) AS bb_emr_cluster_id
        , emr_other.bb_emr_instance_role
        , COALESCE(ec2_od.bb_ec2_purchase_option, ri.bb_ec2_purchase_option, sp.bb_usage_type) AS bb_ec2_purchase_option
        , s3_store.bb_s3_gb_month, s3_store.bb_s3_storage_level, s3_store.bb_s3_is_overhead
        , s3_requests.bb_s3_request_cost_tier
        , s3_requests.bb_s3_num_requests
        , COALESCE(s3_store.bb_s3_bucket, s3_requests.bb_s3_bucket) AS bb_s3_bucket
        , COALESCE(s3_store.bb_s3_usage_type, s3_requests.bb_s3_usage_type) AS bb_s3_usage_type
        , mp.bb_mp_seller, mp.bb_mp_product_name
        , (
            costs.line_item_line_item_type IS NOT NULL
            AND costs.line_item_line_item_type = 'Credit'
        ) AS bb_is_credit
        , COALESCE(sp_unused._bb_usage_date, ri_unused._bb_usage_date, costs._bb_usage_date) AS bb_usage_date
        , dt._bb_dt_type AS bb_dt_type, dt._bb_dt_gb AS bb_dt_gb
        , rds.bb_rds_usage_type, rds.bb_rds_engine, rds.bb_rds_instance_arn, rds.bb_rds_instance_name
        , rds._bb_rds_platform AS bb_rds_platform
        , rds.bb_rds_azness
        , rds.bb_rds_instance_type, rds._bb_rds_instance_type_family AS bb_rds_instance_type_family
        , rds._bb_rds_instance_type_grand_family AS bb_rds_instance_type_grand_family
        , rds.rds_instance_seconds
        , rds.rds_storage_volume_type, rds.rds_storage_gb_month
        , costs.*

        -- DUE TO ATHENA LIMITATION THIS MUST BE LAST FIELD
        , COALESCE(sp_unused._bb_usage_year_month, ri_unused._bb_usage_year_month, costs._bb_usage_year_month) AS bb_usage_year_month
    FROM "bb_dwd_costs" costs
    LEFT JOIN "bb_dwd_amazonebs_costs" ebs USING (bb_id)
    LEFT JOIN "bb_dwd_amazonec2_costs" ec2 USING (bb_id)
    LEFT JOIN "bb_dwd_amazonec2_od_costs" ec2_od USING (bb_id)
    LEFT JOIN "bb_dwd_ri_costs" ri USING (bb_id)
    LEFT JOIN "bb_dwd_sp_costs" sp USING (bb_id)
    LEFT JOIN "bb_dwd_amazonemr_fee_costs" emr_fee USING (bb_id)
    LEFT JOIN "bb_dwd_amazonemr_other_costs" emr_other USING (bb_id)
    LEFT JOIN "bb_dim_amazonemr_cluster_names" emr_name ON (
        emr_name.bb_emr_cluster_id = emr_other.bb_emr_cluster_id
        OR emr_name.bb_emr_cluster_id = emr_fee.bb_emr_cluster_id
    )
    LEFT JOIN "bb_dwd_amazons3_storage_level" s3_store USING (bb_id)
    LEFT JOIN "bb_dwd_amazons3_costs_requests" s3_requests USING (bb_id)
    LEFT JOIN "bb_dwd_aws_marketplace_costs" mp USING (bb_id)
    LEFT JOIN "bb_dwd_data_transfer_costs" dt USING (bb_id)
    LEFT JOIN "bb_dwd_ec2_nat_costs" nat USING (bb_id)
    LEFT JOIN "bb_dwd_rds_costs" rds USING (bb_id)
    FULL JOIN "bb_dwd_sp_unused_costs" sp_unused USING (bb_id)
    FULL JOIN "bb_dwd_ri_unused_costs" ri_unused USING (bb_id)
    WHERE
        line_item_line_item_type IS NULL
        OR (
            line_item_line_item_type NOT IN ('SavingsPlanNegation', 'SavingsPlanRecurringFee', 'RIFee')
        );

;;;

-- REPORT > EC2 HOURLY USAGE
CREATE OR REPLACE VIEW "bb_rpt_ec2_hourly_usage" AS
WITH expanded_hours AS (
    SELECT
        line_item_usage_start_date
        , line_item_usage_end_date
        , date_add('hour', seq_index, line_item_usage_start_date) AS hour
        , LEAST(1, line_item_usage_amount - seq_index) AS fractional_usage
        , line_item_usage_amount
        , bb_ec2_purchase_option
    FROM
        bb_bwt_costs
    CROSS JOIN UNNEST (
        sequence(0, date_diff('hour', line_item_usage_start_date, line_item_usage_end_date) - 1)
    ) AS t(seq_index)
    WHERE bb_service = 'AmazonEC2' AND bb_ec2_purchase_option IS NOT NULL
),
distributed_usage AS (
    SELECT
        hour
        , CASE
            WHEN fractional_usage > 0 THEN fractional_usage
            ELSE 0
        END AS usage
        , bb_ec2_purchase_option
    FROM
        expanded_hours
)
SELECT hour, usage, bb_ec2_purchase_option
FROM distributed_usage
WHERE usage > 0;

;;;

-- QUALITY CONTROL -> TOTAL
CREATE OR REPLACE VIEW bb_bwt_costs_total_q AS
WITH
    a AS (SELECT SUM(bb_cost) AS bb_bwt_cost_total FROM "bb_bwt_costs")
    , b AS (SELECT SUM(line_item_unblended_cost) AS cur_unblended_total FROM "bb_cur_table")
SELECT
    a.bb_bwt_cost_total
    , b.cur_unblended_total
    , a.bb_bwt_cost_total-b.cur_unblended_total AS diff
FROM a, b;

;;;

--- QUALITY CONTROL > BY SERVICE (EXCEPT RI / SP)
WITH
    a AS (
        SELECT _bb_service
        , line_item_line_item_type
        , line_item_line_item_description
        , SUM(bb_cost) AS total
        FROM "bb_bwt_costs"
        GROUP BY _bb_service
        , line_item_line_item_type
        , line_item_line_item_description
    )
    , b AS (
        SELECT line_item_product_code
        , line_item_line_item_type
        , line_item_line_item_description
        , SUM(line_item_unblended_cost) AS total
        FROM "bb_cur_table"
        GROUP BY line_item_product_code
        , line_item_line_item_type
        , line_item_line_item_description
    )
SELECT
    a._bb_service
    , a.line_item_line_item_type
    , a.line_item_line_item_description
    , a.total AS a_total
    , b.total AS b_total
    , ROUND(a.total-b.total, 2) AS diff
FROM a
FULL JOIN b ON (
    a._bb_service = b.line_item_product_code
    and a.line_item_line_item_type = b.line_item_line_item_type
    and a.line_item_line_item_description = b.line_item_line_item_description
)
WHERE a.line_item_line_item_type NOT IN ('DiscountedUsage', 'SavingsPlanCoveredUsage')
    and ROUND(a.total-b.total, 2) <> 0

;;;


-- QA > SP
WITH a AS (
    SELECT SUM(line_item_unblended_cost) AS total
    FROM "bb_cur_table"
    WHERE line_item_line_item_type = 'SavingsPlanRecurringFee'
), b AS (
    SELECT SUM(bb_cost) AS total
    FROM "bb_bwt_costs"
    WHERE bb_sp_cost_type IS NOT NULL
)
SELECT a.total AS a_total, b.total AS b_total, ROUND(a.total-b.total, 2) AS diff
FROM a, b

;;;

-- QA > RI
WITH a AS (
    SELECT _bb_usage_year_month, SUM(line_item_unblended_cost) AS total
    FROM "bb_dwd_costs"
    WHERE line_item_line_item_type = 'RIFee'
    group by _bb_usage_year_month
), b AS (
    SELECT bb_usage_year_month, SUM(bb_cost) AS total
    FROM "bb_bwt_costs"
    WHERE bb_ri_cost_type IS NOT NULL
    group by bb_usage_year_month
)
SELECT bb_usage_year_month, a.total AS a_total, b.total AS b_total, ROUND(a.total-b.total, 2) AS diff
FROM a
FULL JOIN b on (a._bb_usage_year_month = b.bb_usage_year_month)