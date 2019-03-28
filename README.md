# AWSEKSStartup
Helper scripts to get EKS setup.

# Explanation
I went to collapse the provided YAML files from the AWS getting started tutorial, and realized once I had some stacks up that EKS in CloudFormation is a bad idea (you're unable to update the cluster without replacing it).  Pulling that out, and making the workers a separate set enables us to update the pieces as needed for security patches or other miscellaneous updates.

# Requirements
jq
awscli already setup
patience

Hope this helps others quickly get an EKS setup so they can use it.
