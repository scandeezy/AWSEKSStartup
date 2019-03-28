#!/bin/bash
set -eo pipefail

if [ -z $clusterNumber ]; then
    echo "Must specify a cluster number to apply this creation to."
    echo "Example: $ clusterNumber=3 ./create-vpc.sh"
    exit 1
fi

if [ -z $clusterEnv ]; then
    echo "Must specify a cluster environment to apply this to: dev, prod."
    echo "Example: $ clusterEnv=dev ./create-vpc.sh"
    exit 1
fi

#####################################################################
# Initialize
#####################################################################

vpcName="$clusterEnv-$clusterNumber-vpc"
clusterName="k8s-$clusterEnv-$clusterNumber"
nodeGroupName="k8s-workers-$clusterEnv-$clusterNumber"
echo "Creating the VPC $vpcName..."

#####################################################################
# Create VPC
#####################################################################

aws cloudformation create-stack \
	--stack-name $vpcName \
	--template-body file:///`pwd`/amazon-eks-vpc.yaml \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters ParameterKey=ClusterName,ParameterValue=$clusterName

echo "Waiting for the VPC to be complete, this may take several minutes..."
aws cloudformation wait stack-create-complete --stack-name $vpcName
echo "VPC created!  Getting node role for controlling EKS."

#####################################################################
# Collect Data for EKS
#####################################################################

roleName=`aws cloudformation list-stack-resources --stack-name $vpcName | jq '.StackResourceSummaries[] | select(.ResourceType=="AWS::IAM::Role")' | jq -r .PhysicalResourceId`
echo "Role name is " $roleName
roleArn=`aws iam get-role --role-name $roleName | jq -r .Role.Arn`
echo "Role ARN is " $roleArn
subnetIds=`aws cloudformation list-stack-resources --stack-name $vpcName | jq '.StackResourceSummaries[]|select(.["ResourceType"]=="AWS::EC2::Subnet")["PhysicalResourceId"]' -r | paste -sd "," -`
securityGroupIds=`aws cloudformation list-stack-resources --stack-name $vpcName | jq '.StackResourceSummaries[]|select(.["ResourceType"]=="AWS::EC2::SecurityGroup")["PhysicalResourceId"]' -r | paste -sd "," -`

vpcSubnetConfig="subnetIds=$subnetIds,securityGroupIds=$securityGroupIds"
kubeVersion="1.11"

echo "VPC Config is $vpcSubnetConfig"

#####################################################################
# Create EKS Cluster
#####################################################################

echo "Creating the EKS cluster $clusterName"
aws eks create-cluster \
          --name $clusterName \
          --role-arn $roleArn \
          --resources-vpc-config $vpcSubnetConfig \
          --kubernetes-version $kubeVersion \

echo "Waiting for the EKS cluster to be ready..."
aws eks wait cluster-active --name $clusterName
echo "EKS cluster created!"

#####################################################################
# Collect Data for Worker Group
#####################################################################

vpcId=`aws cloudformation list-stack-resources --stack-name $vpcName | jq '.StackResourceSummaries[]|select(.["ResourceType"]=="AWS::EC2::VPC")["PhysicalResourceId"]' -r | paste -sd "," -`
echo "VPC ID is $vpcId"
subnetParameters=`aws cloudformation list-stack-resources --stack-name $vpcName | jq '.StackResourceSummaries[]|select(.["ResourceType"]=="AWS::EC2::Subnet")["PhysicalResourceId"]' -r | paste -sd "," -`
echo "Subnets are " $subnetParameters
echo "SecurityGroup is $securityGroupIds"

#####################################################################
# Create Worker Nodes
#####################################################################

echo "Creating workers for the cluster, $nodeGroupName"
aws cloudformation create-stack \
    --stack-name $nodeGroupName \
    --template-body file:///`pwd`/amazon-eks-nodegroup.yaml \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters ParameterKey=ClusterName,ParameterValue=$clusterName ParameterKey=NodeGroupName,ParameterValue=$nodeGroupName ParameterKey=VpcId,ParameterValue=$vpcId ParameterKey=Subnets,ParameterValue=\"$subnetParameters\" ParameterKey=ClusterControlPlaneSecurityGroup,ParameterValue=$securityGroupIds

echo "Waiting for the worker nodes to be complete, this may take several minutes..."
aws cloudformation wait stack-create-complete --stack-name $nodeGroupName
echo "Workers created!  Getting node role."

#####################################################################
# Update EKS Cluster with Worker Identification
#####################################################################

roleName=`aws cloudformation list-stack-resources --stack-name $nodeGroupName | jq '.StackResourceSummaries[] | select(.ResourceType=="AWS::IAM::Role")' | jq -r .PhysicalResourceId`
echo "Role name is " $roleName
roleArn=`aws iam get-role --role-name $roleName | jq -r .Role.Arn`
echo "Role ARN is " $roleArn

echo "Updating kube config..."
aws eks update-kubeconfig --name $clusterName

echo "Found node role, updating kube config."
cat aws-auth-cm.yaml.template | sed "s|TEMPLATE_ROLE_ARN|$roleArn|" | kubectl apply -f -
