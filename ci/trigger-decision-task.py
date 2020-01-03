import os
import slugid
import taskcluster
from cib import createTask, updateWorkerPool


workerManager = taskcluster.WorkerManager(taskcluster.optionsFromEnvironment())
queue = taskcluster.Queue(taskcluster.optionsFromEnvironment())


updateWorkerPool(
  workerManager = workerManager,
  configPath = 'ci/config/worker-pool/relops/decision.yaml',
  workerPoolId = 'relops/decision')
updateWorkerPool(
  workerManager = workerManager,
  configPath = 'ci/config/worker-pool/relops/win2019.yaml',
  workerPoolId = 'relops/win2019')
createTask(
  queue = queue,
  taskId = slugid.nice(),
  taskName = '00 :: decision task',
  taskDescription = 'determine which windows cloud images should be built, where they should be deployed and trigger appropriate build tasks for the same',
  provisioner = 'relops',
  workerType = 'decision',
  commands = [
    'echo task: $TASK_ID, sha: $GITHUB_HEAD_SHA'
  ]
)
print('info: task {} ({}: {}), created'.format(taskId, taskName, taskDescription))