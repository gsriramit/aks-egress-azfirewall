#!/bin/bash

# Declare the variables
LOC='eastus2'
RG='rg-aksegressfirewalltest-dev0005'
AZKEYVAULT_NAME='kv-azsecretstore-dev01'
SUBSCRIPTION_ID=""
CLUSTER_NAME="aks-egress-dev01"
TENANT_ID=""
PLUGIN=azure
VNET_NAME="aks-egress-vnet"
AKSSUBNET_NAME="aks-subnet"
# DO NOT CHANGE FWSUBNET_NAME - This is currently a requirement for Azure Firewall.
FWSUBNET_NAME="AzureFirewallSubnet"
FWNAME="aks-egress-fw"
FWPUBLICIP_NAME="aks-egress-fwpublicip"
FWIPCONFIG_NAME="aks-egress-fwconfig"
FWROUTE_TABLE_NAME="aks-egress-fwrt"
FWROUTE_NAME="aks-egress-fwrn"
FWROUTE_NAME_INTERNET="aks-egress-fwinternet"

az login
az account set -s "${SUBSCRIPTION_ID}"

# Create Resource Group
az group create --name $RG --location $LOC

# Dedicated virtual network with AKS subnet
az network vnet create \
    --resource-group $RG \
    --name $VNET_NAME \
    --location $LOC \
    --address-prefixes 10.42.0.0/16 \
    --subnet-name $AKSSUBNET_NAME \
    --subnet-prefix 10.42.1.0/24

# Dedicated subnet for Azure Firewall (Firewall name cannot be changed)
az network vnet subnet create \
    --resource-group $RG \
    --vnet-name $VNET_NAME \
    --name $FWSUBNET_NAME \
    --address-prefix 10.42.2.0/24

# Create a standard SKU public IP resource that will be used as the Azure Firewall frontend address.
az network public-ip create -g $RG -n $FWPUBLICIP_NAME -l $LOC --sku "Standard"

# Install Azure Firewall preview CLI extension
az extension add --name azure-firewall
# Deploy Azure Firewall
az network firewall create -g $RG -n $FWNAME -l $LOC --enable-dns-proxy true

# Configure Firewall IP Config
az network firewall ip-config create -g $RG -f $FWNAME -n $FWIPCONFIG_NAME --public-ip-address $FWPUBLICIP_NAME --vnet-name $VNET_NAME

# Capture Firewall IP Address for Later Use
FWPUBLIC_IP=$(az network public-ip show -g $RG -n $FWPUBLICIP_NAME --query "ipAddress" -o tsv)
FWPRIVATE_IP=$(az network firewall show -g $RG -n $FWNAME --query "ipConfigurations[0].privateIpAddress" -o tsv)

# Create UDR and add a route for Azure Firewall

az network route-table create -g $RG -l $LOC --name $FWROUTE_TABLE_NAME
az network route-table route create -g $RG --name $FWROUTE_NAME --route-table-name $FWROUTE_TABLE_NAME --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address $FWPRIVATE_IP
az network route-table route create -g $RG --name $FWROUTE_NAME_INTERNET --route-table-name $FWROUTE_TABLE_NAME --address-prefix $FWPUBLIC_IP/32 --next-hop-type Internet

# Add FW Network Rules
az network firewall network-rule create -g $RG -f $FWNAME --collection-name 'aksfwnr' -n 'apiudp' --protocols 'UDP' --source-addresses '*' --destination-addresses "AzureCloud.$LOC" --destination-ports 1194 --action allow --priority 100
az network firewall network-rule create -g $RG -f $FWNAME --collection-name 'aksfwnr' -n 'apitcp' --protocols 'TCP' --source-addresses '*' --destination-addresses "AzureCloud.$LOC" --destination-ports 9000
az network firewall network-rule create -g $RG -f $FWNAME --collection-name 'aksfwnr' -n 'time' --protocols 'UDP' --source-addresses '*' --destination-fqdns 'ntp.ubuntu.com' --destination-ports 123

# Add FW Application Rules
az network firewall application-rule create -g $RG -f $FWNAME --collection-name 'aksfwar' -n 'fqdn' --source-addresses '*' --protocols 'http=80' 'https=443' --fqdn-tags "AzureKubernetesService" --action allow --priority 100

# Associate route table with next hop to Firewall to the AKS subnet
az network vnet subnet update -g $RG --vnet-name $VNET_NAME --name $AKSSUBNET_NAME --route-table $FWROUTE_TABLE_NAME

# Create SP and Assign Permission to Virtual Network
az ad sp create-for-rbac -n "$aks-egress-sp"

# Extract the ClientId and the ClientSecret from the output of the previous command and update the variables
APPID="8f9ead90-0948-447c-9039-08f386f9b2b4"
PASSWORD="xIOZXqEpx6DsX1imdTRGEv~k~-pEUbc1ye"
VNETID=$(az network vnet show -g $RG --name $VNET_NAME --query id -o tsv)

# Assign SP Permission to VNET
az role assignment create --assignee $APPID --scope $VNETID --role "Network Contributor"

# Get the ID of the subnet to which AKS will be deployed
SUBNETID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME --name $AKSSUBNET_NAME --query id -o tsv)

# Create the AKS cluster
# OutboundType should be defined and strictly be UserDefinedRouting 
# As we are deploying to an existing subnet (this is a prerequisite for UDR outbound), the subnetId needs to be mentioned
az aks create -g $RG -n $CLUSTER_NAME -l $LOC \
  --node-count 2 --generate-ssh-keys \
  --network-plugin $PLUGIN \
  --outbound-type userDefinedRouting \
  --service-cidr 10.41.0.0/16 \
  --dns-service-ip 10.41.0.10 \
  --docker-bridge-address 172.17.0.1/16 \
  --vnet-subnet-id $SUBNETID \
  --service-principal $APPID \
  --client-secret $PASSWORD \
  --api-server-authorized-ip-ranges $FWPUBLIC_IP

# Retrieve your IP address
CURRENT_IP=$(dig @resolver1.opendns.com ANY myip.opendns.com +short)
# Add to AKS approved list
az aks update -g $RG -n $CLUSTER_NAME --api-server-authorized-ip-ranges $CURRENT_IP/32

# Get the credentials to the cluster
az aks get-credentials -g $RG -n $CLUSTER_NAME

# Deploy the sample workload application
kubectl apply -f Deployment/K8sManifests/WorkloadDeployment.yaml
# List all the created services
kubectl get services
# Get the IP of the Load Balancer Service
SERVICE_IP=$(kubectl get svc voting-app -o jsonpath='{.status.loadBalancer.ingress[*].ip}')

# Add the needed NAT rule to handle the asymmetric routing issue
az network firewall nat-rule create --collection-name exampleset --destination-addresses $FWPUBLIC_IP --destination-ports 80 --firewall-name $FWNAME --name inboundrule --protocols Any --resource-group $RG --source-addresses '*' --translated-port 80 --action Dnat --priority 100 --translated-address $SERVICE_IP

# CleanUp
az group delete -g $RG