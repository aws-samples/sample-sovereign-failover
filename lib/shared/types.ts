/**
 * Shared type definitions for the Sovereign Failover Demo
 */

/**
 * Configuration for a CDK stack deployment
 */
export interface StackConfig {
  /** Human-readable region name (e.g., "eu-central" or "eusc-de") */
  regionName: string;
  
  /** Region code identifier (e.g., "eu-central" or "eusc-de") */
  regionCode: string;
  
  /** AWS region for deployment */
  region: string;
  
  /** AWS account ID of the remote partition */
  remoteAccountId: string;
  
  /** AWS region of the remote partition */
  remoteRegion: string;
}

/**
 * Counter object stored in S3
 */
export interface CounterObject {
  /** Current page load count */
  count: number;
  
  /** ISO 8601 timestamp of last update */
  lastUpdated: string;
}

/**
 * Environment variables for Page Handler Lambda
 */
export interface PageHandlerEnv {
  /** Region name for display */
  REGION_NAME: string;
  
  /** Region code (eu-central or eusc-de) */
  REGION_CODE: string;
  
  /** S3 bucket name for counters */
  BUCKET_NAME: string;
}

/**
 * Environment variables for Sync Lambda
 */
export interface SyncLambdaEnv {
  /** Local S3 bucket name */
  LOCAL_BUCKET: string;
  
  /** Remote S3 bucket name */
  REMOTE_BUCKET: string;
  
  /** ARN of cross-account role in remote partition */
  REMOTE_ROLE_ARN: string;
  
  /** Region code (eu-central or eusc-de) */
  REGION_CODE: string;
}
