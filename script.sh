#!/bin/bash

REGION="ca-central-1"
INSTANCE_NAME="vm-$(uuidgen | cut -d'-' -f1)"
DOMAIN="gridengine.local"
KERBROS_DOMAIN="GRIDENGINE.LOCAL"
HOSTNAME="$INSTANCE_NAME.$DOMAIN"
AMI_ID="ami-0c9fe21b60e28d514"            
INSTANCE_TYPE="t2.micro"         
KEY_NAME="linux-key"                 
SECURITY_GROUP_ID="sg-009d3a60f5343fbbd"   
SUBNET_ID="subnet-0006b02cbcef77d4d"
IAM_ROLE="GridEngineEC2Instance"
SSH_KEY_PATH="/home/ubuntu/linux-key.pem"      
LIBSSL_PACKAGE_PATH="/home/ubuntu/libssl1.0.2_1.0.2r-1~deb9u1_amd64.deb"
COMMON_PACKAGE_PATH="/home/ubuntu/gridengine-common_8.1.9+dfsg-4+deb9u2_all.deb"
CLIENT_PACKAGE_PATH="/home/ubuntu/gridengine-client_8.1.9+dfsg-4+deb9u2_amd64.deb"
EXEC_PACKAGE_PATH="/home/ubuntu/gridengine-exec_8.1.9+dfsg-4+deb9u2_amd64.deb"
REMOTE_FILE_PATH="/tmp/"
KEYTAB_FILE_PATH="/etc/config.keytab"
MSAD_IP="10.0.10.140"
MSAD_NAME="dc"
MASTER_NODE_NAME="masternode"
MASTER_NODE_IP="10.0.12.1"
MSAD_SP_NAME="domainjoin"       

# Create new instance (new node)
INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" --security-group-ids "$SECURITY_GROUP_ID" --subnet-id "$SUBNET_ID" --associate-public-ip-address --iam-instance-profile Name="$IAM_ROLE" --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" --query "Instances[0].InstanceId" --output text)

echo "Waiting for the instance to be ready..."
aws ec2 wait instance-status-ok --region "$REGION" --instance-ids "$INSTANCE_ID"
sleep 30

# Fetch private IP of the VM
PRIVATE_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

# Transfer the packages to the new node
sudo scp -i "$SSH_KEY_PATH" "$LIBSSL_PACKAGE_PATH" "$COMMON_PACKAGE_PATH" "$CLIENT_PACKAGE_PATH" "$EXEC_PACKAGE_PATH" ubuntu@"$PRIVATE_IP":"$REMOTE_FILE_PATH/"
sudo scp -i "$SSH_KEY_PATH" "$KEYTAB_FILE_PATH" ubuntu@"$PRIVATE_IP":"/tmp/"


# Set Hostname
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$PRIVATE_IP" << EOF
  sudo apt update -y
  sudo hostnamectl set-hostname "$HOSTNAME"
  sudo mv /tmp/config.keytab "$KEYTAB_FILE_PATH"
EOF

sleep 5

# The rest of the setup
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$PRIVATE_IP" << EOF
  VM_IP=\$(hostname -I | awk '{print \$1}')
  echo "\$VM_IP $HOSTNAME \${HOSTNAME%%.*}" | sudo tee -a /etc/hosts
  echo "10.0.12.1 $MASTER_NODE_NAME.$DOMAIN" | sudo tee -a /etc/hosts > /dev/null

  # Stop local name resolution
  sudo systemctl stop systemd-resolved
  sudo systemctl disable systemd-resolved
  sudo rm /etc/resolv.conf
  echo -e "nameserver $MSAD_IP\nsearch $DOMAIN\ndomain $DOMAIN" | sudo tee /etc/resolv.conf

  # Prepare config for Kerberos
  echo "krb5-config krb5-config/default_realm string $KERBROS_DOMAIN" | sudo debconf-set-selections
  echo "krb5-config krb5-config/kerberos_servers string $MSAD_NAME.$DOMAIN" | sudo debconf-set-selections
  echo "krb5-config krb5-config/admin_server string $MSAD_NAME.$DOMAIN" | sudo debconf-set-selections
  sudo DEBIAN_FRONTEND=noninteractive apt install -y krb5-user libkrb5-dev sssd sssd-tools realmd packagekit

  # Update krb5.conf
  sudo sed -i '/^\s*default_realm = /a \        rdns=false' /etc/krb5.conf

  # Join the domain
  sudo kinit -kt /etc/config.keytab "$MSAD_SP_NAME"@"$KERBROS_DOMAIN"
  sudo realm join "$DOMAIN"
EOF

# Add new node into Master node
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$MASTER_NODE_IP" << EOF
  sudo qconf -ah "$HOSTNAME"
  sudo qconf -as "$HOSTNAME"
EOF


# Install GE packages 
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$PRIVATE_IP" << EOF
  sudo apt install -y debconf-utils
  sudo apt-get install -y libmunge2 libhwloc5
  echo "bsd-mailx mail/alias string" | sudo debconf-set-selections
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y bsd-mailx tcsh libjemalloc1

  # Prepare configuration for GE packages
  echo "shared/gridenginemaster shared/gridenginemaster string $MASTER_NODE_NAME.$DOMAIN" | sudo debconf-set-selections
  echo "shared/gridengineconfig shared/gridengineconfig boolean true" | sudo debconf-set-selections
  echo "shared/gridenginecell shared/gridenginecell string default" | sudo debconf-set-selections

  # Set ownership for the parameters
  echo "gridengine-common shared/gridenginemaster string $MASTER_NODE_NAME.$DOMAIN" | sudo debconf-set-selections
  echo "gridengine-common shared/gridengineconfig boolean true" | sudo debconf-set-selections
  echo "gridengine-common shared/gridenginecell string default" | sudo debconf-set-selections

  echo "gridengine-client shared/gridenginemaster string $MASTER_NODE_NAME.$DOMAIN" | sudo debconf-set-selections
  echo "gridengine-client shared/gridengineconfig boolean true" | sudo debconf-set-selections
  echo "gridengine-client shared/gridenginecell string default" | sudo debconf-set-selections

  echo "gridengine-exec shared/gridenginemaster string $MASTER_NODE_NAME.$DOMAIN" | sudo debconf-set-selections
  echo "gridengine-exec shared/gridengineconfig boolean true" | sudo debconf-set-selections
  echo "gridengine-exec shared/gridenginecell string default" | sudo debconf-set-selections

  export DEBIAN_FRONTEND=noninteractive
  sudo dpkg -i "$REMOTE_FILE_PATH"/libssl1.0.2_1.0.2r-1~deb9u1_amd64.deb
  sudo dpkg -i "$REMOTE_FILE_PATH"/gridengine-common_8.1.9+dfsg-4+deb9u2_all.deb
  sudo dpkg -i "$REMOTE_FILE_PATH"/gridengine-client_8.1.9+dfsg-4+deb9u2_amd64.deb
  sudo dpkg -i "$REMOTE_FILE_PATH"/gridengine-exec_8.1.9+dfsg-4+deb9u2_amd64.deb
EOF
