#!/bin/bash

# Script to issue X.509 certificates for THF Sync Lambda workload (unidirectional flow)
# This script:
# 1. Generates CSR for THF Sync Lambda function
# 2. Issues certificate from FRA Private CA
# 3. Stores certificate and private key in Secrets Manager
# 4. Creates FRA Trust Anchor and Profile for THF Lambda to use
#
# Note: FRA Sync Lambda removed for unidirectional flow (THF → FRA only)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== IAM Roles Anywhere Certificate Issuance (Unidirectional) ===${NC}"
echo -e "${YELLOW}Note: Only creating certificate for THF → FRA synchronization${NC}"
echo ""

# Check if required tools are installed
command -v openssl >/dev/null 2>&1 || { echo -e "${RED}Error: openssl is required but not installed.${NC}" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo -e "${RED}Error: AWS CLI is required but not installed.${NC}" >&2; exit 1; }

# Parse command line arguments
FRA_PROFILE=""
THF_PROFILE=""
FRA_REGION="eu-central-1"
THF_REGION="eusc-de-east-1"

while [[ $# -gt 0 ]]; do
  case $1 in
    --fra-profile)
      FRA_PROFILE="$2"
      shift 2
      ;;
    --thf-profile)
      THF_PROFILE="$2"
      shift 2
      ;;
    --fra-region)
      FRA_REGION="$2"
      shift 2
      ;;
    --thf-region)
      THF_REGION="$2"
      shift 2
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      echo "Usage: $0 --fra-profile <profile> --thf-profile <profile> [--fra-region <region>] [--thf-region <region>]"
      exit 1
      ;;
  esac
done

# Validate required arguments
if [ -z "$FRA_PROFILE" ] || [ -z "$THF_PROFILE" ]; then
  echo -e "${RED}Error: Both --fra-profile and --thf-profile are required${NC}"
  echo "Usage: $0 --fra-profile <profile> --thf-profile <profile> [--fra-region <region>] [--thf-region <region>]"
  exit 1
fi

echo -e "${YELLOW}Configuration:${NC}"
echo "  FRA Profile: $FRA_PROFILE"
echo "  THF Profile: $THF_PROFILE"
echo "  FRA Region: $FRA_REGION"
echo "  THF Region: $THF_REGION"
echo ""

# Create temporary directory for certificates
CERT_DIR=$(mktemp -d)
echo -e "${YELLOW}Using temporary directory: $CERT_DIR${NC}"
echo ""

# Function to get stack output
get_stack_output() {
  local profile=$1
  local region=$2
  local stack_name=$3
  local output_key=$4
  
  aws cloudformation describe-stacks \
    --profile "$profile" \
    --region "$region" \
    --stack-name "$stack_name" \
    --query "Stacks[0].Outputs[?OutputKey=='$output_key'].OutputValue" \
    --output text
}

# Get Private CA ARN from FRA stack output
echo -e "${GREEN}Step 1: Retrieving FRA Private CA ARN...${NC}"
FRA_CA_ARN=$(get_stack_output "$FRA_PROFILE" "$FRA_REGION" "FraStack" "PrivateCaArn")

if [ -z "$FRA_CA_ARN" ]; then
  echo -e "${RED}Error: Could not retrieve FRA Private CA ARN from stack output${NC}"
  echo "  FRA CA ARN: $FRA_CA_ARN"
  exit 1
fi

echo "  FRA CA ARN: $FRA_CA_ARN"
echo ""

# Get FRA CA certificate for Trust Anchor creation
echo -e "${GREEN}Step 2: Retrieving FRA CA certificate for Trust Anchor...${NC}"

aws acm-pca get-certificate-authority-certificate \
  --profile "$FRA_PROFILE" \
  --region "$FRA_REGION" \
  --certificate-authority-arn "$FRA_CA_ARN" \
  --query 'Certificate' \
  --output text > "$CERT_DIR/fra-ca-cert.pem"

echo "  FRA CA Certificate: $CERT_DIR/fra-ca-cert.pem"
echo ""

# Create Trust Anchor in FRA for FRA CA
echo -e "${GREEN}Step 3: Creating Trust Anchor in FRA for FRA CA...${NC}"

# First, check if trust anchor already exists in FRA
FRA_TRUST_ANCHOR_ID=$(aws rolesanywhere list-trust-anchors \
  --profile "$FRA_PROFILE" \
  --region "$FRA_REGION" \
  --query 'trustAnchors[?name==`FRA-Trust-Anchor`].trustAnchorId | [0]' \
  --output text)

if [ -n "$FRA_TRUST_ANCHOR_ID" ] && [ "$FRA_TRUST_ANCHOR_ID" != "None" ]; then
  # Trust anchor exists, delete it to recreate with new CA certificate
  echo "  Deleting existing trust anchor to recreate with new CA certificate..."
  aws rolesanywhere delete-trust-anchor \
    --profile "$FRA_PROFILE" \
    --region "$FRA_REGION" \
    --trust-anchor-id "$FRA_TRUST_ANCHOR_ID" \
    --output text > /dev/null 2>&1
fi

# Create new trust anchor
echo "  Creating new trust anchor in FRA..."
FRA_TRUST_ANCHOR_ARN=$(aws rolesanywhere create-trust-anchor \
  --profile "$FRA_PROFILE" \
  --region "$FRA_REGION" \
  --name "FRA-Trust-Anchor" \
  --enabled \
  --source sourceType=CERTIFICATE_BUNDLE,sourceData={x509CertificateData="$(cat "$CERT_DIR/fra-ca-cert.pem")"} \
  --query 'trustAnchor.trustAnchorArn' \
  --output text 2>&1)

if [ $? -ne 0 ]; then
  echo -e "${RED}Error creating trust anchor: $FRA_TRUST_ANCHOR_ARN${NC}"
  exit 1
fi

echo "  FRA Trust Anchor ARN: $FRA_TRUST_ANCHOR_ARN"
echo ""

# Get IAM Role ARN for FRA Profile
FRA_ROLE_ARN=$(get_stack_output "$FRA_PROFILE" "$FRA_REGION" "FraStack" "RolesAnywhereRoleArn")

# Create Profile in FRA
echo -e "${GREEN}Step 4: Creating IAM Roles Anywhere Profile in FRA...${NC}"

# First, try to retrieve existing profile
FRA_PROFILE_ARN=$(aws rolesanywhere list-profiles \
  --profile "$FRA_PROFILE" \
  --region "$FRA_REGION" \
  --query 'profiles[?name==`FRA-S3-Write-Profile`].profileArn | [0]' \
  --output text)

if [ -z "$FRA_PROFILE_ARN" ] || [ "$FRA_PROFILE_ARN" == "None" ]; then
  # Profile doesn't exist, create it
  echo "  Creating new profile..."
  FRA_PROFILE_ARN=$(aws rolesanywhere create-profile \
    --profile "$FRA_PROFILE" \
    --region "$FRA_REGION" \
    --name "FRA-S3-Write-Profile" \
    --enabled \
    --role-arns "$(echo "$FRA_ROLE_ARN" | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
    --query 'profile.profileArn' \
    --output text 2>&1)
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}Error creating profile: $FRA_PROFILE_ARN${NC}"
    exit 1
  fi
else
  echo "  Profile already exists, using existing profile"
  
  # Ensure it's enabled
  FRA_PROFILE_ID=$(echo "$FRA_PROFILE_ARN" | awk -F'/' '{print $NF}')
  FRA_PROFILE_ENABLED=$(aws rolesanywhere list-profiles \
    --profile "$FRA_PROFILE" \
    --region "$FRA_REGION" \
    --query "profiles[?profileId=='$FRA_PROFILE_ID'].enabled | [0]" \
    --output text)
  
  if [ "$FRA_PROFILE_ENABLED" != "True" ]; then
    echo "  Enabling profile..."
    aws rolesanywhere enable-profile \
      --profile "$FRA_PROFILE" \
      --region "$FRA_REGION" \
      --profile-id "$FRA_PROFILE_ID" \
      --output text > /dev/null 2>&1
  fi
fi

echo "  FRA Profile ARN: $FRA_PROFILE_ARN"
echo ""

# Generate CSR and private key for THF Sync Lambda
echo -e "${GREEN}Step 5: Generating CSR for THF Sync Lambda...${NC}"
openssl req -new -newkey rsa:2048 -nodes \
  -keyout "$CERT_DIR/thf-sync-lambda-key.pem" \
  -out "$CERT_DIR/thf-sync-lambda-csr.pem" \
  -subj "/C=DE/O=AWS Sovereign Failover Demo/OU=THF Sync Lambda/CN=thf-sync-lambda"

echo "  Private key: $CERT_DIR/thf-sync-lambda-key.pem"
echo "  CSR: $CERT_DIR/thf-sync-lambda-csr.pem"
echo ""

# Issue certificate for THF Sync Lambda from FRA CA
echo -e "${GREEN}Step 6: Issuing certificate for THF Sync Lambda from FRA CA...${NC}"
THF_CERT_ARN=$(aws acm-pca issue-certificate \
  --profile "$FRA_PROFILE" \
  --region "$FRA_REGION" \
  --certificate-authority-arn "$FRA_CA_ARN" \
  --csr fileb://"$CERT_DIR/thf-sync-lambda-csr.pem" \
  --signing-algorithm "SHA256WITHRSA" \
  --validity Value=365,Type="DAYS" \
  --query 'CertificateArn' \
  --output text)

echo "  Certificate ARN: $THF_CERT_ARN"

# Wait for certificate to be issued
echo "  Waiting for certificate to be issued..."
sleep 5

# Get the issued certificate
aws acm-pca get-certificate \
  --profile "$FRA_PROFILE" \
  --region "$FRA_REGION" \
  --certificate-authority-arn "$FRA_CA_ARN" \
  --certificate-arn "$THF_CERT_ARN" \
  --query 'Certificate' \
  --output text > "$CERT_DIR/thf-sync-lambda-cert.pem"

# Get the CA certificate chain
aws acm-pca get-certificate \
  --profile "$FRA_PROFILE" \
  --region "$FRA_REGION" \
  --certificate-authority-arn "$FRA_CA_ARN" \
  --certificate-arn "$THF_CERT_ARN" \
  --query 'CertificateChain' \
  --output text > "$CERT_DIR/thf-sync-lambda-chain.pem"

echo "  Certificate: $CERT_DIR/thf-sync-lambda-cert.pem"
echo "  Certificate chain: $CERT_DIR/thf-sync-lambda-chain.pem"
echo ""

# Store THF Sync Lambda certificate and private key in Secrets Manager
echo -e "${GREEN}Step 7: Storing THF Sync Lambda certificate in Secrets Manager...${NC}"
THF_SECRET_VALUE=$(jq -n \
  --arg cert "$(cat "$CERT_DIR/thf-sync-lambda-cert.pem")" \
  --arg key "$(cat "$CERT_DIR/thf-sync-lambda-key.pem")" \
  --arg chain "$(cat "$CERT_DIR/thf-sync-lambda-chain.pem")" \
  '{certificate: $cert, privateKey: $key, certificateChain: $chain}')

aws secretsmanager create-secret \
  --profile "$THF_PROFILE" \
  --region "$THF_REGION" \
  --name "ThfSyncLambdaCertificate" \
  --description "X.509 certificate and private key for THF Sync Lambda IAM Roles Anywhere" \
  --secret-string "$THF_SECRET_VALUE" \
  2>/dev/null || \
aws secretsmanager update-secret \
  --profile "$THF_PROFILE" \
  --region "$THF_REGION" \
  --secret-id "ThfSyncLambdaCertificate" \
  --secret-string "$THF_SECRET_VALUE"

echo "  Secret: ThfSyncLambdaCertificate"
echo ""

# Clean up temporary directory
echo -e "${YELLOW}Cleaning up temporary directory...${NC}"
rm -rf "$CERT_DIR"
echo ""

echo -e "${GREEN}=== Certificate issuance complete! ===${NC}"
echo ""
echo -e "${YELLOW}Unidirectional flow (THF → FRA):${NC}"
echo "  - THF Sync Lambda certificate issued and stored"
echo "  - FRA Trust Anchor and Profile created"
echo "  - THF can now sync to FRA using IAM Roles Anywhere"
echo ""
echo "Next steps:"
echo "  1. Update THF Sync Lambda environment variables (run update-sync-lambdas.sh)"
echo "  2. Deploy updated Lambda function"
echo "  3. Test THF → FRA synchronization"
echo ""
