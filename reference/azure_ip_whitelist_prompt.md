# Azure IP Whitelist Instructions for setting up PowerBI and Data Factory access to AWS PostgreSQL RDS 

## Step 1: Download the Azure IP Ranges JSON File

1. Visit the Microsoft download page: [https://www.microsoft.com/en-us/download/details.aspx?id=56519](https://www.microsoft.com/en-us/download/details.aspx?id=56519)

2. Click the "Download" button on the page.

3. Save the JSON file to your computer. The file is usually named something like `ServiceTags_Public_YYYYMMDD.json` (where YYYYMMDD is the date of publication).

## Step 2: Use AI Tool (ChatGPT, Claude, etc.) to Generate AWS CLI Commands

Copy and paste the following prompt to your AI assistant, replacing `YOUR-SECURITY-GROUP-ID` with your actual AWS security group ID:

```
I have downloaded the Azure IP ranges JSON file (ServiceTags_Public_YYYYMMDD.json) from Microsoft. 

Please help me generate AWS CLI commands to whitelist the following Azure services in my security group:
- DataFactory.CentralIndia
- DataFactory.WestUS2
- PowerBI.WestUS2
- PowerBI.CentralIndia

The commands should be in the format:

aws ec2 authorize-security-group-ingress \
  --group-id YOUR-SECURITY-GROUP-ID \
  --ip-permissions 'IpProtocol=tcp,FromPort=5432,ToPort=5432,IpRanges=[...]'

Please create two commands:
1. One for all IPv4 ranges
2. One for all IPv6 ranges

I want to allow these Azure services to connect to my PostgreSQL database on port 5432.
```

## Example Expected Output from AI Tool

The AI should provide you with two AWS CLI commands similar to these:

### IPv4 Command

```bash
aws ec2 authorize-security-group-ingress \
  --group-id YOUR-SECURITY-GROUP-ID \
  --ip-permissions 'IpProtocol=tcp,FromPort=5432,ToPort=5432,IpRanges=[
    {CidrIp=4.213.106.128/27,Description="DataFactory.CentralIndia"},
    {CidrIp=20.43.121.48/28,Description="DataFactory.CentralIndia"},
    ...additional IPs...
  ]'
```

### IPv6 Command

```bash
aws ec2 authorize-security-group-ingress \
  --group-id YOUR-SECURITY-GROUP-ID \
  --ip-permissions 'IpProtocol=tcp,FromPort=5432,ToPort=5432,Ipv6Ranges=[
    {CidrIpv6=2603:1040:a06::/121,Description="DataFactory.CentralIndia"},
    {CidrIpv6=2603:1040:a06::80/122,Description="DataFactory.CentralIndia"},
    ...additional IPs...
  ]'
```

You can then use these commands in your AWS environment to add these IP ranges to your security group.
