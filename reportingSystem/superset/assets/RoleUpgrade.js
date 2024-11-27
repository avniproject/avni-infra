import fetch from 'node-fetch';

const roleIds = []; // add roles

const permissionIdList = []; // add permission Ids

const baseurl = ""; // provide url

let auth_token = null;


const  login = async () => {

    const response = await fetch(`${baseurl}/api/v1/security/login`,{
        method : "POST",
        headers:{
            'Accept': 'application/json',
            'Content-Type': 'application/json'
        },
        body: JSON.stringify({"username":username, "password":password, "provider": "db", "refresh": true})
    }).then((response)=>{
        if(response.status === 200 && response.headers.get("content-type").includes("application/json")) {
            return  response.json();
        }
        else{
            console.log("Issue in login response"+response);
            process.exit(0);
        }
    }).catch((error)=>{
        console.log(error)
        process.exit(0);
    });

    auth_token = response.access_token;
    console.log(`token is ${auth_token}`);
}

const addPermissionInRole = async (roleId,permissionSet,newPermission) => {
    if(permissionSet.has(newPermission)){
        console.log(`${newPermission} already in ${roleId}`);
        return;
    }
    permissionSet.add(newPermission);
    const response = await fetch(`${baseurl}/api/v1/security/roles/${roleId}/permissions`,{
        method : 'POST',
        headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            "Authorization":`Bearer ${auth_token}`
        },
        body: JSON.stringify({
            "permission_view_menu_ids": [...permissionSet]
        })
    }).then((response)=>{
        if(response.status === 200) {
            return response.json();
        } else{
            console.log("Not updated", response);
            process.exit(0);
        }
    }).catch((error)=>{
        console.log(error)
        process.exit(0);
    })

    if(response.result && response.result.permission_view_menu_ids && permissionSet.size === response.result.permission_view_menu_ids.length){
        console.log(`${newPermission} added to role ${roleId}`);
    }

}

const getPermissionSet = async(roleId)=>{

    const response = await fetch(`${baseurl}/api/v1/security/roles/${roleId}/permissions/`,{
        method : 'GET',
        headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            "Authorization":`Bearer ${auth_token}`
        }
    }).then((response)=>{
        if(response.status === 200 && response.headers.get("content-type").includes("application/json")) {
            return  response.json();
        }
        else{
            console.log("Not getting permission");
            process.exit(0);
        }
    }).catch((error)=>{
        console.log(error)
        process.exit(0);
    })
    const set = new Set();
    response.result.map((element)=>element.id).forEach(element=>set.add(element));
    return set;
}


const doTask = async () => {
    await login();
    for(var role of roleIds){
        for(var permission of permissionIdList) {
            const permissionSet = await getPermissionSet(role);
            await addPermissionInRole(role, permissionSet, permission);
        }
    }
};

doTask();