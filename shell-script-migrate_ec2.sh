#!/bin/bash

# Variables (replace these with your specific values)
INSTANCE_ID="i-xxxxxxxxxxxxxxxxx"
REGION="us-east-1"
KMS_KEY_ID="xxxxxxxx-xxxxxxxxx-xxxxx-xxxxxxxx" # Optional: specify if you want to use a specific KMS key
NEW_INSTANCE_TYPE="t2.micro" # Optional: specify if you want to change the instance type

# Ensure the instance type is specified, otherwise use the original instance type
if [ -z "$NEW_INSTANCE_TYPE" ]; then
    echo "Error: NEW_INSTANCE_TYPE is not specified."
    exit 1
fi

# Step 1: Create an AMI from the existing EC2 instance
echo "Creating an AMI from the existing instance..."
AMI_ID=$(aws ec2 create-image --instance-id $INSTANCE_ID --name "Encrypted-AMI-$(date +%Y%m%d%H%M%S)" --no-reboot --query "ImageId" --output text --region $REGION)

if [ -z "$AMI_ID" ]; then
    echo "Error: Failed to create AMI."
    exit 1
fi

echo "Waiting for AMI to become available..."
aws ec2 wait image-available --image-ids $AMI_ID --region $REGION

# Step 2: Get the original instance's properties
echo "Retrieving the original instance's properties..."
ORIGINAL_INSTANCE_DETAILS=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0]" --output json --region $REGION)

# Extract necessary details
SUBNET_ID=$(echo $ORIGINAL_INSTANCE_DETAILS | jq -r '.SubnetId')
SECURITY_GROUPS=$(echo $ORIGINAL_INSTANCE_DETAILS | jq -r '.SecurityGroups[].GroupId' | tr '\n' ' ')
NO_PUBLIC_IP=$(echo $ORIGINAL_INSTANCE_DETAILS | jq -r '.PublicIpAddress == null')

if [ -z "$SUBNET_ID" ] || [ -z "$SECURITY_GROUPS" ]; then
    echo "Error: Failed to retrieve original instance properties."
    exit 1
fi

# Step 3: Launch a new instance from the AMI
echo "Launching a new EC2 instance from the AMI..."
LAUNCH_COMMAND="aws ec2 run-instances --image-id $AMI_ID --count 1 --instance-type $NEW_INSTANCE_TYPE --subnet-id $SUBNET_ID --security-group-ids $SECURITY_GROUPS --block-device-mappings '[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"DeleteOnTermination\":true,\"Encrypted\":true}}]' --region $REGION"

# Check if the instance had no public IP, and add the --no-associate-public-ip-address flag if true
if [ "$NO_PUBLIC_IP" = "true" ]; then
    LAUNCH_COMMAND="$LAUNCH_COMMAND --no-associate-public-ip-address"
fi

NEW_INSTANCE_DETAILS=$(eval $LAUNCH_COMMAND)

# Get the new instance ID
NEW_INSTANCE_ID=$(echo $NEW_INSTANCE_DETAILS | jq -r '.Instances[0].InstanceId')

if [ -z "$NEW_INSTANCE_ID" ]; then
    echo "Error: Failed to launch the new instance."
    exit 1
fi

# Optional: Tag the New Instance to Match the Old One
echo "Tagging the new instance..."
aws ec2 create-tags --resources $NEW_INSTANCE_ID --tags Key=Name,Value=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Name" --query 'Tags[0].Value' --output text) --region $REGION

echo "Waiting for the new instance to become available..."
aws ec2 wait instance-running --instance-ids $NEW_INSTANCE_ID --region $REGION

# Step 4: (Optional) Delete the old unencrypted instance
# echo "Terminating the old unencrypted EC2 instance..."
# aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION

echo "Old instance terminated. New instance is running with ID: $NEW_INSTANCE_ID"

# Step 5: Clean up old resources (AMI and snapshots) if not needed
echo "Deregistering the AMI and cleaning up snapshots..."
aws ec2 deregister-image --image-id $AMI_ID --region $REGION
SNAPSHOT_IDS=$(aws ec2 describe-snapshots --owner-ids self --query "Snapshots[?Description=='Created by CreateImage($INSTANCE_ID) for ami-*'].SnapshotId" --output text --region $REGION)

for SNAPSHOT_ID in $SNAPSHOT_IDS; do
    aws ec2 delete-snapshot --snapshot-id $SNAPSHOT_ID --region $REGION
done

echo "Completed shifting EC2 instance to encrypted volumes."
