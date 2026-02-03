import { StackConfig } from './types';

/**
 * Configuration for Frankfurt (FRA) stack
 */
export const FRA_CONFIG: Omit<StackConfig, 'remoteAccountId'> = {
  regionName: 'Frankfurt',
  regionCode: 'FRA',
  region: 'eu-central-1',
  remoteRegion: 'eusc-de-east-1',
};

/**
 * Configuration for Brandenburg (THF) stack
 */
export const THF_CONFIG: Omit<StackConfig, 'remoteAccountId'> = {
  regionName: 'Brandenburg',
  regionCode: 'THF',
  region: 'eusc-de-east-1',
  remoteRegion: 'eu-central-1',
};
