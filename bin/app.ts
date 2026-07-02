#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { EuCentralStack } from '../lib/eu-central-stack';
import { EuscDeStack } from '../lib/eusc-de-stack';
import { EU_CENTRAL_CONFIG, EUSC_DE_CONFIG } from '../lib/shared/config';

const app = new cdk.App();

// Get remote account IDs from CDK context
const euCentralRemoteAccountId = app.node.tryGetContext('euCentralRemoteAccountId');
const euscDeRemoteAccountId = app.node.tryGetContext('euscDeRemoteAccountId');

// Validate required context parameters
if (!euCentralRemoteAccountId) {
  throw new Error(
    'Context parameter "euCentralRemoteAccountId" is required. ' +
    'Provide it via -c euCentralRemoteAccountId=<EUSC_DE_ACCOUNT_ID>'
  );
}
if (!euscDeRemoteAccountId) {
  throw new Error(
    'Context parameter "euscDeRemoteAccountId" is required. ' +
    'Provide it via -c euscDeRemoteAccountId=<EU_CENTRAL_ACCOUNT_ID>'
  );
}

// Create eu-central Stack
const euCentralStack = new EuCentralStack(app, 'eu-central-stack', {
  env: {
    region: EU_CENTRAL_CONFIG.region,
  },
  description: 'eu-central stack for Sovereign Failover Demo',
  remoteAccountId: euCentralRemoteAccountId, // eusc-de account ID
});

// Create eusc-de Stack with cross-stack references from eu-central
// Note: We need to manually pass the Customer Gateway ID since cross-region exports don't work
// The user will need to deploy eu-central first, get the Customer Gateway ID from outputs, and pass it as context
const euCentralCustomerGatewayId = app.node.tryGetContext('euCentralCustomerGatewayId');

const euscDeStack = new EuscDeStack(app, 'eusc-de-stack', {
  env: {
    region: EUSC_DE_CONFIG.region,
  },
  description: 'eusc-de stack for Sovereign Failover Demo',
  remoteAccountId: euscDeRemoteAccountId, // eu-central account ID
  euCentralApiGatewayId: euCentralCustomerGatewayId ? euCentralStack.apiGateway.restApiId : undefined,
  euCentralCustomerGatewayId: euCentralCustomerGatewayId,
});

app.synth();
