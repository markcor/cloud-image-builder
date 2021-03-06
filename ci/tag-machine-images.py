import json
import os
import re
import requests
import taskcluster
import urllib.error
import urllib.request
import yaml
from azure.common.credentials import ServicePrincipalCredentials
from azure.mgmt.compute import ComputeManagementClient

from cachetools import cached, TTLCache
cache = TTLCache(maxsize=100, ttl=300)


@cached(cache)
def get_commit(revision):
  try:
    response = urllib.request.urlopen('https://api.github.com/repos/mozilla-platform-ops/cloud-image-builder/commits/{}'.format(revision))
  except urllib.error.HTTPError as e:
    print(e.code)
    print(e.read())
    exit(123 if e.code == 403 else 1)
  return json.loads(response.read().decode())


secretsClient = taskcluster.Secrets({ 'rootUrl': os.environ['TASKCLUSTER_PROXY_URL'] })
secret = secretsClient.get('project/relops/image-builder/dev')['secret']

platform = os.getenv('platform')
group = os.getenv('group')
key = os.getenv('key')

print('platform: {}'.format(platform))
print('group: {}'.format(group))
print('key: {}'.format(key))

if platform == 'azure':
  azureComputeManagementClient = ComputeManagementClient(
    ServicePrincipalCredentials(
      client_id = secret['azure']['id'],
      secret = secret['azure']['key'],
      tenant = secret['azure']['account']),
    secret['azure']['subscription'])

  pattern = re.compile('^{}-{}-([a-z0-9]{{7}})-([a-z0-9]{{7}})$'.format(group.replace('rg-', ''), key))
  images = [x for x in azureComputeManagementClient.images.list_by_resource_group(group) if pattern.match(x.name)]
  for image in images:
    revision = pattern.search(image.name).group(1)
    commit = get_commit(revision)
    print('image: {}, has revision: {}'.format(image.name, revision))
    if image.tags:
      print(', '.join(['%s:: %s' % (key, value) for (key, value) in image.tags.items()]))
    else:
      print('image has no tags. adding tags...')
      configUrl = 'https://raw.githubusercontent.com/mozilla-platform-ops/cloud-image-builder/{}/config/{}.yaml'.format(revision, key)
      if requests.head(configUrl).status_code == requests.codes.ok:
        config = yaml.safe_load(urllib.request.urlopen(configUrl).read().decode())
        image.tags = {
          'diskImageCommitDate': commit['commit']['committer']['date'][0:10],
          'diskImageCommitTime': commit['commit']['committer']['date'],
          'diskImageCommitSha': commit['sha'],
          'diskImageCommitMessage': commit['commit']['message'],
          'isoName': os.path.basename(config['iso']['source']['key']),
          'isoIndex': config['iso']['wimindex'],
          'os': config['image']['os'],
          'edition': config['image']['edition'],
          'language': config['image']['language'],
          'architecture': config['image']['architecture']
        }
      else:
        image.tags = {
          'diskImageCommitDate': commit['commit']['committer']['date'][0:10],
          'diskImageCommitTime': commit['commit']['committer']['date'],
          'diskImageCommitSha': commit['sha'],
          'diskImageCommitMessage': commit['commit']['message']
        }
      azureComputeManagementClient.images.create_or_update(group, image.name, image)
      print('image tags updated')
      print(', '.join(['%s:: %s' % (key, value) for (key, value) in image.tags.items()]))

  snapshots = [x for x in azureComputeManagementClient.snapshots.list_by_resource_group(group) if pattern.match(x.name)]
  for snapshot in snapshots:
    revision = pattern.search(snapshot.name).group(1)
    commit = get_commit(revision)
    print('snapshot: {}, has revision: {}'.format(snapshot.name, revision))
    if snapshot.tags:
      print(', '.join(['%s:: %s' % (key, value) for (key, value) in snapshot.tags.items()]))
    else:
      print('snapshot has no tags. adding tags...')
      configUrl = 'https://raw.githubusercontent.com/mozilla-platform-ops/cloud-image-builder/{}/config/{}.yaml'.format(revision, key)
      if requests.head(configUrl).status_code == requests.codes.ok:
        config = yaml.safe_load(urllib.request.urlopen(configUrl).read().decode())
        snapshot.tags = {
          'diskImageCommitDate': commit['commit']['committer']['date'][0:10],
          'diskImageCommitTime': commit['commit']['committer']['date'],
          'diskImageCommitSha': commit['sha'],
          'diskImageCommitMessage': commit['commit']['message'],
          'isoName': os.path.basename(config['iso']['source']['key']),
          'isoIndex': config['iso']['wimindex'],
          'os': config['image']['os'],
          'edition': config['image']['edition'],
          'language': config['image']['language'],
          'architecture': config['image']['architecture']
        }
      else:
        snapshot.tags = {
          'diskImageCommitDate': commit['commit']['committer']['date'][0:10],
          'diskImageCommitTime': commit['commit']['committer']['date'],
          'diskImageCommitSha': commit['sha'],
          'diskImageCommitMessage': commit['commit']['message']
        }
      azureComputeManagementClient.snapshots.create_or_update(group, snapshot.name, snapshot)
      print('snapshot tags updated')
      print(', '.join(['%s:: %s' % (key, value) for (key, value) in snapshot.tags.items()]))
else:
  print('skipped image tagging. not implemented for platform: {}'.format(platform))