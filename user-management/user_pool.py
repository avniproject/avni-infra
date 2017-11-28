import sys
import subprocess

user_pool_id = lambda id: ["--user-pool-id", id]
app_client = lambda name: ["--client-name", name]

print subprocess.check_output(
    ["aws", "cognito-idp", "create-user-pool-client"] + user_pool_id(sys.argv[1]) + app_client("openchs"))
