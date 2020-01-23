import json
import os
import re
import taskcluster
import urllib.request
import yaml
from azure.common.credentials import ServicePrincipalCredentials
from azure.mgmt.compute import ComputeManagementClient
from cib import updateWorkerPool
from datetime import datetime

taskclusterProductionOptions = { 'rootUrl': os.environ['TASKCLUSTER_PROXY_URL'] }
taskclusterProductionSecretsClient = taskcluster.Secrets(taskclusterProductionOptions)
secret = taskclusterProductionSecretsClient.get('project/relops/image-builder/dev')['secret']

taskclusterStagingOptions = {
  'rootUrl': 'https://stage.taskcluster.nonprod.cloudops.mozgcp.net',
  'credentials': {
    'clientId': 'project/relops/image-builder/dev',
    'accessToken': secret['accessToken']['staging']['relops']['image-builder']['dev']
  }
}
taskclusterStagingWorkerManagerClient = taskcluster.WorkerManager(taskclusterStagingOptions)

azureComputeManagementClient = ComputeManagementClient(
  ServicePrincipalCredentials(
    client_id = secret['azure']['id'],
    secret = secret['azure']['key'],
    tenant = secret['azure']['account']),
  secret['azure']['subscription'])


def getLatestImage(resourceGroup, key):
  pattern = re.compile('^{}-{}-([a-z0-9]{{7}})$'.format(resourceGroup.replace('rg-', ''), key))
  images = sorted([x for x in azureComputeManagementClient.images.list_by_resource_group(resourceGroup) if pattern.match(x.name)], key = lambda i: i.tags['diskImageCommitTime'], reverse=True)
  print('found {} {} images in {}'.format(len(images), key, resourceGroup))
  return images[0] if len(images) > 0 else None


def getLatestImageId(resourceGroup, key):
  image = getLatestImage(resourceGroup, key)
  return image.id if image is not None else None

commitSha = os.getenv('GITHUB_HEAD_SHA')
platform = os.getenv('platform')
key = os.getenv('key')
subscriptionId = 'dd0d4271-9b26-4c37-a025-1284a43a4385'
config = yaml.safe_load(urllib.request.urlopen('https://raw.githubusercontent.com/grenade/cloud-image-builder/{}/config/{}-{}.yaml'.format(commitSha, key, platform)).read().decode())
workerPool = {
  'minCapacity': config['manager']['pool']['capacity']['minimum'],
  'maxCapacity': config['manager']['pool']['capacity']['maximum'],
  'launchConfigs': list(filter(lambda x: x['storageProfile']['imageReference']['id'] is not None and x['location'] in config['manager']['pool']['locations'], map(lambda x: {
    'location': x['region'].lower().replace(' ', ''),
    'capacityPerInstance': 1,
    'subnetId': '/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Network/virtualNetworks/{}/subnets/{}'.format(subscriptionId, x['group'], x['group'].replace('rg-', 'vn-'), x['group'].replace('rg-', 'sn-')),
    'hardwareProfile': {
      'vmSize': x['machine']['format'].format(x['machine']['cpu'])
    },
    'storageProfile': {
      'imageReference': {
        'id': getLatestImageId(x['group'], key)
      },
      'osDisk': {
        'caching': 'ReadWrite',
        'createOption': 'FromImage',
        'managedDisk': {
          'storageAccountType': 'StandardSSD_LRS' if x['disk'][0]['variant'] == 'ssd' else 'Standard_LRS'
        },
        'osType': 'Windows'
      },
      'dataDisks': [
        {
          'lun': 0,
          'caching': 'ReadWrite',
          'createOption': 'Empty',
          'diskSizeGB': x['disk'][1]['size'],
          'managedDisk': {
            'storageAccountType': 'StandardSSD_LRS' if x['disk'][1]['variant'] == 'ssd' else 'Standard_LRS'
          }
        },
        {
          'lun': 1,
          'caching': 'ReadWrite',
          'createOption': 'Empty',
          'diskSizeGB': x['disk'][2]['size'],
          'managedDisk': {
            'storageAccountType': 'StandardSSD_LRS' if x['disk'][2]['variant'] == 'ssd' else 'Standard_LRS'
          }
        }
      ]
    },
    'tags': { t['name']: t['value'] for t in x['tag'] },
    'priority': 'Spot',
    'evictionPolicy': 'Deallocate',
    'billingProfile': {
      'maxPrice': -1
    },
    'workerConfig': {}
  }, config['target'])))
}

# create an artifact containing the worker pool config that can be used for manual worker manager updates in the taskcluster web ui
with open('../{}-{}.json'.format(platform, key), 'w') as file:
  json.dump(workerPool, file, indent = 2, sort_keys = True)

# update the staging worker manager with a complete worker pool config
firstTarget = next(x for x in config['target'] if x['region'].lower().replace(' ', '') in config['manager']['pool']['locations'])
occRevision = next(x for x in firstTarget['tag'] if x['name'] == 'sourceRevision')['value']

# https://firefox-ci-tc.services.mozilla.com/api/index/v1/task/project.relops.cloud-image-builder.azure.win10-64.latest/artifacts/public/unattend.xml
machineImages = filter(lambda x: x is not None, map(lambda x: getLatestImage(x['group'], key), config['target']))
machineImageBuildsDescription = list(map(lambda x: '  - {} {}'.format(x.location, x.name), machineImages))
description = [
  '### experimental {} taskcluster worker'.format(config['manager']['pool']['id']),
  '#### provenance',
  '- operating system: **{}**'.format(config['image']['os']),
  '- os edition: **{}**'.format(config['image']['edition']),
  '- source iso: **{}**'.format(os.path.basename(config['iso']['source']['key'])),
  '- iso wim index: **{}** ({} {})'.format(config['iso']['wimindex'], config['image']['os'], config['image']['edition']),
  '- architecture: **{}**'.format(config['image']['architecture']),
  '- language: **{}**'.format(config['image']['language']),
  '- system timezone: **{}**'.format(config['image']['timezone']),
  '#### integration',
  '- disk image build: {} [{}]({})'.format('0000-00-00 00:00', '<task-id>', 'https://firefox-ci-tc.services.mozilla.com/tasks/index/project.relops.cloud-image-builder.{}.{}/latest/').format(platform, key),
  '- machine image builds:',
  '\n'.join(machineImageBuildsDescription),
  '- applied occ revision: [{}]({})'.format(occRevision[0:7], 'https://github.com/mozilla-releng/OpenCloudConfig/commit/{}'.format(occRevision)),
  '#### deployment',
  '- platform: **{} ({})**'.format(platform, ', '.join(config['manager']['pool']['locations'])),
  '- last staging worker pool update: {} [{}]({})'.format('{}'.format(datetime.utcnow().isoformat()[:-10].replace('T', ' ')), os.getenv('TASK_ID'), 'https://firefox-ci-tc.services.mozilla.com/tasks/{}#artifacts'.format(os.getenv('TASK_ID')))
]

providerConfig = {
  'description': '\n'.join(description),
  'owner': config['manager']['pool']['owner'],
  'emailOnError': True,
  'providerId': config['manager']['pool']['provider'],
  'config': workerPool
}
configPath = '../{}-{}.yaml'.format(platform, key)
with open(configPath, 'w') as file:
  yaml.dump(providerConfig, file, default_flow_style=False)
  updateWorkerPool(
    workerManager = taskclusterStagingWorkerManagerClient,
    configPath = configPath,
    workerPoolId = config['manager']['pool']['id'])