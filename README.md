# AzureOpenshiftCSW
Deployment notes integrating Openshift on Azure with Secure Workload

Azure Openshift Docs - https://aka.ms/openshift/docs
https://docs.microsoft.com/en-us/azure/openshift/tutorial-create-cluster

az login
az account set --subscription <subscriptionID>
az provider register -n Microsoft.RedHatOpenShift --wait
az provider register -n Microsoft.Compute --wait
az provider register -n Microsoft.Storage --wait
az provider register -n Microsoft.Authorization --wait

----

LOCATION=eastus                 # the location of your cluster
RESOURCEGROUP=aro-rg            # the name of the resource group where you want to create your cluster
CLUSTER=tetrationAOS            # the name of your cluster

----

Create a Resource Group
az group create -n aro-rg --location eastus

Create a VNET
az network vnet create --resource-group aro-rg --name aro-vnet --address-prefixes 10.0.0.0/22

Create a Subnet within the recently created VNET for the Master/API servers
az network vnet subnet create --resource-group aro-rg --vnet-name aro-vnet --name master-subnet --address-prefixes 10.0.0.0/23 --service-endpoints Microsoft.ContainerRegistry

Create a Subnet within the recently create VNET for the worker nodes
az network vnet subnet create --resource-group aro-rg --vnet-name aro-vnet --name worker-subnet --address-prefixes 10.0.2.0/23 --service-endpoints Microsoft.ContainerRegistry

We need to expose the Master Subnet as a provider 
az network vnet subnet update --name master-subnet --resource-group aro-rg --vnet-name aro-vnet --disable-private-link-service-network-policies true

Create the Openshift Cluster
az aro create --resource-group aro-rg --name tetrationAOS --vnet aro-vnet --master-subnet master-subnet --worker-subnet worker-subnet --pull-secret @pull-secret.txt

------

To Delete the Openshift Cluster
az aro delete --resource-group aro-rg --name tetrationAOS

------

Gain GUI/URL access to Openshift

Get password for kubeadmin
az aro list-credentials --name tetrationAOS --resource-group aro-rg

Get the console URL:
az aro show --name tetrationAOS --resource-group aro-rg --query "consoleProfile.url" -o tsv

Install openshift CLI - on mac:
brew install openshift-cli

CLI Login:
oc login https://api.qojjh2ff.eastus.aroapp.io:6443 -u kubeadmin -p DeRzI-bd8Tc-FqTyy-ymLPR

------

Prepare Cluster for Tetration

--- Revise this section to use the yaml for cluster-admin
oc create serviceaccount tetration.read.only
oc create clusterrole tetration.read.only --verb=get,list,watch --resource=endpoints,namespaces,nodes,pods,services,ingresses
oc create clusterrolebinding tetration.read.only --clusterrole=tetration.read.only --serviceaccount=default:tetration.read.only
--- Revise this section to use the yaml for cluster-admin

oc apply -f rbac/01-authentication.yaml

Retrieve AuthToken Secret name

oc get serviceaccount -n kube-system -o yaml tetration

This may output multiple "secret" names
- I grabbed both, as one of them will work

oc get secret -n kube-system -o yaml tetration-dockercfg-6mk6l

Copy the token

Create Tetration External Orchestrator Configuration

Type - K8s
Name/Description
Paste the Token in "Auth Token"
Check "Accept Self-signed Cert"
Disable Secure Connector if necessary
Host list - Enter URL of API server along with port
Golden Rules - Enter port of kubelet 10250

In the output look for "ID" this is the cluster ID and can be used for Scopes/Filters

---
Master node(s):

TCP     6443*       Kubernetes API Server
TCP     2379-2380   etcd server client API
TCP     10250       Kubelet API
TCP     10251       kube-scheduler
TCP     10252       kube-controller-manager
TCP     10255       Read-Only Kubelet API

Worker nodes:

TCP     10250       Kubelet API
TCP     10255       Read-Only Kubelet API
TCP     30000-32767 NodePort Services
---

Create Scope
- Name <name> & Type - Kubernetes
- Query = ✻ orchestrator_system/cluster_name contains Openshift
- Query = ✻ orchestrator_system/cluster_id = <id from external orchestrator>

Create Inventory Filter for Openshift and the Worker Nodes
- Name <name>
- Query = ✻ orchestrator_system/cluster_id = <id from external orchestrator>

Worker Nodes = ✻ orchestrator_system/cluster_id = <id from external orchestrator> and Address = <worker node subnet>


Create Software Agent Config Profile
- Enable Enforcement
- Enable Preserve Rules

Create Software Agent Intent
Apply the recently created Profile to the Inventory Filter created for Openshift

------

Add agents via Daemonset

Download the agent

---
Open the agent shell script and copy it
Paste the shell script in the install script yaml

Create a namespace for tetration and apply daemonset

oc create namespace tetration

"one of these will work"
oc adm policy add-scc-to-user privileged -z tetration -n tetration
oc adm policy add-scc-to-user privileged -z default -n tetration

oc describe scc
- check for PID

oc apply -f agent

oc get pods -n tetration
oc get daemonset -n tetration
---

oc describe pod agent-24nmj -n tetration

With the k8s agent - exec format error - ./kubectl: cannot execute binary file


