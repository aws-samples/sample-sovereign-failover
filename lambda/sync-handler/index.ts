import { S3Event, APIGatewayProxyEvent, APIGatewayProxyResult } from 'aws-lambda';
import { S3Client, GetObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { getCredentialsFromRolesAnywhere, RolesAnywhereCredentials } from './credential-helper';

// Environment variables
const LOCAL_BUCKET = process.env.LOCAL_BUCKET || '';
const REMOTE_BUCKET = process.env.REMOTE_BUCKET || '';
const REMOTE_ROLE_ARN = process.env.REMOTE_ROLE_ARN || '';
const REMOTE_PROFILE_ARN = process.env.REMOTE_PROFILE_ARN || '';
const REMOTE_TRUST_ANCHOR_ARN = process.env.REMOTE_TRUST_ANCHOR_ARN || '';
const REGION_CODE = process.env.REGION_CODE || '';
const REMOTE_REGION = process.env.REMOTE_REGION || '';
const CERTIFICATE_SECRET_NAME = process.env.CERTIFICATE_SECRET_NAME || '';

// AWS clients
const s3Client = new S3Client({});
const secretsClient = new SecretsManagerClient({});

// Cache for certificate and credentials
let certificateCache: {
  certificate: string;
  privateKey: string;
  certificateChain: string;
} | null = null;

let credentialsCache: {
  credentials: RolesAnywhereCredentials;
  expiresAt: Date;
} | null = null;

/**
 * Retrieve certificate and private key from Secrets Manager
 */
async function getCertificate(): Promise<{
  certificate: string;
  privateKey: string;
  certificateChain: string;
}> {
  // Return cached certificate if available
  if (certificateCache) {
    console.log('Using cached certificate');
    return certificateCache;
  }

  console.log(`Retrieving certificate from Secrets Manager: ${CERTIFICATE_SECRET_NAME}`);
  
  const command = new GetSecretValueCommand({
    SecretId: CERTIFICATE_SECRET_NAME,
  });

  const response = await secretsClient.send(command);
  
  if (!response.SecretString) {
    throw new Error('Certificate secret is empty');
  }

  const secret = JSON.parse(response.SecretString);
  
  certificateCache = {
    certificate: secret.certificate,
    privateKey: secret.privateKey,
    certificateChain: secret.certificateChain,
  };

  console.log('Certificate retrieved successfully');
  return certificateCache;
}

/**
 * Get temporary credentials from IAM Roles Anywhere
 * Uses certificate-based authentication to obtain short-lived AWS credentials
 */
async function getTemporaryCredentials(): Promise<RolesAnywhereCredentials> {
  // Check if we have valid cached credentials
  if (credentialsCache) {
    const now = new Date();
    const expiresIn = credentialsCache.expiresAt.getTime() - now.getTime();
    
    // Refresh if credentials expire in less than 5 minutes
    if (expiresIn > 5 * 60 * 1000) {
      console.log('Using cached credentials');
      return credentialsCache.credentials;
    }
    
    console.log('Cached credentials expiring soon, refreshing...');
  }

  console.log('Obtaining temporary credentials via IAM Roles Anywhere');

  // Get certificate and private key
  const { certificate, privateKey, certificateChain } = await getCertificate();

  // Get credentials using IAM Roles Anywhere
  const credentials = await getCredentialsFromRolesAnywhere({
    trustAnchorArn: REMOTE_TRUST_ANCHOR_ARN,
    profileArn: REMOTE_PROFILE_ARN,
    roleArn: REMOTE_ROLE_ARN,
    certificate,
    privateKey,
    certificateChain,
  });

  // Cache credentials
  credentialsCache = {
    credentials,
    expiresAt: credentials.expiration,
  };

  console.log(`Credentials obtained, expire at: ${credentials.expiration.toISOString()}`);
  
  return credentials;
}

/**
 * Create S3 client with temporary credentials from IAM Roles Anywhere
 */
async function createRemoteS3Client(): Promise<S3Client> {
  console.log('Creating remote S3 client with IAM Roles Anywhere credentials');

  // Get temporary credentials using IAM Roles Anywhere
  const credentials = await getTemporaryCredentials();

  // Create S3 client for remote region with temporary credentials
  const remoteS3Client = new S3Client({
    region: REMOTE_REGION,
    credentials: {
      accessKeyId: credentials.accessKeyId,
      secretAccessKey: credentials.secretAccessKey,
      sessionToken: credentials.sessionToken,
    },
  });

  return remoteS3Client;
}

/**
 * Sync a counter object from local bucket to remote bucket
 * @param key - S3 object key
 */
async function syncLocalToRemote(key: string): Promise<void> {
  try {
    // 1. Read object from local bucket
    console.log(`Reading object from local bucket: ${LOCAL_BUCKET}/${key}`);
    const getCommand = new GetObjectCommand({
      Bucket: LOCAL_BUCKET,
      Key: key,
    });
    
    const localObject = await s3Client.send(getCommand);
    
    if (!localObject.Body) {
      console.error(`No body found for object: ${key}`);
      return;
    }
    
    // 2. Convert body to buffer
    const bodyBytes = await localObject.Body.transformToByteArray();
    
    // 3. Create remote S3 client with IAM Roles Anywhere credentials
    const remoteS3Client = await createRemoteS3Client();
    
    // 4. Write object to remote bucket using temporary credentials
    console.log(`Writing object to remote bucket: ${REMOTE_BUCKET}/${key}`);
    console.log(`Using remote region: ${REMOTE_REGION}`);
    
    const putCommand = new PutObjectCommand({
      Bucket: REMOTE_BUCKET,
      Key: key,
      Body: bodyBytes,
      ContentType: localObject.ContentType || 'application/json',
    });
    
    await remoteS3Client.send(putCommand);
    
    console.log(`Successfully synced ${key} to remote partition via IAM Roles Anywhere`);
  } catch (error) {
    console.error(`Error syncing object ${key}:`, error);
    // Log error but don't throw - we want to continue processing other objects
  }
}

/**
 * Sync a counter object from remote bucket to local bucket
 * Used when triggered by API Gateway (eu-central → eusc-de direction)
 * @param key - S3 object key
 */
async function syncRemoteToLocal(key: string): Promise<void> {
  try {
    // 1. Create remote S3 client with IAM Roles Anywhere credentials
    const remoteS3Client = await createRemoteS3Client();
    
    // 2. Read object from remote bucket
    console.log(`Reading object from remote bucket: ${REMOTE_BUCKET}/${key}`);
    const getCommand = new GetObjectCommand({
      Bucket: REMOTE_BUCKET,
      Key: key,
    });
    
    const remoteObject = await remoteS3Client.send(getCommand);
    
    if (!remoteObject.Body) {
      console.error(`No body found for object: ${key}`);
      return;
    }
    
    // 3. Convert body to buffer
    const bodyBytes = await remoteObject.Body.transformToByteArray();
    
    // 4. Write object to local bucket
    console.log(`Writing object to local bucket: ${LOCAL_BUCKET}/${key}`);
    
    const putCommand = new PutObjectCommand({
      Bucket: LOCAL_BUCKET,
      Key: key,
      Body: bodyBytes,
      ContentType: remoteObject.ContentType || 'application/json',
    });
    
    await s3Client.send(putCommand);
    
    console.log(`Successfully synced ${key} from remote partition to local bucket`);
  } catch (error) {
    console.error(`Error syncing object ${key} from remote:`, error);
    // Log error but don't throw - we want to continue processing other objects
  }
}

/**
 * Detect if the event is an S3 event
 */
function isS3Event(event: any): event is S3Event {
  return event.Records && event.Records[0] && event.Records[0].eventSource === 'aws:s3';
}

/**
 * Detect if the event is an API Gateway event
 */
function isApiGatewayEvent(event: any): event is APIGatewayProxyEvent {
  return event.requestContext && event.requestContext.requestId && event.httpMethod;
}

/**
 * Handle S3 event trigger (local → remote sync)
 * This is the existing eusc-de → eu-central flow
 */
async function handleS3Event(event: S3Event): Promise<void> {
  console.log('Processing S3 event trigger (local → remote sync)');
  
  // Process each S3 event record
  for (const record of event.Records) {
    try {
      // Extract bucket and key from event
      const bucket = record.s3.bucket.name;
      const key = decodeURIComponent(record.s3.object.key.replace(/\+/g, ' '));
      
      console.log(`Processing S3 event for: ${bucket}/${key}`);
      
      // Loop prevention: only sync objects matching our region code
      // eu-central Sync Lambda only syncs counter-eu-central.json
      // eusc-de Sync Lambda only syncs counter-eusc-de.json
      const expectedKey = `counter-${REGION_CODE}.json`;
      
      if (key !== expectedKey) {
        console.log(`Skipping ${key} - does not match expected key ${expectedKey}`);
        continue;
      }
      
      // Sync the object to remote partition via IAM Roles Anywhere
      await syncLocalToRemote(key);
    } catch (error) {
      console.error('Error processing S3 event record:', error);
      // Continue processing other records even if one fails
    }
  }
}

/**
 * Handle API Gateway event trigger (remote → local sync)
 * This is the new eu-central → eusc-de flow
 */
async function handleApiGatewayEvent(event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> {
  console.log('Processing API Gateway event trigger (remote → local sync)');
  
  try {
    // Parse the request body to get the S3 event details
    // The eu-central S3 bucket will send the S3 event as the request body
    let s3Event: S3Event;
    
    if (event.body) {
      s3Event = JSON.parse(event.body) as S3Event;
    } else {
      console.error('No body in API Gateway event');
      return {
        statusCode: 400,
        body: JSON.stringify({ error: 'Missing request body' }),
      };
    }
    
    // Process each S3 event record from the remote bucket
    for (const record of s3Event.Records) {
      try {
        const key = decodeURIComponent(record.s3.object.key.replace(/\+/g, ' '));
        
        console.log(`Processing remote S3 event for: ${key}`);
        
        // Loop prevention: only sync objects NOT matching our region code
        // eusc-de Sync Lambda should only sync counter-eu-central.json (from eu-central)
        // It should NOT sync counter-eusc-de.json (that would create a loop)
        const ourKey = `counter-${REGION_CODE}.json`;
        
        if (key === ourKey) {
          console.log(`Skipping ${key} - this is our own region's counter (would create loop)`);
          continue;
        }
        
        // Sync the object from remote partition to local bucket
        await syncRemoteToLocal(key);
      } catch (error) {
        console.error('Error processing remote S3 event record:', error);
        // Continue processing other records even if one fails
      }
    }
    
    return {
      statusCode: 200,
      body: JSON.stringify({ message: 'Sync completed successfully' }),
    };
  } catch (error) {
    console.error('Error handling API Gateway event:', error);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: 'Internal server error' }),
    };
  }
}

/**
 * Lambda handler for S3 event notifications and API Gateway triggers
 * Supports bidirectional synchronization:
 * - S3 event trigger: Read from local bucket, write to remote bucket (eusc-de → eu-central)
 * - API Gateway trigger: Read from remote bucket, write to local bucket (eu-central → eusc-de)
 * @param event - S3 event or API Gateway event
 */
export async function handler(event: S3Event | APIGatewayProxyEvent): Promise<void | APIGatewayProxyResult> {
  console.log('Sync Lambda invoked with event:', JSON.stringify(event, null, 2));
  
  // Validate environment variables
  if (!LOCAL_BUCKET || !REMOTE_BUCKET || !REGION_CODE || !REMOTE_REGION) {
    console.error('Missing required environment variables');
    console.error(`LOCAL_BUCKET: ${LOCAL_BUCKET}`);
    console.error(`REMOTE_BUCKET: ${REMOTE_BUCKET}`);
    console.error(`REGION_CODE: ${REGION_CODE}`);
    console.error(`REMOTE_REGION: ${REMOTE_REGION}`);
    
    if (isApiGatewayEvent(event)) {
      return {
        statusCode: 500,
        body: JSON.stringify({ error: 'Missing required environment variables' }),
      };
    }
    return;
  }

  if (!REMOTE_ROLE_ARN || !REMOTE_PROFILE_ARN || !REMOTE_TRUST_ANCHOR_ARN || !CERTIFICATE_SECRET_NAME) {
    console.error('Missing IAM Roles Anywhere configuration');
    console.error(`REMOTE_ROLE_ARN: ${REMOTE_ROLE_ARN}`);
    console.error(`REMOTE_PROFILE_ARN: ${REMOTE_PROFILE_ARN}`);
    console.error(`REMOTE_TRUST_ANCHOR_ARN: ${REMOTE_TRUST_ANCHOR_ARN}`);
    console.error(`CERTIFICATE_SECRET_NAME: ${CERTIFICATE_SECRET_NAME}`);
    
    if (isApiGatewayEvent(event)) {
      return {
        statusCode: 500,
        body: JSON.stringify({ error: 'Missing IAM Roles Anywhere configuration' }),
      };
    }
    return;
  }
  
  // Detect trigger type and route to appropriate handler
  if (isS3Event(event)) {
    console.log('Detected S3 event trigger');
    await handleS3Event(event);
  } else if (isApiGatewayEvent(event)) {
    console.log('Detected API Gateway event trigger');
    return await handleApiGatewayEvent(event);
  } else {
    console.error('Unknown event type:', event);
    return {
      statusCode: 400,
      body: JSON.stringify({ error: 'Unknown event type' }),
    };
  }
  
  console.log('Sync Lambda completed');
}
