/**
 * IAM Roles Anywhere Credential Helper
 * 
 * This module implements credential retrieval from IAM Roles Anywhere
 * using X.509 certificates for cross-partition authentication.
 * 
 * Note: This is a simplified implementation. In production, you would use
 * the official aws_signing_helper tool or implement the full CreateSession
 * API call with proper X.509 certificate signing.
 */

import { execSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

export interface RolesAnywhereCredentials {
  accessKeyId: string;
  secretAccessKey: string;
  sessionToken: string;
  expiration: Date;
}

export interface RolesAnywhereConfig {
  trustAnchorArn: string;
  profileArn: string;
  roleArn: string;
  certificate: string;
  privateKey: string;
  certificateChain: string;
}

/**
 * Get temporary credentials from IAM Roles Anywhere using X.509 certificate
 * 
 * This function uses the aws_signing_helper tool to obtain temporary credentials.
 * The helper tool handles the complex X.509 certificate signing process required
 * by IAM Roles Anywhere.
 * 
 * @param config - IAM Roles Anywhere configuration
 * @returns Temporary AWS credentials
 */
export async function getCredentialsFromRolesAnywhere(
  config: RolesAnywhereConfig
): Promise<RolesAnywhereCredentials> {
  // Create temporary directory for certificate files
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'roles-anywhere-'));
  
  try {
    // Write certificate files to temporary directory
    const certPath = path.join(tempDir, 'certificate.pem');
    const keyPath = path.join(tempDir, 'private-key.pem');
    const chainPath = path.join(tempDir, 'certificate-chain.pem');
    
    fs.writeFileSync(certPath, config.certificate);
    fs.writeFileSync(keyPath, config.privateKey);
    fs.writeFileSync(chainPath, config.certificateChain);
    
    // Set restrictive permissions on private key
    fs.chmodSync(keyPath, 0o400);
    
    // Call aws_signing_helper to get credentials
    // The helper tool is expected to be in /opt/aws_signing_helper (Lambda layer)
    // or in the PATH
    const helperPath = process.env.AWS_SIGNING_HELPER_PATH || 'aws_signing_helper';
    
    const command = [
      helperPath,
      'credential-process',
      '--certificate', certPath,
      '--private-key', keyPath,
      '--trust-anchor-arn', config.trustAnchorArn,
      '--profile-arn', config.profileArn,
      '--role-arn', config.roleArn,
    ].join(' ');
    
    console.log('Calling aws_signing_helper for credentials...');
    
    // Execute the helper tool
    const output = execSync(command, {
      encoding: 'utf-8',
      maxBuffer: 10 * 1024 * 1024, // 10MB buffer
    });
    
    // Parse the credential process output
    // Format: https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sourcing-external.html
    const credentials = JSON.parse(output);
    
    return {
      accessKeyId: credentials.AccessKeyId,
      secretAccessKey: credentials.SecretAccessKey,
      sessionToken: credentials.SessionToken,
      expiration: new Date(credentials.Expiration),
    };
  } finally {
    // Clean up temporary files
    try {
      fs.rmSync(tempDir, { recursive: true, force: true });
    } catch (error) {
      console.warn('Failed to clean up temporary directory:', error);
    }
  }
}
