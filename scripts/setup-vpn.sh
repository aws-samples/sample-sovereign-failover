#!/bin/bash

# Script to establish Site-to-Site VPN connection between FRA and THF partitions
# New architecture: FRA has AWS VPN Gateway, THF has Libreswan customer gateway

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Setting up Site-to-Site VPN between FRA and THF ===${NC}\n"

# Configuration
FRA_REGION="eu-central-1"
THF_REGION="eusc-de-east-1"
THF_PROFILE="thf"

# Step 1: Get FRA VPN Gateway ID
echo -e "${YELLOW}Step 1: Getting FRA VPN Gateway ID...${NC}"

FRA_VGW_ID=$(aws ec2 describe-vpn-gateways \
  --region $FRA_REGION \
  --filters "Name=tag:Name,Values=FRA-VPN-Gateway" "Name=state,Values=available" \
  --query 'VpnGateways[0].VpnGatewayId' \
  --output text)

if [ "$FRA_VGW_ID" == "None" ] || [ -z "$FRA_VGW_ID" ]; then
  echo -e "${RED}Error: FRA VPN Gateway not found. Please deploy FraStack first.${NC}"
  exit 1
fi

echo -e "  FRA VPN Gateway: ${GREEN}$FRA_VGW_ID${NC}\n"

# Step 2: Get THF Libreswan instance information
echo -e "${YELLOW}Step 2: Getting THF Libreswan instance information...${NC}"

THF_INSTANCE_ID=$(aws ec2 describe-instances \
  --region $THF_REGION \
  --profile $THF_PROFILE \
  --filters "Name=tag:Name,Values=THF-Libreswan-VPN-Gateway" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

if [ "$THF_INSTANCE_ID" == "None" ] || [ -z "$THF_INSTANCE_ID" ]; then
  echo -e "${RED}Error: THF Libreswan instance not found. Please deploy ThfStack first.${NC}"
  exit 1
fi

THF_LIBRESWAN_PUBLIC_IP=$(aws ec2 describe-instances \
  --region $THF_REGION \
  --profile $THF_PROFILE \
  --instance-ids $THF_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

THF_LIBRESWAN_PRIVATE_IP=$(aws ec2 describe-instances \
  --region $THF_REGION \
  --profile $THF_PROFILE \
  --instance-ids $THF_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

echo -e "  THF Libreswan Instance: ${GREEN}$THF_INSTANCE_ID${NC}"
echo -e "  THF Libreswan Public IP: ${GREEN}$THF_LIBRESWAN_PUBLIC_IP${NC}"
echo -e "  THF Libreswan Private IP: ${GREEN}$THF_LIBRESWAN_PRIVATE_IP${NC}\n"

# Step 3: Get VPC CIDRs
echo -e "${YELLOW}Step 3: Getting VPC CIDR blocks...${NC}"

FRA_VPC_CIDR="10.0.0.0/16"

THF_VPC_CIDR=$(aws ec2 describe-vpcs \
  --region $THF_REGION \
  --profile $THF_PROFILE \
  --filters "Name=tag:Name,Values=ThfStack/ThfVpc" \
  --query 'Vpcs[0].CidrBlock' \
  --output text)

echo -e "  FRA VPC CIDR: ${GREEN}$FRA_VPC_CIDR${NC}"
echo -e "  THF VPC CIDR: ${GREEN}$THF_VPC_CIDR${NC}\n"

# Step 4: Check for existing VPN connection and verify if it's working
echo -e "${YELLOW}Step 4: Checking for existing FRA VPN Connection...${NC}"

FRA_VPN_ID=$(aws ec2 describe-vpn-connections \
  --region $FRA_REGION \
  --filters "Name=tag:Name,Values=FRA-to-THF-Libreswan-VPN" "Name=state,Values=pending,available" \
  --query 'VpnConnections[0].VpnConnectionId' \
  --output text)

VPN_IS_VALID=false

if [ "$FRA_VPN_ID" != "None" ] && [ -n "$FRA_VPN_ID" ]; then
  echo -e "  Found existing VPN connection: ${GREEN}$FRA_VPN_ID${NC}"
  
  # Check if VPN is connected to the correct Libreswan IP
  EXISTING_CGW_IP=$(aws ec2 describe-vpn-connections \
    --region $FRA_REGION \
    --vpn-connection-ids $FRA_VPN_ID \
    --query 'VpnConnections[0].CustomerGatewayConfiguration' \
    --output text | grep -o '<customer_gateway_id>[^<]*' | head -1 | sed 's/<customer_gateway_id>//')
  
  if [ -n "$EXISTING_CGW_IP" ]; then
    EXISTING_CGW_ID=$(aws ec2 describe-vpn-connections \
      --region $FRA_REGION \
      --vpn-connection-ids $FRA_VPN_ID \
      --query 'VpnConnections[0].CustomerGatewayId' \
      --output text)
    
    EXISTING_CGW_PUBLIC_IP=$(aws ec2 describe-customer-gateways \
      --region $FRA_REGION \
      --customer-gateway-ids $EXISTING_CGW_ID \
      --query 'CustomerGateways[0].IpAddress' \
      --output text 2>/dev/null || echo "")
    
    if [ "$EXISTING_CGW_PUBLIC_IP" == "$THF_LIBRESWAN_PUBLIC_IP" ]; then
      echo -e "  Customer Gateway IP matches: ${GREEN}$EXISTING_CGW_PUBLIC_IP${NC}"
      
      # Check tunnel status
      TUNNEL1_STATUS=$(aws ec2 describe-vpn-connections \
        --region $FRA_REGION \
        --vpn-connection-ids $FRA_VPN_ID \
        --query 'VpnConnections[0].VgwTelemetry[0].Status' \
        --output text)
      
      TUNNEL2_STATUS=$(aws ec2 describe-vpn-connections \
        --region $FRA_REGION \
        --vpn-connection-ids $FRA_VPN_ID \
        --query 'VpnConnections[0].VgwTelemetry[1].Status' \
        --output text)
      
      echo -e "  Tunnel 1 Status: ${YELLOW}$TUNNEL1_STATUS${NC}"
      echo -e "  Tunnel 2 Status: ${YELLOW}$TUNNEL2_STATUS${NC}"
      
      if [ "$TUNNEL1_STATUS" == "UP" ] || [ "$TUNNEL2_STATUS" == "UP" ]; then
        echo -e "  ${GREEN}✓ VPN connection is UP and connected to correct IP${NC}"
        echo -e "  ${GREEN}Skipping VPN recreation - using existing connection${NC}\n"
        VPN_IS_VALID=true
      else
        echo -e "  ${YELLOW}VPN tunnels are DOWN - will recreate connection${NC}"
      fi
    else
      echo -e "  ${YELLOW}Customer Gateway IP mismatch:${NC}"
      echo -e "    Expected: $THF_LIBRESWAN_PUBLIC_IP"
      echo -e "    Found: $EXISTING_CGW_PUBLIC_IP"
      echo -e "  ${YELLOW}Will recreate VPN connection${NC}"
    fi
  fi
fi

# Only delete and recreate if VPN is not valid
if [ "$VPN_IS_VALID" = false ]; then
  if [ "$FRA_VPN_ID" != "None" ] && [ -n "$FRA_VPN_ID" ]; then
    echo -e "  Deleting existing FRA VPN Connection..."
    aws ec2 delete-vpn-connection --region $FRA_REGION --vpn-connection-id $FRA_VPN_ID || true
    
    # Wait for deletion
    echo -e "  Waiting for VPN connection to delete..."
    for i in {1..24}; do
      VPN_STATE=$(aws ec2 describe-vpn-connections --region $FRA_REGION --vpn-connection-ids $FRA_VPN_ID --query 'VpnConnections[0].State' --output text 2>/dev/null || echo "deleted")
      if [ "$VPN_STATE" == "deleted" ]; then
        echo -e "  ${GREEN}FRA VPN connection deleted${NC}"
        break
      fi
      sleep 5
    done
  fi
else
  # Skip to the end if VPN is valid
  echo -e "\n${GREEN}=== VPN Setup Complete (Using Existing Connection) ===${NC}"
  echo -e "\nVPN Connection ID: $FRA_VPN_ID"
  echo -e "Libreswan Instance: $THF_INSTANCE_ID"
  echo -e "\nTo check VPN status:"
  echo -e "  FRA side: ${YELLOW}aws ec2 describe-vpn-connections --region $FRA_REGION --vpn-connection-ids $FRA_VPN_ID --query 'VpnConnections[0].VgwTelemetry' --output table${NC}"
  echo -e "  THF side: ${YELLOW}aws ssm start-session --region $THF_REGION --profile $THF_PROFILE --target $THF_INSTANCE_ID${NC}"
  echo -e "            Then run: ${YELLOW}sudo ipsec status${NC}\n"
  exit 0
fi

# Step 5: Create/update FRA Customer Gateway pointing to Libreswan
echo -e "${YELLOW}Step 5: Creating FRA Customer Gateway pointing to THF Libreswan...${NC}"

# Check if customer gateway already exists
FRA_CGW_ID=$(aws ec2 describe-customer-gateways \
  --region $FRA_REGION \
  --filters "Name=tag:Name,Values=FRA-Customer-Gateway-to-THF-Libreswan" "Name=state,Values=available" \
  --query 'CustomerGateways[0].CustomerGatewayId' \
  --output text)

if [ "$FRA_CGW_ID" != "None" ] && [ -n "$FRA_CGW_ID" ]; then
  echo -e "  Deleting existing FRA Customer Gateway..."
  aws ec2 delete-customer-gateway --region $FRA_REGION --customer-gateway-id $FRA_CGW_ID || true
  
  # Wait for deletion
  for i in {1..10}; do
    CGW_STATE=$(aws ec2 describe-customer-gateways --region $FRA_REGION --customer-gateway-ids $FRA_CGW_ID --query 'CustomerGateways[0].State' --output text 2>/dev/null || echo "deleted")
    if [ "$CGW_STATE" == "deleted" ]; then
      break
    fi
    sleep 2
  done
fi

# Create new customer gateway
FRA_CGW_ID=$(aws ec2 create-customer-gateway \
  --region $FRA_REGION \
  --type ipsec.1 \
  --public-ip $THF_LIBRESWAN_PUBLIC_IP \
  --bgp-asn 65000 \
  --tag-specifications 'ResourceType=customer-gateway,Tags=[{Key=Name,Value=FRA-Customer-Gateway-to-THF-Libreswan}]' \
  --query 'CustomerGateway.CustomerGatewayId' \
  --output text)

echo -e "  FRA Customer Gateway: ${GREEN}$FRA_CGW_ID${NC} (points to $THF_LIBRESWAN_PUBLIC_IP)\n"

# Step 6: Create FRA VPN Connection
echo -e "${YELLOW}Step 6: Creating FRA VPN Connection...${NC}"

# Create new VPN connection
FRA_VPN_ID=$(aws ec2 create-vpn-connection \
  --region $FRA_REGION \
  --type ipsec.1 \
  --customer-gateway-id $FRA_CGW_ID \
  --vpn-gateway-id $FRA_VGW_ID \
  --options '{"StaticRoutesOnly":true}' \
  --tag-specifications 'ResourceType=vpn-connection,Tags=[{Key=Name,Value=FRA-to-THF-Libreswan-VPN}]' \
  --query 'VpnConnection.VpnConnectionId' \
  --output text)

echo -e "  FRA VPN Connection: ${GREEN}$FRA_VPN_ID${NC}\n"

# Step 7: Add static route for THF VPC CIDR
echo -e "${YELLOW}Step 7: Adding static route to VPN connection...${NC}"

aws ec2 create-vpn-connection-route \
  --region $FRA_REGION \
  --vpn-connection-id $FRA_VPN_ID \
  --destination-cidr-block $THF_VPC_CIDR

echo -e "  ${GREEN}Static route added for $THF_VPC_CIDR${NC}\n"

# Step 8: Wait for VPN connection to be available and get tunnel IPs
echo -e "${YELLOW}Step 8: Waiting for VPN connection configuration...${NC}"
sleep 15

FRA_TUNNEL1_IP=$(aws ec2 describe-vpn-connections \
  --region $FRA_REGION \
  --vpn-connection-ids $FRA_VPN_ID \
  --query 'VpnConnections[0].VgwTelemetry[0].OutsideIpAddress' \
  --output text)

FRA_TUNNEL2_IP=$(aws ec2 describe-vpn-connections \
  --region $FRA_REGION \
  --vpn-connection-ids $FRA_VPN_ID \
  --query 'VpnConnections[0].VgwTelemetry[1].OutsideIpAddress' \
  --output text)

echo -e "  ${GREEN}FRA VPN Tunnel 1 IP: $FRA_TUNNEL1_IP${NC}"
echo -e "  ${GREEN}FRA VPN Tunnel 2 IP: $FRA_TUNNEL2_IP${NC}\n"

# Step 9: Extract VPN configuration to get pre-shared keys
echo -e "${YELLOW}Step 9: Extracting VPN configuration...${NC}"

VPN_CONFIG=$(aws ec2 describe-vpn-connections \
  --region $FRA_REGION \
  --vpn-connection-ids $FRA_VPN_ID \
  --query 'VpnConnections[0].CustomerGatewayConfiguration' \
  --output text)

# Extract pre-shared key from XML configuration (macOS compatible)
PSK=$(echo "$VPN_CONFIG" | grep -o '<pre_shared_key>[^<]*' | sed 's/<pre_shared_key>//' | head -1)

if [ -z "$PSK" ]; then
  echo -e "${RED}Error: Could not extract pre-shared key from VPN configuration${NC}"
  exit 1
fi

echo -e "  ${GREEN}Pre-shared key extracted${NC}\n"

# Step 10: Configure Libreswan on THF instance
echo -e "${YELLOW}Step 10: Configuring Libreswan on THF instance...${NC}"

# Execute configuration via SSM using proper JSON format
aws ssm send-command \
  --region $THF_REGION \
  --profile $THF_PROFILE \
  --instance-ids $THF_INSTANCE_ID \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[\"cat > /etc/ipsec.d/aws-vpn-tunnel1.conf << 'EOFCONF'\nconn aws-vpn-tunnel1\n    type=tunnel\n    authby=secret\n    left=$THF_LIBRESWAN_PRIVATE_IP\n    leftsubnet=$THF_VPC_CIDR\n    right=$FRA_TUNNEL1_IP\n    rightsubnet=$FRA_VPC_CIDR\n    ike=aes128-sha1-modp2048\n    phase2alg=aes128-sha1-modp2048\n    auto=start\n    dpddelay=10\n    dpdtimeout=30\n    dpdaction=restart\nEOFCONF\",\"cat > /etc/ipsec.d/aws-vpn-tunnel2.conf << 'EOFCONF'\nconn aws-vpn-tunnel2\n    type=tunnel\n    authby=secret\n    left=$THF_LIBRESWAN_PRIVATE_IP\n    leftsubnet=$THF_VPC_CIDR\n    right=$FRA_TUNNEL2_IP\n    rightsubnet=$FRA_VPC_CIDR\n    ike=aes128-sha1-modp2048\n    phase2alg=aes128-sha1-modp2048\n    auto=start\n    dpddelay=10\n    dpdtimeout=30\n    dpdaction=restart\nEOFCONF\",\"echo '$THF_LIBRESWAN_PRIVATE_IP $FRA_TUNNEL1_IP : PSK \\\"$PSK\\\"' > /etc/ipsec.d/aws-vpn.secrets\",\"echo '$THF_LIBRESWAN_PRIVATE_IP $FRA_TUNNEL2_IP : PSK \\\"$PSK\\\"' >> /etc/ipsec.d/aws-vpn.secrets\",\"chmod 600 /etc/ipsec.d/aws-vpn.secrets\",\"systemctl restart ipsec\"]}" \
  --comment "Configure Libreswan VPN" \
  --query 'Command.CommandId' \
  --output text > /dev/null

echo -e "  ${GREEN}Libreswan configuration sent to instance${NC}\n"

echo -e "\n${GREEN}=== VPN Setup Complete ===${NC}"
echo -e "\nVPN Connection ID: $FRA_VPN_ID"
echo -e "Libreswan Instance: $THF_INSTANCE_ID"
echo -e "\n${YELLOW}Note: VPN tunnels may take 1-2 minutes to establish.${NC}"
echo -e "\nTo check VPN status:"
echo -e "  FRA side: ${YELLOW}aws ec2 describe-vpn-connections --region $FRA_REGION --vpn-connection-ids $FRA_VPN_ID --query 'VpnConnections[0].VgwTelemetry' --output table${NC}"
echo -e "  THF side: ${YELLOW}aws ssm start-session --region $THF_REGION --profile $THF_PROFILE --target $THF_INSTANCE_ID${NC}"
echo -e "            Then run: ${YELLOW}sudo ipsec status${NC}\n"
