#!/bin/bash

# Script to build and deploy all stacks for the Sovereign Failover Demo
# This script builds Lambda functions, synthesizes CDK, and deploys both FRA and THF stacks

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Sovereign Failover Demo - Build & Deploy All Stacks     ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n"

# Default: deploy both stacks
DEPLOY_STACK="both"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --stack)
      DEPLOY_STACK="$2"
      shift 2
      ;;
    --help)
      echo "Usage: $0 [OPTIONS] <FRA_ACCOUNT_ID> <THF_ACCOUNT_ID>"
      echo ""
      echo "Options:"
      echo "  --stack <fra|thf|both>   Deploy only FRA, only THF, or both stacks (default: both)"
      echo "  --help                   Show this help message"
      echo ""
      echo "Examples:"
      echo "  $0 <FRA_ACCOUNT_ID> <THF_ACCOUNT_ID>                    # Deploy both stacks"
      echo "  $0 --stack fra <FRA_ACCOUNT_ID> <THF_ACCOUNT_ID>        # Deploy only FRA"
      echo "  $0 --stack thf <FRA_ACCOUNT_ID> <THF_ACCOUNT_ID>        # Deploy only THF"
      exit 0
      ;;
    *)
      if [ -z "$FRA_REMOTE_ACCOUNT_ID" ]; then
        FRA_REMOTE_ACCOUNT_ID=$1
      elif [ -z "$THF_REMOTE_ACCOUNT_ID" ]; then
        THF_REMOTE_ACCOUNT_ID=$1
      fi
      shift
      ;;
  esac
done

# Validate stack option
if [[ ! "$DEPLOY_STACK" =~ ^(fra|thf|both)$ ]]; then
  echo -e "${RED}Error: Invalid --stack option: $DEPLOY_STACK${NC}"
  echo -e "Valid options: fra, thf, both"
  exit 1
fi

# Check for required context parameters
if [ -z "$FRA_REMOTE_ACCOUNT_ID" ] || [ -z "$THF_REMOTE_ACCOUNT_ID" ]; then
  echo -e "${RED}Error: Required account IDs not provided${NC}"
  echo -e "Usage: $0 [--stack <fra|thf|both>] <FRA_ACCOUNT_ID> <THF_ACCOUNT_ID>"
  echo -e "Run '$0 --help' for more information"
  exit 1
fi

echo -e "${GREEN}Configuration:${NC}"
echo -e "  Deploy Stack: $DEPLOY_STACK"
echo -e "  FRA Account ID: $FRA_REMOTE_ACCOUNT_ID"
echo -e "  THF Account ID: $THF_REMOTE_ACCOUNT_ID"
echo -e ""

# Step 1: Install root dependencies
echo -e "${YELLOW}Step 1: Installing root dependencies...${NC}"
npm install
echo -e "${GREEN}✓ Root dependencies installed${NC}\n"

# Step 2: Build Lambda functions
echo -e "${YELLOW}Step 2: Building Lambda functions...${NC}"

# Build Page Handler Lambda
echo -e "  Building Page Handler Lambda..."
cd lambda/page-handler
npm install
npm run build
cd ../..
echo -e "${GREEN}  ✓ Page Handler Lambda built${NC}"

# Build Sync Handler Lambda
echo -e "  Building Sync Handler Lambda..."
cd lambda/sync-handler
npm install
npm run build
cd ../..
echo -e "${GREEN}  ✓ Sync Handler Lambda built${NC}\n"

# Step 2.5: Build CDK TypeScript code
echo -e "${YELLOW}Step 2.5: Building CDK TypeScript code...${NC}"
npm run build
echo -e "${GREEN}✓ CDK code compiled${NC}\n"

# Step 3: Synthesize CDK
echo -e "${YELLOW}Step 3: Synthesizing CDK stacks...${NC}"
npx cdk synth \
  -c fraRemoteAccountId=$FRA_REMOTE_ACCOUNT_ID \
  -c thfRemoteAccountId=$THF_REMOTE_ACCOUNT_ID
echo -e "${GREEN}✓ CDK synthesis complete${NC}\n"

# Step 3.5: Bootstrap CDK in target accounts/regions
echo -e "${YELLOW}Step 3.5: Bootstrapping CDK in target accounts/regions...${NC}"

if [[ "$DEPLOY_STACK" == "fra" || "$DEPLOY_STACK" == "both" ]]; then
  echo -e "  Bootstrapping FRA account ($FRA_REMOTE_ACCOUNT_ID) in eu-central-1..."
  npx cdk bootstrap aws://$FRA_REMOTE_ACCOUNT_ID/eu-central-1 \
    -c fraRemoteAccountId=$FRA_REMOTE_ACCOUNT_ID \
    -c thfRemoteAccountId=$THF_REMOTE_ACCOUNT_ID
  echo -e "${GREEN}  ✓ FRA account bootstrapped${NC}"
fi

if [[ "$DEPLOY_STACK" == "thf" || "$DEPLOY_STACK" == "both" ]]; then
  echo -e "  Bootstrapping THF account ($THF_REMOTE_ACCOUNT_ID) in eusc-de-east-1..."
  npx cdk bootstrap aws://$THF_REMOTE_ACCOUNT_ID/eusc-de-east-1 \
    --profile thf \
    -c fraRemoteAccountId=$FRA_REMOTE_ACCOUNT_ID \
    -c thfRemoteAccountId=$THF_REMOTE_ACCOUNT_ID
  echo -e "${GREEN}  ✓ THF account bootstrapped${NC}"
fi

echo -e "${GREEN}✓ CDK bootstrap complete${NC}\n"

# Step 4: Deploy FRA Stack
if [[ "$DEPLOY_STACK" == "fra" || "$DEPLOY_STACK" == "both" ]]; then
  echo -e "${YELLOW}Step 4: Deploying FRA Stack to eu-central-1...${NC}"
  npx cdk deploy FraStack \
    --require-approval never \
    -c fraRemoteAccountId=$FRA_REMOTE_ACCOUNT_ID \
    -c thfRemoteAccountId=$THF_REMOTE_ACCOUNT_ID

  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ FRA Stack deployed successfully${NC}\n"
  else
    echo -e "${RED}✗ FRA Stack deployment failed${NC}"
    exit 1
  fi
else
  echo -e "${BLUE}Skipping FRA Stack deployment (--stack=$DEPLOY_STACK)${NC}\n"
fi

# Step 5: Deploy THF Stack
if [[ "$DEPLOY_STACK" == "thf" || "$DEPLOY_STACK" == "both" ]]; then
  echo -e "${YELLOW}Step 5: Deploying THF Stack to eusc-de-east-1...${NC}"
  npx cdk deploy ThfStack \
    --profile thf \
    --require-approval never \
    -c fraRemoteAccountId=$FRA_REMOTE_ACCOUNT_ID \
    -c thfRemoteAccountId=$THF_REMOTE_ACCOUNT_ID

  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ THF Stack deployed successfully${NC}\n"
  else
    echo -e "${RED}✗ THF Stack deployment failed${NC}"
    exit 1
  fi
else
  echo -e "${BLUE}Skipping THF Stack deployment (--stack=$DEPLOY_STACK)${NC}\n"
fi

# Step 5.5: Issue certificates and create Trust Anchors
if [[ "$DEPLOY_STACK" == "both" ]]; then
  echo -e "${YELLOW}Step 5.5: Setting up IAM Roles Anywhere Trust Anchors...${NC}"
  
  # Check if certificates exist in Secrets Manager
  FRA_CERT_EXISTS=$(aws secretsmanager describe-secret \
    --region eu-central-1 \
    --secret-id FraSyncLambdaCertificate \
    --query 'Name' \
    --output text 2>/dev/null || echo "")

  THF_CERT_EXISTS=$(aws secretsmanager describe-secret \
    --region eusc-de-east-1 \
    --profile thf \
    --secret-id ThfSyncLambdaCertificate \
    --query 'Name' \
    --output text 2>/dev/null || echo "")

  if [ -n "$FRA_CERT_EXISTS" ] && [ -n "$THF_CERT_EXISTS" ]; then
    echo -e "${GREEN}✓ Certificates already exist in both partitions${NC}"
    echo -e "  FRA Certificate: $FRA_CERT_EXISTS"
    echo -e "  THF Certificate: $THF_CERT_EXISTS"
    echo -e "\n${YELLOW}Would you like to regenerate the certificates and Trust Anchors? (y/n)${NC}"
    read -r cert_response
    
    if [[ ! "$cert_response" =~ ^[Yy]$ ]]; then
      echo -e "${GREEN}Skipping certificate generation${NC}\n"
      SKIP_CERT_GENERATION=true
    fi
  else
    if [ -z "$FRA_CERT_EXISTS" ]; then
      echo -e "${YELLOW}⚠ FRA certificate not found${NC}"
    fi
    if [ -z "$THF_CERT_EXISTS" ]; then
      echo -e "${YELLOW}⚠ THF certificate not found${NC}"
    fi
    
    echo -e "\n${YELLOW}Issuing X.509 certificates and creating Trust Anchors...${NC}"
    echo -e "${BLUE}Note: This will create Trust Anchors and Profiles via AWS CLI${NC}\n"
  fi

  # Issue certificates if user agreed and they don't exist (or want to regenerate)
  if [ "$SKIP_CERT_GENERATION" != "true" ]; then
    if [ -f "./scripts/issue-certificates.sh" ]; then
      ./scripts/issue-certificates.sh \
        --fra-profile default \
        --thf-profile thf \
        --fra-region eu-central-1 \
        --thf-region eusc-de-east-1
      
      if [ $? -eq 0 ]; then
        echo -e "\n${GREEN}✓ Certificates issued and Trust Anchors created${NC}\n"
      else
        echo -e "\n${RED}✗ Certificate issuance failed${NC}"
        echo -e "${YELLOW}You can issue certificates manually later by running:${NC}"
        echo -e "  ${BLUE}./scripts/issue-certificates.sh --fra-profile default --thf-profile thf${NC}\n"
        exit 1
      fi
    else
      echo -e "${RED}Error: issue-certificates.sh script not found in ./scripts/${NC}"
      exit 1
    fi
  fi
else
  echo -e "${BLUE}Skipping certificate issuance (only needed when deploying both stacks)${NC}\n"
fi

# Step 5.6: Update Sync Lambda environment variables with actual ARNs
if [[ "$DEPLOY_STACK" == "both" ]] && [ "$SKIP_CERT_GENERATION" != "true" ]; then
  echo -e "${YELLOW}Step 5.6: Updating Sync Lambda environment variables...${NC}"
  if [ -f "./scripts/update-sync-lambdas.sh" ]; then
    ./scripts/update-sync-lambdas.sh
  else
    echo -e "${RED}Error: update-sync-lambdas.sh script not found${NC}"
    exit 1
  fi
else
  echo -e "${BLUE}Skipping Sync Lambda update (Trust Anchors not configured)${NC}\n"
fi

# Step 5.7: Configure API Key for bidirectional sync
if [[ "$DEPLOY_STACK" == "both" ]]; then
  echo -e "${YELLOW}Step 5.7: Configuring API Key for bidirectional sync (FRA → THF)...${NC}"
  
  # Get THF API Key ID from CloudFormation outputs
  echo -e "  Retrieving THF Sync API Key..."
  THF_API_KEY_ID=$(aws cloudformation describe-stacks \
    --region eusc-de-east-1 \
    --profile thf \
    --stack-name ThfStack \
    --query 'Stacks[0].Outputs[?OutputKey==`SyncApiKeyValue`].OutputValue' \
    --output text)
  
  if [ -z "$THF_API_KEY_ID" ]; then
    echo -e "${RED}Error: Could not retrieve THF API Key ID from CloudFormation outputs${NC}"
    echo -e "${YELLOW}You can configure the API key manually later using the README instructions${NC}\n"
  else
    echo -e "  THF API Key ID: $THF_API_KEY_ID"
    
    # Get the actual API Key value
    echo -e "  Retrieving API Key value..."
    THF_API_KEY=$(aws apigateway get-api-key \
      --region eusc-de-east-1 \
      --profile thf \
      --api-key $THF_API_KEY_ID \
      --include-value \
      --query 'value' \
      --output text)
    
    if [ -z "$THF_API_KEY" ]; then
      echo -e "${RED}Error: Could not retrieve API Key value${NC}"
      echo -e "${YELLOW}You can configure the API key manually later using the README instructions${NC}\n"
    else
      echo -e "  ${GREEN}✓ API Key retrieved${NC}"
      
      # Get THF Sync API Gateway URL
      echo -e "  Retrieving THF Sync API Gateway URL..."
      THF_SYNC_API_URL=$(aws cloudformation describe-stacks \
        --region eusc-de-east-1 \
        --profile thf \
        --stack-name ThfStack \
        --query 'Stacks[0].Outputs[?OutputKey==`SyncApiGatewayUrl`].OutputValue' \
        --output text)
      
      if [ -z "$THF_SYNC_API_URL" ]; then
        echo -e "${RED}Error: Could not retrieve THF Sync API Gateway URL${NC}"
        echo -e "${YELLOW}You can configure the API key manually later using the README instructions${NC}\n"
      else
        echo -e "  THF Sync API URL: $THF_SYNC_API_URL"
        
        # Get FRA Forwarder Lambda function name
        echo -e "  Retrieving FRA Forwarder Lambda function name..."
        FRA_FORWARDER_LAMBDA=$(aws lambda list-functions \
          --region eu-central-1 \
          --query "Functions[?starts_with(FunctionName, 'FraStack-ForwarderLambda')].FunctionName" \
          --output text)
        
        if [ -z "$FRA_FORWARDER_LAMBDA" ]; then
          echo -e "${RED}Error: Could not find FRA Forwarder Lambda function${NC}"
          echo -e "${YELLOW}You can configure the API key manually later using the README instructions${NC}\n"
        else
          echo -e "  FRA Forwarder Lambda: $FRA_FORWARDER_LAMBDA"
          
          # Update FRA Forwarder Lambda environment variables
          echo -e "  Updating FRA Forwarder Lambda environment variables..."
          aws lambda update-function-configuration \
            --region eu-central-1 \
            --function-name $FRA_FORWARDER_LAMBDA \
            --environment "Variables={THF_SYNC_API_URL=$THF_SYNC_API_URL,THF_SYNC_API_KEY=$THF_API_KEY,REGION_CODE=FRA}" \
            --output text > /dev/null
          
          if [ $? -eq 0 ]; then
            echo -e "  ${GREEN}✓ FRA Forwarder Lambda configured with API Key${NC}\n"
            echo -e "${GREEN}Bidirectional sync (FRA → THF) is now configured!${NC}\n"
          else
            echo -e "${RED}Error: Failed to update FRA Forwarder Lambda${NC}"
            echo -e "${YELLOW}You can configure the API key manually later using the README instructions${NC}\n"
          fi
        fi
      fi
    fi
  fi
else
  echo -e "${BLUE}Skipping API Key configuration (only needed when deploying both stacks)${NC}\n"
fi

# Step 6: Get stack outputs
echo -e "${YELLOW}Step 6: Retrieving stack outputs...${NC}\n"

echo -e "${GREEN}FRA Stack Outputs:${NC}"
aws cloudformation describe-stacks \
  --region eu-central-1 \
  --stack-name FraStack \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiGatewayUrl` || OutputKey==`BucketName` || OutputKey==`TrustAnchorArn` || OutputKey==`RolesAnywhereProfileArn`].[OutputKey,OutputValue]' \
  --output table

echo -e "\n${GREEN}THF Stack Outputs:${NC}"
aws cloudformation describe-stacks \
  --region eusc-de-east-1 \
  --profile thf \
  --stack-name ThfStack \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiGatewayUrl` || OutputKey==`BucketName` || OutputKey==`TrustAnchorArn` || OutputKey==`RolesAnywhereProfileArn`].[OutputKey,OutputValue]' \
  --output table

echo -e "\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              Deployment Complete!                          ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n"

# Step 7: Ask user if they want to set up VPN now
echo -e "${YELLOW}Would you like to set up the Site-to-Site VPN connection now? (y/n)${NC}"
echo -e "${BLUE}Note: VPN is optional if using IAM Roles Anywhere for cross-partition access${NC}"
read -r response

if [[ "$response" =~ ^[Yy]$ ]]; then
  echo -e "\n${YELLOW}Setting up VPN connection...${NC}\n"
  
  # Check if setup-vpn.sh exists
  if [ -f "./scripts/setup-vpn.sh" ]; then
    ./scripts/setup-vpn.sh
    
    # Ask if user wants to check VPN status now
    echo -e "\n${YELLOW}VPN tunnels may take 1-2 minutes to fully establish.${NC}"
    echo -e "${YELLOW}Would you like to check the VPN connection status now? (y/n)${NC}"
    read -r vpn_check_response
    
    if [[ "$vpn_check_response" =~ ^[Yy]$ ]]; then
      echo -e "\n${YELLOW}Checking VPN connection status...${NC}\n"
      if [ -f "./scripts/check-vpn.sh" ]; then
        ./scripts/check-vpn.sh
      else
        echo -e "${RED}Error: check-vpn.sh script not found${NC}"
      fi
    else
      echo -e "\n${GREEN}You can check VPN status later by running:${NC}"
      echo -e "  ${BLUE}./scripts/check-vpn.sh${NC}\n"
    fi
  else
    echo -e "${RED}Error: setup-vpn.sh script not found in ./scripts/${NC}"
    echo -e "Please run ${YELLOW}./scripts/setup-vpn.sh${NC} manually to establish the VPN connection\n"
  fi
else
  echo -e "\n${GREEN}Next Steps:${NC}"
  echo -e "  1. ${YELLOW}(Optional)${NC} Run ${YELLOW}./scripts/setup-vpn.sh${NC} to establish the VPN connection"
  echo -e "  2. ${YELLOW}(Optional)${NC} Run ${YELLOW}./scripts/update-sync-lambdas.sh${NC} to update Lambda environment variables"
  echo -e "  3. ${YELLOW}(Optional)${NC} Run ${YELLOW}./scripts/check-vpn.sh${NC} to verify VPN status"
  echo -e "  4. Test the FRA endpoint by visiting the FRA API Gateway URL"
  echo -e "  5. Test the THF endpoint by visiting the THF API Gateway URL"
  echo -e "  6. Verify counter synchronization between partitions\n"
fi

echo -e "${YELLOW}Useful Commands:${NC}"
echo -e "  Issue certificates: ${BLUE}./scripts/issue-certificates.sh --fra-profile default --thf-profile thf${NC}"
echo -e "  Check VPN status: ${BLUE}./scripts/check-vpn.sh${NC}"
echo -e "  Update Sync Lambdas: ${BLUE}./scripts/update-sync-lambdas.sh${NC}"
echo -e "  Check FRA stack: ${BLUE}aws cloudformation describe-stacks --region eu-central-1 --stack-name FraStack${NC}"
echo -e "  Check THF stack: ${BLUE}aws cloudformation describe-stacks --region eusc-de-east-1 --profile thf --stack-name ThfStack${NC}"
echo -e "  View FRA Sync logs: ${BLUE}aws logs tail /aws/lambda/FraStack-SyncLambda --follow --region eu-central-1${NC}"
echo -e "  View THF Sync logs: ${BLUE}aws logs tail /aws/lambda/ThfStack-SyncLambda --follow --region eusc-de-east-1 --profile thf${NC}\n"
