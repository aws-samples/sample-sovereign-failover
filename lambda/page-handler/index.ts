import { APIGatewayProxyEvent, APIGatewayProxyResult } from 'aws-lambda';
import { S3Client, GetObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';

const s3Client = new S3Client({});

const REGION_NAME = process.env.REGION_NAME || 'Unknown';
const REGION_CODE = process.env.REGION_CODE || 'UNK';
const BUCKET_NAME = process.env.BUCKET_NAME || '';

// Determine remote region code
const REMOTE_REGION_CODE = REGION_CODE === 'FRA' ? 'THF' : 'FRA';

interface CounterObject {
  count: number;
  lastUpdated: string;
}

/**
 * Read counter value from S3
 * @param regionCode - Region code (FRA or THF)
 * @returns Counter value, or 0 if not found
 */
async function readCounter(regionCode: string): Promise<number> {
  try {
    const command = new GetObjectCommand({
      Bucket: BUCKET_NAME,
      Key: `counter-${regionCode}.json`,
    });
    
    const response = await s3Client.send(command);
    
    if (!response.Body) {
      return 0;
    }
    
    const bodyString = await response.Body.transformToString();
    const data: CounterObject = JSON.parse(bodyString);
    
    return data.count || 0;
  } catch (error: any) {
    // Handle NoSuchKey error - counter doesn't exist yet
    if (error.name === 'NoSuchKey' || error.Code === 'NoSuchKey') {
      return 0;
    }
    
    console.error(`Error reading counter for ${regionCode}:`, error);
    throw error;
  }
}

/**
 * Write counter value to S3
 * @param regionCode - Region code (FRA or THF)
 * @param count - Counter value to write
 */
async function writeCounter(regionCode: string, count: number): Promise<void> {
  const counterObject: CounterObject = {
    count,
    lastUpdated: new Date().toISOString(),
  };
  
  const command = new PutObjectCommand({
    Bucket: BUCKET_NAME,
    Key: `counter-${regionCode}.json`,
    Body: JSON.stringify(counterObject),
    ContentType: 'application/json',
  });
  
  await s3Client.send(command);
}

/**
 * Generate HTML page with region information and counters
 * @param params - Parameters for HTML generation
 * @returns HTML string
 */
function generateHTML(params: {
  regionName: string;
  localCounter: number;
  remoteCounter: number;
}): string {
  const { regionName, localCounter, remoteCounter } = params;
  
  // Determine which counter is FRA and which is THF
  const fraCounter = REGION_CODE === 'FRA' ? localCounter : remoteCounter;
  const thfCounter = REGION_CODE === 'THF' ? localCounter : remoteCounter;
  
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Sovereign Failover Demo - ${regionName}</title>
  <style>
    /* AWS Brand Colors */
    :root {
      --aws-orange: #FF9900;
      --aws-dark: #232F3E;
      --aws-light: #FFFFFF;
    }
    
    body {
      font-family: 'Amazon Ember', Arial, sans-serif;
      background: linear-gradient(135deg, var(--aws-dark) 0%, #1a2332 100%);
      color: var(--aws-light);
      margin: 0;
      padding: 20px;
      min-height: 100vh;
      display: flex;
      justify-content: center;
      align-items: center;
    }
    
    .container {
      max-width: 800px;
      background: rgba(255, 255, 255, 0.05);
      border-radius: 12px;
      padding: 40px;
      box-shadow: 0 8px 32px rgba(0, 0, 0, 0.3);
    }
    
    h1 {
      color: var(--aws-orange);
      margin-bottom: 10px;
    }
    
    .counter-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 20px;
      margin-top: 30px;
    }
    
    .counter-card {
      background: rgba(255, 255, 255, 0.08);
      border-radius: 8px;
      padding: 20px;
      text-align: center;
    }
    
    .counter-value {
      font-size: 48px;
      font-weight: bold;
      color: var(--aws-orange);
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>AWS Sovereign Failover Demo</h1>
    <h2>Currently serving from: ${regionName}</h2>
    
    <div class="counter-grid">
      <div class="counter-card">
        <h3>Frankfurt (FRA)</h3>
        <div class="counter-value">${fraCounter}</div>
        <p>Page Loads</p>
      </div>
      
      <div class="counter-card">
        <h3>Brandenburg (THF)</h3>
        <div class="counter-value">${thfCounter}</div>
        <p>Page Loads</p>
      </div>
    </div>
    
    <p style="margin-top: 30px; text-align: center; opacity: 0.7;">
      This demo showcases AWS European Sovereign Cloud failover capabilities
    </p>
  </div>
</body>
</html>`;
}

/**
 * Lambda handler for API Gateway requests
 * @param event - API Gateway proxy event
 * @returns API Gateway proxy result with HTML page
 */
export async function handler(event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> {
  try {
    // 1. Read local counter for current region
    const localCounter = await readCounter(REGION_CODE);
    
    // 2. Read remote counter from local bucket (synced via Sync Lambda)
    const remoteCounter = await readCounter(REMOTE_REGION_CODE);
    
    // 3. Increment local counter
    const newLocalCounter = localCounter + 1;
    
    // 4. Write updated counter back to S3
    await writeCounter(REGION_CODE, newLocalCounter);
    
    // 5. Generate HTML page
    const html = generateHTML({
      regionName: REGION_NAME,
      localCounter: newLocalCounter,
      remoteCounter: remoteCounter,
    });
    
    return {
      statusCode: 200,
      headers: {
        'Content-Type': 'text/html',
      },
      body: html,
    };
  } catch (error) {
    console.error('Error processing request:', error);
    
    return {
      statusCode: 500,
      headers: {
        'Content-Type': 'text/plain',
      },
      body: 'Internal Server Error',
    };
  }
}
