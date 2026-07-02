#!/bin/bash

# Script to check Site-to-Site VPN connection status between eu-central and eusc-de partitions

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         VPN Connection Status Check                       ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n"

# Configuration
EU_CENTRAL_REGION="eu-central-1"
EUSC_DE_REGION="eusc-de-east-1"
EUSC_DE_PROFILE="eusc-de"

# Step 1: Get eu-central VPN Connection
echo -e "${YELLOW}Step 1: Checking eu-central VPN Connection...${NC}"

EU_CENTRAL_VPN_ID=$(aws ec2 describe-vpn-connections \
  --region $EU_CENTRAL_REGION \
  --filters "Name=tag:Name,Values=eu-central-to-eusc-de-Libreswan-VPN" "Name=state,Values=pending,available" \
  --query 'VpnConnections[0].VpnConnectionId' \
  --output text)

if [ "$EU_CENTRAL_VPN_ID" == "None" ] || [ -z "$EU_CENTRAL_VPN_ID" ]; then
  echo -e "${RED}✗ No VPN connection found${NC}"
  echo -e "  Run ./scripts/setup-vpn.sh to create the VPN connection\n"
  exit 1
fi

echo -e "  VPN Connection ID: ${GREEN}$EU_CENTRAL_VPN_ID${NC}"

# Get VPN connection details
VPN_STATE=$(aws ec2 describe-vpn-connections \
  --region $EU_CENTRAL_REGION \
  --vpn-connection-ids $EU_CENTRAL_VPN_ID \
  --query 'VpnConnections[0].State' \
  --output text)

echo -e "  VPN State: ${GREEN}$VPN_STATE${NC}"

# Get Customer Gateway details
CGW_ID=$(aws ec2 describe-vpn-connections \
  --region $EU_CENTRAL_REGION \
  --vpn-connection-ids $EU_CENTRAL_VPN_ID \
  --query 'VpnConnections[0].CustomerGatewayId' \
  --output text)

CGW_IP=$(aws ec2 describe-customer-gateways \
  --region $EU_CENTRAL_REGION \
  --customer-gateway-ids $CGW_ID \
  --query 'CustomerGateways[0].IpAddress' \
  --output text)

echo -e "  Customer Gateway: ${GREEN}$CGW_ID${NC} (IP: $CGW_IP)"

# Get VPN Gateway details
VGW_ID=$(aws ec2 describe-vpn-connections \
  --region $EU_CENTRAL_REGION \
  --vpn-connection-ids $EU_CENTRAL_VPN_ID \
  --query 'VpnConnections[0].VpnGatewayId' \
  --output text)

echo -e "  VPN Gateway: ${GREEN}$VGW_ID${NC}\n"

# Step 2: Check eu-central Tunnel Status
echo -e "${YELLOW}Step 2: Checking eu-central Tunnel Status...${NC}"

TUNNEL1_IP=$(aws ec2 describe-vpn-connections \
  --region $EU_CENTRAL_REGION \
  --vpn-connection-ids $EU_CENTRAL_VPN_ID \
  --query 'VpnConnections[0].VgwTelemetry[0].OutsideIpAddress' \
  --output text)

TUNNEL1_STATUS=$(aws ec2 describe-vpn-connections \
  --region $EU_CENTRAL_REGION \
  --vpn-connection-ids $EU_CENTRAL_VPN_ID \
  --query 'VpnConnections[0].VgwTelemetry[0].Status' \
  --output text)

TUNNEL1_LAST_STATUS_CHANGE=$(aws ec2 describe-vpn-connections \
  --region $EU_CENTRAL_REGION \
  --vpn-connection-ids $EU_CENTRAL_VPN_ID \
  --query 'VpnConnections[0].VgwTelemetry[0].LastStatusChange' \
  --output text)

TUNNEL2_IP=$(aws ec2 describe-vpn-connections \
  --region $EU_CENTRAL_REGION \
  --vpn-connection-ids $EU_CENTRAL_VPN_ID \
  --query 'VpnConnections[0].VgwTelemetry[1].OutsideIpAddress' \
  --output text)

TUNNEL2_STATUS=$(aws ec2 describe-vpn-connections \
  --region $EU_CENTRAL_REGION \
  --vpn-connection-ids $EU_CENTRAL_VPN_ID \
  --query 'VpnConnections[0].VgwTelemetry[1].Status' \
  --output text)

TUNNEL2_LAST_STATUS_CHANGE=$(aws ec2 describe-vpn-connections \
  --region $EU_CENTRAL_REGION \
  --vpn-connection-ids $EU_CENTRAL_VPN_ID \
  --query 'VpnConnections[0].VgwTelemetry[1].LastStatusChange' \
  --output text)

# Display tunnel 1 status
if [ "$TUNNEL1_STATUS" == "UP" ]; then
  echo -e "  Tunnel 1: ${GREEN}✓ UP${NC}"
else
  echo -e "  Tunnel 1: ${RED}✗ $TUNNEL1_STATUS${NC}"
fi
echo -e "    IP: $TUNNEL1_IP"
echo -e "    Last Status Change: $TUNNEL1_LAST_STATUS_CHANGE"

# Display tunnel 2 status
if [ "$TUNNEL2_STATUS" == "UP" ]; then
  echo -e "  Tunnel 2: ${GREEN}✓ UP${NC}"
else
  echo -e "  Tunnel 2: ${RED}✗ $TUNNEL2_STATUS${NC}"
fi
echo -e "    IP: $TUNNEL2_IP"
echo -e "    Last Status Change: $TUNNEL2_LAST_STATUS_CHANGE\n"

# Overall eu-central status
EU_CENTRAL_STATUS="DOWN"
if [ "$TUNNEL1_STATUS" == "UP" ] || [ "$TUNNEL2_STATUS" == "UP" ]; then
  EU_CENTRAL_STATUS="UP"
  echo -e "${GREEN}✓ eu-central side: At least one tunnel is UP${NC}\n"
else
  echo -e "${RED}✗ eu-central side: Both tunnels are DOWN${NC}\n"
fi

# Step 3: Check eusc-de Libreswan Status
echo -e "${YELLOW}Step 3: Checking eusc-de Libreswan Status...${NC}"

EUSC_DE_INSTANCE_ID=$(aws ec2 describe-instances \
  --region $EUSC_DE_REGION \
  --profile $EUSC_DE_PROFILE \
  --filters "Name=tag:Name,Values=eusc-de-Libreswan-VPN-Gateway" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

if [ "$EUSC_DE_INSTANCE_ID" == "None" ] || [ -z "$EUSC_DE_INSTANCE_ID" ]; then
  echo -e "${RED}✗ eusc-de Libreswan instance not found or not running${NC}\n"
  exit 1
fi

EUSC_DE_PUBLIC_IP=$(aws ec2 describe-instances \
  --region $EUSC_DE_REGION \
  --profile $EUSC_DE_PROFILE \
  --instance-ids $EUSC_DE_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

EUSC_DE_PRIVATE_IP=$(aws ec2 describe-instances \
  --region $EUSC_DE_REGION \
  --profile $EUSC_DE_PROFILE \
  --instance-ids $EUSC_DE_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

echo -e "  Instance ID: ${GREEN}$EUSC_DE_INSTANCE_ID${NC}"
echo -e "  Public IP: $EUSC_DE_PUBLIC_IP"
echo -e "  Private IP: $EUSC_DE_PRIVATE_IP"

# Check if IPsec service is running
echo -e "\n  Checking IPsec service status..."

IPSEC_STATUS=$(aws ssm send-command \
  --region $EUSC_DE_REGION \
  --profile $EUSC_DE_PROFILE \
  --instance-ids $EUSC_DE_INSTANCE_ID \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["systemctl is-active ipsec"]}' \
  --query 'Command.CommandId' \
  --output text)

# Wait for command to complete
sleep 3

IPSEC_ACTIVE=$(aws ssm get-command-invocation \
  --region $EUSC_DE_REGION \
  --profile $EUSC_DE_PROFILE \
  --command-id $IPSEC_STATUS \
  --instance-id $EUSC_DE_INSTANCE_ID \
  --query 'StandardOutputContent' \
  --output text 2>/dev/null || echo "unknown")

if [ "$IPSEC_ACTIVE" == "active" ]; then
  echo -e "  IPsec Service: ${GREEN}✓ Active${NC}"
else
  echo -e "  IPsec Service: ${RED}✗ $IPSEC_ACTIVE${NC}"
fi

# Get IPsec tunnel status
echo -e "\n  Checking IPsec tunnel status..."

IPSEC_STATUS_CMD=$(aws ssm send-command \
  --region $EUSC_DE_REGION \
  --profile $EUSC_DE_PROFILE \
  --instance-ids $EUSC_DE_INSTANCE_ID \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["ipsec status"]}' \
  --query 'Command.CommandId' \
  --output text)

# Wait for command to complete
sleep 3

IPSEC_OUTPUT=$(aws ssm get-command-invocation \
  --region $EUSC_DE_REGION \
  --profile $EUSC_DE_PROFILE \
  --command-id $IPSEC_STATUS_CMD \
  --instance-id $EUSC_DE_INSTANCE_ID \
  --query 'StandardOutputContent' \
  --output text 2>/dev/null || echo "")

if [ -n "$IPSEC_OUTPUT" ]; then
  # Check for ESTABLISHED connections
  TUNNEL1_ESTABLISHED=$(echo "$IPSEC_OUTPUT" | grep -c "aws-vpn-tunnel1.*ESTABLISHED" || echo "0")
  TUNNEL2_ESTABLISHED=$(echo "$IPSEC_OUTPUT" | grep -c "aws-vpn-tunnel2.*ESTABLISHED" || echo "0")
  
  if [ "$TUNNEL1_ESTABLISHED" -gt 0 ]; then
    echo -e "  Tunnel 1 (to $TUNNEL1_IP): ${GREEN}✓ ESTABLISHED${NC}"
  else
    echo -e "  Tunnel 1 (to $TUNNEL1_IP): ${RED}✗ Not established${NC}"
  fi
  
  if [ "$TUNNEL2_ESTABLISHED" -gt 0 ]; then
    echo -e "  Tunnel 2 (to $TUNNEL2_IP): ${GREEN}✓ ESTABLISHED${NC}"
  else
    echo -e "  Tunnel 2 (to $TUNNEL2_IP): ${RED}✗ Not established${NC}"
  fi
  
  # Overall eusc-de status
  EUSC_DE_STATUS="DOWN"
  if [ "$TUNNEL1_ESTABLISHED" -gt 0 ] || [ "$TUNNEL2_ESTABLISHED" -gt 0 ]; then
    EUSC_DE_STATUS="UP"
    echo -e "\n${GREEN}✓ eusc-de side: At least one tunnel is ESTABLISHED${NC}\n"
  else
    echo -e "\n${RED}✗ eusc-de side: No tunnels are ESTABLISHED${NC}\n"
  fi
else
  echo -e "${RED}✗ Could not retrieve IPsec status${NC}\n"
  EUSC_DE_STATUS="UNKNOWN"
fi

# Step 4: Overall Status Summary
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              VPN Connection Summary                        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n"

echo -e "eu-central Side (AWS VPN Gateway):"
if [ "$EU_CENTRAL_STATUS" == "UP" ]; then
  echo -e "  Status: ${GREEN}✓ UP${NC}"
else
  echo -e "  Status: ${RED}✗ DOWN${NC}"
fi
echo -e "  Tunnel 1: $TUNNEL1_STATUS ($TUNNEL1_IP)"
echo -e "  Tunnel 2: $TUNNEL2_STATUS ($TUNNEL2_IP)"

echo -e "\neusc-de Side (Libreswan):"
if [ "$EUSC_DE_STATUS" == "UP" ]; then
  echo -e "  Status: ${GREEN}✓ UP${NC}"
elif [ "$EUSC_DE_STATUS" == "UNKNOWN" ]; then
  echo -e "  Status: ${YELLOW}? UNKNOWN${NC}"
else
  echo -e "  Status: ${RED}✗ DOWN${NC}"
fi
echo -e "  Instance: $EUSC_DE_INSTANCE_ID"
echo -e "  Public IP: $EUSC_DE_PUBLIC_IP"

echo -e "\nOverall VPN Status:"
if [ "$EU_CENTRAL_STATUS" == "UP" ] && [ "$EUSC_DE_STATUS" == "UP" ]; then
  echo -e "  ${GREEN}✓ VPN CONNECTION IS OPERATIONAL${NC}"
  echo -e "  Both sides report at least one tunnel UP/ESTABLISHED\n"
  exit 0
elif [ "$EU_CENTRAL_STATUS" == "UP" ] || [ "$EUSC_DE_STATUS" == "UP" ]; then
  echo -e "  ${YELLOW}⚠ VPN CONNECTION IS PARTIALLY OPERATIONAL${NC}"
  echo -e "  One side reports tunnels UP, but the other side may have issues\n"
  exit 1
else
  echo -e "  ${RED}✗ VPN CONNECTION IS DOWN${NC}"
  echo -e "  Both sides report no active tunnels\n"
  
  echo -e "${YELLOW}Troubleshooting Steps:${NC}"
  echo -e "  1. Check if Libreswan service is running:"
  echo -e "     ${BLUE}aws ssm start-session --region $EUSC_DE_REGION --profile $EUSC_DE_PROFILE --target $EUSC_DE_INSTANCE_ID${NC}"
  echo -e "     ${BLUE}sudo systemctl status ipsec${NC}"
  echo -e "\n  2. Restart Libreswan if needed:"
  echo -e "     ${BLUE}sudo systemctl restart ipsec${NC}"
  echo -e "\n  3. Check Libreswan logs:"
  echo -e "     ${BLUE}sudo journalctl -u ipsec -n 50${NC}"
  echo -e "\n  4. Recreate VPN connection:"
  echo -e "     ${BLUE}./scripts/setup-vpn.sh${NC}\n"
  exit 1
fi
