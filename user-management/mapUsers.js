let cognitoUserResponse = require("../cognito-users.json");

function newUUID() {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
        const r = Math.random() * 16 | 0, v = c == 'x' ? r : (r & 0x3 | 0x8);
        return v.toString(16);
    });
}

function getCustomAttributeValue(cognitoUser, attributeName) {
    let attribute = cognitoUser["Attributes"].find(function (attribute) {
        return attribute["Name"] === ("custom:" + attributeName);
    });
    return attribute["Value"];
}

function mapToServerContract(cognitoJSON) {
    return cognitoJSON["Users"].map(function (cognitoUser) {
        return {
            "name": cognitoUser["Username"],
            "organisationId": Number(getCustomAttributeValue(cognitoUser, "organisationId")),
            "catchmentId": Number(getCustomAttributeValue(cognitoUser, "catchmentId")),
            "orgAdmin": getCustomAttributeValue(cognitoUser, "isOrganisationAdmin") === "true",
            "admin": getCustomAttributeValue(cognitoUser, "isAdmin") === "true"
        };
    });
}

let output = mapToServerContract(cognitoUserResponse);
console.log(JSON.stringify(output));