import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as apigateway from 'aws-cdk-lib/aws-apigateway';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3n from 'aws-cdk-lib/aws-s3-notifications';
import { THF_CONFIG } from './shared/config';
import { StackConfig } from './shared/types';
import { LibreswanVpnGateway } from './constructs/libreswan-vpn-gateway';

export interface ThfStackProps extends cdk.StackProps {
  remoteAccountId: string;
  fraApiGatewayId?: string;
  fraCustomerGatewayId?: string;
}

export class ThfStack extends cdk.Stack {
  public readonly bucket: s3.Bucket;
  public readonly apiGateway: apigateway.RestApi;

  constructor(scope: Construct, id: string, props: ThfStackProps) {
    super(scope, id, props);

    // Build complete stack configuration
    const config: StackConfig = {
      ...THF_CONFIG,
      remoteAccountId: props.remoteAccountId,
    };

    // Create VPC with public and private subnets
    // Using 172.16.0.0/16 to avoid overlap with FRA VPC (10.0.0.0/16)
    const vpc = new ec2.Vpc(this, 'ThfVpc', {
      ipAddresses: ec2.IpAddresses.cidr('172.16.0.0/16'),
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

    // Note: THF VPN Gateway removed - will use Libreswan customer VPN gateway instead
    // FRA partition has the AWS-managed VPN Gateway
    // THF partition will have a Libreswan EC2 instance that connects to FRA VPN Gateway

    // Create Libreswan VPN gateway instance
    new LibreswanVpnGateway(this, 'LibreswanVpnGateway', {
      vpc: vpc,
      instanceName: 'THF-Libreswan-VPN-Gateway',
      localCidr: vpc.vpcCidrBlock,
      remoteCidr: '10.0.0.0/16', // FRA VPC CIDR - placeholder, will be configured by script
    });

    // Create S3 bucket for counter storage
    this.bucket = new s3.Bucket(this, 'ThfCounterBucket', {
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

    // Export bucket name for cross-stack reference
    new cdk.CfnOutput(this, 'BucketName', {
      value: this.bucket.bucketName,
      description: 'S3 bucket name for THF counter storage',
      exportName: 'ThfBucketName',
    });

    // Create IAM execution role for Page Handler Lambda
    const pageHandlerRole = new iam.Role(this, 'PageHandlerRole', {
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      description: 'Execution role for THF Page Handler Lambda',
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
      description: `Page Handler Lambda for ${config.regionName} (${config.regionCode})`,
    });

    // Export Lambda function ARN
    new cdk.CfnOutput(this, 'PageHandlerLambdaArn', {
      value: pageHandlerLambda.functionArn,
      description: 'ARN of the Page Handler Lambda function',
      exportName: 'ThfPageHandlerLambdaArn',
    });

    // Create REST API Gateway
    // Note: Using REGIONAL endpoint type as EDGE is not supported in sovereign cloud regions
    this.apiGateway = new apigateway.RestApi(this, 'ThfApiGateway', {
      restApiName: `${config.regionCode}-Sovereign-Failover-API`,
      description: `API Gateway for ${config.regionName} sovereign failover demo`,
      endpointConfiguration: {
        types: [apigateway.EndpointType.REGIONAL],
      },
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
      exportName: 'ThfApiGatewayUrl',
    });

    // Create IAM execution role for Sync Lambda
    const syncLambdaRole = new iam.Role(this, 'SyncLambdaRole', {
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      description: 'Execution role for THF Sync Lambda',
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole'),
      ],
    });

    // Grant S3 read and write permissions for local bucket
    // Sync Lambda needs to:
    // - Read local counter (for THF → FRA sync)
    // - Write remote counter received from FRA (for FRA → THF sync via API Gateway)
    this.bucket.grantReadWrite(syncLambdaRole);

    // Grant Secrets Manager read permissions for certificate retrieval
    syncLambdaRole.addToPolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: ['secretsmanager:GetSecretValue'],
        resources: [`arn:aws-eusc:secretsmanager:${config.region}:${this.account}:secret:ThfSyncLambdaCertificate-*`],
      })
    );

    // Note: VPC configuration removed - IAM Roles Anywhere doesn't require VPN
    // Direct S3 access using temporary credentials from IAM Roles Anywhere

    // Create Lambda Layer with aws_signing_helper binary
    // The binary is pre-downloaded in lambda/signing-helper-layer/bin/
    const signingHelperLayer = new lambda.LayerVersion(this, 'SigningHelperLayer', {
      code: lambda.Code.fromAsset('lambda/signing-helper-layer'),
      compatibleRuntimes: [lambda.Runtime.NODEJS_20_X],
      description: 'AWS IAM Roles Anywhere signing helper binary',
    });

    // Create Sync Lambda function (no VPC needed)
    // Configuration verified for THF → FRA unidirectional synchronization:
    // - REMOTE_ROLE_ARN points to FRA account
    // - REMOTE_REGION is eu-central-1 (FRA)
    // - REMOTE_BUCKET points to FRA bucket
    // - REMOTE_TRUST_ANCHOR_ARN and REMOTE_PROFILE_ARN will be updated by deployment scripts
    const syncLambda = new lambda.Function(this, 'SyncLambda', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromAsset('lambda/sync-handler/dist'),
      role: syncLambdaRole,
      layers: [signingHelperLayer],
      timeout: cdk.Duration.seconds(60),
      memorySize: 256,
      environment: {
        LOCAL_BUCKET: this.bucket.bucketName,
        REMOTE_BUCKET: `fra-counter-bucket-${config.remoteAccountId}`, // Placeholder - update with actual bucket name
        REMOTE_ROLE_ARN: `arn:aws:iam::${config.remoteAccountId}:role/FraRolesAnywhereS3WriteRole`, // Role in remote (FRA) account
        REMOTE_PROFILE_ARN: 'PLACEHOLDER-UPDATE-AFTER-FRA-DEPLOYMENT', // Will be provided by FRA stack output
        REMOTE_TRUST_ANCHOR_ARN: 'PLACEHOLDER-UPDATE-AFTER-FRA-DEPLOYMENT', // Will be provided by FRA stack output
        REGION_CODE: config.regionCode,
        REMOTE_REGION: config.remoteRegion,
        CERTIFICATE_SECRET_NAME: 'ThfSyncLambdaCertificate',
        AWS_SIGNING_HELPER_PATH: '/opt/bin/aws_signing_helper',
      },
      description: `Sync Lambda for ${config.regionName} (${config.regionCode}) using IAM Roles Anywhere`,
    });

    // Connect S3 event notification to Sync Lambda
    // Trigger on PUT operations for counter objects
    this.bucket.addEventNotification(
      s3.EventType.OBJECT_CREATED_PUT,
      new s3n.LambdaDestination(syncLambda),
      {
        prefix: 'counter-',
        suffix: '.json',
      }
    );

    // Export Sync Lambda role ARN for cross-account trust policy
    new cdk.CfnOutput(this, 'SyncLambdaRoleArn', {
      value: syncLambdaRole.roleArn,
      description: 'ARN of the Sync Lambda execution role',
      exportName: 'ThfSyncLambdaRoleArn',
    });

    // Create REST API Gateway for triggering Sync Lambda from FRA S3 events
    const syncApiGateway = new apigateway.RestApi(this, 'ThfSyncApiGateway', {
      restApiName: `${config.regionCode}-Sync-API`,
      description: `API Gateway for triggering ${config.regionName} Sync Lambda from remote partition`,
      endpointConfiguration: {
        types: [apigateway.EndpointType.REGIONAL],
      },
      deployOptions: {
        stageName: 'prod',
        loggingLevel: apigateway.MethodLoggingLevel.INFO,
        dataTraceEnabled: true,
        metricsEnabled: true,
      },
      defaultCorsPreflightOptions: {
        allowOrigins: apigateway.Cors.ALL_ORIGINS,
        allowMethods: ['POST'],
        allowHeaders: ['Content-Type', 'Authorization', 'x-api-key'],
      },
      cloudWatchRole: true,
    });

    // Create API Key for cross-partition authentication
    // Since IAM doesn't work across aws and aws-eusc partitions, we use API Key
    const syncApiKey = new apigateway.ApiKey(this, 'ThfSyncApiKey', {
      apiKeyName: `${config.regionCode}-Sync-API-Key`,
      description: 'API Key for FRA Forwarder Lambda to authenticate with THF Sync API Gateway',
      enabled: true,
    });

    // Create Usage Plan
    const syncUsagePlan = new apigateway.UsagePlan(this, 'ThfSyncUsagePlan', {
      name: `${config.regionCode}-Sync-Usage-Plan`,
      description: 'Usage plan for THF Sync API Gateway',
      apiStages: [
        {
          api: syncApiGateway,
          stage: syncApiGateway.deploymentStage,
        },
      ],
      throttle: {
        rateLimit: 100,
        burstLimit: 200,
      },
    });

    // Associate API Key with Usage Plan
    syncUsagePlan.addApiKey(syncApiKey);

    // Configure POST endpoint to trigger Sync Lambda with API Key requirement
    const syncLambdaIntegration = new apigateway.LambdaIntegration(syncLambda, {
      proxy: true,
      integrationResponses: [
        {
          statusCode: '200',
        },
      ],
    });

    syncApiGateway.root.addMethod('POST', syncLambdaIntegration, {
      apiKeyRequired: true,
      methodResponses: [
        {
          statusCode: '200',
          responseParameters: {
            'method.response.header.Content-Type': true,
          },
        },
      ],
    });

    // Export API Key value for FRA Forwarder Lambda
    new cdk.CfnOutput(this, 'SyncApiKeyValue', {
      value: syncApiKey.keyId,
      description: 'API Key ID for THF Sync API Gateway (retrieve value from console)',
      exportName: 'ThfSyncApiKeyId',
    });

    // Export Sync API Gateway URL for FRA S3 event notification
    new cdk.CfnOutput(this, 'SyncApiGatewayUrl', {
      value: syncApiGateway.url,
      description: 'API Gateway endpoint URL for triggering Sync Lambda',
      exportName: 'ThfSyncApiGatewayUrl',
    });

    // Export Sync API Gateway ID for reference
    new cdk.CfnOutput(this, 'SyncApiGatewayId', {
      value: syncApiGateway.restApiId,
      description: 'API Gateway ID for Sync Lambda trigger',
      exportName: 'ThfSyncApiGatewayId',
    });
  }
}
