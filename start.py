from pprint import pprint

import boto3
import re

REGION_NAME = 'us-west-2'
ATHENA_OUTPUT_LOCATION = 's3://000-json'
CUR_DB = 'betterbill'
CUR_TABLE = 'cur_table'
PLACEHOLDER_DICT = {
    'CUR_DB': CUR_DB,
    'CUR_TABLE': CUR_TABLE
}


def extract_sql_comments(sql_string):
    sql_string = sql_string.strip()
    lines = sql_string.split('\n')
    comments = []

    # Check if the first line starts with SQL comment characters
    if lines[0].strip().startswith('--'):
        for line in lines:
            line = line.strip()
            if line.startswith('--'):
                comment = line[2:].strip()  # Remove leading '--' and space
                comments.append(comment)
            else:
                break  # Stop at the first non-comment line

    return comments

def remove_leading_sql_comments(sql_string):
    sql_string = sql_string.strip()
    lines = sql_string.split('\n')
    cleaned_lines = []
    skip_comments = True

    for line in lines:
        line = line.strip()
        if skip_comments:
            if line.startswith('--'):
                continue
            else:
                skip_comments = False
        cleaned_lines.append(line)

    return '\n'.join(cleaned_lines)

def run_athena_ddl(ddl_statement, database):
    sql_comments = extract_sql_comments(ddl_statement)
    for c in sql_comments:
        print(f'[run_athena_ddl] {c}')

    ddl_statement = remove_leading_sql_comments(ddl_statement)

    print(f'[run_athena_ddl] RUNNING SQL: {ddl_statement}')

    # Create an Athena client
    athena_client = boto3.client('athena', region_name=REGION_NAME)

    # Define the query input parameters
    query_input = {
        'QueryString': ddl_statement,
        # 'ResultConfiguration': {
        #     'OutputLocation': f's3://{output_bucket}/athena-results/',
        # }
    }

    # Start the query execution
    response = athena_client.start_query_execution(
        QueryString=query_input['QueryString'],
        QueryExecutionContext={
            'Database': database,
            'Catalog': 'AwsDataCatalog'
        },
        ResultConfiguration={
            'OutputLocation': ATHENA_OUTPUT_LOCATION
        }
    )

    # Get the query execution ID
    query_execution_id = response['QueryExecutionId']

    # Wait for the query to complete
    while True:
        query_status = athena_client.get_query_execution(QueryExecutionId=query_execution_id)
        query_state = query_status['QueryExecution']['Status']['State']
        if query_state == 'SUCCEEDED':
            break
        elif query_state == 'FAILED':
            raise Exception(f"Query failed: {query_status['QueryExecution']['Status']['StateChangeReason']}")

    # Retrieve the query results
    result_response = athena_client.get_query_results(QueryExecutionId=query_execution_id)

    print('[run_athena_ddl] RESULTS:')
    pprint(result_response)

    if result_response['ResponseMetadata']['HTTPStatusCode'] != 200:
        raise RuntimeError("[run_athena_ddl] QUERY FAILED")

    return result_response


def replace_placeholders(placeholder_dict, input_string):
    # Create a pattern to match placeholders in the form {KEY}
    pattern = re.compile(r'{(\w+)}')

    # Replacement function to substitute placeholders with values
    def replace_placeholder(match):
        key = match.group(1)
        if key in placeholder_dict:
            return placeholder_dict[key]
        else:
            return match.group(0)  # Return the original placeholder if key not found

    # Replace placeholders in the input string
    result = pattern.sub(replace_placeholder, input_string)

    return result

with open('bb.sql') as f: sql_content = f.read()

sql_list = sql_content.split(';;;')

for sql in sql_list:
    sql = replace_placeholders(PLACEHOLDER_DICT, sql)
    run_athena_ddl(sql, CUR_DB)

