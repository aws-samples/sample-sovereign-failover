#!/bin/bash

# Script to update eusc-de Sync Lambda environment variables with IAM Roles Anywhere ARNs
# This must be run after both eu-central and eusc-de stacks are deployed
# 
# Note: Unidirectional flow (eusc-de → eu-central only)
# eu-central Sync Lambda has been removed from the architecture

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Updating eusc-de Sync Lambda Environment Variables (Unidirectional) ===${NC}"
echo -e "${YELLOW}Note: Only updating eusc-de Lambda for eusc-de → eu-central synchronization${NC}\n"

# Configuration
EU_CENTRAL_REGION="eu-central-1"
EUSC_DE_REGION="eusc-de-east-1"
EUSC_DE_PROFILE="eusc-de"

# Get eu-central IAM Roles Anywhere ARNs (for eusc-de Lambda to use)
echo -e "${YELLOW}Getting eu-central IAM Roles Anywhere ARNs...${NC}"

# Trust Anchor is in eu-central partition (same region as Profile)
EU_CENTRAL_TRUST_ANCHOR_ARN=$(aws rolesanywhere list-trust-anchors \
  --region $EU_CENTRAL_REGION \
  --query 'trustAnchors[?name==`eu-central-Trust-Anchor`].trustAnchorArn | [0]' \
  --output text)

# Profile is in eu-central partition (links to eu-central role)
EU_CENTRAL_PROFILE_ARN=$(aws rolesanywhere list-profiles \
  --region $EU_CENTRAL_REGION \
  --query 'profiles[?name==`eu-central-S3-Write-Profile`].profileArn | [0]' \
  --output text)

# Role ARN from eu-central stack output
EU_CENTRAL_ROLE_ARN=$(aws cloudformation describe-stacks \
  --region $EU_CENTRAL_REGION \
  --stack-name eu-central-stack \
  --query 'Stacks[0].Outputs[?OutputKey==`RolesAnywhereRoleArn`].OutputValue' \
  --output text)

if [ -z "$EU_CENTRAL_TRUST_ANCHOR_ARN" ] || [ "$EU_CENTRAL_TRUST_ANCHOR_ARN" == "None" ]; then
  echo -e "${RED}Error: Could not retrieve eu-central Trust Anchor ARN${NC}"
  echo -e "${YELLOW}Note: Trust Anchor should be named 'eu-central-Trust-Anchor' in eu-central partition${NC}"
  exit 1
fi

if [ -z "$EU_CENTRAL_PROFILE_ARN" ] || [ "$EU_CENTRAL_PROFILE_ARN" == "None" ]; then
  echo -e "${RED}Error: Could not retrieve eu-central Profile ARN${NC}"
  exit 1
fi

if [ -z "$EU_CENTRAL_ROLE_ARN" ] || [ "$EU_CENTRAL_ROLE_ARN" == "None" ]; then
  echo -e "${RED}Error: Could not retrieve eu-central Role ARN${NC}"
  exit 1
fi

echo -e "  eu-central Trust Anchor ARN: ${GREEN}$EU_CENTRAL_TRUST_ANCHOR_ARN${NC}"
echo -e "  eu-central Profile ARN: ${GREEN}$EU_CENTRAL_PROFILE_ARN${NC}"
echo -e "  eu-central Role ARN: ${GREEN}$EU_CENTRAL_ROLE_ARN${NC}\n"

# Get eusc-de Sync Lambda Function Name
echo -e "${YELLOW}Getting eusc-de Sync Lambda Function Name...${NC}"

EUSC_DE_SYNC_LAMBDA=$(aws lambda list-functions \
  --region $EUSC_DE_REGION \
  --profile $EUSC_DE_PROFILE \
  --query "Functions[?starts_with(FunctionName, 'eusc-de-stack-SyncLambda')].FunctionName" \
  --output text)

if [ -z "$EUSC_DE_SYNC_LAMBDA" ]; then
  echo -e "${RED}Error: Could not find eusc-de Sync Lambda${NC}"
  exit 1
fi

echo -e "  eusc-de Sync Lambda: ${GREEN}$EUSC_DE_SYNC_LAMBDA${NC}\n"

# Get actual bucket name from eu-central stack
echo -e "${YELLOW}Getting eu-central S3 bucket name...${NC}"

EU_CENTRAL_BUCKET_NAME=$(aws cloudformation describe-stacks \
  --region $EU_CENTRAL_REGION \
  --stack-name eu-central-stack \
  --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' \
  --output text)

if [ -z "$EU_CENTRAL_BUCKET_NAME" ]; then
  echo -e "${RED}Error: Could not retrieve eu-central bucket name${NC}"
  exit 1
fi

echo -e "  eu-central Bucket: ${GREEN}$EU_CENTRAL_BUCKET_NAME${NC}\n"

# Update eusc-de Sync Lambda Environment Variables
echo -e "${YELLOW}Updating eusc-de Sync Lambda environment variables...${NC}"

# Get current environment variables
EUSC_DE_ENV=$(aws lambda get-function-configuration \
  --region $EUSC_DE_REGION \
  --profile $EUSC_DE_PROFILE \
  --function-name $EUSC_DE_SYNC_LAMBDA \
  --query 'Environment.Variables' \
  --output json)

# Update with eu-central IAM Roles Anywhere ARNs and actual bucket name
EUSC_DE_ENV_UPDATED=$(echo "$EUSC_DE_ENV" | jq \
  --arg trust "$EU_CENTRAL_TRUST_ANCHOR_ARN" \
  --arg profile "$EU_CENTRAL_PROFILE_ARN" \
  --arg role "$EU_CENTRAL_ROLE_ARN" \
  --arg bucket "$EU_CENTRAL_BUCKET_NAME" \
  '.REMOTE_TRUST_ANCHOR_ARN = $trust | .REMOTE_PROFILE_ARN = $profile | .REMOTE_ROLE_ARN = $role | .REMOTE_BUCKET = $bucket')

# Update Lambda configuration
aws lambda update-function-configuration \
  --region $EUSC_DE_REGION \
  --profile $EUSC_DE_PROFILE \
  --function-name $EUSC_DE_SYNC_LAMBDA \
  --environment "{\"Variables\":$EUSC_DE_ENV_UPDATED}" \
  --output text > /dev/null

echo -e "  ${GREEN}✓ eusc-de Sync Lambda updated with eu-central IAM Roles Anywhere ARNs${NC}\n"

echo -e "${GREEN}=== Update Complete ===${NC}\n"
echo -e "eusc-de Sync Lambda now configured with:"
echo -e "  Trust Anchor: ${GREEN}$EU_CENTRAL_TRUST_ANCHOR_ARN${NC}"
echo -e "  Profile: ${GREEN}$EU_CENTRAL_PROFILE_ARN${NC}"
echo -e "  Role: ${GREEN}$EU_CENTRAL_ROLE_ARN${NC}"
echo -e "  Remote Bucket: ${GREEN}$EU_CENTRAL_BUCKET_NAME${NC}\n"
echo -e "${YELLOW}Note: Lambda function may take a few seconds to pick up the new configuration${NC}\n"
