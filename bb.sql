-- 基础表（基于字段形成年月字段）
CREATE OR REPLACE VIEW "bb_dwd_costs" AS (
  SELECT 
    CONCAT(CAST(line_item_usage_start_date AS VARCHAR), identity_line_item_id) AS bb_id
    , CAST(line_item_usage_start_date AS DATE) AS bb_usage_date
    , product_region_code AS bb_region
    , DATE_FORMAT(line_item_usage_start_date, '%Y-%m') AS bb_usage_year_month
    , line_item_unblended_cost AS bb_cost_no_tax
    , line_item_line_item_description AS bb_cost_desc
    , product_region_code AS bb_cost_region_code
    , *
  FROM "{CUR_TABLE}"  -- !!! CHANGE TO YOUR CUR TABLE
  WHERE 
    line_item_usage_account_id = '{ACCOUNT_ID}'  -- !!! CHANGE TO YOUR ACCOUNT ID
    AND bill_invoice_id <> '' -- blank means not final = possible dups
);


-- EBS 费用（字段重命名）、筛选拆表
CREATE OR REPLACE VIEW "bb_dwd_amazonebs_costs" AS (
    SELECT
        bb_id
        , 'AmazonEBS' AS bb_service,
        , line_item_resource_id AS bb_ebs_volume_id
        , product_volume_api_name AS bb_ebs_volume_type
        , line_item_usage_amount AS bb_ebs_gb_month
        , line_item_unblended_cost AS bb_cost
    FROM "bb_dwd_costs"
    WHERE
        line_item_usage_type LIKE '%EBS:Volume%'
        AND line_item_line_item_type <> 'Credit'
);



-- EC2
CREATE OR REPLACE VIEW "bb_dwd_amazonec2_costs" AS (
    SELECT
        bb_id
        , 'AmazonEC2' AS bb_service
        , line_item_resource_id AS bb_ec2_instance_id
        , product_instance_type as bb_ec2_instance_class
        , line_item_usage_amount * 3600 AS bb_ec2_seconds
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

CREATE OR REPLACE VIEW "bb_dwd_amazonec2_od_costs" AS (
    SELECT
        bb_id
        , 'On Demand' AS bb_ec2_usage_type
        , line_item_unblended_cost AS bb_cost_used
    FROM "bb_dwd_costs"
    WHERE line_item_line_item_type = 'Usage' AND product_product_family = 'Compute Instance'
);

CREATE OR REPLACE VIEW "bb_dwd_amazonec2_ri_paid_costs" AS (
    SELECT
        bb_id
        , reservation_reservation_a_r_n AS bb_ec2_ri_arn
        , line_item_usage_amount AS bb_ec2_hours
        , REGEXP_EXTRACT(line_item_usage_type, '^.+?:(.+)$', 1) AS bb_ec2_instance_class_inferred
    FROM "bb_dwd_costs"
    WHERE line_item_line_item_type = 'RIFee'
);

CREATE OR REPLACE VIEW "bb_dwd_amazonec2_ri_costs" AS (
    SELECT
        bb_id
        , 'Reserved Instance' AS bb_ec2_usage_type
        , reservation_reservation_a_r_n as bb_ec2_ri_arn
        , pricing_lease_contract_length AS bb_ec2_ri_term_year
        , reservation_effective_cost as bb_cost_used
    FROM "bb_dwd_costs"
    WHERE line_item_line_item_type = 'DiscountedUsage'
);



CREATE OR REPLACE VIEW "bb_dwd_sp_costs" AS (
    SELECT
        bb_id
        , 'Savings Plans' AS bb_usage_type
        , savings_plan_savings_plan_a_r_n AS bb_sp_arn
        , savings_plan_savings_plan_effective_cost AS bb_cost_used
    FROM "bb_dwd_costs"
    WHERE line_item_line_item_type = 'SavingsPlanCoveredUsage'
);


CREATE OR REPLACE VIEW "bb_dwd_sp_negation_costs" AS (
    SELECT
        bb_id
        , savings_plan_savings_plan_a_r_n AS bb_sp_arn
        , line_item_unblended_cost AS bb_sp_cost_negation
        , 0 AS bb_ec2_seconds
    FROM "bb_dwd_costs"
    WHERE line_item_line_item_type = 'SavingsPlanNegation'
);

CREATE OR REPLACE VIEW "bb_dwd_sp_unused_costs" AS (
    SELECT
        bb_id
        , savings_plan_savings_plan_a_r_n AS bb_sp_arn
        , line_item_unblended_cost AS bb_sp_cost_negation
    FROM "bb_dwd_costs" r
    WHERE line_item_line_item_type = 'SavingsPlanRecurringFee'
    LEFT JOIN bb_dwd_sp_negation_costs ON (bb_sp_arn)
);

CREATE OR REPLACE VIEW "bb_dwd_amazonemr_fee_costs" AS (
    SELECT
        bb_id
        , 'AmazonEMR' AS bb_parent_service
        , resource_tags_user_name AS bb_emr_cluster_name
        , REGEXP_EXTRACT(line_item_resource_id, '(j-.+?)$', 1) AS bb_emr_cluster_id
    FROM "bb_dwd_costs"
    WHERE line_item_product_code = 'ElasticMapReduce'
);

-- 潜在 BUG: 集群名字是有可能变化的
CREATE OR REPLACE VIEW "bb_dim_amazonemr_cluster_names" AS (
    SELECT
        DISTINCT resource_tags_user_name AS bb_emr_cluster_name
        , REGEXP_EXTRACT(line_item_resource_id, '(j-.+?)$', 1) AS bb_emr_cluster_id
    FROM "bb_dwd_costs"
    WHERE 
        line_item_product_code = 'ElasticMapReduce'
        AND bb_emr_cluster_name <> ''
);

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


---
--- S3

CREATE OR REPLACE VIEW "bb_dwd_amazons3_storage_level" AS (
    SELECT
        bb_id
        , line_item_usage_amount AS bb_s3_gb_month
        , line_item_resource_id AS bb_s3_bucket
        , CASE
            WHEN line_item_operation = 'StandardStorage' THEN 'STD'
            WHEN line_item_operation = 'IntelligentTieringIAStorage' THEN 'IT-IA'
            WHEN line_item_operation = 'IntelligentTieringFAStorage' THEN 'IT-FA'
            ELSE line_item_operation
        END AS bb_s3_storage_level
        , 'TimedStorage' AS bb_s3_cost_type
    FROM "bb_dwd_costs"
    WHERE 
        line_item_usage_type LIKE '%-TimedStorage-%' 
        AND line_item_product_code = 'AmazonS3'
);

CREATE OR REPLACE VIEW "bb_dwd_amazons3_costs_requests" AS (
    SELECT
        bb_id
        , line_item_operation AS bb_s3_requested_api
        , REGEXP_EXTRACT(line_item_usage_type, '.+?-(Tier\d)', 1) AS bb_s3_request_cost_tier
        , line_item_usage_amount AS bb_s3_num_requests
        , line_item_resource_id AS bb_s3_bucket
        , 'Requests' AS bb_s3_cost_type
    FROM "bb_dwd_costs"
    WHERE 
        line_item_usage_type LIKE '%-Requests-%'
        AND line_item_product_code = 'AmazonS3'
);


CREATE OR REPLACE VIEW "bb_dws_costs" AS (
    SELECT
        COALESCE(ebs.bb_service, ec2.bb_service, costs.line_item_product_code) AS bb_service
        , COALESCE(emr_fee.bb_parent_service, emr_other.bb_parent_service) AS bb_parent_service
        , ebs.bb_ebs_volume_id
        , ebs.bb_ebs_volume_type
        , ebs.bb_ebs_gb_month
        , ec2.bb_ec2_instance_id
        , ec2.bb_ec2_instance_class
        , COALESCE(sp_neg.bb_ec2_seconds, ec2.bb_ec2_seconds) AS bb_ec2_seconds
        , ec2.bb_ec2_platform
        , ec2_ri.bb_ec2_ri_arn
        , ec2_ri.bb_ec2_ri_term_year
        , sp.bb_sp_arn
        , COALESCE(emr_name.bb_emr_cluster_name, emr_fee.bb_emr_cluster_name) AS bb_emr_cluster_name
        , COALESCE(emr_other.bb_emr_cluster_id, emr_fee.bb_emr_cluster_id) AS bb_emr_cluster_id
        , emr_other.bb_emr_instance_role
        , COALESCE(ec2_od.bb_ec2_usage_type, ec2_ri.bb_ec2_usage_type, sp.bb_usage_type) AS bb_ec2_usage_type
        , COALESCE(ebs.bb_cost, ec2_od.bb_cost_used, ec2_ri.bb_cost_used, sp.bb_cost_used, costs.line_item_unblended_cost) AS bb_cost
        , s3_store.bb_s3_gb_month
        , s3_store.bb_s3_storage_level
        , s3_requests.bb_s3_request_cost_tier
        , s3_requests.bb_s3_num_requests
        , COALESCE(s3_store.bb_s3_bucket, s3_requests.bb_s3_bucket) AS bb_s3_bucket
        , COALESCE(s3_store.bb_s3_cost_type, s3_requests.bb_s3_cost_type) AS bb_s3_cost_type
        , costs.*
    FROM "bb_dwd_costs" costs
    LEFT JOIN "bb_dwd_amazonebs_costs" ebs USING (bb_id)
    LEFT JOIN "bb_dwd_amazonec2_costs" ec2 USING (bb_id)
    LEFT JOIN "bb_dwd_amazonec2_od_costs" ec2_od USING (bb_id)
    LEFT JOIN "bb_dwd_amazonec2_ri_costs" ec2_ri USING (bb_id)
    LEFT JOIN "bb_dwd_sp_costs" sp USING (bb_id)
    LEFT JOIN "bb_dwd_sp_negation_costs" sp_neg USING (bb_id)
    LEFT JOIN "bb_dwd_amazonemr_fee_costs" emr_fee USING (bb_id)
    LEFT JOIN "bb_dwd_amazonemr_other_costs" emr_other USING (bb_id)
    LEFT JOIN "bb_dim_amazonemr_cluster_names" emr_name ON (
        emr_name.bb_emr_cluster_id = emr_other.bb_emr_cluster_id
        OR emr_name.bb_emr_cluster_id = emr_fee.bb_emr_cluster_id
    )
    LEFT JOIN "bb_dwd_amazons3_storage_level" s3_store USING (bb_id)
    LEFT JOIN "bb_dwd_amazons3_costs_requests" s3_requests USING (bb_id)
);