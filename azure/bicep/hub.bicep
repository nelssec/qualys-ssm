// Qualys VM Scanner - Hub (Central Resources)
// Deploys: Storage Account + Key Vault for centralized credential and result storage

@description('Location for all resources')
param location string = resourceGroup().location

@description('Qualys POD identifier')
@allowed(['US1', 'US2', 'US3', 'US4', 'EU1', 'EU2', 'IN1', 'CA1', 'AE1', 'UK1', 'AU1'])
param qualysPod string = 'US2'

@secure()
@description('Qualys API access token')
param qualysAccessToken string

@description('Tenant IDs allowed to access hub resources (for cross-subscription access)')
param allowedTenantIds array = [subscription().tenantId]

@description('Result retention in days')
param resultRetentionDays int = 90

var uniqueSuffix = uniqueString(resourceGroup().id)
var storageAccountName = 'qualysscan${uniqueSuffix}'
var keyVaultName = 'qualys-hub-${uniqueSuffix}'

// Storage Account for scan results
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Blob service with lifecycle management
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

// Container for scan results
resource scansContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'scans'
  properties: {
    publicAccess: 'None'
  }
}

// Lifecycle management policy for result retention
resource lifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'ExpireResults'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob']
              prefixMatch: ['scans/']
            }
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: resultRetentionDays
                }
              }
            }
          }
        }
      ]
    }
  }
}

// Key Vault for Qualys credentials
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Store Qualys credentials as secrets
resource qualysPodSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'qualys-pod'
  properties: {
    value: qualysPod
  }
}

resource qualysTokenSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'qualys-access-token'
  properties: {
    value: qualysAccessToken
  }
}

// Outputs for spoke deployment
output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output scansContainerName string = scansContainer.name
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output hubSubscriptionId string = subscription().subscriptionId
output hubResourceGroup string = resourceGroup().name
