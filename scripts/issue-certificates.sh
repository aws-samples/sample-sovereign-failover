#!/bin/bash

# Script to issue X.509 certificates for eusc-de Sync Lambda workload (unidirectional flow)
# This script:
# 1. Generates CSR for eusc-de Sync Lambda function
# 2. Issues certificate from eu-central Private CA
# 3. Stores certificate and private key in Secrets Manager
# 4. Creates eu-central Trust Anchor and Profile for eusc-de Lambda to use
#
# Note: eu-central Sync Lambda removed for unidirectional flow (eusc-de → eu-central only)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== IAM Roles Anywhere Certificate Issuance (Unidirectional) ===${NC}"
echo -e "${YELLOW}Note: Only creating certificate for eusc-de → eu-central synchronization${NC}"
echo ""

# Check if required tools are installed
command -v openssl >/dev/null 2>&1 || { echo -e "${RED}Error: openssl is required but not installed.${NC}" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo -e "${RED}Error: AWS CLI is required but not installed.${NC}" >&2; exit 1; }

# Parse command line arguments
EU_CENTRAL_PROFILE=""
EUSC_DE_PROFILE=""
EU_CENTRAL_REGION="eu-central-1"
EUSC_DE_REGION="eusc-de-east-1"

while [[ $# -gt 0 ]]; do
  case $1 in
    --eu-central-profile)
      EU_CENTRAL_PROFILE="$2"
      shift 2
      ;;
    --eusc-de-profile)
      EUSC_DE_PROFILE="$2"
      shift 2
      ;;
    --eu-central-region)
      EU_CENTRAL_REGION="$2"
      shift 2
      ;;
    --eusc-de-region)
      EUSC_DE_REGION="$2"
      shift 2
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      echo "Usage: $0 --eu-central-profile <profile> --eusc-de-profile <profile> [--eu-central-region <region>] [--eusc-de-region <region>]"
      exit 1
      ;;
  esac
done

# Validate required arguments
if [ -z "$EU_CENTRAL_PROFILE" ] || [ -z "$EUSC_DE_PROFILE" ]; then
  echo -e "${RED}Error: Both --eu-central-profile and --eusc-de-profile are required${NC}"
  echo "Usage: $0 --eu-central-profile <profile> --eusc-de-profile <profile> [--eu-central-region <region>] [--eusc-de-region <region>]"
  exit 1
fi

echo -e "${YELLOW}Configuration:${NC}"
echo "  eu-central Profile: $EU_CENTRAL_PROFILE"
echo "  eusc-de Profile: $EUSC_DE_PROFILE"
echo "  eu-central Region: $EU_CENTRAL_REGION"
echo "  eusc-de Region: $EUSC_DE_REGION"
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

# Get Private CA ARN from eu-central stack output
echo -e "${GREEN}Step 1: Retrieving eu-central Private CA ARN...${NC}"
EU_CENTRAL_CA_ARN=$(get_stack_output "$EU_CENTRAL_PROFILE" "$EU_CENTRAL_REGION" "eu-central-stack" "PrivateCaArn")

if [ -z "$EU_CENTRAL_CA_ARN" ]; then
  echo -e "${RED}Error: Could not retrieve eu-central Private CA ARN from stack output${NC}"
  echo "  eu-central CA ARN: $EU_CENTRAL_CA_ARN"
  exit 1
fi

echo "  eu-central CA ARN: $EU_CENTRAL_CA_ARN"
echo ""

# Get eu-central CA certificate for Trust Anchor creation
echo -e "${GREEN}Step 2: Retrieving eu-central CA certificate for Trust Anchor...${NC}"

aws acm-pca get-certificate-authority-certificate \
  --profile "$EU_CENTRAL_PROFILE" \
  --region "$EU_CENTRAL_REGION" \
  --certificate-authority-arn "$EU_CENTRAL_CA_ARN" \
  --query 'Certificate' \
  --output text > "$CERT_DIR/eu-central-ca-cert.pem"

echo "  eu-central CA Certificate: $CERT_DIR/eu-central-ca-cert.pem"
echo ""

# Create Trust Anchor in eu-central for eu-central CA
echo -e "${GREEN}Step 3: Creating Trust Anchor in eu-central for eu-central CA...${NC}"

# First, check if trust anchor already exists in eu-central
EU_CENTRAL_TRUST_ANCHOR_ID=$(aws rolesanywhere list-trust-anchors \
  --profile "$EU_CENTRAL_PROFILE" \
  --region "$EU_CENTRAL_REGION" \
  --query 'trustAnchors[?name==`eu-central-Trust-Anchor`].trustAnchorId | [0]' \
  --output text)

if [ -n "$EU_CENTRAL_TRUST_ANCHOR_ID" ] && [ "$EU_CENTRAL_TRUST_ANCHOR_ID" != "None" ]; then
  # Trust anchor exists, delete it to recreate with new CA certificate
  echo "  Deleting existing trust anchor to recreate with new CA certificate..."
  aws rolesanywhere delete-trust-anchor \
    --profile "$EU_CENTRAL_PROFILE" \
    --region "$EU_CENTRAL_REGION" \
    --trust-anchor-id "$EU_CENTRAL_TRUST_ANCHOR_ID" \
    --output text > /dev/null 2>&1
fi

# Create new trust anchor
echo "  Creating new trust anchor in eu-central..."
EU_CENTRAL_TRUST_ANCHOR_ARN=$(aws rolesanywhere create-trust-anchor \
  --profile "$EU_CENTRAL_PROFILE" \
  --region "$EU_CENTRAL_REGION" \
  --name "eu-central-Trust-Anchor" \
  --enabled \
  --source sourceType=CERTIFICATE_BUNDLE,sourceData={x509CertificateData="$(cat "$CERT_DIR/eu-central-ca-cert.pem")"} \
  --query 'trustAnchor.trustAnchorArn' \
  --output text 2>&1)

if [ $? -ne 0 ]; then
  echo -e "${RED}Error creating trust anchor: $EU_CENTRAL_TRUST_ANCHOR_ARN${NC}"
  exit 1
fi

echo "  eu-central Trust Anchor ARN: $EU_CENTRAL_TRUST_ANCHOR_ARN"
echo ""

# Get IAM Role ARN for eu-central Profile
EU_CENTRAL_ROLE_ARN=$(get_stack_output "$EU_CENTRAL_PROFILE" "$EU_CENTRAL_REGION" "eu-central-stack" "RolesAnywhereRoleArn")

# Create Profile in eu-central
echo -e "${GREEN}Step 4: Creating IAM Roles Anywhere Profile in eu-central...${NC}"

# First, try to retrieve existing profile
EU_CENTRAL_PROFILE_ARN=$(aws rolesanywhere list-profiles \
  --profile "$EU_CENTRAL_PROFILE" \
  --region "$EU_CENTRAL_REGION" \
  --query 'profiles[?name==`eu-central-S3-Write-Profile`].profileArn | [0]' \
  --output text)

if [ -z "$EU_CENTRAL_PROFILE_ARN" ] || [ "$EU_CENTRAL_PROFILE_ARN" == "None" ]; then
  # Profile doesn't exist, create it
  echo "  Creating new profile..."
  EU_CENTRAL_PROFILE_ARN=$(aws rolesanywhere create-profile \
    --profile "$EU_CENTRAL_PROFILE" \
    --region "$EU_CENTRAL_REGION" \
    --name "eu-central-S3-Write-Profile" \
    --enabled \
    --role-arns "$(echo "$EU_CENTRAL_ROLE_ARN" | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
    --query 'profile.profileArn' \
    --output text 2>&1)
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}Error creating profile: $EU_CENTRAL_PROFILE_ARN${NC}"
    exit 1
  fi
else
  echo "  Profile already exists, using existing profile"
  
  # Ensure it's enabled
  EU_CENTRAL_PROFILE_ID=$(echo "$EU_CENTRAL_PROFILE_ARN" | awk -F'/' '{print $NF}')
  EU_CENTRAL_PROFILE_ENABLED=$(aws rolesanywhere list-profiles \
    --profile "$EU_CENTRAL_PROFILE" \
    --region "$EU_CENTRAL_REGION" \
    --query "profiles[?profileId=='$EU_CENTRAL_PROFILE_ID'].enabled | [0]" \
    --output text)
  
  if [ "$EU_CENTRAL_PROFILE_ENABLED" != "True" ]; then
    echo "  Enabling profile..."
    aws rolesanywhere enable-profile \
      --profile "$EU_CENTRAL_PROFILE" \
      --region "$EU_CENTRAL_REGION" \
      --profile-id "$EU_CENTRAL_PROFILE_ID" \
      --output text > /dev/null 2>&1
  fi
fi

echo "  eu-central Profile ARN: $EU_CENTRAL_PROFILE_ARN"
echo ""

# Generate CSR and private key for eusc-de Sync Lambda
echo -e "${GREEN}Step 5: Generating CSR for eusc-de Sync Lambda...${NC}"
openssl req -new -newkey rsa:2048 -nodes \
  -keyout "$CERT_DIR/eusc-de-sync-lambda-key.pem" \
  -out "$CERT_DIR/eusc-de-sync-lambda-csr.pem" \
  -subj "/C=DE/O=AWS Sovereign Failover Demo/OU=eusc-de Sync Lambda/CN=eusc-de-sync-lambda"

echo "  Private key: $CERT_DIR/eusc-de-sync-lambda-key.pem"
echo "  CSR: $CERT_DIR/eusc-de-sync-lambda-csr.pem"
echo ""

# Issue certificate for eusc-de Sync Lambda from eu-central CA
echo -e "${GREEN}Step 6: Issuing certificate for eusc-de Sync Lambda from eu-central CA...${NC}"
EUSC_DE_CERT_ARN=$(aws acm-pca issue-certificate \
  --profile "$EU_CENTRAL_PROFILE" \
  --region "$EU_CENTRAL_REGION" \
  --certificate-authority-arn "$EU_CENTRAL_CA_ARN" \
  --csr fileb://"$CERT_DIR/eusc-de-sync-lambda-csr.pem" \
  --signing-algorithm "SHA256WITHRSA" \
  --validity Value=365,Type="DAYS" \
  --query 'CertificateArn' \
  --output text)

echo "  Certificate ARN: $EUSC_DE_CERT_ARN"

# Wait for certificate to be issued
echo "  Waiting for certificate to be issued..."
sleep 5

# Get the issued certificate
aws acm-pca get-certificate \
  --profile "$EU_CENTRAL_PROFILE" \
  --region "$EU_CENTRAL_REGION" \
  --certificate-authority-arn "$EU_CENTRAL_CA_ARN" \
  --certificate-arn "$EUSC_DE_CERT_ARN" \
  --query 'Certificate' \
  --output text > "$CERT_DIR/eusc-de-sync-lambda-cert.pem"

# Get the CA certificate chain
aws acm-pca get-certificate \
  --profile "$EU_CENTRAL_PROFILE" \
  --region "$EU_CENTRAL_REGION" \
  --certificate-authority-arn "$EU_CENTRAL_CA_ARN" \
  --certificate-arn "$EUSC_DE_CERT_ARN" \
  --query 'CertificateChain' \
  --output text > "$CERT_DIR/eusc-de-sync-lambda-chain.pem"

echo "  Certificate: $CERT_DIR/eusc-de-sync-lambda-cert.pem"
echo "  Certificate chain: $CERT_DIR/eusc-de-sync-lambda-chain.pem"
echo ""

# Store eusc-de Sync Lambda certificate and private key in Secrets Manager
echo -e "${GREEN}Step 7: Storing eusc-de Sync Lambda certificate in Secrets Manager...${NC}"
EUSC_DE_SECRET_VALUE=$(jq -n \
  --arg cert "$(cat "$CERT_DIR/eusc-de-sync-lambda-cert.pem")" \
  --arg key "$(cat "$CERT_DIR/eusc-de-sync-lambda-key.pem")" \
  --arg chain "$(cat "$CERT_DIR/eusc-de-sync-lambda-chain.pem")" \
  '{certificate: $cert, privateKey: $key, certificateChain: $chain}')

aws secretsmanager create-secret \
  --profile "$EUSC_DE_PROFILE" \
  --region "$EUSC_DE_REGION" \
  --name "EuscDeSyncLambdaCertificate" \
  --description "X.509 certificate and private key for eusc-de Sync Lambda IAM Roles Anywhere" \
  --secret-string "$EUSC_DE_SECRET_VALUE" \
  2>/dev/null || \
aws secretsmanager update-secret \
  --profile "$EUSC_DE_PROFILE" \
  --region "$EUSC_DE_REGION" \
  --secret-id "EuscDeSyncLambdaCertificate" \
  --secret-string "$EUSC_DE_SECRET_VALUE"

echo "  Secret: EuscDeSyncLambdaCertificate"
echo ""

# Clean up temporary directory
echo -e "${YELLOW}Cleaning up temporary directory...${NC}"
rm -rf "$CERT_DIR"
echo ""

echo -e "${GREEN}=== Certificate issuance complete! ===${NC}"
echo ""
echo -e "${YELLOW}Unidirectional flow (eusc-de → eu-central):${NC}"
echo "  - eusc-de Sync Lambda certificate issued and stored"
echo "  - eu-central Trust Anchor and Profile created"
echo "  - eusc-de can now sync to eu-central using IAM Roles Anywhere"
echo ""
echo "Next steps:"
echo "  1. Update eusc-de Sync Lambda environment variables (run update-sync-lambdas.sh)"
echo "  2. Deploy updated Lambda function"
echo "  3. Test eusc-de → eu-central synchronization"
echo ""
