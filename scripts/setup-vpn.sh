#!/bin/bash

# Script to establish Site-to-Site VPN connection between eu-central and eusc-de partitions
# New architecture: eu-central has AWS VPN Gateway, eusc-de has Libreswan customer gateway

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Setting up Site-to-Site VPN between eu-central and eusc-de ===${NC}\n"

# Configuration
EU_CENTRAL_REGION="eu-central-1"
EUSC_DE_REGION="eusc-de-east-1"
EUSC_DE_PROFILE="eusc-de"

# Step 1: Get eu-central VPN Gateway ID
echo -e "${YELLOW}Step 1: Getting eu-central VPN Gateway ID...${NC}"

EU_CENTRAL_VGW_ID=$(aws ec2 describe-vpn-gateways \
  --region $EU_CENTRAL_REGION \
  --filters "Name=tag:Name,Values=eu-central-VPN-Gateway" "Name=state,Values=available" \
  --query 'VpnGateways[0].VpnGatewayId' \
  --output text)

if [ "$EU_CENTRAL_VGW_ID" == "None" ] || [ -z "$EU_CENTRAL_VGW_ID" ]; then
  echo -e "${RED}Error: eu-central VPN Gateway not found. Please deploy eu-central-stack first.${NC}"
  exit 1
fi

echo -e "  eu-central VPN Gateway: ${GREEN}$EU_CENTRAL_VGW_ID${NC}\n"

# Step 2: Get eusc-de Libreswan instance information
echo -e "${YELLOW}Step 2: Getting eusc-de Libreswan instance information...${NC}"

EUSC_DE_INSTANCE_ID=$(aws ec2 describe-instances \
  --region $EUSC_DE_REGION \
  --profile $EUSC_DE_PROFILE \
  --filters "Name=tag:Name,Values=eusc-de-Libreswan-VPN-Gateway" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

if [ "$EUSC_DE_INSTANCE_ID" == "None" ] || [ -z "$EUSC_DE_INSTANCE_ID" ]; then
  echo -e "${RED}Error: eusc-de Libreswan instance not found. Please deploy eusc-de-stack first.${NC}"
  exit 1
fi

EUSC_DE_LIBRESWAN_PUBLIC_IP=$(aws ec2 describe-instances \
  --region $EUSC_DE_REGION \
  --profile $EUSC_DE_PROFILE \
  --instance-ids $EUSC_DE_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

EUSC_DE_LIBRESWAN_PRIVATE_IP=$(aws ec2 describe-instances \
  --region $EUSC_DE_REGION \
  --profile $EUSC_DE_PROFILE \
  --instance-ids $EUSC_DE_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

echo -e "  eusc-de Libreswan Instance: ${GREEN}$EUSC_DE_INSTANCE_ID${NC}"
echo -e "  eusc-de Libreswan Public IP: ${GREEN}$EUSC_DE_LIBRESWAN_PUBLIC_IP${NC}"
echo -e "  eusc-de Libreswan Private IP: ${GREEN}$EUSC_DE_LIBRESWAN_PRIVATE_IP${NC}\n"

# Step 3: Get VPC CIDRs
echo -e "${YELLOW}Step 3: Getting VPC CIDR blocks...${NC}"

EU_CENTRAL_VPC_CIDR="10.0.0.0/16"

EUSC_DE_VPC_CIDR=$(aws ec2 describe-vpcs \
  --region $EUSC_DE_REGION \
  --profile $EUSC_DE_PROFILE \
  --filters "Name=tag:Name,Values=eusc-de-stack/EuscDeVpc" \
  --query 'Vpcs[0].CidrBlock' \
  --output text)

echo -e "  eu-central VPC CIDR: ${GREEN}$EU_CENTRAL_VPC_CIDR${NC}"
echo -e "  eusc-de VPC CIDR: ${GREEN}$EUSC_DE_VPC_CIDR${NC}\n"

# Step 4: Check for existing VPN connection and verify if it's working
echo -e "${YELLOW}Step 4: Checking for existing eu-central VPN Connection...${NC}"

EU_CENTRAL_VPN_ID=$(aws ec2 describe-vpn-connections \
  --region $EU_CENTRAL_REGION \
  --filters "Name=tag:Name,Values=eu-central-to-eusc-de-Libreswan-VPN" "Name=state,Values=pending,available" \
  --query 'VpnConnections[0].VpnConnectionId' \
  --output text)

VPN_IS_VALID=false

if [ "$EU_CENTRAL_VPN_ID" != "None" ] && [ -n "$EU_CENTRAL_VPN_ID" ]; then
  echo -e "  Found existing VPN connection: ${GREEN}$EU_CENTRAL_VPN_ID${NC}"
  
  # Check if VPN is connected to the correct Libreswan IP
  EXISTING_CGW_IP=$(aws ec2 describe-vpn-connections \
    --region $EU_CENTRAL_REGION \
    --vpn-connection-ids $EU_CENTRAL_VPN_ID \
    --query 'VpnConnections[0].CustomerGatewayConfiguration' \
    --output text | grep -o '<customer_gateway_id>[^<]*' | head -1 | sed 's/<customer_gateway_id>//')
  
  if [ -n "$EXISTING_CGW_IP" ]; then
    EXISTING_CGW_ID=$(aws ec2 describe-vpn-connections \
      --region $EU_CENTRAL_REGION \
      --vpn-connection-ids $EU_CENTRAL_VPN_ID \
      --query 'VpnConnections[0].CustomerGatewayId' \
      --output text)
    
    EXISTING_CGW_PUBLIC_IP=$(aws ec2 describe-customer-gateways \
      --region $EU_CENTRAL_REGION \
      --customer-gateway-ids $EXISTING_CGW_ID \
      --query 'CustomerGateways[0].IpAddress' \
      --output text 2>/dev/null || echo "")
    
    if [ "$EXISTING_CGW_PUBLIC_IP" == "$EUSC_DE_LIBRESWAN_PUBLIC_IP" ]; then
      echo -e "  Customer Gateway IP matches: ${GREEN}$EXISTING_CGW_PUBLIC_IP${NC}"
      
      # Check tunnel status
      TUNNEL1_STATUS=$(aws ec2 describe-vpn-connections \
        --region $EU_CENTRAL_REGION \
        --vpn-connection-ids $EU_CENTRAL_VPN_ID \
        --query 'VpnConnections[0].VgwTelemetry[0].Status' \
        --output text)
      
      TUNNEL2_STATUS=$(aws ec2 describe-vpn-connections \
        --region $EU_CENTRAL_REGION \
        --vpn-connection-ids $EU_CENTRAL_VPN_ID \
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
      echo -e "    Expected: $EUSC_DE_LIBRESWAN_PUBLIC_IP"
      echo -e "    Found: $EXISTING_CGW_PUBLIC_IP"
      echo -e "  ${YELLOW}Will recreate VPN connection${NC}"
    fi
  fi
fi

# Only delete and recreate if VPN is not valid
if [ "$VPN_IS_VALID" = false ]; then
  if [ "$EU_CENTRAL_VPN_ID" != "None" ] && [ -n "$EU_CENTRAL_VPN_ID" ]; then
    echo -e "  Deleting existing eu-central VPN Connection..."
    aws ec2 delete-vpn-connection --region $EU_CENTRAL_REGION --vpn-connection-id $EU_CENTRAL_VPN_ID || true
    
    # Wait for deletion
    echo -e "  Waiting for VPN connection to delete..."
    for i in {1..24}; do
      VPN_STATE=$(aws ec2 describe-vpn-connections --region $EU_CENTRAL_REGION --vpn-connection-ids $EU_CENTRAL_VPN_ID --query 'VpnConnections[0].State' --output text 2>/dev/null || echo "deleted")
      if [ "$VPN_STATE" == "deleted" ]; then
        echo -e "  ${GREEN}eu-central VPN connection deleted${NC}"
        break
      fi
      sleep 5
    done
  fi
else
  # Skip to the end if VPN is valid
  echo -e "\n${GREEN}=== VPN Setup Complete (Using Existing Connection) ===${NC}"
  echo -e "\nVPN Connection ID: $EU_CENTRAL_VPN_ID"
  echo -e "Libreswan Instance: $EUSC_DE_INSTANCE_ID"
  echo -e "\nTo check VPN status:"
  echo -e "  eu-central side: ${YELLOW}aws ec2 describe-vpn-connections --region $EU_CENTRAL_REGION --vpn-connection-ids $EU_CENTRAL_VPN_ID --query 'VpnConnections[0].VgwTelemetry' --output table${NC}"
  echo -e "  eusc-de side: ${YELLOW}aws ssm start-session --region $EUSC_DE_REGION --profile $EUSC_DE_PROFILE --target $EUSC_DE_INSTANCE_ID${NC}"
  echo -e "            Then run: ${YELLOW}sudo ipsec status${NC}\n"
  exit 0
fi

# Step 5: Create/update eu-central Customer Gateway pointing to Libreswan
echo -e "${YELLOW}Step 5: Creating eu-central Customer Gateway pointing to eusc-de Libreswan...${NC}"

# Check if customer gateway already exists
EU_CENTRAL_CGW_ID=$(aws ec2 describe-customer-gateways \
  --region $EU_CENTRAL_REGION \
  --filters "Name=tag:Name,Values=eu-central-Customer-Gateway-to-eusc-de-Libreswan" "Name=state,Values=available" \
  --query 'CustomerGateways[0].CustomerGatewayId' \
  --output text)

if [ "$EU_CENTRAL_CGW_ID" != "None" ] && [ -n "$EU_CENTRAL_CGW_ID" ]; then
  echo -e "  Deleting existing eu-central Customer Gateway..."
  aws ec2 delete-customer-gateway --region $EU_CENTRAL_REGION --customer-gateway-id $EU_CENTRAL_CGW_ID || true
  
  # Wait for deletion
  for i in {1..10}; do
    CGW_STATE=$(aws ec2 describe-customer-gateways --region $EU_CENTRAL_REGION --customer-gateway-ids $EU_CENTRAL_CGW_ID --query 'CustomerGateways[0].State' --output text 2>/dev/null || echo "deleted")
    if [ "$CGW_STATE" == "deleted" ]; then
      break
    fi
    sleep 2
  done
fi

# Create new customer gateway
EU_CENTRAL_CGW_ID=$(aws ec2 create-customer-gateway \
  --region $EU_CENTRAL_REGION \
  --type ipsec.1 \
  --public-ip $EUSC_DE_LIBRESWAN_PUBLIC_IP \
  --bgp-asn 65000 \
  --tag-specifications 'ResourceType=customer-gateway,Tags=[{Key=Name,Value=eu-central-Customer-Gateway-to-eusc-de-Libreswan}]' \
  --query 'CustomerGateway.CustomerGatewayId' \
  --output text)

echo -e "  eu-central Customer Gateway: ${GREEN}$EU_CENTRAL_CGW_ID${NC} (points to $EUSC_DE_LIBRESWAN_PUBLIC_IP)\n"

# Step 6: Create eu-central VPN Connection
echo -e "${YELLOW}Step 6: Creating eu-central VPN Connection...${NC}"

# Create new VPN connection
EU_CENTRAL_VPN_ID=$(aws ec2 create-vpn-connection \
  --region $EU_CENTRAL_REGION \
  --type ipsec.1 \
  --customer-gateway-id $EU_CENTRAL_CGW_ID \
  --vpn-gateway-id $EU_CENTRAL_VGW_ID \
  --options '{"StaticRoutesOnly":true}' \
  --tag-specifications 'ResourceType=vpn-connection,Tags=[{Key=Name,Value=eu-central-to-eusc-de-Libreswan-VPN}]' \
  --query 'VpnConnection.VpnConnectionId' \
  --output text)

echo -e "  eu-central VPN Connection: ${GREEN}$EU_CENTRAL_VPN_ID${NC}\n"

# Step 7: Add static route for eusc-de VPC CIDR
echo -e "${YELLOW}Step 7: Adding static route to VPN connection...${NC}"

aws ec2 create-vpn-connection-route \
  --region $EU_CENTRAL_REGION \
  --vpn-connection-id $EU_CENTRAL_VPN_ID \
  --destination-cidr-block $EUSC_DE_VPC_CIDR

echo -e "  ${GREEN}Static route added for $EUSC_DE_VPC_CIDR${NC}\n"

# Step 8: Wait for VPN connection to be available and get tunnel IPs
echo -e "${YELLOW}Step 8: Waiting for VPN connection configuration...${NC}"
sleep 15

EU_CENTRAL_TUNNEL1_IP=$(aws ec2 describe-vpn-connections \
  --region $EU_CENTRAL_REGION \
  --vpn-connection-ids $EU_CENTRAL_VPN_ID \
  --query 'VpnConnections[0].VgwTelemetry[0].OutsideIpAddress' \
  --output text)

EU_CENTRAL_TUNNEL2_IP=$(aws ec2 describe-vpn-connections \
  --region $EU_CENTRAL_REGION \
  --vpn-connection-ids $EU_CENTRAL_VPN_ID \
  --query 'VpnConnections[0].VgwTelemetry[1].OutsideIpAddress' \
  --output text)

echo -e "  ${GREEN}eu-central VPN Tunnel 1 IP: $EU_CENTRAL_TUNNEL1_IP${NC}"
echo -e "  ${GREEN}eu-central VPN Tunnel 2 IP: $EU_CENTRAL_TUNNEL2_IP${NC}\n"

# Step 9: Extract VPN configuration to get pre-shared keys
echo -e "${YELLOW}Step 9: Extracting VPN configuration...${NC}"

VPN_CONFIG=$(aws ec2 describe-vpn-connections \
  --region $EU_CENTRAL_REGION \
  --vpn-connection-ids $EU_CENTRAL_VPN_ID \
  --query 'VpnConnections[0].CustomerGatewayConfiguration' \
  --output text)

# Extract pre-shared key from XML configuration (macOS compatible)
PSK=$(echo "$VPN_CONFIG" | grep -o '<pre_shared_key>[^<]*' | sed 's/<pre_shared_key>//' | head -1)

if [ -z "$PSK" ]; then
  echo -e "${RED}Error: Could not extract pre-shared key from VPN configuration${NC}"
  exit 1
fi

echo -e "  ${GREEN}Pre-shared key extracted${NC}\n"

# Step 10: Configure Libreswan on eusc-de instance
echo -e "${YELLOW}Step 10: Configuring Libreswan on eusc-de instance...${NC}"

# Execute configuration via SSM using proper JSON format
aws ssm send-command \
  --region $EUSC_DE_REGION \
  --profile $EUSC_DE_PROFILE \
  --instance-ids $EUSC_DE_INSTANCE_ID \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[\"cat > /etc/ipsec.d/aws-vpn-tunnel1.conf << 'EOFCONF'\nconn aws-vpn-tunnel1\n    type=tunnel\n    authby=secret\n    left=$EUSC_DE_LIBRESWAN_PRIVATE_IP\n    leftsubnet=$EUSC_DE_VPC_CIDR\n    right=$EU_CENTRAL_TUNNEL1_IP\n    rightsubnet=$EU_CENTRAL_VPC_CIDR\n    ike=aes128-sha1-modp2048\n    phase2alg=aes128-sha1-modp2048\n    auto=start\n    dpddelay=10\n    dpdtimeout=30\n    dpdaction=restart\nEOFCONF\",\"cat > /etc/ipsec.d/aws-vpn-tunnel2.conf << 'EOFCONF'\nconn aws-vpn-tunnel2\n    type=tunnel\n    authby=secret\n    left=$EUSC_DE_LIBRESWAN_PRIVATE_IP\n    leftsubnet=$EUSC_DE_VPC_CIDR\n    right=$EU_CENTRAL_TUNNEL2_IP\n    rightsubnet=$EU_CENTRAL_VPC_CIDR\n    ike=aes128-sha1-modp2048\n    phase2alg=aes128-sha1-modp2048\n    auto=start\n    dpddelay=10\n    dpdtimeout=30\n    dpdaction=restart\nEOFCONF\",\"echo '$EUSC_DE_LIBRESWAN_PRIVATE_IP $EU_CENTRAL_TUNNEL1_IP : PSK \\\"$PSK\\\"' > /etc/ipsec.d/aws-vpn.secrets\",\"echo '$EUSC_DE_LIBRESWAN_PRIVATE_IP $EU_CENTRAL_TUNNEL2_IP : PSK \\\"$PSK\\\"' >> /etc/ipsec.d/aws-vpn.secrets\",\"chmod 600 /etc/ipsec.d/aws-vpn.secrets\",\"systemctl restart ipsec\"]}" \
  --comment "Configure Libreswan VPN" \
  --query 'Command.CommandId' \
  --output text > /dev/null

echo -e "  ${GREEN}Libreswan configuration sent to instance${NC}\n"

echo -e "\n${GREEN}=== VPN Setup Complete ===${NC}"
echo -e "\nVPN Connection ID: $EU_CENTRAL_VPN_ID"
echo -e "Libreswan Instance: $EUSC_DE_INSTANCE_ID"
echo -e "\n${YELLOW}Note: VPN tunnels may take 1-2 minutes to establish.${NC}"
echo -e "\nTo check VPN status:"
echo -e "  eu-central side: ${YELLOW}aws ec2 describe-vpn-connections --region $EU_CENTRAL_REGION --vpn-connection-ids $EU_CENTRAL_VPN_ID --query 'VpnConnections[0].VgwTelemetry' --output table${NC}"
echo -e "  eusc-de side: ${YELLOW}aws ssm start-session --region $EUSC_DE_REGION --profile $EUSC_DE_PROFILE --target $EUSC_DE_INSTANCE_ID${NC}"
echo -e "            Then run: ${YELLOW}sudo ipsec status${NC}\n"
