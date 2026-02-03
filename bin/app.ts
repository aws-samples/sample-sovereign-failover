#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { FraStack } from '../lib/fra-stack';
import { ThfStack } from '../lib/thf-stack';
import { FRA_CONFIG, THF_CONFIG } from '../lib/shared/config';

const app = new cdk.App();

// Get remote account IDs from CDK context
const fraRemoteAccountId = app.node.tryGetContext('fraRemoteAccountId');
const thfRemoteAccountId = app.node.tryGetContext('thfRemoteAccountId');

// Validate required context parameters
if (!fraRemoteAccountId) {
  throw new Error(
    'Context parameter "fraRemoteAccountId" is required. ' +
    'Provide it via -c fraRemoteAccountId=<THF_ACCOUNT_ID>'
  );
}
if (!thfRemoteAccountId) {
  throw new Error(
    'Context parameter "thfRemoteAccountId" is required. ' +
    'Provide it via -c thfRemoteAccountId=<FRA_ACCOUNT_ID>'
  );
}

// Create FRA Stack
const fraStack = new FraStack(app, 'FraStack', {
  env: {
    region: FRA_CONFIG.region,
  },
  description: 'Frankfurt (FRA) stack for Sovereign Failover Demo',
  remoteAccountId: fraRemoteAccountId, // THF account ID
});

// Create THF Stack with cross-stack references from FRA
// Note: We need to manually pass the Customer Gateway ID since cross-region exports don't work
// The user will need to deploy FRA first, get the Customer Gateway ID from outputs, and pass it as context
const fraCustomerGatewayId = app.node.tryGetContext('fraCustomerGatewayId');

const thfStack = new ThfStack(app, 'ThfStack', {
  env: {
    region: THF_CONFIG.region,
  },
  description: 'Brandenburg (THF) stack for Sovereign Failover Demo',
  remoteAccountId: thfRemoteAccountId, // FRA account ID
  fraApiGatewayId: fraCustomerGatewayId ? fraStack.apiGateway.restApiId : undefined,
  fraCustomerGatewayId: fraCustomerGatewayId,
});

app.synth();
