@description('Location for all resources')
param location string = resourceGroup().location

@description('Hub subscription ID')
param hubSubscriptionId string

@description('Hub resource group name')
param hubResourceGroup string

@description('Hub storage account name')
param hubStorageAccountName string

@description('Hub Key Vault name')
param hubKeyVaultName string

@description('Scan types to run')
param scanTypes string = 'os,sca,fileinsight'

@description('Enable scanning on new VM creation')
param enableNewVmTrigger bool = true

@description('Enable scheduled scanning')
param enableScheduledScan bool = true

@description('Schedule for automated scans (cron format)')
param scheduleExpression string = '0 2 * * *'

var uniqueSuffix = uniqueString(resourceGroup().id)
var functionAppName = 'qualys-scan-${uniqueSuffix}'
var automationAccountName = 'qualys-automation-${uniqueSuffix}'
var storageAccountName = 'qualysfunc${uniqueSuffix}'
var appInsightsName = 'qualys-insights-${uniqueSuffix}'
var hostingPlanName = 'qualys-plan-${uniqueSuffix}'

resource functionStorage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_GRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Request_Source: 'rest'
  }
}

resource hostingPlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: hostingPlanName
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {}
}

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    publicNetworkAccess: 'Disabled'
    siteConfig: {
      pythonVersion: '3.12'
      http20Enabled: true
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${functionStorage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${functionStorage.listKeys().keys[0].value}'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'HUB_SUBSCRIPTION_ID'
          value: hubSubscriptionId
        }
        {
          name: 'HUB_RESOURCE_GROUP'
          value: hubResourceGroup
        }
        {
          name: 'HUB_STORAGE_ACCOUNT'
          value: hubStorageAccountName
        }
        {
          name: 'HUB_KEY_VAULT'
          value: hubKeyVaultName
        }
        {
          name: 'SCAN_TYPES'
          value: scanTypes
        }
        {
          name: 'AUTOMATION_ACCOUNT_NAME'
          value: automationAccountName
        }
      ]
    }
    httpsOnly: true
  }
}

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    encryption: {
      keySource: 'Microsoft.Automation'
    }
  }
}

resource scanRunbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'Invoke-QualysScan'
  location: location
  properties: {
    runbookType: 'PowerShell'
    logProgress: true
    logVerbose: false
    description: 'Executes Qualys QScanner on target VMs via Run Command'
    publishContentLink: {
      uri: 'about:blank'
    }
  }
}

resource eventGridTopic 'Microsoft.EventGrid/systemTopics@2023-12-15-preview' = if (enableNewVmTrigger) {
  name: 'qualys-vm-events-${uniqueSuffix}'
  location: 'global'
  properties: {
    source: subscription().id
    topicType: 'Microsoft.Resources.Subscriptions'
  }
}

resource vmEventSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2023-12-15-preview' = if (enableNewVmTrigger) {
  parent: eventGridTopic
  name: 'new-vm-trigger'
  properties: {
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        resourceId: '${functionApp.id}/functions/TriggerScan'
        maxEventsPerBatch: 1
        preferredBatchSizeInKilobytes: 64
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Resources.ResourceWriteSuccess'
      ]
      advancedFilters: [
        {
          key: 'data.resourceProvider'
          operatorType: 'StringEquals'
          values: ['Microsoft.Compute']
        }
        {
          key: 'data.operationName'
          operatorType: 'StringContains'
          values: ['Microsoft.Compute/virtualMachines/write']
        }
      ]
    }
    eventDeliverySchema: 'EventGridSchema'
  }
}

resource scanSchedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = if (enableScheduledScan) {
  parent: automationAccount
  name: 'daily-scan'
  properties: {
    frequency: 'Day'
    interval: 1
    startTime: dateTimeAdd(utcNow(), 'PT1H')
    timeZone: 'UTC'
  }
}

resource functionVmContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, functionApp.id, 'vm-contributor')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '9980e02c-c2be-4d73-94e8-173b1dc7cf3c')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource automationVmContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, automationAccount.id, 'vm-contributor')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '9980e02c-c2be-4d73-94e8-173b1dc7cf3c')
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output functionAppName string = functionApp.name
output functionAppPrincipalId string = functionApp.identity.principalId
output automationAccountName string = automationAccount.name
output automationAccountPrincipalId string = automationAccount.identity.principalId
