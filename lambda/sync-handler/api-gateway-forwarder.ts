import { S3Event } from 'aws-lambda';
import https from 'https';
import http from 'http';

// Environment variables
const THF_SYNC_API_URL = process.env.THF_SYNC_API_URL || '';
const THF_SYNC_API_KEY = process.env.THF_SYNC_API_KEY || '';
const REGION_CODE = process.env.REGION_CODE || '';

/**
 * Forward S3 event to THF Sync API Gateway
 * This Lambda is triggered by FRA S3 bucket events and forwards them to THF
 * Uses API Key authentication since IAM doesn't work across aws and aws-eusc partitions
 * @param event - S3 event from FRA bucket
 */
export async function handler(event: S3Event): Promise<void> {
  console.log('API Gateway Forwarder invoked with event:', JSON.stringify(event, null, 2));
  
  // Validate environment variables
  if (!THF_SYNC_API_URL) {
    console.error('Missing THF_SYNC_API_URL environment variable');
    return;
  }
  
  if (!THF_SYNC_API_KEY) {
    console.error('Missing THF_SYNC_API_KEY environment variable');
    return;
  }
  
  if (!REGION_CODE) {
    console.error('Missing REGION_CODE environment variable');
    return;
  }
  
  // Loop prevention: only forward events for our region's counter
  // FRA forwarder only forwards counter-FRA.json events
  for (const record of event.Records) {
    const key = decodeURIComponent(record.s3.object.key.replace(/\+/g, ' '));
    const expectedKey = `counter-${REGION_CODE}.json`;
    
    if (key !== expectedKey) {
      console.log(`Skipping ${key} - does not match expected key ${expectedKey}`);
      continue;
    }
  }
  
  // Forward the S3 event to THF Sync API Gateway
  try {
    await forwardToApiGateway(event);
    console.log('Successfully forwarded S3 event to THF Sync API Gateway');
  } catch (error) {
    console.error('Error forwarding S3 event to THF Sync API Gateway:', error);
    throw error; // Throw to trigger Lambda retry
  }
}

/**
 * Make HTTP POST request to THF Sync API Gateway with API Key authentication
 * @param event - S3 event to forward
 */
async function forwardToApiGateway(event: S3Event): Promise<void> {
  return new Promise((resolve, reject) => {
    const url = new URL(THF_SYNC_API_URL);
    const postData = JSON.stringify(event);
    
    const options = {
      hostname: url.hostname,
      port: url.port || (url.protocol === 'https:' ? 443 : 80),
      path: url.pathname + url.search,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData),
        'x-api-key': THF_SYNC_API_KEY,
      },
    };
    
    const client = url.protocol === 'https:' ? https : http;
    
    const req = client.request(options, (res) => {
      let responseBody = '';
      
      res.on('data', (chunk) => {
        responseBody += chunk;
      });
      
      res.on('end', () => {
        console.log(`API Gateway response status: ${res.statusCode}`);
        console.log(`API Gateway response body: ${responseBody}`);
        
        if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
          resolve();
        } else {
          reject(new Error(`API Gateway returned status ${res.statusCode}: ${responseBody}`));
        }
      });
    });
    
    req.on('error', (error) => {
      console.error('HTTP request error:', error);
      reject(error);
    });
    
    req.write(postData);
    req.end();
  });
}
