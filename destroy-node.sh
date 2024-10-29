REGION="ca-central-1"
DOMAIN="gridengine.local"
HOSTNAME="$1"
NODE_IP="$2"
SSH_KEY_PATH="/home/ubuntu/linux-key.pem"
MASTER_NODE_IP="10.0.12.1"


# Remove the node form the clister
ssh -i "$SSH_KEY_PATH" ubuntu@"$MASTER_NODE_IP" << EOF
  sudo qconf -dh "$HOSTNAME"
  sudo qconf -ds "$HOSTNAME"
  sudo qconf -de "$HOSTNAME"
EOF

# Leave the domain
ssh -i "$SSH_KEY_PATH" ubuntu@"$NODE_IP" << EOF
  sudo realm leave "$DOMAIN"
EOF


# Destroy the VM
INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" --filters "Name=private-ip-address,Values=$NODE_IP" --query "Reservations[*].Instances[*].InstanceId" --output text)
aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID"



