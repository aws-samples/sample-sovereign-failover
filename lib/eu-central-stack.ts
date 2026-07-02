import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as apigateway from 'aws-cdk-lib/aws-apigateway';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as acmpca from 'aws-cdk-lib/aws-acmpca';
import { EU_CENTRAL_CONFIG } from './shared/config';
import { StackConfig } from './shared/types';

export interface EuCentralStackProps extends cdk.StackProps {
  remoteAccountId: string;
  remoteAccessPointAlias?: string; // Optional - eusc-de Sync API Gateway URL
  euscDeSyncApiKey?: string; // Optional - API key for eusc-de Sync API Gateway
}

export class EuCentralStack extends cdk.Stack {
  public readonly bucket: s3.Bucket;
  public readonly apiGateway: apigateway.RestApi;
  public readonly privateCa: acmpca.CfnCertificateAuthority;

  constructor(scope: Construct, id: string, props: EuCentralStackProps) {
    super(scope, id, props);

    // Build complete stack configuration
    const config: StackConfig = {
      ...EU_CENTRAL_CONFIG,
      remoteAccountId: props.remoteAccountId,
    };

    // Create AWS Private CA for issuing certificates to eusc-de Sync Lambda
    // This CA will be used as a trust anchor in eusc-de partition's IAM Roles Anywhere
    this.privateCa = new acmpca.CfnCertificateAuthority(this, 'EuCentralPrivateCA', {
      type: 'ROOT',
      keyAlgorithm: 'RSA_2048',
      signingAlgorithm: 'SHA256WITHRSA',
      subject: {
        country: 'DE',
        organization: 'AWS Sovereign Failover Demo',
        organizationalUnit: 'eu-central Partition',
        commonName: 'eu-central Private CA v2', // Changed to force replacement
      },
      revocationConfiguration: {
        crlConfiguration: {
          enabled: false, // Disable CRL for demo purposes
        },
      },
      usageMode: 'GENERAL_PURPOSE', // Allows certificates up to 10 years
    });

    // Install CA certificate (self-signed for root CA)
    // This is required to make the CA operational
    const caCertificate = new acmpca.CfnCertificate(this, 'EuCentralCACertificate', {
      certificateAuthorityArn: this.privateCa.attrArn,
      certificateSigningRequest: this.privateCa.attrCertificateSigningRequest,
      signingAlgorithm: 'SHA256WITHRSA',
      templateArn: 'arn:aws:acm-pca:::template/RootCACertificate/V1',
      validity: {
        type: 'YEARS',
        value: 10,
      },
    });

    // Activate the CA by installing the certificate
    new acmpca.CfnCertificateAuthorityActivation(this, 'EuCentralCAActivation', {
      certificateAuthorityArn: this.privateCa.attrArn,
      certificate: caCertificate.attrCertificate,
      status: 'ACTIVE',
    });

    // Export CA ARN for reference
    new cdk.CfnOutput(this, 'PrivateCaArn', {
      value: this.privateCa.attrArn,
      description: 'ARN of the eu-central Private Certificate Authority',
      exportName: 'EuCentralPrivateCaArn',
    });

    // Store CA certificate in SSM Parameter Store (too large for CloudFormation output)
    const caCertificateParameter = new cdk.aws_ssm.StringParameter(this, 'EuCentralCACertificateParameter', {
      parameterName: '/sovereign-failover/eu-central/ca-certificate',
      stringValue: caCertificate.attrCertificate,
      description: 'eu-central Private CA certificate for eusc-de trust anchor',
      tier: cdk.aws_ssm.ParameterTier.ADVANCED, // Required for values > 4KB
    });

    // Export parameter name instead of certificate value
    new cdk.CfnOutput(this, 'PrivateCaCertificateParameter', {
      value: caCertificateParameter.parameterName,
      description: 'SSM Parameter containing eu-central Private CA certificate',
      exportName: 'EuCentralCACertificateParameter',
    });

    // Note: eusc-de Trust Anchor removed for unidirectional flow.
    // eu-central does not need to verify certificates from eusc-de CA since eu-central doesn't sync to eusc-de.
    // Only eusc-de needs to verify certificates from eu-central CA for eusc-de → eu-central synchronization.

    // Note: IAM role creation moved to after S3 bucket creation (see below)

    // Create VPC with public and private subnets
    const vpc = new ec2.Vpc(this, 'EuCentralVpc', {
      maxAzs: 2,
      natGateways: 1,
      subnetConfiguration: [
        {
          cidrMask: 24,
          name: 'Public',
          subnetType: ec2.SubnetType.PUBLIC,
        },
        {
          cidrMask: 24,
          name: 'Private',
          subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS,
        },
      ],
    });

    // Note: Customer Gateway and VPN Connection are created by setup-vpn.sh script
    // They cannot be created in CDK because the Libreswan IP is only known after eusc-de stack deploys
    
    // Create Virtual Private Gateway
    const vpnGateway = new ec2.CfnVPNGateway(this, 'EuCentralVpnGateway', {
      type: 'ipsec.1',
      amazonSideAsn: 64512, // AWS side ASN
      tags: [
        {
          key: 'Name',
          value: 'eu-central-VPN-Gateway',
        },
      ],
    });

    // Attach VPG to VPC
    new ec2.CfnVPCGatewayAttachment(this, 'EuCentralVpnGatewayAttachment', {
      vpcId: vpc.vpcId,
      vpnGatewayId: vpnGateway.ref,
    });

    // Note: VPN Connection is created by setup-vpn.sh script
    // It cannot be created in CDK because the Libreswan IP is only known after eusc-de stack deploys

    // Export VPN Gateway ID for reference
    new cdk.CfnOutput(this, 'VpnGatewayId', {
      value: vpnGateway.ref,
      description: 'VPN Gateway ID for eu-central partition',
      exportName: 'EuCentralVpnGatewayId',
    });

    // Create S3 bucket for counter storage
    this.bucket = new s3.Bucket(this, 'EuCentralCounterBucket', {
      versioned: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      removalPolicy: cdk.RemovalPolicy.DESTROY, // For demo purposes
      autoDeleteObjects: true, // For demo purposes
      lifecycleRules: [
        {
          noncurrentVersionExpiration: cdk.Duration.days(30),
        },
      ],
    });

    // Note: Bucket policy not needed - IAM Roles Anywhere role has direct S3 permissions

    // Export bucket name for cross-stack reference
    new cdk.CfnOutput(this, 'BucketName', {
      value: this.bucket.bucketName,
      description: 'S3 bucket name for eu-central counter storage',
      exportName: 'EuCentralBucketName',
    });

    // Note: S3 event notification will be added after Sync Lambda is created (subtask 5.5)

    // Create IAM role for eusc-de Sync Lambda to assume via IAM Roles Anywhere
    // This role grants S3 write permissions to the eu-central bucket
    const rolesAnywhereRole = new iam.Role(this, 'EuCentralRolesAnywhereS3WriteRole', {
      roleName: 'EuCentralRolesAnywhereS3WriteRole',
      description: 'Role for eusc-de Sync Lambda to write to eu-central S3 bucket via IAM Roles Anywhere',
      // Trust policy for IAM Roles Anywhere - must allow all three STS actions
      assumedBy: new iam.ServicePrincipal('rolesanywhere.amazonaws.com'),
    });

    // Add the required STS actions for IAM Roles Anywhere
    rolesAnywhereRole.assumeRolePolicy?.addStatements(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        principals: [new iam.ServicePrincipal('rolesanywhere.amazonaws.com')],
        actions: ['sts:AssumeRole', 'sts:TagSession', 'sts:SetSourceIdentity'],
      })
    );

    // Grant full S3 permissions to the eu-central bucket (read, write, list, delete)
    this.bucket.grantReadWrite(rolesAnywhereRole);
    this.bucket.grantDelete(rolesAnywhereRole);
    
    // Also grant list permissions
    rolesAnywhereRole.addToPolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: ['s3:ListBucket'],
        resources: [this.bucket.bucketArn],
      })
    );

    // Export role ARN
    new cdk.CfnOutput(this, 'RolesAnywhereRoleArn', {
      value: rolesAnywhereRole.roleArn,
      description: 'ARN of the IAM Roles Anywhere role for S3 write access',
      exportName: 'EuCentralRolesAnywhereRoleArn',
    });

    // Note: IAM Roles Anywhere Profile and Trust Anchor are created via scripts
    // after both stacks are deployed, since they require cross-partition CA certificates.

    // Create IAM execution role for Page Handler Lambda
    const pageHandlerRole = new iam.Role(this, 'PageHandlerRole', {
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      description: 'Execution role for eu-central Page Handler Lambda',
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole'),
      ],
    });

    // Grant S3 read/write permissions to the bucket
    this.bucket.grantReadWrite(pageHandlerRole);

    // Create Page Handler Lambda function
    const pageHandlerLambda = new lambda.Function(this, 'PageHandlerLambda', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/page-handler/dist'),
      role: pageHandlerRole,
      timeout: cdk.Duration.seconds(30),
      memorySize: 256,
      environment: {
        REGION_NAME: config.regionName,
        REGION_CODE: config.regionCode,
        BUCKET_NAME: this.bucket.bucketName,
      },
      description: `Page Handler Lambda for ${config.regionName}`,
    });

    // Export Lambda function ARN
    new cdk.CfnOutput(this, 'PageHandlerLambdaArn', {
      value: pageHandlerLambda.functionArn,
      description: 'ARN of the Page Handler Lambda function',
      exportName: 'EuCentralPageHandlerLambdaArn',
    });

    // Create REST API Gateway
    this.apiGateway = new apigateway.RestApi(this, 'EuCentralApiGateway', {
      restApiName: `${config.regionCode}-Sovereign-Failover-API`,
      description: `API Gateway for ${config.regionName} sovereign failover demo`,
      deployOptions: {
        stageName: 'prod',
        loggingLevel: apigateway.MethodLoggingLevel.INFO,
        dataTraceEnabled: true,
        metricsEnabled: true,
      },
      defaultCorsPreflightOptions: {
        allowOrigins: apigateway.Cors.ALL_ORIGINS,
        allowMethods: apigateway.Cors.ALL_METHODS,
        allowHeaders: ['Content-Type', 'Authorization'],
      },
      cloudWatchRole: true,
    });

    // Configure root resource with GET method
    const lambdaIntegration = new apigateway.LambdaIntegration(pageHandlerLambda, {
      proxy: true,
      integrationResponses: [
        {
          statusCode: '200',
        },
      ],
    });

    this.apiGateway.root.addMethod('GET', lambdaIntegration, {
      methodResponses: [
        {
          statusCode: '200',
          responseParameters: {
            'method.response.header.Content-Type': true,
          },
        },
      ],
    });

    // Export API Gateway URL
    new cdk.CfnOutput(this, 'ApiGatewayUrl', {
      value: this.apiGateway.url,
      description: 'API Gateway endpoint URL',
      exportName: 'EuCentralApiGatewayUrl',
    });

    // Create IAM execution role for API Gateway Forwarder Lambda
    const forwarderLambdaRole = new iam.Role(this, 'ForwarderLambdaRole', {
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      description: 'Execution role for eu-central API Gateway Forwarder Lambda',
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole'),
      ],
    });

    // Grant S3 read permissions for local bucket (to read counter metadata if needed)
    this.bucket.grantRead(forwarderLambdaRole);

    // Note: No IAM permission needed for eusc-de Sync API Gateway since we use API Key authentication
    // API Key authentication works across partitions without IAM trust relationships

    // Create API Gateway Forwarder Lambda function
    // This Lambda forwards S3 events from eu-central to eusc-de Sync API Gateway
    const forwarderLambda = new lambda.Function(this, 'ForwarderLambda', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'api-gateway-forwarder.handler',
      code: lambda.Code.fromAsset('lambda/sync-handler/dist'),
      role: forwarderLambdaRole,
      timeout: cdk.Duration.seconds(60),
      memorySize: 256,
      environment: {
        EUSC_DE_SYNC_API_URL: props.remoteAccessPointAlias || 'PLACEHOLDER-UPDATE-AFTER-EUSC-DE-DEPLOYMENT',
        EUSC_DE_SYNC_API_KEY: props.euscDeSyncApiKey || 'PLACEHOLDER-UPDATE-AFTER-EUSC-DE-DEPLOYMENT',
        REGION_CODE: config.regionCode,
      },
      description: `API Gateway Forwarder Lambda for ${config.regionName}`,
    });

    // Connect S3 event notification to Forwarder Lambda
    // Trigger on PUT operations for counter objects
    this.bucket.addEventNotification(
      s3.EventType.OBJECT_CREATED_PUT,
      new (require('aws-cdk-lib/aws-s3-notifications').LambdaDestination)(forwarderLambda),
      {
        prefix: 'counter-',
        suffix: '.json',
      }
    );

    // Export Forwarder Lambda ARN
    new cdk.CfnOutput(this, 'ForwarderLambdaArn', {
      value: forwarderLambda.functionArn,
      description: 'ARN of the API Gateway Forwarder Lambda function',
      exportName: 'EuCentralForwarderLambdaArn',
    });

    // Note: eu-central Sync Lambda and related resources have been removed.
    // Only eusc-de → eu-central synchronization is supported in this architecture.
    // eu-central does not sync to eusc-de, making eu-central the "source of truth" for counter data.

    // Note: Cross-account role removed for unidirectional IAM Roles Anywhere flow.
    // eusc-de Sync Lambda uses IAM Roles Anywhere with X.509 certificates instead of AssumeRole.
    // The EuCentralRolesAnywhereS3WriteRole (created above) is used for cross-partition access.
  }
}
