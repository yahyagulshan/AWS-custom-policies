#!/bin/bash

# Set the required variables
INSTANCE_ID="i-xxxxxxxxxxxxxxxxxxx"  # Replace with your instance ID
REGION="us-east-1"                # Replace with your desired region
KMS_KEY_ID="xxxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxxxx"  # Replace with your KMS Key ID (optional)

# Step 1: Create a snapshot of the unencrypted volume
echo "Creating a snapshot of the unencrypted volume..."
VOLUME_ID=$(aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" "Name=attachment.device,Values=/dev/sda1" --query "Volumes[0].VolumeId" --output text --region $REGION)
SNAPSHOT_ID=$(aws ec2 create-snapshot --volume-id $VOLUME_ID --description "Snapshot of unencrypted volume" --query "SnapshotId" --output text --region $REGION)

# Wait for the snapshot to complete
aws ec2 wait snapshot-completed --snapshot-ids $SNAPSHOT_ID --region $REGION

# Step 2: Create an encrypted copy of the snapshot
echo "Creating an encrypted copy of the snapshot..."
ENCRYPTED_SNAPSHOT_ID=$(aws ec2 copy-snapshot --source-snapshot-id $SNAPSHOT_ID --source-region $REGION --encrypted --kms-key-id $KMS_KEY_ID --description "Encrypted snapshot" --query "SnapshotId" --output text --region $REGION)

# Wait for the encrypted snapshot to complete
aws ec2 wait snapshot-completed --snapshot-ids $ENCRYPTED_SNAPSHOT_ID --region $REGION

# Step 3: Create an encrypted volume from the encrypted snapshot
echo "Creating an encrypted volume from the encrypted snapshot..."
ENCRYPTED_VOLUME_ID=$(aws ec2 create-volume --snapshot-id $ENCRYPTED_SNAPSHOT_ID --availability-zone $(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].Placement.AvailabilityZone" --output text --region $REGION) --volume-type gp2 --query "VolumeId" --output text --region $REGION)

# Step 4: Stop the instance
echo "Stopping the instance..."
aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $REGION

# Wait for the instance to stop
aws ec2 wait instance-stopped --instance-ids $INSTANCE_ID --region $REGION

# Step 5: Detach the unencrypted volume and attach the encrypted volume
echo "Detaching the unencrypted volume and attaching the encrypted volume..."
aws ec2 detach-volume --volume-id $VOLUME_ID --region $REGION
aws ec2 attach-volume --volume-id $ENCRYPTED_VOLUME_ID --instance-id $INSTANCE_ID --device /dev/sda1 --region $REGION

# Step 6: Start the instance
echo "Starting the instance..."
aws ec2 start-instances --instance-ids $INSTANCE_ID --region $REGION

echo "The unencrypted volume has been replaced with an encrypted volume."
