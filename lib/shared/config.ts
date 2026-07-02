import { StackConfig } from './types';

/**
 * Configuration for eu-central stack
 */
export const EU_CENTRAL_CONFIG: Omit<StackConfig, 'remoteAccountId'> = {
  regionName: 'eu-central',
  regionCode: 'eu-central',
  region: 'eu-central-1',
  remoteRegion: 'eusc-de-east-1',
};

/**
 * Configuration for eusc-de stack
 */
export const EUSC_DE_CONFIG: Omit<StackConfig, 'remoteAccountId'> = {
  regionName: 'eusc-de',
  regionCode: 'eusc-de',
  region: 'eusc-de-east-1',
  remoteRegion: 'eu-central-1',
};
