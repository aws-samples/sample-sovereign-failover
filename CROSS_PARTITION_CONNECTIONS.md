# Cross-Partition Integration: Patterns and Solutions

## Overview

This document explores integration patterns for AWS services across different AWS partitions, specifically between the standard AWS partition (`aws`) and the AWS European Sovereign Cloud partition (`aws-eusc`). Understanding partition boundaries is essential for architecting solutions that span isolated AWS environments while maintaining security and sovereignty requirements.

This sample implements a combination of _Method: API Gateway + Lambda Trigger (Bidirectional Sync)_ and _Method: IAM Roles Anywhere with X.509 Certificates_. 

## Understanding AWS Partitions

AWS partitions are completely isolated environments designed for security, compliance, and sovereignty requirements. Each partition maintains separate:
- IAM systems and identity providers
- Service endpoints and APIs
- Resource namespaces (ARN formats)
- Authentication and authorization systems

Common partitions:
- `aws` - Standard AWS (most regions worldwide)
- `aws-cn` - AWS China
- `aws-us-gov` - AWS GovCloud (US)
- `aws-eusc` - AWS European Sovereign Cloud

This isolation ensures that data, identities, and operations remain within jurisdictional boundaries, providing strong guarantees for data sovereignty and compliance.


## Method: Cross-Account Roles

Cross-account role assumption using AWS STS is the standard approach for accessing resources across AWS accounts. A Lambda function in Account A assumes a role in Account B using `sts:AssumeRole`, receiving temporary credentials scoped to the target account's permissions.

```typescript
// Account A Lambda assuming role in Account B (same partition)
const credentials = await sts.assumeRole({
  RoleArn: 'arn:aws:iam::ACCOUNT_B:role/CrossAccountRole'
});

const s3Client = new S3Client({ credentials });
await s3Client.send(new PutObjectCommand({ Bucket: 'account-b-bucket', ... }));
```

**Cross-partition applicability:** ❌ Not applicable

IAM trust policies are partition-scoped, meaning a role in the `aws` partition cannot be assumed by a principal in the `aws-eusc` partition. Each partition maintains its own completely isolated IAM system with separate identity providers, so cross-account role assumption only works between accounts within the same partition.


## Method: Cross-Partition VPN

A Site-to-Site VPN connection enables secure, encrypted Layer 3 connectivity between VPCs in different partitions. This provides IP-based access to subnets in each VPC, forming the network foundation for cross-partition integration patterns. However, network connectivity alone does not solve authentication. Accessing AWS services in the remote partition still requires valid credentials for that partition's IAM system.

```typescript
// VPN Gateway and Connection (CDK)
const vpnGateway = new ec2.CfnVPNGateway(this, 'VpnGateway', {
  type: 'ipsec.1',
  amazonSideAsn: 64512,
});

const vpnConnection = new ec2.CfnVPNConnection(this, 'VpnConnection', {
  type: 'ipsec.1',
  customerGatewayId: customerGateway.ref,
  vpnGatewayId: vpnGateway.ref,
});
```

**Cross-partition applicability:** ✅ Applicable

VPN operates at the network layer and is partition-agnostic, simply establishing encrypted IP tunnels between two endpoints. This works seamlessly across partitions because it does not depend on IAM or any partition-scoped authentication system. VPN provides the foundational connectivity layer that other cross-partition patterns can build upon.


## Method: S3 Access Points with VPC-Only Access

S3 Access Points provide a dedicated endpoint for accessing an S3 bucket, and can be restricted to VPC-only access to eliminate internet exposure. When combined with a VPN connection, a Lambda in one regions's VPC can route traffic to an S3 Access Point in the remote regions's VPC over the private network.

```typescript
// S3 Access Point restricted to VPC (CDK)
const accessPoint = new s3.CfnAccessPoint(this, 'VpcAccessPoint', {
  bucket: bucket.bucketName,
  name: 'vpc-only-access-point',
  vpcConfiguration: {
    vpcId: vpc.vpcId,
  },
});

// S3 Gateway Endpoint for private S3 access
vpc.addGatewayEndpoint('S3Endpoint', {
  service: ec2.GatewayVpcEndpointAwsService.S3,
});
```

**Cross-partition applicability:** ❌ Not applicable

Although VPN provides network connectivity to the remote VPC, S3 API requests require AWS Signature Version 4 (SigV4) authentication, which is validated against the partition-scoped IAM system. A SigV4 signature generated with credentials from the `aws` partition will not be accepted by the S3 service in the `aws-eusc` partition. VPN solves the network routing problem but not the authentication problem.


## Method: API Gateway with Direct S3 Integration

API Gateway can be configured with a native AWS service integration to proxy requests directly to S3 without an intermediary Lambda function. The API Gateway authenticates to its local S3 using a local IAM role, while the calling Lambda in the remote partition authenticates to the API Gateway using an API key over HTTPS.

```
Architecture:
Source Partition: Sync Lambda → HTTPS over VPN → Target API Gateway → Target S3
```

```typescript
// API Gateway S3 Integration
const s3Integration = new apigateway.AwsIntegration({
  service: 's3',
  integrationHttpMethod: 'PUT',
  path: '{bucket}/{key}',
  options: { credentialsRole: s3Role }
});

// Sync Lambda calls API Gateway
await fetch(`https://${REMOTE_API_ENDPOINT}/${REMOTE_BUCKET}/${key}`, {
  method: 'PUT',
  headers: { 'x-api-key': API_KEY },
  body: objectData
});
```

**Cross-partition applicability:** ✅ Applicable

This pattern works across partitions because it decouples authentication from the partition boundary. The API Gateway handles local IAM authentication to S3 on behalf of the caller, while the cross-partition caller only needs an API key, a simple shared secret that is not tied to any partition's IAM system. The HTTPS call can traverse either the internet or a VPN tunnel, making this a straightforward and maintainable approach for unidirectional data writes.


## Method: API Gateway + Lambda Trigger (Bidirectional Sync)

This pattern uses an event-driven architecture for bidirectional synchronization between partitions. An S3 event in the source partition triggers a Forwarder Lambda, which makes an HTTPS POST with an API key to a Sync API Gateway in the target partition. The target API Gateway invokes a Sync Lambda that performs the actual data synchronization. This is the pattern implemented in this demo for the eu-central → eusc-de direction.

```
Architecture:
Source Partition: S3 Event → Forwarder Lambda → HTTPS + API Key → Target API Gateway → Target Sync Lambda → Target S3
```

```typescript
// Forwarder Lambda (eu-central)
export async function handler(event: S3Event): Promise<void> {
  await fetch(EUSC_DE_SYNC_API_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': EUSC_DE_SYNC_API_KEY,
    },
    body: JSON.stringify(event),
  });
}

// Sync Lambda (eusc-de) - handles both S3 events and API Gateway events
export async function handler(event: S3Event | APIGatewayProxyEvent): Promise<void> {
  if (isS3Event(event)) {
    await syncLocalToRemote(event);  
  } else {
    await syncRemoteToLocal(event);  
  }
}

// API Gateway configuration (eusc-de)
const syncApi = new apigateway.RestApi(this, 'SyncApi', {
  restApiName: 'eusc-de Sync API',
  apiKeySourceType: apigateway.ApiKeySourceType.HEADER,
});

const apiKey = syncApi.addApiKey('SyncApiKey');
const usagePlan = syncApi.addUsagePlan('SyncUsagePlan', {
  throttle: { rateLimit: 100, burstLimit: 200 },
});
usagePlan.addApiKey(apiKey);
```

**Cross-partition applicability:** ✅ Applicable

This pattern can avoid cross-partition IAM entirely by using API key authentication for the cross-partition hop. The Forwarder Lambda makes an HTTPS request with an API key header. The Sync Lambda in the target partition then operates with its own local IAM role for S3 access (or uses IAM Roles Anywhere for reading from the remote partition). API Gateway provides built-in rate limiting, monitoring, and error handling. This both works over the internet as well as over VPN.


## Method: IAM Roles Anywhere with X.509 Certificates

IAM Roles Anywhere enables workloads outside of AWS (or in a different partition) to obtain temporary AWS credentials by presenting an X.509 certificate signed by a trusted Certificate Authority. A Lambda function uses the `aws_signing_helper` to exchange its certificate for temporary credentials from the target partition's IAM Roles Anywhere service, then uses those credentials to access resources like S3 directly. 

```
Architecture:
Source Partition: Sync Lambda + Certificate → IAM Roles Anywhere (Target) → Temporary Credentials → Target S3
```

```typescript
// Get temporary credentials using certificate via aws_signing_helper
const credentials = execSync(`aws_signing_helper credential-process \
  --certificate /tmp/cert.pem \
  --private-key /tmp/key.pem \
  --trust-anchor-arn ${TRUST_ANCHOR_ARN} \
  --profile-arn ${PROFILE_ARN} \
  --role-arn ${ROLE_ARN}`);

// Use credentials to access remote S3
const remoteS3 = new S3Client({ 
  region: REMOTE_REGION,
  credentials: JSON.parse(credentials)
});
await remoteS3.send(new PutObjectCommand({ Bucket: REMOTE_BUCKET, ... }));
```

**Cross-partition applicability:** ✅ Applicable

IAM Roles Anywhere is specifically designed for workloads that exist outside the target partition's trust boundary. The X.509 certificate acts as a portable identity that is validated against a Trust Anchor (backed by a Private CA) in the target partition. Because the authentication is certificate-based rather than IAM-based, it bridges the partition boundary cleanly. The target partition's IAM Roles Anywhere service issues temporary credentials scoped to a specific role, providing the same security model as native IAM with short-lived credentials. This is the AWS-recommended approach for production cross-partition access, as described in the [Transfer data across AWS partitions with IAM Roles Anywhere](https://aws.amazon.com/blogs/security/transfer-data-across-aws-partitions-with-iam-roles-anywhere/) blog post.


## Method: IAM User Access Keys

An IAM user with long-lived access keys can be created in the target partition, and those credentials stored in Secrets Manager in the source partition. The source Lambda retrieves the access keys at runtime and uses them to authenticate directly against the target partition's AWS services.

```typescript
// Retrieve IAM user credentials from Secrets Manager
const secret = await secretsManager.getSecretValue({ SecretId: REMOTE_ACCESS_KEY_SECRET });
const { accessKeyId, secretAccessKey } = JSON.parse(secret.SecretString);

// Use credentials to access remote S3
const remoteS3 = new S3Client({ credentials: { accessKeyId, secretAccessKey } });
await remoteS3.send(new PutObjectCommand({ Bucket: REMOTE_BUCKET, ... }));
```

**Cross-partition applicability:** ✅ Applicable _(but not recommended)_

Long-lived IAM user access keys are not partition-scoped in the same way as STS tokens. They are simply a static credential pair that authenticates against the partition where the IAM user was created. This means a Lambda in the `aws` partition can use access keys from an IAM user in `aws-eusc` to call S3 directly. However, **this is considered a legacy pattern** per AWS guidance because long-lived credentials pose a higher security risk (no automatic expiration, rotation burden, broader blast radius if compromised). IAM Roles Anywhere with X.509 certificates is the recommended alternative for production workloads.


## Method: AWS Database Migration Service (DMS)

AWS DMS provides managed, continuous data replication between data stores. A DMS replication instance can be configured to replicate data from an S3 source endpoint to an S3 target endpoint, supporting both full-load and change data capture (CDC) for ongoing synchronization.

```typescript
// DMS Replication Task (CDK)
const replicationTask = new dms.CfnReplicationTask(this, 'ReplicationTask', {
  replicationInstanceArn: replicationInstance.ref,
  sourceEndpointArn: sourceEndpoint.ref,
  targetEndpointArn: targetEndpoint.ref,
  migrationType: 'cdc', // Continuous replication
});
```

**Cross-partition applicability:** ✅ Applicable

For database-to-database replication (e.g., RDS to RDS), DMS connects using native database credentials, completely sidestepping cross-partition IAM. Only network connectivity via VPN is required. For S3 endpoints, DMS does need AWS credentials (IAM user keys or IAM Roles Anywhere), but database endpoints rely purely on database-native authentication. The trade-off is higher cost and complexity since DMS requires a running replication instance and careful endpoint configuration, making it best suited for large-scale, continuous replication scenarios rather than lightweight event-driven sync.


## Method: Pre-Signed URL Exchange

Pre-signed S3 URLs encode temporary, scoped access permissions directly into a URL. A coordination service in the target partition generates pre-signed URLs and exposes them via an API Gateway. The source partition retrieves a URL and uses it to upload or download objects directly to/from the target S3 bucket without needing its own credentials for that partition.

```
Architecture:
Source Partition: Sync Lambda → Coordination API → Pre-signed URL → Target S3
```

```typescript
// Target partition: Generate pre-signed URL
const url = await getSignedUrl(s3Client, new PutObjectCommand({
  Bucket: TARGET_BUCKET,
  Key: 'data.json',
}), { expiresIn: 300 });

// Source partition: Upload using pre-signed URL
await fetch(url, { method: 'PUT', body: data });
```

**Cross-partition applicability:** ✅ Applicable

Pre-signed URLs work across partitions because the URL itself contains all the authentication information needed, so the source partition never needs credentials for the target partition. The target partition's coordination service generates the URL using its own local IAM credentials, and the resulting URL can be used by any HTTP client regardless of partition. The main drawback is the need for a coordination service to manage URL generation and lifecycle (expiration, single-use enforcement), adding architectural complexity compared to direct credential-based approaches.


## Method: API Gateway + PrivateLink

A Private API Gateway can be accessed through a VPC Interface Endpoint (powered by AWS PrivateLink), ensuring that all traffic between the source VPC and the API Gateway stays within the private network. Combined with a VPN tunnel between partitions, this creates a fully private data path from source to target.

```
Architecture:
Source VPC → VPN → Target VPC → VPC Endpoint (PrivateLink) → Private API Gateway → S3
```

```typescript
// Private API Gateway with VPC Endpoint
const api = new apigateway.RestApi(this, 'PrivateApi', {
  endpointConfiguration: {
    types: [apigateway.EndpointType.PRIVATE],
    vpcEndpoints: [vpcEndpoint],
  },
  policy: new iam.PolicyDocument({
    statements: [new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      principals: [new iam.AnyPrincipal()],
      actions: ['execute-api:Invoke'],
      resources: ['execute-api:/*'],
      conditions: { StringEquals: { 'aws:sourceVpce': vpcEndpoint.vpcEndpointId } },
    })],
  }),
});
```

**Cross-partition applicability:** ✅ Applicable

This pattern keeps all traffic off the internet by combining VPN (for cross-partition network connectivity) with PrivateLink (for private access to the API Gateway within the target VPC). It works across partitions because the authentication to the API Gateway can use API keys or IAM authorization local to the target partition, while the VPN handles the network routing. The trade-off is higher cost and complexity, requiring both a VPN tunnel and VPC Endpoint infrastructure, making it most appropriate when regulatory or compliance requirements mandate that no traffic traverses the internet.


## Additional Resources

- [AWS Partitions Documentation](https://docs.aws.amazon.com/general/latest/gr/aws-arns-and-namespaces.html)
- [AWS Fault Isolation Boundaries - Partitions](https://docs.aws.amazon.com/whitepapers/latest/aws-fault-isolation-boundaries/partitions.html)
- [AWS European Sovereign Cloud](https://aws.amazon.com/sovereign-cloud/european-sovereign-cloud/)
- [Transfer data across AWS partitions with IAM Roles Anywhere](https://aws.amazon.com/blogs/security/transfer-data-across-aws-partitions-with-iam-roles-anywhere/)
- [IAM Roles Anywhere Documentation](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html)
- [API Gateway AWS Service Integration](https://docs.aws.amazon.com/apigateway/latest/developerguide/integration-aws-services.html)
- [API Gateway S3 Integration Tutorial](https://docs.aws.amazon.com/apigateway/latest/developerguide/integrating-api-with-aws-services-s3.html)
