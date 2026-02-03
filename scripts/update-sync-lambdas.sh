#!/bin/bash

# Script to update THF Sync Lambda environment variables with IAM Roles Anywhere ARNs
# This must be run after both FRA and THF stacks are deployed
# 
# Note: Unidirectional flow (THF → FRA only)
# FRA Sync Lambda has been removed from the architecture

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Updating THF Sync Lambda Environment Variables (Unidirectional) ===${NC}"
echo -e "${YELLOW}Note: Only updating THF Lambda for THF → FRA synchronization${NC}\n"

# Configuration
FRA_REGION="eu-central-1"
THF_REGION="eusc-de-east-1"
THF_PROFILE="thf"

# Get FRA IAM Roles Anywhere ARNs (for THF Lambda to use)
echo -e "${YELLOW}Getting FRA IAM Roles Anywhere ARNs...${NC}"

# Trust Anchor is in FRA partition (same region as Profile)
FRA_TRUST_ANCHOR_ARN=$(aws rolesanywhere list-trust-anchors \
  --region $FRA_REGION \
  --query 'trustAnchors[?name==`FRA-Trust-Anchor`].trustAnchorArn | [0]' \
  --output text)

# Profile is in FRA partition (links to FRA role)
FRA_PROFILE_ARN=$(aws rolesanywhere list-profiles \
  --region $FRA_REGION \
  --query 'profiles[?name==`FRA-S3-Write-Profile`].profileArn | [0]' \
  --output text)

# Role ARN from FRA stack output
FRA_ROLE_ARN=$(aws cloudformation describe-stacks \
  --region $FRA_REGION \
  --stack-name FraStack \
  --query 'Stacks[0].Outputs[?OutputKey==`RolesAnywhereRoleArn`].OutputValue' \
  --output text)

if [ -z "$FRA_TRUST_ANCHOR_ARN" ] || [ "$FRA_TRUST_ANCHOR_ARN" == "None" ]; then
  echo -e "${RED}Error: Could not retrieve FRA Trust Anchor ARN${NC}"
  echo -e "${YELLOW}Note: Trust Anchor should be named 'FRA-Trust-Anchor' in FRA partition${NC}"
  exit 1
fi

if [ -z "$FRA_PROFILE_ARN" ] || [ "$FRA_PROFILE_ARN" == "None" ]; then
  echo -e "${RED}Error: Could not retrieve FRA Profile ARN${NC}"
  exit 1
fi

if [ -z "$FRA_ROLE_ARN" ] || [ "$FRA_ROLE_ARN" == "None" ]; then
  echo -e "${RED}Error: Could not retrieve FRA Role ARN${NC}"
  exit 1
fi

echo -e "  FRA Trust Anchor ARN: ${GREEN}$FRA_TRUST_ANCHOR_ARN${NC}"
echo -e "  FRA Profile ARN: ${GREEN}$FRA_PROFILE_ARN${NC}"
echo -e "  FRA Role ARN: ${GREEN}$FRA_ROLE_ARN${NC}\n"

# Get THF Sync Lambda Function Name
echo -e "${YELLOW}Getting THF Sync Lambda Function Name...${NC}"

THF_SYNC_LAMBDA=$(aws lambda list-functions \
  --region $THF_REGION \
  --profile $THF_PROFILE \
  --query "Functions[?starts_with(FunctionName, 'ThfStack-SyncLambda')].FunctionName" \
  --output text)

if [ -z "$THF_SYNC_LAMBDA" ]; then
  echo -e "${RED}Error: Could not find THF Sync Lambda${NC}"
  exit 1
fi

echo -e "  THF Sync Lambda: ${GREEN}$THF_SYNC_LAMBDA${NC}\n"

# Get actual bucket name from FRA stack
echo -e "${YELLOW}Getting FRA S3 bucket name...${NC}"

FRA_BUCKET_NAME=$(aws cloudformation describe-stacks \
  --region $FRA_REGION \
  --stack-name FraStack \
  --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' \
  --output text)

if [ -z "$FRA_BUCKET_NAME" ]; then
  echo -e "${RED}Error: Could not retrieve FRA bucket name${NC}"
  exit 1
fi

echo -e "  FRA Bucket: ${GREEN}$FRA_BUCKET_NAME${NC}\n"

# Update THF Sync Lambda Environment Variables
echo -e "${YELLOW}Updating THF Sync Lambda environment variables...${NC}"

# Get current environment variables
THF_ENV=$(aws lambda get-function-configuration \
  --region $THF_REGION \
  --profile $THF_PROFILE \
  --function-name $THF_SYNC_LAMBDA \
  --query 'Environment.Variables' \
  --output json)

# Update with FRA IAM Roles Anywhere ARNs and actual bucket name
THF_ENV_UPDATED=$(echo "$THF_ENV" | jq \
  --arg trust "$FRA_TRUST_ANCHOR_ARN" \
  --arg profile "$FRA_PROFILE_ARN" \
  --arg role "$FRA_ROLE_ARN" \
  --arg bucket "$FRA_BUCKET_NAME" \
  '.REMOTE_TRUST_ANCHOR_ARN = $trust | .REMOTE_PROFILE_ARN = $profile | .REMOTE_ROLE_ARN = $role | .REMOTE_BUCKET = $bucket')

# Update Lambda configuration
aws lambda update-function-configuration \
  --region $THF_REGION \
  --profile $THF_PROFILE \
  --function-name $THF_SYNC_LAMBDA \
  --environment "{\"Variables\":$THF_ENV_UPDATED}" \
  --output text > /dev/null

echo -e "  ${GREEN}✓ THF Sync Lambda updated with FRA IAM Roles Anywhere ARNs${NC}\n"

echo -e "${GREEN}=== Update Complete ===${NC}\n"
echo -e "THF Sync Lambda now configured with:"
echo -e "  Trust Anchor: ${GREEN}$FRA_TRUST_ANCHOR_ARN${NC}"
echo -e "  Profile: ${GREEN}$FRA_PROFILE_ARN${NC}"
echo -e "  Role: ${GREEN}$FRA_ROLE_ARN${NC}"
echo -e "  Remote Bucket: ${GREEN}$FRA_BUCKET_NAME${NC}\n"
echo -e "${YELLOW}Note: Lambda function may take a few seconds to pick up the new configuration${NC}\n"
