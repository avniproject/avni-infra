import sys
import subprocess
import json

user_pool_id = lambda id: ["--user-pool-id", id]
app_client = lambda name: ["--client-name", name]

response = subprocess.check_output(
    ["aws", "cognito-idp", "create-user-pool-client"] + user_pool_id(sys.argv[1]) + app_client("openchs"))

response_dict = json.loads(response)
print response_dict['UserPoolClient']["ClientId"]
