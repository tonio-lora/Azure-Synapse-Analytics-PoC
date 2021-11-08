#!/bin/bash
#
# This script finishes the database level configuration that cannot be done in Terraform. It should be executed after the Terraform 
# deployment because Terraform outputs several variables used by this script.
#
#

# Make sure this configuration script hasn't been executed already
if [ -f "configure.complete" ]; then
    echo "ERROR: It appears this configuration has already been completed.";
    exit 1;
fi

# Make sure we have all the required artifacts
declare -A artifactFiles
artifactFiles[1]="artifacts/Auto_Ingestion_Logging_DDL.sql"
artifactFiles[2]="artifacts/Auto_Pause_and_Resume.json.tmpl"
artifactFiles[3]="artifacts/Create_Resource_Class_Logins.sql.tmpl"
artifactFiles[4]="artifacts/Create_Resource_Class_Users.sql"
artifactFiles[5]="artifacts/Demo_Data_Serverless_DDL.sql"
artifactFiles[6]="artifacts/DS_Synapse_Managed_Identity.json.tmpl"
artifactFiles[7]="artifacts/LS_Synapse_Managed_Identity.json.tmpl"
artifactFiles[8]="artifacts/Parquet_Auto_Ingestion_Metadata.csv"
artifactFiles[9]="artifacts/Parquet_Auto_Ingestion.json.tmpl"
artifactFiles[10]="artifacts/triggerPause.json.tmpl"
artifactFiles[11]="artifacts/triggerResume.json.tmpl"
for file in "${artifactFiles[@]}"; do
    if ! [ -f "$file" ]; then
        echo "ERROR: The required $file file does not exist. Please clone the git repo with the supporting artifacts and then execute this script.";
        exit 1;
    fi
done

# Try and determine if we're executing from within the Azure Cloud Shell
if [ ! "${AZUREPS_HOST_ENVIRONMENT}" = "cloud-shell/1.0" ]; then
    echo "ERROR: It doesn't appear like your executing this from the Azure Cloud Shell. Please use the Azure Cloud Shell at https://shell.azure.com";
    exit 1;
fi

# Try and get a token to validate that we're logged into Azure CLI
aadToken=$(az account get-access-token --resource=https://dev.azuresynapse.net --query accessToken --output tsv 2>&1)
if echo "$aadToken" | grep -q "ERROR"; then
    echo "ERROR: You don't appear to be logged in to Azure CLI. Please login to the Azure CLI using 'az login'";
    exit 1;
fi

# Make sure the Terraform deployment was completed by checking if the terraform.tfstate file exists
if ! [ -f "terraform.tfstate" ]; then
    echo "ERROR: It does not appear that the Terraform deployment was completed for the Synaspe Analytics environment. That must be completed before executing this script.";
    exit 1;
fi

# Get environment details
azureSubscriptionName=$(az account show --query "name" --output tsv 2>&1)
azureSubscriptionID=$(az account show --query "id" --output tsv 2>&1)
azureUsername=$(az account show --query "user.name" --output tsv 2>&1)
echo "Azure Subscription: ${azureSubscriptionName}"
echo "Azure Subscription ID: ${azureSubscriptionID}"
echo "Azure AD Username: ${azureUsername}"

# Get the output variables from Terraform
synapseAnalyticsWorkspaceResourceGroup=$(terraform output -raw synapse_analytics_workspace_resource_group 2>&1)
synapseAnalyticsWorkspaceName=$(terraform output -raw synapse_analytics_workspace_name 2>&1)
synapseAnalyticsSQLPoolName=$(terraform output -raw synapse_sql_pool_name 2>&1)
synapseAnalyticsSQLAdmin=$(terraform output -raw synapse_sql_administrator_login 2>&1)
synapseAnalyticsSQLAdminPassword=$(terraform output -raw synapse_sql_administrator_login_password 2>&1)
datalakeName=$(terraform output -raw datalake_name 2>&1)
datalakeKey=$(terraform output -raw datalake_key 2>&1)
privateEndpointsEnabled=$(terraform output -raw private_endpoints_enabled 2>&1)
if echo "$synapseAnalyticsWorkspaceName" | grep -q "The output variable requested could not be found"; then
    echo "ERROR: It doesn't look like a 'terraform apply' was performed. This script needs to be executed after the Terraform deployment.";
    exit 1;
fi
echo "Synapse Analytics Workspace Resource Group: ${synapseAnalyticsWorkspaceResourceGroup}"
echo "Synapse Analytics Workspace: ${synapseAnalyticsWorkspaceName}"
echo "Synapse Analytics Dedicated SQL endpoint: ${synapseAnalyticsWorkspaceName}.sql.azuresynapse.net"
echo "Synapse Analytics SQL Admin: ${synapseAnalyticsSQLAdmin}"
echo "Synapse Analytics SQL Admin password: ${synapseAnalyticsSQLAdminPassword}"
echo "Data Lake Name: ${datalakeName}"

# If Private Endpoints are enabled, temporarily disable the firewalls so we can copy files and perform additional configuration
if echo "$privateEndpointsEnabled" | grep -q "true"; then
    az storage account update --name ${datalakeName} --resource-group ${synapseAnalyticsWorkspaceResourceGroup} --default-action Allow --only-show-errors -o none
    az synapse workspace firewall-rule create --name AllowAllWindowsAzureIps --resource-group ${synapseAnalyticsWorkspaceResourceGroup} --workspace-name ${synapseAnalyticsWorkspaceName} --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 --only-show-errors -o none
fi

# Enable Result Set Cache
echo "Enabling Result Set Caching..."
sqlcmd -U ${synapseAnalyticsSQLAdmin} -P ${synapseAnalyticsSQLAdminPassword} -S tcp:${synapseAnalyticsWorkspaceName}.sql.azuresynapse.net -d master -I -Q "ALTER DATABASE ${synapseAnalyticsSQLPoolName} SET RESULT_SET_CACHING ON;"

echo "Creating the auto pause/resume pipeline..."

# Copy the Auto_Pause_and_Resume Pipeline template and update the variables
cp artifacts/Auto_Pause_and_Resume.json.tmpl artifacts/Auto_Pause_and_Resume.json 2>&1
sed -i "s/REPLACE_SUBSCRIPTION/${azureSubscriptionID}/g" artifacts/Auto_Pause_and_Resume.json
sed -i "s/REPLACE_RESOURCE_GROUP/${synapseAnalyticsWorkspaceResourceGroup}/g" artifacts/Auto_Pause_and_Resume.json
sed -i "s/REPLACE_SYNAPSE_ANALYTICS_WORKSPACE_NAME/${synapseAnalyticsWorkspaceName}/g" artifacts/Auto_Pause_and_Resume.json
sed -i "s/REPLACE_SYNAPSE_ANALYTICS_SQL_POOL_NAME/${synapseAnalyticsSQLPoolName}/g" artifacts/Auto_Pause_and_Resume.json

# Create the Auto_Pause_and_Resume Pipeline in the Synapse Analytics Workspace
az synapse pipeline create --only-show-errors -o none --workspace-name ${synapseAnalyticsWorkspaceName} --name "Auto Pause and Resume" --file @artifacts/Auto_Pause_and_Resume.json

# Create the Pause/Resume triggers in the Synapse Analytics Workspace
az synapse trigger create --only-show-errors -o none --workspace-name ${synapseAnalyticsWorkspaceName} --name Pause --file @artifacts/triggerPause.json.tmpl
az synapse trigger create --only-show-errors -o none --workspace-name ${synapseAnalyticsWorkspaceName} --name Resume --file @artifacts/triggerResume.json.tmpl

echo "Creating the parquet auto ingestion pipeline..."

# Create the logging schema and tables for the Auto Ingestion pipeline
sqlcmd -U ${synapseAnalyticsSQLAdmin} -P ${synapseAnalyticsSQLAdminPassword} -S tcp:${synapseAnalyticsWorkspaceName}.sql.azuresynapse.net -d ${synapseAnalyticsSQLPoolName} -I -i artifacts/Auto_Ingestion_Logging_DDL.sql > /dev/null 2>&1

# Create the Resource Class Logins
cp artifacts/Create_Resource_Class_Logins.sql.tmpl artifacts/Create_Resource_Class_Logins.sql 2>&1
sed -i "s/REPLACE_PASSWORD/${synapseAnalyticsSQLAdminPassword}/g" artifacts/Create_Resource_Class_Logins.sql
sqlcmd -U ${synapseAnalyticsSQLAdmin} -P ${synapseAnalyticsSQLAdminPassword} -S tcp:${synapseAnalyticsWorkspaceName}.sql.azuresynapse.net -d master -I -i artifacts/Create_Resource_Class_Logins.sql

# Create the Resource Class Users
sed -i "s/REPLACE_SYNAPSE_ANALYTICS_SQL_POOL_NAME/${synapseAnalyticsSQLPoolName}/g" artifacts/Create_Resource_Class_Users.sql
sqlcmd -U ${synapseAnalyticsSQLAdmin} -P ${synapseAnalyticsSQLAdminPassword} -S tcp:${synapseAnalyticsWorkspaceName}.sql.azuresynapse.net -d ${synapseAnalyticsSQLPoolName} -I -i artifacts/Create_Resource_Class_Users.sql

# Create the LS_Synapse_Managed_Identity Linked Service. This is primarily used for the Auto Ingestion pipeline.
cp artifacts/LS_Synapse_Managed_Identity.json.tmpl artifacts/LS_Synapse_Managed_Identity.json 2>&1
sed -i "s/REPLACE_SYNAPSE_ANALYTICS_WORKSPACE_NAME/${synapseAnalyticsWorkspaceName}/g" artifacts/LS_Synapse_Managed_Identity.json
sed -i "s/REPLACE_SYNAPSE_ANALYTICS_SQL_POOL_NAME/${synapseAnalyticsSQLPoolName}/g" artifacts/LS_Synapse_Managed_Identity.json
az synapse linked-service create --only-show-errors -o none --workspace-name ${synapseAnalyticsWorkspaceName} --name LS_Synapse_Managed_Identity --file @artifacts/LS_Synapse_Managed_Identity.json

# Create the DS_Synapse_Managed_Identity Dataset. This is primarily used for the Auto Ingestion pipeline.
cp artifacts/DS_Synapse_Managed_Identity.json.tmpl artifacts/DS_Synapse_Managed_Identity.json 2>&1
sed -i "s/REPLACE_SYNAPSE_ANALYTICS_WORKSPACE_NAME/${synapseAnalyticsWorkspaceName}/g" artifacts/DS_Synapse_Managed_Identity.json
sed -i "s/REPLACE_SYNAPSE_ANALYTICS_SQL_POOL_NAME/${synapseAnalyticsSQLPoolName}/g" artifacts/DS_Synapse_Managed_Identity.json
az synapse dataset create --only-show-errors -o none --workspace-name ${synapseAnalyticsWorkspaceName} --name DS_Synapse_Managed_Identity --file @artifacts/DS_Synapse_Managed_Identity.json

# Copy the Parquet Auto Ingestion Pipeline template and update the variables
cp artifacts/Parquet_Auto_Ingestion.json.tmpl artifacts/Parquet_Auto_Ingestion.json 2>&1
sed -i "s/REPLACE_SYNAPSE_ANALYTICS_WORKSPACE_NAME/${synapseAnalyticsWorkspaceName}/g" artifacts/Parquet_Auto_Ingestion.json
sed -i "s/REPLACE_DATALAKE_NAME/${datalakeName}/g" artifacts/Parquet_Auto_Ingestion.json
sed -i "s#REPLACE_DATALAKE_KEY#${datalakeKey}#g" artifacts/Parquet_Auto_Ingestion.json
sed -i "s/REPLACE_SYNAPSE_ANALYTICS_SQL_POOL_NAME/${synapseAnalyticsSQLPoolName}/g" artifacts/Parquet_Auto_Ingestion.json

# Update the Parquet Auto Ingestion Metadata file tamplate with the correct storage account and then upload it
sed -i "s/REPLACE_DATALAKE_NAME/${datalakeName}/g" artifacts/Parquet_Auto_Ingestion_Metadata.csv
az storage copy --only-show-errors -o none --destination https://${datalakeName}.blob.core.windows.net/data/ --source artifacts/Parquet_Auto_Ingestion_Metadata.csv > /dev/null 2>&1

# Copy sample data for the Parquet Auto Ingestion pipeline
az storage copy --only-show-errors -o none --recursive --destination https://${datalakeName}.blob.core.windows.net/data/sample --source https://oneclickpocadls.blob.core.windows.net/data/sample/* --source-sas 'sp=rle&st=2021-11-07T15:44:01Z&se=2022-11-08T23:44:01Z&spr=https&sv=2020-08-04&sr=c&sig=WnRS%2F9g84KZ2T%2F%2FlxcUasaSt1nuJ9awTC9HfnrJYwRs%3D' > /dev/null 2>&1
# Create the Auto_Pause_and_Resume Pipeline in the Synapse Analytics Workspace
az synapse pipeline create --only-show-errors -o none --workspace-name ${synapseAnalyticsWorkspaceName} --name "Parquet Auto Ingestion" --file @artifacts/Parquet_Auto_Ingestion.json

echo "Creating the Demo Data database using Synapse Serverless SQL..."

# Create a Demo Data database using Synapse Serverless SQL
sqlcmd -U ${synapseAnalyticsSQLAdmin} -P ${synapseAnalyticsSQLAdminPassword} -S tcp:${synapseAnalyticsWorkspaceName}-ondemand.sql.azuresynapse.net -d master -I -Q "CREATE DATABASE [Demo Data (Serverless)];"

# Create the Views over the external data
sqlcmd -U ${synapseAnalyticsSQLAdmin} -P ${synapseAnalyticsSQLAdminPassword} -S tcp:${synapseAnalyticsWorkspaceName}-ondemand.sql.azuresynapse.net -d "Demo Data (Serverless)" -I -i artifacts/Demo_Data_Serverless_DDL.sql

# Restore the firewall rules on ADLS an Azure Synapse Analytics. That was needed temporarily to apply these settings.
if echo "$privateEndpointsEnabled" | grep -q "true"; then
    echo "Restoring firewall rules..."
    az storage account update --name ${datalakeName} --resource-group ${synapseAnalyticsWorkspaceResourceGroup} --default-action Deny --only-show-errors -o none
    az synapse workspace firewall-rule delete --name AllowAllWindowsAzureIps --resource-group ${synapseAnalyticsWorkspaceResourceGroup} --workspace-name ${synapseAnalyticsWorkspaceName} --only-show-errors -o none --yes
fi

echo "Uploading SQL Scipts and Notebook samples..."

# Update PowerShell Scripts to upload SQL Scripts - This can be replaced once az cli supports SQL Scripts
sed -i "s/REPLACE_SYNAPSE_ANALYTICS_WORKSPACE_NAME/${synapseAnalyticsWorkspaceName}/g" ./upload_sql_scripts.ps1
sed -i "s/REPLACE_SYNAPSE_ANALYTICS_SQL_POOL_NAME/${synapseAnalyticsSQLPoolName}/g" ./upload_sql_scripts.ps1

# Update Notebook variables
sed -i "s/REPLACE_DATALAKE_NAME/${datalakeName}/g" ./artifacts/synapse_spark_notebooks/01-load-staging-table.ipynb
sed -i "s/REPLACE_DATALAKE_NAME/${datalakeName}/g" ./artifacts/synapse_spark_notebooks/02-load-dimension-table.ipynb
sed -i "s/REPLACE_DATALAKE_NAME/${datalakeName}/g" ./artifacts/synapse_spark_notebooks/03-load-fact-table.ipynb

# Create Sample Notebooks
# Missing adding folder option: Synapse Spark Notebooks\
az synapse notebook import --workspace-name ${synapseAnalyticsWorkspaceName} --name "01-load-staging-table" --file "@artifacts/synapse_spark_notebooks/01-load-staging-table.ipynb"
az synapse notebook import --workspace-name ${synapseAnalyticsWorkspaceName} --name "02-load-dimension-table" --file "@artifacts/synapse_spark_notebooks/02-load-dimension-table.ipynb"
az synapse notebook import --workspace-name ${synapseAnalyticsWorkspaceName} --name "03-load-fact-table" --file "@artifacts/synapse_spark_notebooks/03-load-fact-table.ipynb"


echo "Deployment complete!"
touch configure.complete
