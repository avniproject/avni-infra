import sys
import subprocess
import json

user_pool_id = sys.argv[1]


def json_input(username, password, email, org_name, org_id, catchment_id, phone_number, is_user="true",
               is_admin="false",
               is_org_admin="false"):
    return {
        'Username': username,
        'UserPoolId': user_pool_id,
        'ValidationData': [],
        'UserAttributes': [
            {'Name': 'email', 'Value': email},
            {'Name': 'phone_number', 'Value': phone_number},
            {'Name': 'custom:organisationId', 'Value': org_id},
            {'Name': 'custom:organisationName', 'Value': org_name},
            {'Name': 'custom:isUser', 'Value': is_user},
            {'Name': 'custom:catchmentId', 'Value': catchment_id},
            {'Name': 'custom:isAdmin', 'Value': is_admin},
            {'Name': 'custom:isOrganisationAdmin', 'Value': is_org_admin}
        ],
        'ForceAliasCreation': True,
        'TemporaryPassword': password,
        'DesiredDeliveryMediums': ['SMS', 'EMAIL']
    }


def create_user(user):
    user_json = json_input(user["username"], user["password"], user["email"], user["org_name"], user["org_id"],
                           user["catchment_id"], user["phone_number"], user["is_user"], user["is_admin"],
                           user["is_org_admin"])
    print subprocess.check_output(
        ["aws", "cognito-idp", "admin-create-user", "--cli-input-json", json.dumps(user_json)])


users = json.load(open('./users.json'))
map(create_user, users)
